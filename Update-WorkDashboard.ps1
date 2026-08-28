<#
  Update-WorkDashboard.ps1
  Fetches a 7-day forecast + heat/cold advisories (Open-Meteo), the nearest upcoming Korean
  holiday block (Nager.Date), Vietnam-area typhoon activity and history relative to the
  하노이/호치민 hubs (GDACS), crude oil + US lumber futures (Yahoo Finance), KCl monthly prices
  (World Bank Pink Sheet), the SCFI container freight index (Shanghai Shipping Exchange),
  optionally Korean pump prices (Opinet, needs $env:OPINET_API_KEY), and commodity news
  headlines (Google News RSS), then regenerates dashboard.html.
  Run manually by double-clicking run.bat, or right-click > Run with PowerShell.
#>

$ErrorActionPreference = "Stop"
$root = $PSScriptRoot
$headers = @{ "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36" }

$config = Get-Content -Path (Join-Path $root "config.json") -Raw -Encoding UTF8 | ConvertFrom-Json

# ConvertFrom-Json on pwsh 7 (the Linux Actions runner) turns a full ISO timestamp like
# "2026-07-04T18:00:00" into a [DateTime], while Windows PowerShell 5.1 leaves it a [string] -
# so calling .Substring() on it works locally and crashes in CI. Date-only strings such as
# "2026-08-28" stay strings on both. Normalize before formatting rather than assuming either.
function Format-DateOnly {
    param($value)
    if ($null -eq $value) { return "" }
    if ($value -is [DateTime]) { return $value.ToString("yyyy-MM-dd") }
    if ($value -is [DateTimeOffset]) { return $value.ToString("yyyy-MM-dd") }
    $s = [string]$value
    if ($s.Length -ge 10) { return $s.Substring(0, 10) }
    return $s
}

# --- Accumulated history store ------------------------------------------------------------
# Opinet only serves the last 7 days and SSE gates SCFI history behind a subscriber login, so
# neither can be charted over a year from a single call. Instead every run merges what it just
# fetched into data-history.json, which the workflow commits back - the series then grows on
# its own, and re-running is idempotent because points are keyed by date.
$historyPath = Join-Path $root "data-history.json"
$HISTORY_MAX_DAYS = 730

function Read-HistoryStore {
    if (-not (Test-Path $historyPath)) { return @{} }
    try {
        $raw = Get-Content -Path $historyPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $store = @{}
        foreach ($prop in $raw.PSObject.Properties) {
            $series = @{}
            foreach ($pt in $prop.Value.PSObject.Properties) { $series[$pt.Name] = $pt.Value }
            $store[$prop.Name] = $series
        }
        return $store
    } catch {
        Write-Warning "history store 읽기 실패, 새로 시작합니다: $($_.Exception.Message)"
        return @{}
    }
}

function Merge-HistorySeries {
    # $points: objects with .label (yyyy-MM-dd) and .value. Returns the merged series as a
    # sorted array of the same shape, so callers can chart the accumulated history directly.
    param($store, [string]$key, $points)

    if (-not $store.ContainsKey($key)) { $store[$key] = @{} }
    $series = $store[$key]
    foreach ($p in $points) {
        if ($null -eq $p -or -not $p.label) { continue }
        $series[[string]$p.label] = $p.value
    }

    $cutoff = (Get-Date).Date.AddDays(-$HISTORY_MAX_DAYS)
    $kept = @{}
    foreach ($k in $series.Keys) {
        [DateTime]$parsed = Get-Date
        if ([DateTime]::TryParse($k, [ref]$parsed) -and $parsed -ge $cutoff) { $kept[$k] = $series[$k] }
    }
    $store[$key] = $kept

    @($kept.Keys | Sort-Object | ForEach-Object {
        [PSCustomObject]@{ label = $_; value = $kept[$_] }
    })
}

function Write-HistoryStore {
    param($store)
    try {
        $ordered = [ordered]@{}
        foreach ($k in ($store.Keys | Sort-Object)) {
            $series = [ordered]@{}
            foreach ($d in ($store[$k].Keys | Sort-Object)) { $series[$d] = $store[$k][$d] }
            $ordered[$k] = $series
        }
        $json = ConvertTo-Json -InputObject $ordered -Depth 4
        $utf8NoBomLocal = New-Object System.Text.UTF8Encoding $false
        [System.IO.File]::WriteAllText($historyPath, $json, $utf8NoBomLocal)
        Write-Host "History store updated: $historyPath"
    } catch {
        Write-Warning "history store 저장 실패: $($_.Exception.Message)"
    }
}

# --- Weather ------------------------------------------------------------------------
# Switched from wttr.in to Open-Meteo: free, no key, and (unlike wttr.in's free tier, which
# caps at 3 days) supports a real week-ahead forecast in one call. Codes are WMO weather codes
# (0-99), a much smaller fixed set than wttr.in's WWO codes.
$weatherCodeKo = @{
    "0" = "맑음"; "1" = "대체로 맑음"; "2" = "부분 흐림"; "3" = "흐림"
    "45" = "안개"; "48" = "착빙 안개"
    "51" = "약한 이슬비"; "53" = "이슬비"; "55" = "강한 이슬비"
    "56" = "약한 착빙성 이슬비"; "57" = "강한 착빙성 이슬비"
    "61" = "약한 비"; "63" = "보통 비"; "65" = "강한 비"
    "66" = "약한 착빙성 비"; "67" = "강한 착빙성 비"
    "71" = "약한 눈"; "73" = "보통 눈"; "75" = "강한 눈"; "77" = "싸락눈"
    "80" = "약한 소나기"; "81" = "보통 소나기"; "82" = "강한 소나기"
    "85" = "약한 눈 소나기"; "86" = "강한 눈 소나기"
    "95" = "뇌우"; "96" = "우박 동반 뇌우"; "99" = "강한 우박 동반 뇌우"
}

function Get-WeatherDescKo {
    param($code)
    if ($weatherCodeKo.ContainsKey("$code")) { return $weatherCodeKo["$code"] }
    return "정보 없음"
}

# KMA(기상청) 특보 발표 기준을 단순화한 임계값 - 체감/최고기온 33도 이상은 폭염주의보,
# 35도 이상은 폭염경보 수준. 최저기온 -12도 이하는 한파주의보, -15도 이하는 한파경보 수준.
function Get-TempAdvisories {
    param($heatRefC, $minC)

    $advisories = @()
    if ($null -ne $heatRefC) {
        if ($heatRefC -ge 35) { $advisories += [PSCustomObject]@{ text = "폭염경보 수준 · 온열질환 각별 주의"; tone = "danger" } }
        elseif ($heatRefC -ge 33) { $advisories += [PSCustomObject]@{ text = "폭염주의보 수준 · 온열질환 주의"; tone = "warn" } }
    }
    if ($null -ne $minC) {
        if ($minC -le -15) { $advisories += [PSCustomObject]@{ text = "한파경보 수준 · 동파 등 각별 주의"; tone = "danger" } }
        elseif ($minC -le -12) { $advisories += [PSCustomObject]@{ text = "한파주의보 수준 · 대비 필요"; tone = "warn" } }
    }
    @($advisories)
}

function Get-WeatherSnapshot {
    param($loc)

    $uri = "https://api.open-meteo.com/v1/forecast?latitude=$($loc.Lat)&longitude=$($loc.Lon)" +
           "&daily=temperature_2m_max,temperature_2m_min,precipitation_probability_max,weathercode" +
           "&current=temperature_2m,relative_humidity_2m,apparent_temperature,weathercode" +
           "&timezone=Asia%2FSeoul&forecast_days=7"
    try {
        $resp = Invoke-RestMethod -Uri $uri -Headers $headers
        $cur = $resp.current
        $daily = $resp.daily

        $days = @(for ($i = 0; $i -lt $daily.time.Count; $i++) {
            $maxC = [int][math]::Round($daily.temperature_2m_max[$i])
            $minC = [int][math]::Round($daily.temperature_2m_min[$i])
            [PSCustomObject]@{
                date         = Format-DateOnly $daily.time[$i]
                maxC         = $maxC
                minC         = $minC
                desc         = Get-WeatherDescKo $daily.weathercode[$i]
                chanceOfRain = [int]$daily.precipitation_probability_max[$i]
                # @(...) at the call site (not just inside the function) matters here - without
                # it, a function whose output happens to be an empty collection collapses to
                # $null on capture, and ConvertTo-Json then renders that as {} instead of [],
                # which crashes the dashboard's advisories.map() in the browser.
                advisories   = @(Get-TempAdvisories -heatRefC $maxC -minC $minC)
            }
        })

        $curAdvisories = @(Get-TempAdvisories -heatRefC ([int][math]::Round($cur.apparent_temperature)) -minC $null)

        [PSCustomObject]@{
            id          = $loc.Id
            displayName = $loc.DisplayName
            country     = $loc.Country
            tempC       = [int][math]::Round($cur.temperature_2m)
            feelsLikeC  = [int][math]::Round($cur.apparent_temperature)
            humidity    = [int]$cur.relative_humidity_2m
            desc        = Get-WeatherDescKo $cur.weathercode
            advisories  = $curAdvisories
            days        = $days
        }
    } catch {
        Write-Warning "Weather fetch failed for '$($loc.DisplayName)': $($_.Exception.Message)"
        $null
    }
}

# --- Holidays -------------------------------------------------------------------------
function Get-HolidayBlock {
    # Merges KR public holidays (Nager.Date) with weekends into a set of non-working days,
    # then returns the nearest contiguous run (today or later) that contains at least one
    # actual public holiday - i.e. the soonest "연휴" (long weekend / holiday block), not just
    # an ordinary Saturday-Sunday.
    param($todayKst)

    try {
        $year = $todayKst.Year
        $holidays = @()
        foreach ($y in @($year, ($year + 1))) {
            $uri = "https://date.nager.at/api/v3/PublicHolidays/$y/KR"
            $holidays += Invoke-RestMethod -Uri $uri -Headers $headers
        }

        $today = $todayKst.Date
        $horizon = $today.AddDays(365)
        $holidayByDate = @{}
        foreach ($h in $holidays) {
            $d = [DateTime]::Parse($h.date)
            if ($d -ge $today -and $d -le $horizon) { $holidayByDate[$d.ToString("yyyy-MM-dd")] = $h.localName }
        }

        $offDates = New-Object System.Collections.Generic.List[DateTime]
        for ($d = $today; $d -le $horizon; $d = $d.AddDays(1)) {
            $isWeekend = ($d.DayOfWeek -eq [DayOfWeek]::Saturday) -or ($d.DayOfWeek -eq [DayOfWeek]::Sunday)
            $isHoliday = $holidayByDate.ContainsKey($d.ToString("yyyy-MM-dd"))
            if ($isWeekend -or $isHoliday) { $offDates.Add($d) }
        }
        if ($offDates.Count -eq 0) { return $null }

        # group into consecutive runs
        $runs = New-Object System.Collections.Generic.List[object]
        $runStart = $offDates[0]
        $runEnd = $offDates[0]
        for ($i = 1; $i -lt $offDates.Count; $i++) {
            if (($offDates[$i] - $runEnd).Days -eq 1) {
                $runEnd = $offDates[$i]
            } else {
                $runs.Add([PSCustomObject]@{ Start = $runStart; End = $runEnd })
                $runStart = $offDates[$i]; $runEnd = $offDates[$i]
            }
        }
        $runs.Add([PSCustomObject]@{ Start = $runStart; End = $runEnd })

        $target = $runs | Where-Object {
            $r = $_
            $hasHoliday = $false
            for ($d = $r.Start; $d -le $r.End; $d = $d.AddDays(1)) {
                if ($holidayByDate.ContainsKey($d.ToString("yyyy-MM-dd"))) { $hasHoliday = $true; break }
            }
            $hasHoliday
        } | Select-Object -First 1
        if (-not $target) { return $null }

        $namesInRun = @()
        for ($d = $target.Start; $d -le $target.End; $d = $d.AddDays(1)) {
            $name = $holidayByDate[$d.ToString("yyyy-MM-dd")]
            if ($name) { $namesInRun += $name }
        }

        $nextHolidays = @($holidayByDate.Keys | Sort-Object | Select-Object -First 6 | ForEach-Object {
            [PSCustomObject]@{ date = $_; name = $holidayByDate[$_] }
        })

        [PSCustomObject]@{
            startDate  = $target.Start.ToString("yyyy-MM-dd")
            endDate    = $target.End.ToString("yyyy-MM-dd")
            days       = ($target.End - $target.Start).Days + 1
            dDay       = ($target.Start - $today).Days
            holidayNames = @($namesInRun)
            nextHolidays = $nextHolidays
        }
    } catch {
        Write-Warning "Holiday fetch failed: $($_.Exception.Message)"
        $null
    }
}

# --- Vietnam typhoon watch ---------------------------------------------------------------
# Vietnam-sourced 부자재 shipments get delayed when a typhoon disrupts the route, so this
# tracks tropical cyclones against the shipping corridor rather than only Vietnam itself.
#
# The first version compared one point - GDACS's last known storm position - to 하노이/호치민
# and required <=800km or Vietnam in the affected-country list. That silently missed the
# August 2026 storms a Vietnamese supplier actually reported delays for: NOUL-26 crossed the
# South China Sea and passed 78km from Hong Kong/Shenzhen, while DOLPHIN-26 and SAUDEL-26 ran
# up the Taiwan side. None list Vietnam and all ended far from it, yet each disrupts the
# transshipment hubs Vietnam cargo moves through. So relevance is now judged on the storm's
# whole track (fetched per event) against both the Vietnam hubs and those transshipment ports.
function Get-HaversineKm {
    param([double]$lat1, [double]$lon1, [double]$lat2, [double]$lon2)
    $R = 6371.0
    $dLat = ($lat2 - $lat1) * [math]::PI / 180
    $dLon = ($lon2 - $lon1) * [math]::PI / 180
    $a = [math]::Sin($dLat / 2) * [math]::Sin($dLat / 2) +
         [math]::Cos($lat1 * [math]::PI / 180) * [math]::Cos($lat2 * [math]::PI / 180) *
         [math]::Sin($dLon / 2) * [math]::Sin($dLon / 2)
    $c = 2 * [math]::Atan2([math]::Sqrt($a), [math]::Sqrt(1 - $a))
    [math]::Round($R * $c)
}

function Get-StormTrackPoints {
    # GDACS's event list carries only the storm's latest position; the per-event geometry
    # endpoint carries the whole track as LineString segments. Returns @() on any failure so
    # a storm without a usable track just falls back to its single reported point.
    param($eventId, $episodeId)
    try {
        $uri = "https://www.gdacs.org/gdacsapi/api/polygons/getgeometry?eventtype=TC&eventid=$eventId&episodeid=$episodeId"
        $geo = Invoke-RestMethod -Uri $uri -Headers $headers -TimeoutSec 45
        # Collect straight into an array. Accumulating into a List[object] and returning
        # @($list) throws "Argument types do not match" on Windows PowerShell 5.1, which is
        # what silently reduced every storm to its single last-known position.
        $pts = @(foreach ($f in $geo.features) {
            if ($f.geometry.type -ne "LineString") { continue }
            foreach ($c in $f.geometry.coordinates) {
                [PSCustomObject]@{ lat = [double]$c[1]; lon = [double]$c[0] }
            }
        })
        return $pts
    } catch {
        Write-Warning "  태풍 경로 조회 실패 (event $eventId): $($_.Exception.Message)"
        return @()
    }
}

function Get-ClosestHub {
    # Nearest approach of the whole track to any hub in the list.
    param($track, $hubList)
    $best = $null
    foreach ($hub in $hubList) {
        foreach ($tp in $track) {
            $d = Get-HaversineKm -lat1 $tp.lat -lon1 $tp.lon -lat2 $hub.Lat -lon2 $hub.Lon
            if ($null -eq $best -or $d -lt $best.km) {
                $best = [PSCustomObject]@{ hub = $hub.DisplayName; km = $d }
            }
        }
    }
    $best
}

function Get-TyphoonWatch {
    param($hubs, $transshipHubs, $maxTracks = 10)

    try {
        # GDACS routinely takes 7-15s to answer and intermittently fails outright; a single
        # attempt is what blanked this card in production. Retry a few times with a longer
        # timeout before giving up.
        $uri = "https://www.gdacs.org/gdacsapi/api/events/geteventlist/SEARCH?eventtypes=TC"
        $resp = $null
        for ($attempt = 1; $attempt -le 3 -and -not $resp; $attempt++) {
            try {
                $resp = Invoke-RestMethod -Uri $uri -Headers $headers -TimeoutSec 45
            } catch {
                if ($attempt -eq 3) { throw }
                Write-Warning "  GDACS 응답 실패 ($attempt/3), 재시도: $($_.Exception.Message)"
                Start-Sleep -Seconds 3
            }
        }
        $tcs = @($resp.features | Where-Object { $_.properties.eventtype -eq "TC" })

        # Coarse pre-filter before spending a request per track: keep West-Pacific / SE-Asia
        # storms only. Everything else (Atlantic, Indian Ocean) can never touch this route.
        $candidates = @(foreach ($f in $tcs) {
            $p = $f.properties
            $lon = [double]$f.geometry.coordinates[0]
            $lat = [double]$f.geometry.coordinates[1]
            $inRegion = ($lat -ge -5 -and $lat -le 45 -and $lon -ge 95 -and $lon -le 145)
            $namesAsia = $p.country -match "Viet ?Nam|China|Philippines|Taiwan|Hong Kong|Japan|Cambodia|Laos|Thailand|Malaysia"
            if (-not ($inRegion -or $namesAsia)) { continue }
            [PSCustomObject]@{ f = $f; p = $p; lat = $lat; lon = $lon }
        })
        # newest first, capped - each track is a separate slow request
        $candidates = @($candidates |
            Sort-Object { if ($_.p.todate) { [DateTime]$_.p.todate } else { [DateTime]::MinValue } } -Descending |
            Select-Object -First $maxTracks)

        $items = @(foreach ($cand in $candidates) {
            $p = $cand.p
            $track = Get-StormTrackPoints -eventId $p.eventid -episodeId $p.episodeid
            if ($track.Count -eq 0) { $track = @([PSCustomObject]@{ lat = $cand.lat; lon = $cand.lon }) }
            Start-Sleep -Milliseconds 250

            $nearVn = Get-ClosestHub -track $track -hubList $hubs
            $nearPort = if ($transshipHubs) { Get-ClosestHub -track $track -hubList $transshipHubs } else { $null }
            # does the track cross the South China Sea lane Vietnam cargo sails through?
            $crossesScs = @($track | Where-Object {
                $_.lat -ge 5 -and $_.lat -le 23 -and $_.lon -ge 105 -and $_.lon -le 120
            }).Count -gt 0

            $mentionsVietnam = $p.country -match "Viet ?Nam"
            $impact = $null
            if ($mentionsVietnam -or ($nearVn -and $nearVn.km -le 500)) { $impact = "direct" }
            elseif ($crossesScs -or ($nearPort -and $nearPort.km -le 400)) { $impact = "route" }
            if (-not $impact) { continue }

            [PSCustomObject]@{
                name           = ($p.name -replace "^Tropical Cyclone ", "")
                alertLevel     = $p.alertlevel
                isCurrent      = ($p.iscurrent -eq "true")
                severityText   = $p.severitydata.severitytext
                country        = $p.country
                fromDate       = $p.fromdate
                toDate         = $p.todate
                impact         = $impact
                nearestHub     = $nearVn.hub
                distanceKm     = $nearVn.km
                nearestPort    = if ($nearPort) { $nearPort.hub } else { $null }
                portDistanceKm = if ($nearPort) { $nearPort.km } else { $null }
                crossesScs     = $crossesScs
                trackPoints    = $track.Count
                reportUrl      = $p.url.report
            }
        })

        $active = @($items | Where-Object { $_.isCurrent } | Sort-Object distanceKm)

        # Not time-limited (unlike an "active" check) - showing when the last few Vietnam-relevant
        # typhoons actually happened, regardless of age, is what lets 부자재 shipping schedules be
        # extrapolated against typhoon-season timing rather than only reacting to a live storm.
        $today = (Get-Date).Date
        $past = @($items | Where-Object { -not $_.isCurrent -and $_.toDate } |
            Sort-Object { [DateTime]$_.toDate } -Descending | Select-Object -First 6 |
            ForEach-Object {
                $daysAgo = [math]::Round(($today - [DateTime]$_.toDate).TotalDays)
                $_ | Add-Member -NotePropertyName daysAgo -NotePropertyValue $daysAgo -Force
                # normalize so both the email and the page get a plain yyyy-MM-dd regardless
                # of whether this came back as a string or a DateTime
                $_.toDate = Format-DateOnly $_.toDate
                $_.fromDate = Format-DateOnly $_.fromDate
                $_
            })

        [PSCustomObject]@{
            active = $active
            past   = $past
        }
    } catch {
        Write-Warning "Typhoon watch fetch failed: $($_.Exception.Message)"
        $null
    }
}

# --- KCl (염화칼륨/potash) price trend -----------------------------------------------------
# World Bank's Pink Sheet is the only free, no-key numeric series found for either KCl or
# PP/PE - data.go.kr has an official petrochemical price API but it needs account signup, and
# SunSirs (the other PP/PE candidate) sits behind a bot-check challenge that only a real
# browser can clear, so it's not something a scheduled script can rely on.
function Get-ZipEntryXml {
    param($zip, $name)
    $entry = $zip.Entries | Where-Object { $_.FullName -eq $name }
    if (-not $entry) { throw "zip entry not found: $name" }
    $reader = New-Object System.IO.StreamReader($entry.Open())
    try { [xml]$reader.ReadToEnd() } finally { $reader.Close() }
}

function Get-KclPriceHistory {
    param($months = 30)

    $tmpXlsx = [System.IO.Path]::GetTempFileName() + ".xlsx"
    try {
        $xlsxUrl = "https://thedocs.worldbank.org/en/doc/74e8be41ceb20fa0da750cda2f6b9e4e-0050012026/related/CMO-Historical-Data-Monthly.xlsx"
        Invoke-WebRequest -Uri $xlsxUrl -Headers $headers -OutFile $tmpXlsx

        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [System.IO.Compression.ZipFile]::OpenRead($tmpXlsx)
        try {
            $wbXml = Get-ZipEntryXml $zip "xl/workbook.xml"
            $relsXml = Get-ZipEntryXml $zip "xl/_rels/workbook.xml.rels"

            # sheet name -> rId -> zip-internal worksheet filename, resolved dynamically since
            # the Pink Sheet's own internal sheet ordering isn't guaranteed stable release to release
            $nsWb = New-Object System.Xml.XmlNamespaceManager($wbXml.NameTable)
            $nsWb.AddNamespace("s", "http://schemas.openxmlformats.org/spreadsheetml/2006/main")
            $nsWb.AddNamespace("r", "http://schemas.openxmlformats.org/officeDocument/2006/relationships")
            $sheetNode = $wbXml.SelectSingleNode("//s:sheet[@name='Monthly Prices']", $nsWb)
            $rId = $sheetNode.GetAttribute("id", "http://schemas.openxmlformats.org/officeDocument/2006/relationships")

            $nsRels = New-Object System.Xml.XmlNamespaceManager($relsXml.NameTable)
            $nsRels.AddNamespace("p", "http://schemas.openxmlformats.org/package/2006/relationships")
            $relNode = $relsXml.SelectSingleNode("//p:Relationship[@Id='$rId']", $nsRels)
            $target = $relNode.GetAttribute("Target")

            $sheetXml = Get-ZipEntryXml $zip "xl/$target"
            $sharedXml = Get-ZipEntryXml $zip "xl/sharedStrings.xml"
            $nsSheet = New-Object System.Xml.XmlNamespaceManager($sheetXml.NameTable)
            $nsSheet.AddNamespace("s", "http://schemas.openxmlformats.org/spreadsheetml/2006/main")

            # .InnerText (not .t) so both plain <si><t>..</t></si> and rich-text-run
            # <si><r><t>..</t></r>...</si> shared-string entries resolve the same way
            $sharedStrings = @($sharedXml.sst.si | ForEach-Object { $_.InnerText })

            # row 5 holds the column titles - find which column is Potassium chloride
            $headerRow = $sheetXml.SelectSingleNode("//s:row[@r='5']", $nsSheet)
            $kclCol = $null
            foreach ($c in @($headerRow.c)) {
                $colLetters = ($c.r -replace '\d+$', '')
                $val = if ($c.t -eq "s") { $sharedStrings[[int]$c.v] } else { $c.v }
                if ($val -eq "Potassium chloride **") { $kclCol = $colLetters; break }
            }
            if (-not $kclCol) { throw "Potassium chloride column not found in Pink Sheet" }

            $dataRows = @($sheetXml.SelectNodes("//s:row", $nsSheet) | Where-Object { [int]$_.r -ge 7 })
            $points = foreach ($row in $dataRows) {
                $cells = @($row.c)
                $dateCell = $cells | Where-Object { ($_.r -replace '\d+$', '') -eq "A" } | Select-Object -First 1
                $valCell  = $cells | Where-Object { ($_.r -replace '\d+$', '') -eq $kclCol } | Select-Object -First 1
                if (-not $dateCell -or -not $valCell) { continue }
                $dateLabel = if ($dateCell.t -eq "s") { $sharedStrings[[int]$dateCell.v] } else { $dateCell.v }
                if (-not $dateLabel -or $dateLabel -notmatch '^\d{4}M\d{2}$') { continue }
                if ($valCell.t -eq "s") { continue }  # missing-data marker stored as text (e.g. "..")
                $rawVal = $valCell.v
                if (-not $rawVal -or $rawVal -notmatch '^-?[\d.]+$') { continue }
                [PSCustomObject]@{
                    label = ($dateLabel -replace 'M', '-')
                    value = [math]::Round([double]$rawVal, 1)
                }
            }
            $points = @($points | Select-Object -Last $months)
            if ($points.Count -eq 0) { return $null }

            [PSCustomObject]@{
                unit   = "USD/mt"
                source = "World Bank Pink Sheet"
                points = $points
            }
        } finally {
            $zip.Dispose()
        }
    } catch {
        Write-Warning "KCl price fetch failed: $($_.Exception.Message)"
        $null
    } finally {
        Remove-Item $tmpXlsx -ErrorAction SilentlyContinue
    }
}

# --- Yahoo Finance daily series (crude oil, US lumber) ------------------------------------
# Same keyless chart endpoint the stockdashboard repo already relies on. Monthly-sampled down
# to ~2 years so the chart shape matches the KCl one rather than being 500 noisy daily points.
function Get-YahooSeries {
    param($cfg)

    try {
        $uri = "https://query1.finance.yahoo.com/v8/finance/chart/$([uri]::EscapeDataString($cfg.Symbol))?interval=1wk&range=2y"
        $resp = Invoke-RestMethod -Uri $uri -Headers $headers
        $result = $resp.chart.result[0]
        $closes = $result.indicators.quote[0].close
        $stamps = $result.timestamp
        if (-not $closes -or -not $stamps) { throw "no series data returned" }

        $decimals = if ($null -ne $cfg.Decimals) { [int]$cfg.Decimals } else { 2 }
        $points = for ($i = 0; $i -lt $closes.Count; $i++) {
            if ($null -eq $closes[$i]) { continue }
            [PSCustomObject]@{
                label = [DateTimeOffset]::FromUnixTimeSeconds($stamps[$i]).ToString("yyyy-MM-dd")
                value = [math]::Round([double]$closes[$i], $decimals)
            }
        }
        $points = @($points)
        if ($points.Count -eq 0) { throw "all closes were null" }

        [PSCustomObject]@{
            id          = $cfg.Id
            displayName = $cfg.DisplayName
            unit        = $cfg.Unit
            note        = $cfg.Note
            source      = "Yahoo Finance"
            # Every series here used to be dollar-denominated. The FX card is quoted the other
            # way round - won per dollar - so a hardcoded "$" would print $1,374.6.
            currency    = if ($null -ne $cfg.Currency) { $cfg.Currency } else { "$" }
            points      = $points
            newsQuery   = $cfg.NewsQuery
        }
    } catch {
        Write-Warning "Yahoo series fetch failed for '$($cfg.Symbol)': $($_.Exception.Message)"
        $null
    }
}

# --- SCFI (Shanghai Containerized Freight Index) ------------------------------------------
# The AJAX endpoint behind SSE's own public SCFI page. Their historical-series endpoint
# (/singleIndex/scfi) requires a subscriber login, so only the current and prior week are
# available - shown as a value + weekly change rather than a chart.
function Get-ScfiIndex {
    try {
        $scfiHeaders = $headers.Clone()
        $scfiHeaders["Referer"] = "https://en.sse.net.cn/indices/scfinew.jsp"
        $scfiHeaders["X-Requested-With"] = "XMLHttpRequest"
        $resp = Invoke-RestMethod -Uri "https://en.sse.net.cn/currentIndex?indexName=scfi" -Headers $scfiHeaders

        $data = $resp.data
        if (-not $data) { throw "no data node in response" }
        $comp = $data.lineDataList | Where-Object { $_.dataItemTypeName -eq "SCFI_T" } | Select-Object -First 1
        if (-not $comp) { throw "comprehensive index row not found" }

        [PSCustomObject]@{
            id          = "scfi"
            displayName = "컨테이너 운임지수 (SCFI)"
            current     = [math]::Round([double]$comp.currentContent, 1)
            previous    = [math]::Round([double]$comp.lastContent, 1)
            change      = [math]::Round([double]$comp.absolute, 1)
            changePct   = [math]::Round([double]$comp.percentage, 2)
            currentDate = Format-DateOnly $data.currentDate
            lastDate    = Format-DateOnly $data.lastDate
            note        = "상하이 → 세계 주요 13개 항로 수출 컨테이너 운임"
            source      = "Shanghai Shipping Exchange"
        }
    } catch {
        Write-Warning "SCFI fetch failed: $($_.Exception.Message)"
        $null
    }
}

# --- 국내 경유가 (Opinet) -------------------------------------------------------------------
# Opinet's public API is free but key-gated (signup at opinet.co.kr, 1,500 calls/day). Without
# a key the endpoint answers with an empty OIL array rather than an error, so this returns
# $null and the dashboard shows a "키 필요" placeholder instead of a broken card.
function Get-DomesticFuelPrices {
    $apiKey = $env:OPINET_API_KEY
    if (-not $apiKey) {
        Write-Host "  (OPINET_API_KEY 미설정 - 국내 유가 건너뜀)"
        return $null
    }

    try {
        # avgRecentPrice returns the last 7 days of nationwide averages per product code,
        # which gives the card a small trend line instead of just today's number.
        $uri = "https://www.opinet.co.kr/api/avgRecentPrice.do?out=json&code=$apiKey"
        $resp = Invoke-RestMethod -Uri $uri -Headers $headers
        $rows = @($resp.RESULT.OIL)
        if ($rows.Count -eq 0) { throw "empty OIL array (키가 유효하지 않을 수 있음)" }

        # PRODCD: B027 = 휘발유, D047 = 자동차용 경유
        $products = @(
            @{ code = "D047"; name = "국내 경유 (전국평균)" }
            @{ code = "B027"; name = "국내 휘발유 (전국평균)" }
        )

        $out = foreach ($p in $products) {
            $series = @($rows | Where-Object { $_.PRODCD -eq $p.code } | Sort-Object DATE)
            if ($series.Count -eq 0) { continue }
            $points = foreach ($r in $series) {
                [PSCustomObject]@{
                    label = ([string]$r.DATE -replace '^(\d{4})(\d{2})(\d{2})$', '$1-$2-$3')
                    value = [math]::Round([double]$r.PRICE, 1)
                }
            }
            [PSCustomObject]@{
                id          = $p.code
                displayName = $p.name
                unit        = "원/L"
                currency    = ""
                note        = "최근 7일 전국 주유소 평균"
                source      = "한국석유공사 오피넷"
                points      = @($points)
            }
        }
        @($out)
    } catch {
        Write-Warning "Opinet fuel price fetch failed: $($_.Exception.Message)"
        $null
    }
}

# --- News (materials) -------------------------------------------------------------------
function Get-NewsHeadlines {
    param($query, $max = 4)

    $uri = "https://news.google.com/rss/search?q=" + [uri]::EscapeDataString($query) + "&hl=ko&gl=KR&ceid=KR:ko"
    try {
        $raw = Invoke-WebRequest -Uri $uri -Headers $headers -UseBasicParsing
        [xml]$rss = $raw.Content
        $items = $rss.rss.channel.item | Select-Object -First $max
        @(foreach ($it in $items) {
            $title = $it.title
            $source = $null
            if ($title -match '^(.*) - ([^-]{1,40})$') {
                $title = $matches[1].Trim(); $source = $matches[2].Trim()
            }
            # RSS pubDate is RFC-822 with English month/day names ("Tue, 26 Aug 2026 ..."), which
            # a non-English culture can't parse - and an unguarded throw here loses every headline
            # from the whole feed, not just the one bad item. Parse invariantly, skip on failure.
            $dateStr = ""
            try {
                $dateStr = [System.DateTimeOffset]::Parse(
                    $it.pubDate, [System.Globalization.CultureInfo]::InvariantCulture
                ).ToString("yyyy-MM-dd")
            } catch {
                Write-Warning "  (pubDate 파싱 실패, 날짜 생략: '$($it.pubDate)')"
            }
            [PSCustomObject]@{
                title  = $title
                source = $source
                date   = $dateStr
                link   = $it.link
            }
        })
    } catch {
        Write-Warning "News fetch failed for '$query': $($_.Exception.Message)"
        @()
    }
}

function Get-MaterialSnapshot {
    param($mat)

    $news = @()
    foreach ($q in $mat.NewsQueries) {
        $news += Get-NewsHeadlines -query $q -max 3
        Start-Sleep -Milliseconds 300
    }
    # de-dup by link, keep first-seen order, cap at 8
    $seen = New-Object System.Collections.Generic.HashSet[string]
    $deduped = @(foreach ($n in $news) {
        if ($seen.Add($n.link)) { $n }
    })

    [PSCustomObject]@{
        id          = $mat.Id
        displayName = $mat.DisplayName
        news        = @($deduped | Select-Object -First 8)
    }
}

# Korea has no DST, so UTC+9 is always correct - avoids TimeZoneInfo id mismatches between
# Windows PowerShell 5.1 locally and pwsh on the Linux Actions runner.
$nowKst = (Get-Date).ToUniversalTime().AddHours(9)

Write-Host "Fetching weather..."
$weather = @(foreach ($loc in $config.weatherLocations) {
    Write-Host "  - $($loc.DisplayName)"
    Get-WeatherSnapshot $loc
    Start-Sleep -Milliseconds 300
})
$weather = @($weather | Where-Object { $_ })

Write-Host "Fetching holiday info..."
$holiday = Get-HolidayBlock -todayKst $nowKst

Write-Host "Fetching Vietnam typhoon watch..."
$typhoon = Get-TyphoonWatch -hubs $config.typhoonWatchHubs -transshipHubs $config.typhoonTransshipHubs

Write-Host "Fetching KCl price history..."
$kcl = Get-KclPriceHistory
if ($kcl) {
    $kcl = [PSCustomObject]@{
        id          = "kcl"
        displayName = "KCl (염화칼륨)"
        unit        = "/mt"
        currency    = "$"
        # KCl is the feedstock for both KOH (KCl brine electrolysis) and K2CO3 (KOH + CO2),
        # neither of which has a free price series - so this doubles as their cost indicator.
        note        = "월간 국제가 · KOH/K2CO3 원료"
        source      = $kcl.source
        points      = $kcl.points
    }
}

Write-Host "Fetching commodity series (oil, lumber)..."
$yahooSeries = @(foreach ($cfg in $config.yahooSeries) {
    Write-Host "  - $($cfg.DisplayName)"
    Get-YahooSeries $cfg
    Start-Sleep -Milliseconds 400
})
$yahooSeries = @($yahooSeries | Where-Object { $_ })

Write-Host "Fetching SCFI..."
$scfi = Get-ScfiIndex

Write-Host "Fetching domestic fuel prices..."
$fuel = @(Get-DomesticFuelPrices | Where-Object { $_ })

# Both of these upstreams serve only a short window, so merge into (and read back from) the
# accumulated store - that is what turns 7 days of pump prices and 2 weeks of SCFI into a
# series worth charting over months.
$historyStore = Read-HistoryStore
foreach ($f in $fuel) {
    $merged = Merge-HistorySeries -store $historyStore -key "fuel-$($f.id)" -points $f.points
    $f.points = $merged
    $f.note = "전국 주유소 평균 · 누적 $($merged.Count)일"
}
if ($scfi) {
    $scfiPoints = @(
        [PSCustomObject]@{ label = $scfi.lastDate;    value = $scfi.previous }
        [PSCustomObject]@{ label = $scfi.currentDate; value = $scfi.current }
    ) | Where-Object { $_.label }
    $scfiHistory = Merge-HistorySeries -store $historyStore -key "scfi" -points $scfiPoints
    $scfi | Add-Member -NotePropertyName points -NotePropertyValue $scfiHistory -Force
}
Write-HistoryStore -store $historyStore

# One flat list so the dashboard/email render every price card the same way regardless of
# which upstream it came from. Order here is the display order.
$priceCards = @()
# FX leads: every imported packaging input and the whole ocean-freight bill is quoted in
# dollars, so a won move resets the landed cost of every other card below it. Note this list
# selects Yahoo series by explicit id - a series added to config.json is dropped silently
# unless it is named here too.
$priceCards += @($yahooSeries | Where-Object { $_.id -eq "usdkrw" })
$priceCards += @($yahooSeries | Where-Object { $_.id -eq "wti" -or $_.id -eq "brent" })
$priceCards += @($fuel)
$priceCards += @($yahooSeries | Where-Object { $_.id -eq "lumber" })
if ($kcl) { $priceCards += $kcl }
$priceCards = @($priceCards)

# Attach "왜 움직였나" headlines to each price card - shown in the detail popup, so a move on
# the chart can be read against what was reported around it rather than left unexplained.
Write-Host "Fetching price driver news..."
foreach ($c in $priceCards) {
    $q = $c.newsQuery
    if (-not $q) { $q = $config.priceNewsQueries.($c.id) }
    if (-not $q) { continue }
    Write-Host "  - $($c.displayName)"
    $driverNews = @(Get-NewsHeadlines -query $q -max 5)
    $c | Add-Member -NotePropertyName news -NotePropertyValue $driverNews -Force
    Start-Sleep -Milliseconds 300
}
if ($scfi) {
    $q = $config.priceNewsQueries.scfi
    if ($q) {
        Write-Host "  - $($scfi.displayName)"
        $scfi | Add-Member -NotePropertyName news -NotePropertyValue @(Get-NewsHeadlines -query $q -max 5) -Force
    }
}

Write-Host "Fetching material news..."
$materials = @(foreach ($mat in $config.materials) {
    Write-Host "  - $($mat.DisplayName)"
    Get-MaterialSnapshot $mat
})

if ($weather.Count -eq 0 -and -not $holiday -and -not $typhoon -and $materials.Count -eq 0) {
    throw "모든 데이터 소스 fetch가 실패했습니다 - 이전 대시보드를 유지하기 위해 중단합니다."
}

function ConvertTo-JsonOrNull {
    param($InputObject, $Depth = 6)
    if ($null -eq $InputObject) { return "null" }
    $json = ConvertTo-Json -InputObject $InputObject -Depth $Depth
    if ($null -eq $json -or $json -eq "") { return "null" }
    return $json
}

$weatherJson = ConvertTo-Json -InputObject @($weather) -Depth 6
$holidayJson = ConvertTo-JsonOrNull -InputObject $holiday -Depth 4
$typhoonJson = ConvertTo-JsonOrNull -InputObject $typhoon -Depth 4
$pricesJson = ConvertTo-Json -InputObject @($priceCards) -Depth 6
$scfiJson = ConvertTo-JsonOrNull -InputObject $scfi -Depth 4
$hasFuelKey = if ($env:OPINET_API_KEY) { "true" } else { "false" }
$materialsJson = ConvertTo-Json -InputObject @($materials) -Depth 6
$fetchedAt = $nowKst.ToString("yyyy-MM-ddTHH:mm:ss") + "+09:00"

$template = Get-Content -Path (Join-Path $root "template.html") -Raw -Encoding UTF8
$output = $template.Replace("__WEATHER_JSON__", $weatherJson).Replace("__HOLIDAY_JSON__", $holidayJson).Replace("__TYPHOON_JSON__", $typhoonJson).Replace("__PRICES_JSON__", $pricesJson).Replace("__SCFI_JSON__", $scfiJson).Replace("__HAS_FUEL_KEY__", $hasFuelKey).Replace("__MATERIALS_JSON__", $materialsJson).Replace("__FETCHED_AT__", $fetchedAt)

$outPath = Join-Path $root "dashboard.html"
Set-Content -Path $outPath -Value $output -Encoding UTF8

Write-Host "Dashboard updated: $outPath"
if (-not $env:CI) {
    Start-Process $outPath
}

# --- Email summary -----------------------------------------------------------------
Write-Host "Building email summary..."

$dayNames = @("일", "월", "화", "수", "목", "금", "토")
$emailDateStr = "{0}년 {1}월 {2}일 ({3})" -f $nowKst.Year, $nowKst.Month, $nowKst.Day, $dayNames[[int]$nowKst.DayOfWeek]

function Get-AdvisoryHtml {
    param($advisories)
    if (-not $advisories -or $advisories.Count -eq 0) { return "" }
    ($advisories | ForEach-Object {
        $color = if ($_.tone -eq "danger") { "#b3221f" } else { "#a15c00" }
        "<span style='display:inline-block;margin-right:8px;color:$color;font-weight:700;'>⚠ $($_.text)</span>"
    }) -join ""
}

$weatherRowsHtml = foreach ($w in $weather) {
    $curAdvisoryHtml = Get-AdvisoryHtml $w.advisories
    # The forecast used to be seven 11px grey sentences that ran together; as aligned columns
    # the same data can be read down a single axis instead of parsed line by line.
    $dayRows = foreach ($d in $w.days) {
        $dAdvisoryHtml = Get-AdvisoryHtml $d.advisories
        $dateStr = Format-DateOnly $d.date
        $md = if ($dateStr.Length -ge 10) { $dateStr.Substring(5) } else { $dateStr }
        [DateTime]$parsedDay = Get-Date
        $dow = if ([DateTime]::TryParse($dateStr, [ref]$parsedDay)) { $dayNames[[int]$parsedDay.DayOfWeek] } else { "" }
        $isWeekend = $dow -eq "토" -or $dow -eq "일"
        $dayColor = if ($isWeekend) { "#b3221f" } else { "#3d3b37" }
        # Only call out rain worth planning around - colouring every row defeats the purpose.
        $rainColor = if ([int]$d.chanceOfRain -ge 60) { "#2a78d6" } else { "#898781" }
        $rainWeight = if ([int]$d.chanceOfRain -ge 60) { "700" } else { "400" }
        @"
<tr>
  <td style="padding:4px 8px 4px 0;white-space:nowrap;color:$dayColor;font-weight:600;">$md ($dow)</td>
  <td style="padding:4px 8px 4px 0;color:#52514e;">$($d.desc)</td>
  <td style="padding:4px 8px 4px 0;white-space:nowrap;color:#0b0b0b;font-weight:600;">$($d.minC)° / $($d.maxC)°</td>
  <td style="padding:4px 8px 4px 0;white-space:nowrap;color:$rainColor;font-weight:$rainWeight;">☂ $($d.chanceOfRain)%</td>
  <td style="padding:4px 0;">$dAdvisoryHtml</td>
</tr>
"@
    }
    @"
<tr>
  <td style="padding:14px 16px;border-bottom:1px solid #e1e0d9;">
    <div style="font-weight:700;font-size:13.5px;color:#0b0b0b;">$($w.displayName)</div>
    <div style="margin-top:5px;">
      <span style="font-size:20px;font-weight:700;color:#0b0b0b;">$($w.tempC)°C</span>
      <span style="font-size:12px;color:#52514e;">체감 $($w.feelsLikeC)° · 습도 $($w.humidity)% · $($w.desc)</span>
    </div>
    <div style="margin-top:3px;">$curAdvisoryHtml</div>
    <table style="width:100%;border-collapse:collapse;font-size:12px;margin-top:8px;">$($dayRows -join "")</table>
  </td>
</tr>
"@
}

$holidayHtml = ""
if ($holiday) {
    $names = ($holiday.holidayNames | Select-Object -Unique) -join ", "
    $dDayText = if ($holiday.dDay -eq 0) { "오늘부터" } else { "D-$($holiday.dDay)" }
    $holidayHtml = @"
<div style="margin:16px 0;padding:12px 14px;background:#eef4fc;border:1px solid #cfe0f5;border-radius:8px;">
  <div style="font-weight:650;font-size:13px;color:#0b0b0b;">가장 빠른 연휴: $($holiday.startDate) ~ $($holiday.endDate) ($($holiday.days)일, $dDayText)</div>
  <div style="font-size:12px;color:#52514e;margin-top:4px;">$names</div>
</div>
"@
}

function Format-TyphoonSeverity {
    # GDACS answers in English prose ("Tropical Storm (maximum wind speed of 213 km/h)"), which
    # in a Korean digest was both the longest line in the alert and the least scannable.
    param($text)
    if (-not $text) { return "" }
    $wind = if ($text -match '(\d+(?:\.\d+)?)\s*km/h') { "최대풍속 $($matches[1])km/h" } else { "" }
    $kind = switch -Regex ($text) {
        'Severe Tropical'           { "강한 열대폭풍"; break }
        'Tropical Depression'       { "열대저압부"; break }
        'Tropical Storm'            { "열대폭풍"; break }
        'Typhoon|Hurricane|Cyclone' { "태풍"; break }
        default                     { "" }
    }
    $parts = @(@($kind, $wind) | Where-Object { $_ })
    if ($parts.Count -eq 0) { return $text }
    $parts -join " · "
}

function Get-TyphoonBadge {
    param($impact)
    $bg = if ($impact -eq "direct") { "#b3221f" } else { "#c2410c" }
    $label = if ($impact -eq "direct") { "직접" } else { "항로" }
    "<span style='background:$bg;color:#ffffff;font-size:11px;font-weight:700;padding:2px 7px;'>$label</span>"
}

function Get-TyphoonWhere {
    # A route-impact storm is flagged for where it passed relative to the transshipment ports
    # Vietnamese cargo moves through, so printing its Vietnam distance instead - 1,223km for
    # SAUDEL-26 - made the alert read as "why am I being told this?". Report the distance that
    # actually triggered the flag.
    param($t)
    if ($t.impact -eq "direct") { return "$($t.nearestHub) $($t.distanceKm)km" }
    $parts = @()
    if ($t.crossesScs) { $parts += "남중국해 항로 통과" }
    if ($t.nearestPort) { $parts += "$($t.nearestPort) $($t.portDistanceKm)km" }
    if ($parts.Count -eq 0) { return "$($t.nearestHub) $($t.distanceKm)km" }
    $parts -join " · "
}

$typhoonHtml = ""
if ($typhoon) {
    # The old history list was six near-identical grey sentences that outweighed the one line
    # that mattered. As a table the columns line up, so it scans as reference material.
    $pastRows = foreach ($t in $typhoon.past) {
        @"
<tr>
  <td style="padding:3px 8px 3px 0;white-space:nowrap;">$(Get-TyphoonBadge $t.impact)</td>
  <td style="padding:3px 8px 3px 0;font-weight:600;color:#3d3b37;white-space:nowrap;">$($t.name)</td>
  <td style="padding:3px 8px 3px 0;color:#0b0b0b;font-weight:600;white-space:nowrap;">$($t.daysAgo)일 전</td>
  <td style="padding:3px 0;color:#6e6c66;">$(Format-DateOnly $t.toDate) 소멸 · $(Get-TyphoonWhere $t)</td>
</tr>
"@
    }
    $pastBlockHtml = if ($pastRows) {
        @"
<div style="margin-top:12px;padding-top:10px;border-top:1px solid #e1e0d9;font-size:11px;color:#898781;">최근 발생 이력 · 다음 시기 가늠용</div>
  <table style="width:100%;border-collapse:collapse;font-size:11.5px;margin-top:4px;">$($pastRows -join "")</table>
"@
    } else { "" }

    # 직접/항로 is the whole point of this watch, but the email never said what they meant -
    # the page carries that explanation and the mail was read on its own.
    $legendHtml = "<div style='margin-top:10px;font-size:11px;color:#898781;line-height:1.6;'><b>직접</b> = 베트남 상륙 또는 하노이/호치민 500km 이내 · <b>항로</b> = 남중국해 항로 통과 또는 환적항(홍콩·선전/가오슝/상하이·닝보) 400km 이내. 항로 태풍은 베트남에 상륙하지 않아도 선적을 밀어냅니다.</div>"

    if ($typhoon.active.Count -gt 0) {
        $anyDirect = @($typhoon.active | Where-Object { $_.impact -eq "direct" }).Count -gt 0
        $headline = if ($anyDirect) { "태풍 직접 영향권 — 베트남 부자재 입고 지연 주의" } else { "항로상 태풍 활동 중 — 베트남 부자재 입고 지연 가능성" }
        $activeRows = foreach ($t in $typhoon.active) {
            $reportLink = if ($t.reportUrl) { " <a href='$($t.reportUrl)' style='color:#2a78d6;text-decoration:none;font-size:11px;'>GDACS 리포트 →</a>" } else { "" }
            @"
<div style="margin-top:9px;padding:9px 11px;background:#ffffff;border:1px solid #f3caca;">
      <div>$(Get-TyphoonBadge $t.impact) <b style="font-size:14px;color:#0b0b0b;">$($t.name)</b> <span style="font-size:11px;color:#898781;">경보등급 $($t.alertLevel)</span></div>
      <div style="font-size:12.5px;color:#0b0b0b;font-weight:600;margin-top:4px;">$(Get-TyphoonWhere $t)</div>
      <div style="font-size:11.5px;color:#6e6c66;margin-top:2px;">$(Format-TyphoonSeverity $t.severityText)$reportLink</div>
    </div>
"@
        }
        $typhoonHtml = @"
<div style="margin:16px 0;padding:13px 15px;background:#fdeeee;border:1px solid #f3caca;border-left:4px solid #b3221f;">
  <div style="font-weight:700;font-size:14px;color:#b3221f;">⚠ $headline</div>
  $($activeRows -join "")
  $legendHtml
  $pastBlockHtml
</div>
"@
    } elseif ($pastRows) {
        $typhoonHtml = @"
<div style="margin:16px 0;padding:13px 15px;background:#f1f6f1;border:1px solid #cfe3cf;border-left:4px solid #0a6b0a;">
  <div style="font-weight:700;font-size:14px;color:#0a6b0a;">✓ 베트남 인근 활성 태풍 없음 · 입고 일정 영향 없음</div>
  $legendHtml
  $pastBlockHtml
</div>
"@
    } else {
        $typhoonHtml = @"
<div style="margin:16px 0;padding:13px 15px;background:#f1f6f1;border:1px solid #cfe3cf;border-left:4px solid #0a6b0a;">
  <div style="font-weight:700;font-size:14px;color:#0a6b0a;">✓ 베트남 인근 태풍 활동 없음 · 부자재 입고 일정 영향 없음</div>
</div>
"@
    }
}

function Format-PriceValue {
    param($v)
    if ($null -eq $v) { return "" }
    $d = [double]$v
    $r = if ([math]::Abs($d) -ge 1000) { [math]::Round($d, 1) } else { [math]::Round($d, 2) }
    ((("{0:N2}" -f $r) -replace '0+$', '') -replace '\.$', '')
}

function Get-BarChartHtml {
    # Replaces a Unicode-block sparkline ("▁▂▃▄"). That had only 8 height levels to spread two
    # years of weekly closes across, and mail clients font-substituted the glyphs onto
    # inconsistent baselines, so every series arrived looking like the same flat smear.
    # Bars drawn as <td bgcolor> in a nested table are the one chart form Outlook's Word
    # renderer draws like every other client, and the spacer row above each bar means the
    # height never depends on valign being honoured.
    param($values, $accent = "#2a78d6", $maxBars = 24, $height = 44)

    $vals = @($values | Where-Object { $null -ne $_ } | ForEach-Object { [double]$_ })
    if ($vals.Count -lt 2) { return "" }

    # Average into buckets rather than sampling every Nth point - sampling drops the spikes
    # that fall between two indices, which is the movement most worth seeing.
    if ($vals.Count -gt $maxBars) {
        $src = $vals
        $bucket = $src.Count / $maxBars
        $vals = @(for ($i = 0; $i -lt $maxBars; $i++) {
            $from = [int][math]::Floor($i * $bucket)
            $to = [int][math]::Floor(($i + 1) * $bucket) - 1
            if ($to -lt $from) { $to = $from }
            if ($to -gt $src.Count - 1) { $to = $src.Count - 1 }
            ($src[$from..$to] | Measure-Object -Average).Average
        })
    }

    $min = ($vals | Measure-Object -Minimum).Minimum
    $max = ($vals | Measure-Object -Maximum).Maximum
    $range = $max - $min
    $last = $vals.Count - 1
    # Pump prices start life as 7 accumulated days; without widening, those draw a chart barely
    # a thumbnail across while a 24-bucket series fills the column.
    $barW = [math]::Max(4, [math]::Min(14, [int](340 / $vals.Count) - 2))

    $cells = for ($i = 0; $i -lt $vals.Count; $i++) {
        # Floor the height at 3px: a zero-height bar collapses and reads as missing data
        # rather than as the low point of the series.
        $h = if ($range -eq 0) { [int]($height / 2) } else { 3 + [int][math]::Round((($vals[$i] - $min) / $range) * ($height - 3)) }
        $pad = $height - $h
        $fill = if ($i -eq $last) { $accent } else { "#c3d5ea" }
        $spacer = if ($pad -gt 0) { "<tr><td height='$pad' style='font-size:0;line-height:0;'>&nbsp;</td></tr>" } else { "" }
        "<td style='padding:0 1px;font-size:0;line-height:0;'><table cellpadding='0' cellspacing='0' border='0' style='border-collapse:collapse;'>$spacer<tr><td height='$h' width='$barW' bgcolor='$fill' style='font-size:0;line-height:0;'>&nbsp;</td></tr></table></td>"
    }
    "<table cellpadding='0' cellspacing='0' border='0' style='border-collapse:collapse;'><tr>$($cells -join '')</tr></table>"
}

function Get-PriceChangeHtml {
    # Returns both the rendered badge and the colour, because the chart's latest bar is tinted
    # to match the move - one place decides whether today counts as up, down, or flat.
    param($latestValue, $priorValue)
    if ($null -eq $priorValue) { return [PSCustomObject]@{ html = ""; accent = "#2a78d6" } }
    $diff = $latestValue - $priorValue
    $pct = if ($priorValue -ne 0) { ($diff / $priorValue) * 100 } else { 0 }
    # Pump prices move by fractions of a won, which the old "{0:N1}%" printed as "-0.0%" -
    # that reads as a broken template rather than as "barely moved".
    if ([math]::Abs($pct) -lt 0.05) {
        return [PSCustomObject]@{ html = "<span style='color:#6e6c66;font-weight:600;'>보합</span>"; accent = "#8f9aa6" }
    }
    $up = $diff -ge 0
    # Up is red: every series here is an input cost, so rising is the bad direction.
    $accent = if ($up) { "#b3221f" } else { "#0a6b0a" }
    $arrow = if ($up) { "▲" } else { "▼" }
    $pctStr = "{0:N1}" -f [math]::Abs($pct)
    $diffStr = Format-PriceValue ([math]::Abs($diff))
    [PSCustomObject]@{
        html   = "<span style='color:$accent;font-weight:700;'>$arrow $diffStr ($pctStr%)</span>"
        accent = $accent
    }
}

function Get-PriceChartHtml {
    param($points, $accent, $currency)
    $pts = @($points)
    if ($pts.Count -lt 3) { return "" }
    $vals = @($pts | ForEach-Object { $_.value })
    $lo = Format-PriceValue (($vals | Measure-Object -Minimum).Minimum)
    $hi = Format-PriceValue (($vals | Measure-Object -Maximum).Maximum)
    $bars = Get-BarChartHtml -values $vals -accent $accent
    if (-not $bars) { return "" }
    # Bars are scaled to the series min/max, which makes a 0.5% drift fill the full height.
    # Printing the band beside the chart is what stops the shape overstating the move.
    @"
<div style="margin-top:9px;">$bars</div>
    <div style="font-size:11px;color:#898781;margin-top:4px;">차트 구간 $currency$lo ~ $currency$hi · $($pts[0].label) ~ $($pts[-1].label) ($($pts.Count)개 시점)</div>
"@
}

$priceRowsHtml = foreach ($c in $priceCards) {
    $pts = @($c.points)
    if ($pts.Count -eq 0) { continue }
    $latest = $pts[-1]
    $prior = if ($pts.Count -gt 1) { $pts[-2] } else { $null }
    $change = Get-PriceChangeHtml -latestValue $latest.value -priorValue $(if ($prior) { $prior.value } else { $null })
    $chartHtml = Get-PriceChartHtml -points $pts -accent $change.accent -currency $c.currency
    @"
<tr>
  <td style="padding:14px 16px;border-bottom:1px solid #e1e0d9;">
    <div style="font-weight:700;font-size:13.5px;color:#0b0b0b;">$($c.displayName)</div>
    <div style="margin-top:5px;">
      <span style="font-size:20px;font-weight:700;color:#0b0b0b;">$($c.currency)$(Format-PriceValue $latest.value)</span>
      <span style="font-size:12px;color:#898781;">$($c.unit)</span>
      <span style="font-size:13px;margin-left:5px;">$($change.html)</span>
      <span style="font-size:11px;color:#898781;">· $($latest.label) 기준</span>
    </div>
    $chartHtml
    <div style="font-size:11px;color:#898781;margin-top:7px;">$($c.note) · $($c.source)</div>
  </td>
</tr>
"@
}

$scfiHtml = ""
if ($scfi) {
    $scfiChange = Get-PriceChangeHtml -latestValue $scfi.current -priorValue $scfi.previous
    # SCFI only started accumulating when this repo did, so for the first few weeks there is
    # nothing to draw - the note below already explains why the chart is missing.
    $scfiChartHtml = Get-PriceChartHtml -points $scfi.points -accent $scfiChange.accent -currency ""
    $scfiHtml = @"
<tr>
  <td style="padding:14px 16px;border-bottom:1px solid #e1e0d9;">
    <div style="font-weight:700;font-size:13.5px;color:#0b0b0b;">$($scfi.displayName)</div>
    <div style="margin-top:5px;">
      <span style="font-size:20px;font-weight:700;color:#0b0b0b;">$(Format-PriceValue $scfi.current)</span>
      <span style="font-size:13px;margin-left:5px;">$($scfiChange.html)</span>
      <span style="font-size:11px;color:#898781;">· $($scfi.currentDate) 기준, 전주 $(Format-PriceValue $scfi.previous)</span>
    </div>
    $scfiChartHtml
    <div style="font-size:11px;color:#898781;margin-top:7px;">$($scfi.note) · $($scfi.source)</div>
  </td>
</tr>
"@
}

$materialsHtml = foreach ($m in $materials) {
    $newsLines = foreach ($n in ($m.news | Select-Object -First 3)) {
        # Outlet and date were already fetched but thrown away here, leaving three unattributed
        # blue lines - knowing who ran it and when is most of what makes a headline worth trusting.
        $meta = (@($n.source, $n.date) | Where-Object { $_ }) -join " · "
        $metaHtml = if ($meta) { "<div style='font-size:11px;color:#898781;margin-top:1px;'>$meta</div>" } else { "" }
        @"
<div style="margin-top:7px;">
      <a href="$($n.link)" style="font-size:12.5px;color:#2a78d6;text-decoration:none;line-height:1.45;">$($n.title)</a>
      $metaHtml
    </div>
"@
    }
    @"
<tr>
  <td style="padding:14px 16px;border-bottom:1px solid #e1e0d9;">
    <div style="font-weight:700;font-size:13.5px;color:#0b0b0b;">$($m.displayName)</div>
    $($newsLines -join "")
  </td>
</tr>
"@
}

function Get-EmailSection {
    # The digest used to be one undivided table running weather straight into prices and then
    # into news, so nothing signalled where one kind of information stopped.
    param($title, $rowsHtml)
    if (-not $rowsHtml -or $rowsHtml.Trim() -eq "") { return "" }
    @"
<div style="margin:22px 0 7px;font-size:11.5px;font-weight:700;color:#6e6c66;letter-spacing:0.6px;">$title</div>
  <table style="width:100%;border-collapse:collapse;background:#ffffff;border:1px solid #e1e0d9;">
    $rowsHtml
  </table>
"@
}

$dashboardUrl = "https://jhkim0603.github.io/work-dashboard/"
$updateUrl = "https://github.com/JHKim0603/work-dashboard/actions/workflows/update-dashboard.yml"

$emailHtml = @"
<!DOCTYPE html>
<html><body style="margin:0;padding:0;background:#f9f9f7;font-family:'Malgun Gothic',sans-serif;">
<div style="max-width:600px;margin:0 auto;padding:24px 16px;">
  <h2 style="margin:0 0 4px;color:#0b0b0b;">업무 참고자료 Dashboard</h2>
  <div style="font-size:12px;color:#898781;margin-bottom:14px;">$emailDateStr 기준</div>
  <div style="margin-bottom:16px;">
    <a href="$dashboardUrl" style="display:inline-block;background:#2a78d6;color:#ffffff;font-size:13px;font-weight:bold;text-decoration:none;padding:10px 18px;border-radius:6px;">📋 대시보드 열기 →</a>
    <a href="$updateUrl" style="display:inline-block;margin-left:8px;background:#ffffff;color:#2a78d6;border:1px solid #cfe0f5;font-size:13px;font-weight:bold;text-decoration:none;padding:9px 16px;border-radius:6px;">🔄 지금 업데이트</a>
  </div>
  $holidayHtml
  $typhoonHtml
  $(Get-EmailSection "날씨 · 온습도" ($weatherRowsHtml -join "`n"))
  $(Get-EmailSection "원자재 · 물류 가격" ($scfiHtml + "`n" + ($priceRowsHtml -join "`n")))
  $(Get-EmailSection "수급 뉴스" ($materialsHtml -join "`n"))
  <div style="margin-top:16px;font-size:11px;color:#898781;line-height:1.6;">
    날씨: Open-Meteo · 공휴일: Nager.Date · 태풍: GDACS · 유가/목재: Yahoo Finance · KCl: World Bank · 운임지수: Shanghai Shipping Exchange · 뉴스: Google 뉴스. 업무 참고용 요약입니다.<br>
    자세한 내용은 <a href="$dashboardUrl" style="color:#2a78d6;">대시보드</a>에서 확인하세요.
  </div>
</div>
</body></html>
"@

$utf8NoBom = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllText((Join-Path $root "email-summary.html"), $emailHtml, $utf8NoBom)
[System.IO.File]::WriteAllText((Join-Path $root "email-subject.txt"), "업무 참고자료 Dashboard - $emailDateStr", $utf8NoBom)
Write-Host "Email summary written: email-summary.html"
