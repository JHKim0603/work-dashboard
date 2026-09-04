<#
  Update-WorkDashboard.ps1
  Fetches a 7-day forecast + heat/cold advisories (Open-Meteo), the nearest upcoming Korean
  holiday block (Nager.Date), Vietnam-area typhoon activity and history relative to the
  하노이/호치민 hubs (GDACS), crude oil futures + USD/KRW (Yahoo Finance), PP/PE resin (DCE), KCl monthly prices
  (World Bank Pink Sheet), the SCFI container freight index (Shanghai Shipping Exchange),
  optionally Korean pump prices (Opinet, needs $env:OPINET_API_KEY), and commodity news
  headlines (Google News RSS), then regenerates dashboard.html.
  Run manually by double-clicking run.bat, or right-click > Run with PowerShell.
#>

$ErrorActionPreference = "Stop"
$root = $PSScriptRoot
$headers = @{ "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36" }

$config = Get-Content -Path (Join-Path $root "config.json") -Raw -Encoding UTF8 | ConvertFrom-Json

$spamKeywords = @($config.newsBlocklist.keywords)
$spamSources  = @($config.newsBlocklist.sources)
$spamBlocked  = 0

# CI gets its keys from Actions secrets; a local run.bat had none, so the pump-price cards were
# silently absent from the local page while the deployed one carried them. Reviewing the local
# file then means reviewing something the recipient never sees. This closes that gap: drop the
# keys in secrets.local.json (gitignored) and a local run renders exactly what CI renders.
# Environment variables still win, so CI is unaffected.
$secretsPath = Join-Path $root "secrets.local.json"
if (Test-Path $secretsPath) {
    try {
        $localSecrets = Get-Content -Path $secretsPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($name in @("OPINET_API_KEY", "DATA_GO_KR_KEY")) {
            $val = $localSecrets.$name
            if ($val -and -not (Get-Item "env:$name" -ErrorAction SilentlyContinue)) {
                Set-Item "env:$name" $val
                Write-Host "  secrets.local.json에서 $name 로드"
            }
        }
    } catch {
        Write-Warning "secrets.local.json을 읽지 못했습니다 (JSON 형식 확인): $($_.Exception.Message)"
    }
}

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
        # Three years, not two: with a two-year horizon a run started in December needs the
        # year after next to resolve, and the extra call is cheap.
        $year = $todayKst.Year
        $holidays = @()
        foreach ($y in @($year, ($year + 1), ($year + 2))) {
            $uri = "https://date.nager.at/api/v3/PublicHolidays/$y/KR"
            $holidays += Invoke-RestMethod -Uri $uri -Headers $headers
        }

        $today = $todayKst.Date
        # A 365-day horizon meant the list always died at the end of the current year - in late
        # August it stopped at 크리스마스 and showed nothing for the year after, which is exactly
        # when next year's 설날/추석 start mattering for shipping plans.
        $horizon = $today.AddDays(730)
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

        # 6 raw dates collapsed to about four rows, and 추석 alone eats three of them. Korea has
        # roughly 16 holiday dates a year, so 40 carries the full two-year horizon; the page
        # scrolls the list rather than truncating it.
        $nextHolidays = @($holidayByDate.Keys | Sort-Object | Select-Object -First 40 | ForEach-Object {
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
    # Retries, because the fallback is the method this card was rebuilt to stop using. Without a
    # track a storm is judged on its last reported point alone - the approach that missed
    # NOUL-26, DOLPHIN-26 and SAUDEL-26, every one of which actually delayed a shipment. A single
    # 45s attempt was leaving seven storms a run on that footing, silently.
    param($eventId, $episodeId, $attempts = 3)

    $uri = "https://www.gdacs.org/gdacsapi/api/polygons/getgeometry?eventtype=TC&eventid=$eventId&episodeid=$episodeId"
    for ($try = 1; $try -le $attempts; $try++) {
        try {
            # Shorter per-attempt timeout: GDACS either answers in a few seconds or is not going
            # to, and three 45s waits would push a run past its useful length.
            $geo = Invoke-RestMethod -Uri $uri -Headers $headers -TimeoutSec 20
            # Collect straight into an array. Accumulating into a List[object] and returning
            # @($list) throws "Argument types do not match" on Windows PowerShell 5.1, which is
            # what silently reduced every storm to its single last-known position.
            $pts = @(foreach ($f in $geo.features) {
                if ($f.geometry.type -ne "LineString") { continue }
                foreach ($c in $f.geometry.coordinates) {
                    [PSCustomObject]@{ lat = [double]$c[1]; lon = [double]$c[0] }
                }
            })
            if ($pts.Count -gt 0) { return $pts }
            # An empty answer is a real answer - this episode has no track published yet.
            return @()
        } catch {
            if ($try -lt $attempts) {
                Start-Sleep -Seconds ($try * 2)
                continue
            }
            Write-Warning "  태풍 경로 조회 실패 ($attempts회 시도, event $eventId): $($_.Exception.Message)"
            return @()
        }
    }
    return @()
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
    param($hubs, $transshipHubs, $arrivalHubs, $maxTracks = 10)

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
            # Falling back is not the same as judging on a track, and the page has to say so:
            # a one-point verdict is the one this card exists to have stopped making.
            $trackOk = $track.Count -gt 0
            if (-not $trackOk) { $track = @([PSCustomObject]@{ lat = $cand.lat; lon = $cand.lon }) }
            Start-Sleep -Milliseconds 250

            $nearVn = Get-ClosestHub -track $track -hubList $hubs
            $nearPort = if ($transshipHubs) { Get-ClosestHub -track $track -hubList $transshipHubs } else { $null }
            # does the track cross the South China Sea lane Vietnam cargo sails through?
            $crossesScs = @($track | Where-Object {
                $_.lat -ge 5 -and $_.lat -le 23 -and $_.lon -ge 105 -and $_.lon -le 120
            }).Count -gt 0

            $nearKr = if ($arrivalHubs) { Get-ClosestHub -track $track -hubList $arrivalHubs } else { $null }

            # The shipment is only delivered when it is discharged in Korea, so the watch runs
            # the whole chain rather than the origin alone: 출발지 → 항로 → 도착지. The arrival
            # leg was missing entirely, and it is not covered by the other two - 47 years of
            # tracks put 4.0 storms a year within 400km of the Korean ports, 1.6 of which touch
            # neither Vietnam nor the transshipment route. A typhoon parked over 부산 stops the
            # box just as surely as one over 하이퐁.
            $mentionsVietnam = $p.country -match "Viet ?Nam"
            # Plain array, not List[object]: wrapping a generic list in @() throws
            # "Argument types do not match" on Windows PowerShell 5.1, the same trap that once
            # reduced every storm to its last reported point.
            $legs = @(
                if ($mentionsVietnam -or ($nearVn -and $nearVn.km -le 500)) {
                    [PSCustomObject]@{ code = "origin"; label = "출발지"
                        detail = "$($nearVn.hub) $($nearVn.km)km" }
                }
                if ($crossesScs -or ($nearPort -and $nearPort.km -le 400)) {
                    $d = @()
                    if ($crossesScs) { $d += "남중국해 통과" }
                    if ($nearPort -and $nearPort.km -le 400) { $d += "$($nearPort.hub) $($nearPort.km)km" }
                    [PSCustomObject]@{ code = "route"; label = "항로"; detail = ($d -join " · ") }
                }
                if ($nearKr -and $nearKr.km -le 400) {
                    [PSCustomObject]@{ code = "arrival"; label = "도착지"
                        detail = "$($nearKr.hub) $($nearKr.km)km" }
                }
            )
            if ($legs.Count -eq 0) { continue }

            # Primary leg drives the badge colour; arrival outranks route because cargo already
            # at sea has no way to wait it out.
            $impact = if ($legs.code -contains "origin") { "direct" }
                      elseif ($legs.code -contains "arrival") { "arrival" }
                      else { "route" }

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
                legs           = $legs
                arrivalHub     = if ($nearKr) { $nearKr.hub } else { $null }
                arrivalKm      = if ($nearKr) { $nearKr.km } else { $null }
                trackPoints    = $track.Count
                trackOk        = $trackOk
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

# Last edition confirmed working. Only used if discovery below fails - the hash and the
# trailing 0050012026 are edition-specific, so this link dies whenever a new Pink Sheet ships.
$kclFallbackUrl = "https://thedocs.worldbank.org/en/doc/74e8be41ceb20fa0da750cda2f6b9e4e-0050012026/related/CMO-Historical-Data-Monthly.xlsx"

function Get-PinkSheetUrl {
    # The workbook lives under an edition-stamped path, so hardcoding it means the KCl card
    # disappears without a word the next time the World Bank publishes - a 404 here is caught
    # below, returns $null, and the card is simply never added. The Commodity Markets landing
    # page always links the current edition, so read the link from there and keep the last
    # known-good URL only as a fallback.
    param($fallbackUrl)

    try {
        $page = Invoke-WebRequest -Uri "https://www.worldbank.org/en/research/commodity-markets" `
            -Headers $headers -UseBasicParsing -TimeoutSec 30
        $match = [regex]::Match($page.Content, 'https://[^"''\s]*CMO-Historical-Data-Monthly\.xlsx')
        if ($match.Success) {
            if ($match.Value -ne $fallbackUrl) {
                Write-Host "  Pink Sheet 새 판 감지: $($match.Value)"
            }
            return $match.Value
        }
        Write-Warning "  Pink Sheet 링크를 페이지에서 찾지 못했습니다 - 마지막 확인된 URL로 시도합니다."
    } catch {
        Write-Warning "  Pink Sheet 링크 조회 실패 ($($_.Exception.Message)) - 마지막 확인된 URL로 시도합니다."
    }
    $fallbackUrl
}

function Get-KclPriceHistory {
    param($months = 30)

    $tmpXlsx = [System.IO.Path]::GetTempFileName() + ".xlsx"
    try {
        $xlsxUrl = Get-PinkSheetUrl -fallbackUrl $kclFallbackUrl
        # ~2MB over a link that may have just rotated; one attempt was enough to lose the card
        # to a transient failure, the same way a single GDACS attempt used to blank the typhoon one.
        $downloaded = $false
        for ($attempt = 1; $attempt -le 3 -and -not $downloaded; $attempt++) {
            try {
                Invoke-WebRequest -Uri $xlsxUrl -Headers $headers -OutFile $tmpXlsx -TimeoutSec 60
                $downloaded = $true
            } catch {
                if ($attempt -eq 3) { throw }
                Write-Warning "  Pink Sheet 다운로드 실패 ($attempt/3), 재시도: $($_.Exception.Message)"
                Start-Sleep -Seconds 3
            }
        }

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

# --- Yahoo Finance daily series (crude oil, USD/KRW) ------------------------------------
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

# --- PP / PE resin futures (Dalian Commodity Exchange, via Sina) ---------------------------
# The README long listed PP/PE as unavailable: the Pink Sheet has no plastics column (checked -
# 89 commodities, none), data.go.kr's petrochemical API is key-gated, SunSirs sits behind a
# bot check, and FRED's resin PPI series answer empty. DCE is where Asian resin actually
# trades, and Sina's daily K-line endpoint serves it keyless as dated JSON going back to 2007.
#
# Read it as a direction indicator, not as a quote: this is a Chinese onshore futures price in
# CNY/t inclusive of VAT, not a Korean CFR purchase price. Northeast Asian resin moves together
# closely enough that the trend is the useful part, which is why the card says so on its face.
function Get-DceResinSeries {
    param($cfg, $years = 2, $everyNth = 5)

    try {
        $uri = "https://stock2.finance.sina.com.cn/futures/api/jsonp.php/var%20_k=/InnerFuturesNewService.getDailyKLine?symbol=$([uri]::EscapeDataString($cfg.Symbol))"
        # Sina rejects the request without a matching Referer, and answers GBK for the quote
        # endpoint - this K-line one is plain ASCII JSON, which is the other reason to prefer it.
        $resinHeaders = $headers.Clone()
        $resinHeaders["Referer"] = "https://finance.sina.com.cn"
        $resp = Invoke-WebRequest -Uri $uri -Headers $resinHeaders -UseBasicParsing -TimeoutSec 45

        # Payload is a JSONP wrapper with an anti-hotlink <script> comment in front of it, so
        # slice to the array rather than trying to strip a fixed prefix.
        $content = $resp.Content
        $start = $content.IndexOf('[')
        $end = $content.LastIndexOf(']')
        if ($start -lt 0 -or $end -le $start) { throw "K-line array not found in response" }
        # Assign before wrapping: Windows PowerShell's ConvertFrom-Json emits a JSON array as one
        # pipeline object, so @(... | ConvertFrom-Json) yields a 1-element array holding the whole
        # array rather than the rows. @() on an already-assigned array is the no-op we want.
        $parsed = ConvertFrom-Json ($content.Substring($start, $end - $start + 1))
        $rows = @($parsed)
        if ($rows.Count -eq 0) { throw "no rows returned" }

        # yyyy-MM-dd sorts lexicographically, so a string compare is exact here and avoids
        # per-row DateTime parsing across ~3,000 rows.
        $cutoff = (Get-Date).AddYears(-$years).ToString("yyyy-MM-dd")
        $recent = @($rows | Where-Object { $_.d -ge $cutoff })
        if ($recent.Count -eq 0) { throw "no rows inside the $years-year window" }

        # Every 5th trading day ~= weekly, matching the 1wk/2y shape the Yahoo cards already use
        # so the charts sit side by side at the same density.
        $sampled = @(for ($i = 0; $i -lt $recent.Count; $i += $everyNth) { $recent[$i] })
        if ($sampled[-1].d -ne $recent[-1].d) { $sampled += $recent[-1] }  # always keep the latest close

        $points = foreach ($r in $sampled) {
            [PSCustomObject]@{ label = $r.d; value = [math]::Round([double]$r.c, 0) }
        }

        [PSCustomObject]@{
            id          = $cfg.Id
            displayName = $cfg.DisplayName
            unit        = $cfg.Unit
            note        = $cfg.Note
            # Exchange comes from config: resin trades on Dalian, the alkalis on Zhengzhou.
            # Sina serves both from one endpoint, so only the label differs.
            source      = "$(if ($cfg.Exchange) { $cfg.Exchange } else { '대련상품거래소(DCE)' }) · Sina"
            currency    = $cfg.Currency
            points      = @($points)
            newsQuery   = $cfg.NewsQuery
        }
    } catch {
        Write-Warning "중국 선물 조회 실패 '$($cfg.Symbol)': $($_.Exception.Message)"
        $null
    }
}

# --- 한국은행 ECOS 생산자물가지수 --------------------------------------------------------
# The one domestic-price series here. Everything else priced in this section is a foreign
# benchmark standing in for what Korea pays; this is what Korean producers actually realised.
#
# It exists because 염소 and 염산 have no free per-tonne price anywhere. Customs looks like it
# should work and does not: HS 280110 exports run 1.5-12 tonne shipments at $9,000-23,600/t,
# which is electronic-grade chlorine in cylinders. Bulk chlorine is hazardous and moves by
# pipeline and tanker inside the country, so it never appears in trade data at all. Paid
# subscriptions (ChemLocus, ChemAnalyst) are the only per-tonne sources, same as for KOH.
#
# So this is a category index, not a chlorine price: 기초무기화합물 bundles chlorine, HCl and
# caustic soda together, and it is published as an index rather than 원/톤. The card says so.
function Get-EcosSeries {
    param($cfg, $months = 24)

    # The public sample key works and is what runs without a secret; it caps a call at 10 rows,
    # so pages are 10 wide regardless of key rather than branching on which one is in use.
    $key = if ($env:ECOS_API_KEY) { $env:ECOS_API_KEY } else { "sample" }
    $pageSize = 10

    try {
        # PPI lags about two months, so anchor on a month that is certainly published rather
        # than on today - asking for an unpublished month returns nothing, not an error.
        $end = (Get-Date).AddMonths(-1)
        $start = $end.AddMonths(-($months - 1))
        $startStr = $start.ToString("yyyyMM")
        $endStr = $end.ToString("yyyyMM")

        $rows = @()
        for ($from = 1; $from -le $months; $from += $pageSize) {
            $to = $from + $pageSize - 1
            $uri = "https://ecos.bok.or.kr/api/StatisticSearch/$([uri]::EscapeDataString($key))/json/kr/$from/$to/" +
                   "$($cfg.StatCode)/M/$startStr/$endStr/$($cfg.ItemCode)"
            $resp = Invoke-RestMethod -Uri $uri -Headers $headers -TimeoutSec 30

            if ($resp.RESULT) { throw "ECOS: $($resp.RESULT.CODE) $($resp.RESULT.MESSAGE)" }
            $page = @($resp.StatisticSearch.row)
            if ($page.Count -eq 0) { break }
            $rows += $page
            if ($page.Count -lt $pageSize) { break }
            Start-Sleep -Milliseconds 250
        }
        if ($rows.Count -eq 0) { throw "no rows returned" }

        $points = foreach ($r in $rows) {
            $t = [string]$r.TIME
            if ($t -notmatch '^\d{6}$') { continue }
            $v = $r.DATA_VALUE
            if (-not $v -or $v -notmatch '^-?[\d.]+$') { continue }
            [PSCustomObject]@{
                label = $t.Substring(0, 4) + "-" + $t.Substring(4, 2)
                value = [math]::Round([double]$v, 2)
            }
        }
        $points = @($points | Sort-Object label)
        if ($points.Count -eq 0) { throw "no usable data points" }

        [PSCustomObject]@{
            id          = $cfg.Id
            displayName = $cfg.DisplayName
            unit        = $cfg.Unit
            note        = $cfg.Note
            source      = "한국은행 ECOS"
            currency    = ""
            points      = $points
            newsQuery   = $cfg.NewsQuery
        }
    } catch {
        Write-Warning "ECOS 지수 조회 실패 ($($cfg.Id)): $($_.Exception.Message)"
        $null
    }
}

# --- 관세청 수입 단가 (data.go.kr 품목별 국가별 수출입실적) --------------------------------
# Deliberately generic: this is the one source here that can price nearly any traded input, so
# it is driven entirely by config.customsSeries rather than wired to a particular commodity.
# Adding a material is one config entry - no code change.
#
# Unit price is derived, not published: the API reports value and weight, so 수입금액 ÷ 수입중량
# is the landed USD/톤. That is what makes it worth having - it is what Korea actually paid,
# not a foreign benchmark standing in for it.
#
# Two limits worth knowing before relying on it. The window is capped at one year per call, so
# a longer series costs one call per year. And the data is monthly with roughly a month's lag -
# on 2026-08-28 the newest month available was 2026-07 - which makes this a confirmation
# series, not a leading one. Do not put a fast-moving decision on top of it.
function Get-CustomsImportSeries {
    param($cfg, $months = 12)

    $key = $env:DATA_GO_KR_KEY
    if (-not $key) { return $null }

    try {
        $end = (Get-Date).AddMonths(-1)          # newest published month, given the lag
        $start = $end.AddMonths(-($months - 1))
        $uri = "https://apis.data.go.kr/1220000/nitemtrade/getNitemtradeList" +
               "?serviceKey=$([uri]::EscapeDataString($key))" +
               "&strtYymm=$($start.ToString('yyyyMM'))&endYymm=$($end.ToString('yyyyMM'))" +
               "&hsSgn=$([uri]::EscapeDataString($cfg.HsSgn))"
        if ($cfg.CntyCd) { $uri += "&cntyCd=$([uri]::EscapeDataString($cfg.CntyCd))" }

        $resp = Invoke-WebRequest -Uri $uri -Headers $headers -UseBasicParsing -TimeoutSec 45
        [xml]$xml = $resp.Content

        $code = $xml.response.header.resultCode
        if ($code -ne "00") { throw "resultCode=$code $($xml.response.header.resultMsg)" }

        # 총계 repeats the window sum as a pseudo-row; a real month always looks like "2026.07".
        $items = @($xml.response.body.items.item | Where-Object { $_.year -match '^\d{4}\.\d{2}$' })
        if ($cfg.StatKorMatch) {
            $items = @($items | Where-Object { $_.statKor -like "*$($cfg.StatKorMatch)*" })
        }
        if ($items.Count -eq 0) { throw "no rows matched" }

        # One HS heading spans several sub-items per month, so sum value and weight across them
        # before dividing - averaging the per-row unit prices would weight a 5-tonne shipment
        # the same as a 2,000-tonne one.
        $byMonth = @{}
        foreach ($it in $items) {
            $m = $it.year
            if (-not $byMonth.ContainsKey($m)) { $byMonth[$m] = @{ dlr = 0.0; wgt = 0.0 } }
            $byMonth[$m].dlr += [double]$it.impDlr
            $byMonth[$m].wgt += [double]$it.impWgt
        }

        # Guard on value as well as weight. An HS code that does not exist still answers 정상서비스
        # with rows carrying impDlr=0 and a nonzero impWgt, which a weight-only check waves
        # through as a 0 USD/톤 card - a typo in config would ship a plausible-looking empty chart.
        $points = foreach ($m in ($byMonth.Keys | Sort-Object)) {
            $w = $byMonth[$m].wgt
            $d = $byMonth[$m].dlr
            if ($w -le 0 -or $d -le 0) { continue }
            [PSCustomObject]@{
                label = $m -replace '\.', '-'
                value = [math]::Round(($d / $w) * 1000, 0)   # USD per tonne
            }
        }
        $points = @($points)
        if ($points.Count -eq 0) { throw "no month had both import value and weight - check HsSgn/CntyCd" }

        [PSCustomObject]@{
            id          = $cfg.Id
            displayName = $cfg.DisplayName
            unit        = if ($cfg.Unit) { $cfg.Unit } else { "USD/톤" }
            note        = $cfg.Note
            source      = "관세청 수출입무역통계 (data.go.kr)"
            currency    = "$"
            points      = $points
            newsQuery   = $cfg.NewsQuery
        }
    } catch {
        Write-Warning "관세청 수입단가 조회 실패 ($($cfg.Id)): $($_.Exception.Message)"
        $null
    }
}

# --- SCFI (Shanghai Containerized Freight Index) ------------------------------------------
# The AJAX endpoint behind SSE's own public SCFI page. Their historical-series endpoint
# (/singleIndex/scfi) requires a subscriber login, so only the current and prior week are
# available - shown as a value + weekly change rather than a chart.
# One fetcher for every Shanghai Shipping Exchange index, because the payload shape is identical
# across them - only indexName and which dataItemTypeName row to pick differ.
#
# SCFI publishes its per-lane rates as null on the free endpoint (Korea 20ft Pusan included -
# those are subscriber-only), so from SCFI only the composite is usable. CCFI carries values for
# all 13 lanes, which is the reason both are fetched: the composite is a Shanghai-to-world
# average weighted toward Europe and the Americas, lanes this cargo never touches.
function Get-SseIndex {
    param($indexName, $itemType, $id, $displayName, $note)

    try {
        $sseHeaders = $headers.Clone()
        $sseHeaders["Referer"] = "https://en.sse.net.cn/indices/scfinew.jsp"
        $sseHeaders["X-Requested-With"] = "XMLHttpRequest"
        $resp = Invoke-RestMethod -Uri "https://en.sse.net.cn/currentIndex?indexName=$indexName" -Headers $sseHeaders

        $data = $resp.data
        if (-not $data) { throw "no data node in response" }
        $row = $data.lineDataList | Where-Object { $_.dataItemTypeName -eq $itemType } | Select-Object -First 1
        if (-not $row) { throw "row '$itemType' not found" }
        # Lane rows exist but come back null when the value is subscriber-only; a null would
        # otherwise round to a confident-looking 0.
        if ($null -eq $row.currentContent) { throw "row '$itemType' has no value (구독 전용일 수 있음)" }

        [PSCustomObject]@{
            id          = $id
            displayName = $displayName
            current     = [math]::Round([double]$row.currentContent, 1)
            previous    = [math]::Round([double]$row.lastContent, 1)
            change      = [math]::Round([double]$row.absolute, 1)
            changePct   = [math]::Round([double]$row.percentage, 2)
            currentDate = Format-DateOnly $data.currentDate
            lastDate    = Format-DateOnly $data.lastDate
            note        = $note
            source      = "Shanghai Shipping Exchange"
        }
    } catch {
        Write-Warning "SSE index fetch failed ($indexName/$itemType): $($_.Exception.Message)"
        $null
    }
}

# --- 국내 경유가 (Opinet) -------------------------------------------------------------------
# Opinet's public API is free but key-gated (signup at opinet.co.kr, 1,500 calls/day). Without
# a key the endpoint answers with an empty OIL array rather than an error, so this returns
# $null and the dashboard shows a "키 필요" placeholder instead of a broken card.
# --- 산업용 전기 판매단가 -------------------------------------------------------------------
# Electrolysis is how KOH comes out of KCl brine, so power is a first-order input cost here.
#
# This is what industrial customers are actually billed per kWh - KEPCO's revenue divided by
# industrial sales - not SMP. SMP is the wholesale clearing price generators are paid; a plant
# never sees it. An earlier version charted SMP because it moves daily and the tariff does not,
# but a daily line of the wrong number is worse than an annual line of the right one: the
# series below shows 105.48 in 2021 becoming 181.90 in 2025, a 72% step-change in the cost of
# running a cell room, which SMP's daily wobble said nothing about.
#
# Caveat kept on the card: it is the industry-wide average, so a specific 계약종별·전압·시간대
# contract will differ in level - the trend is what transfers, not the absolute number.
#
# EPSIS renders the series straight into its page as chart rows, so no key is needed. The
# data.go.kr equivalent needs a second signup on 전력데이터개방포털 on top of the portal key.
function Get-IndustrialPowerPrice {
    param($years = 16)

    try {
        $resp = Invoke-WebRequest -Uri "https://epsis.kpx.or.kr/epsisnew/selectEksaScfChart.do?menuId=060600" `
            -Headers $headers -UseBasicParsing -TimeoutSec 30

        # Series order is fixed by the chart legend: 주택용/일반용/교육용/산업용/농사용/가로등/심야,
        # mapping onto Value, Value2 .. Value7 - so 산업용 is Value4. Verified against the
        # published table: 2025 reads 농사용 88.55 (lowest, subsidised) and 산업용 181.90.
        $legend = [regex]::Match($resp.Content, 'lineChartLayoutMake\("Date","([^"]+)"')
        if ($legend.Success) {
            $names = $legend.Groups[1].Value -split '/'
            $idx = [array]::IndexOf($names, "산업용")
            if ($idx -lt 0) { throw "범례에 산업용이 없습니다: $($legend.Groups[1].Value)" }
            $valueKey = if ($idx -eq 0) { "Value" } else { "Value$($idx + 1)" }
        } else {
            $valueKey = "Value4"
        }

        $points = foreach ($m in [regex]::Matches($resp.Content, 'chartData\.push\(\{([^}]*)\}\)')) {
            $blob = $m.Groups[1].Value
            $year = [regex]::Match($blob, '"Date"\s*:\s*"(\d{4})"')
            $val  = [regex]::Match($blob, "`"$valueKey`"\s*:\s*`"([0-9.]+)`"")
            if (-not $year.Success -or -not $val.Success) { continue }
            $v = [double]$val.Groups[1].Value
            if ($v -le 0) { continue }   # pre-1973 rows are zero-filled placeholders
            [PSCustomObject]@{ label = $year.Groups[1].Value; value = [math]::Round($v, 2) }
        }

        # the page repeats each year across chart and grid blocks - keep one row per year
        $points = @($points | Group-Object label | ForEach-Object { $_.Group[0] } |
            Sort-Object label | Select-Object -Last $years)
        if ($points.Count -eq 0) { throw "산업용 판매단가를 파싱하지 못했습니다" }

        [PSCustomObject]@{
            id          = "power"
            displayName = "산업용 전기요금"
            unit        = "원/kWh"
            currency    = ""
            note        = "한전 산업용 평균 판매단가 · 연 1회(7월경) 갱신 · 업계 평균이라 개별 계약 단가와는 차이"
            source      = "전력거래소 EPSIS"
            points      = $points
        }
    } catch {
        Write-Warning "산업용 전기요금 fetch failed: $($_.Exception.Message)"
        $null
    }
}

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
# Google News indexes SEO spam farms that publish Korean gambling copy on foreign domains, and
# they match on almost any query - "엠카지노 도메인에 대한 궁금증을 해소하는 완벽한 가이드" from
# an Italian site surfaced on both fuel cards at once. This digest is mailed to a work address
# every morning, so a gambling link in it is not merely noise.
#
# Two checks, because either alone leaks. Keywords catch a new domain running the same copy;
# the source list catches a farm that drops the obvious words. Both are in config.json so a
# newly seen farm is one line, not a code change.
#
# Chosen to avoid false positives on this dashboard's actual subjects: "슬롯" is left out
# because 선복 슬롯 is ordinary shipping vocabulary and the 해상운임 card would lose real
# headlines to it; "슬롯머신" carries the meaning without the collision.
function Test-SpamHeadline {
    param([string]$title, [string]$source)

    $haystack = "$title $source"
    foreach ($word in $spamKeywords) {
        if ($haystack -like "*$word*") {
            $script:spamBlocked++
            return $true
        }
    }
    foreach ($bad in $spamSources) {
        if ($source -and $source -like "*$bad*") {
            $script:spamBlocked++
            return $true
        }
    }
    return $false
}

# Scores a headline for "is this worth stopping on today".
#
# The scoring exists because the company's own name is a weak signal on its own: 유니드 appears
# in auto-generated stock write-ups and in 조직문화 press releases as readily as in the piece
# reporting 가동률 90%대 and 영업익 -44.6%. Name alone would rank those equally, so the noise
# term is what does the real work - a headline can carry the company and still finish below
# threshold.
#
# Impact keywords are events, not topics, deliberately. Every item on the 해상운임 card is about
# freight, so "운임" separates nothing there; 급등·봉쇄·차질 do.
#
# Returns the score and the labels behind it, because the badge shown to the reader says what
# they would get by clicking - "유니드 직접 · 실적" - rather than asserting "중요", which is a
# claim with nothing in it.
function Get-NewsImportance {
    param([string]$title, [string]$source)

    $cfg = $config.newsScoring
    if (-not $cfg) { return $null }

    $score = 0
    $labels = New-Object System.Collections.Generic.List[string]

    $hit = $false
    foreach ($w in @($cfg.companyWords)) { if ($title -like "*$w*") { $hit = $true; break } }
    if ($hit) { $score += $cfg.companyScore; $labels.Add($cfg.companyLabel) }
    else {
        foreach ($w in @($cfg.peerWords)) {
            if ($title -like "*$w*") { $score += $cfg.peerScore; $labels.Add($cfg.peerLabel); break }
        }
    }

    foreach ($grp in @($cfg.impactGroups)) {
        foreach ($w in @($grp.words)) {
            if ($title -like "*$w*") { $score += $grp.score; $labels.Add($grp.label); break }
        }
    }

    # A figure in the headline usually means it reports something rather than describes it.
    if ($title -match '\d') { $score += $cfg.numberScore }

    foreach ($w in @($cfg.noiseWords)) {
        if ("$title $source" -like "*$w*") { $score += $cfg.noiseScore; break }
    }

    [PSCustomObject]@{
        score  = $score
        flag   = ($score -ge $cfg.threshold)
        reason = (($labels | Select-Object -Unique) -join " · ")
    }
}

function Get-NewsHeadlines {
    # Google News RSS ranks by relevance, not date, and honours no recency unless the query
    # says so. Taking the first N items therefore returned whatever matched best across all
    # time: the 수급 뉴스 cards were showing headlines 322 and even 1,569 days old, with the
    # freshest item on the page a month behind. Asking for a window and then sorting and
    # filtering by date is what makes "오늘의 뉴스" actually mean today's.
    param($query, $max = 4, $withinDays = 21)

    $scoped = if ($withinDays -gt 0) { "$query when:${withinDays}d" } else { $query }
    $uri = "https://news.google.com/rss/search?q=" + [uri]::EscapeDataString($scoped) + "&hl=ko&gl=KR&ceid=KR:ko"
    try {
        $raw = Invoke-WebRequest -Uri $uri -Headers $headers -UseBasicParsing
        [xml]$rss = $raw.Content
        $cutoff = (Get-Date).ToUniversalTime().AddDays(-$withinDays)

        $parsed = @(foreach ($it in $rss.rss.channel.item) {
            $title = $it.title
            $source = $null
            if ($title -match '^(.*) - ([^-]{1,40})$') {
                $title = $matches[1].Trim(); $source = $matches[2].Trim()
            }
            # RSS pubDate is RFC-822 with English month/day names ("Tue, 26 Aug 2026 ..."), which
            # a non-English culture can't parse - and an unguarded throw here loses every headline
            # from the whole feed, not just the one bad item. Parse invariantly, skip on failure.
            $when = $null
            try {
                $when = [System.DateTimeOffset]::Parse(
                    $it.pubDate, [System.Globalization.CultureInfo]::InvariantCulture
                )
            } catch {
                Write-Warning "  (pubDate 파싱 실패, 날짜 생략: '$($it.pubDate)')"
            }
            # An item whose date won't parse can't be shown to be recent, and the whole point
            # here is recency - drop it rather than let an undateable headline pose as today's.
            if ($null -eq $when -or $when.UtcDateTime -lt $cutoff) { continue }

            if (Test-SpamHeadline -title $title -source $source) { continue }

            $rank = Get-NewsImportance -title $title -source $source
            [PSCustomObject]@{
                title  = $title
                source = $source
                date   = $when.ToString("yyyy-MM-dd")
                sortAt = $when.UtcDateTime
                link   = $it.link
                score  = if ($rank) { $rank.score } else { 0 }
                flag   = if ($rank) { $rank.flag } else { $false }
                reason = if ($rank) { $rank.reason } else { "" }
            }
        })

        # Still newest-first inside the card - recency is what this feed is for. Selection of
        # the few items shown is by date; the flagged ones get pulled up afterwards so a
        # 9-point headline from three days ago does not sit under today's filler.
        $fresh = @($parsed | Sort-Object sortAt -Descending | Select-Object -First $max |
                   Sort-Object @{Expression={[int]$_.flag}; Descending=$true},
                               @{Expression="sortAt"; Descending=$true})
        if ($fresh.Count -eq 0) {
            # ${} braces required: PowerShell would otherwise read the trailing Korean
            # character as part of the variable name and print an empty number.
            Write-Host "    (최근 ${withinDays}일 내 '$query' 기사 없음)"
        }
        # sortAt is dropped (a DateTime the page has no use for); score/flag/reason are what
        # the badge and the mail's "눈여겨볼 기사" block read.
        @($fresh | Select-Object title, source, date, link, score, flag, reason)
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
    # de-dup by link
    $seen = New-Object System.Collections.Generic.HashSet[string]
    $deduped = @(foreach ($n in $news) {
        if ($seen.Add($n.link)) { $n }
    })

    # Order across the merged queries, not within each one. Keeping first-seen order meant a
    # flagged headline from the third query sat behind everything the first query returned -
    # invisible on the page's 8-item list, but the mail only prints the top 3 and was dropping
    # it entirely. Sort once here so both surfaces slice the same ranking.
    $ordered = @($deduped | Sort-Object @{Expression={[int]$_.flag}; Descending=$true},
                                        @{Expression="date"; Descending=$true})

    [PSCustomObject]@{
        id          = $mat.Id
        displayName = $mat.DisplayName
        news        = @($ordered | Select-Object -First 8)
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
$typhoon = Get-TyphoonWatch -hubs $config.typhoonWatchHubs -transshipHubs $config.typhoonTransshipHubs -arrivalHubs $config.typhoonArrivalHubs

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

Write-Host "Fetching commodity series (FX, oil)..."
$yahooSeries = @(foreach ($cfg in $config.yahooSeries) {
    Write-Host "  - $($cfg.DisplayName)"
    Get-YahooSeries $cfg
    Start-Sleep -Milliseconds 400
})
$yahooSeries = @($yahooSeries | Where-Object { $_ })

Write-Host "Fetching DCE resin futures (PP/PE)..."
$resinSeries = @(foreach ($cfg in $config.dceSeries) {
    Write-Host "  - $($cfg.DisplayName)"
    Get-DceResinSeries $cfg
    Start-Sleep -Milliseconds 400
})
$resinSeries = @($resinSeries | Where-Object { $_ })

# Empty by default - the plumbing is here so a future material is a config entry, not a code
# change. Skips silently without a key, exactly like the Opinet card.
$ecosSeries = @()
if ($config.ecosSeries -and @($config.ecosSeries).Count -gt 0) {
    Write-Host "Fetching 한국은행 물가지수..."
    $ecosSeries = @(foreach ($cfg in $config.ecosSeries) {
        Write-Host "  - $($cfg.DisplayName)"
        Get-EcosSeries $cfg
        Start-Sleep -Milliseconds 300
    })
    $ecosSeries = @($ecosSeries | Where-Object { $_ })
}

$customsSeries = @()
if ($config.customsSeries -and @($config.customsSeries).Count -gt 0) {
    if ($env:DATA_GO_KR_KEY) {
        Write-Host "Fetching 관세청 수입 단가..."
        $customsSeries = @(foreach ($cfg in $config.customsSeries) {
            Write-Host "  - $($cfg.DisplayName)"
            Get-CustomsImportSeries $cfg
            Start-Sleep -Milliseconds 400
        })
        $customsSeries = @($customsSeries | Where-Object { $_ })
    } else {
        Write-Warning "DATA_GO_KR_KEY 미설정 - 관세청 수입 단가 카드를 건너뜁니다."
    }
}

Write-Host "Fetching SCFI..."
$scfi = Get-SseIndex -indexName "scfi" -itemType "SCFI_T" -id "scfi" `
    -displayName "컨테이너 운임지수 (SCFI)" -note "상하이 → 세계 주요 13개 항로 수출 컨테이너 운임"

# Lane-level rates, which the SCFI composite above averages away - it is weighted toward Europe
# and the Americas, so a move on the lanes this cargo actually uses barely registers in it.
Write-Host "Fetching CCFI 항로별 운임..."
$sseLanes = @(foreach ($lane in $config.sseLanes) {
    Write-Host "  - $($lane.Label)"
    Get-SseIndex -indexName $lane.IndexName -itemType $lane.ItemType -id $lane.Id `
        -displayName $lane.Label -note $null
    Start-Sleep -Milliseconds 300
})
$sseLanes = @($sseLanes | Where-Object { $_ })

Write-Host "Fetching domestic fuel prices..."
$fuel = @(Get-DomesticFuelPrices | Where-Object { $_ })

# Both of these upstreams serve only a short window, so merge into (and read back from) the
# accumulated store - that is what turns 7 days of pump prices and 2 weeks of SCFI into a
# series worth charting over months.
$historyStore = Read-HistoryStore
foreach ($f in $fuel) {
    # @() at the call site, not just inside the function: a function returning a one-element
    # collection has it unrolled to a bare object on capture, and ConvertTo-Json then writes
    # an object where the page expects an array - points.length goes undefined and the chart
    # renders nothing. Only bites a series on its very first day, which is exactly when
    # nobody is looking closely.
    $merged = @(Merge-HistorySeries -store $historyStore -key "fuel-$($f.id)" -points $f.points)
    $f.points = $merged
    $f.note = "전국 주유소 평균 · 누적 $($merged.Count)일"
}
if ($scfi) {
    $scfiPoints = @(
        [PSCustomObject]@{ label = $scfi.lastDate;    value = $scfi.previous }
        [PSCustomObject]@{ label = $scfi.currentDate; value = $scfi.current }
    ) | Where-Object { $_.label }
    $scfiHistory = @(Merge-HistorySeries -store $historyStore -key "scfi" -points $scfiPoints)
    $scfi | Add-Member -NotePropertyName points -NotePropertyValue $scfiHistory -Force
}

Write-HistoryStore -store $historyStore

# Published annually and already carrying its own decades of history, so unlike pump prices or
# SCFI this one needs no accumulation - it comes back whole on every fetch.
Write-Host "Fetching 산업용 전기요금..."
$power = Get-IndustrialPowerPrice
if ($power) {
    $latest = $power.points[-1]
    Write-Host "  $($latest.label)년 $($latest.value)원/kWh (최근 $($power.points.Count)개년)"
}

# One flat list so the dashboard/email render every price card the same way regardless of
# which upstream it came from. Order here is the display order.
$priceCards = @()
# FX leads: every imported packaging input and the whole ocean-freight bill is quoted in
# dollars, so a won move resets the landed cost of every other card below it. Note this list
# selects Yahoo series by explicit id - a series added to config.json is dropped silently
# unless it is named here too.
$priceCards += @($yahooSeries | Where-Object { $_.id -eq "usdkrw" })
$priceCards += @($yahooSeries | Where-Object { $_.id -eq "wti" -or $_.id -eq "brent" })
# Resin sits next to crude deliberately: PP/PE are naphtha derivatives, so the oil cards above
# are the upstream half of the same story the film and strapping prices below tell.
$priceCards += @($resinSeries)
$priceCards += @($fuel)
# Power sits after the fuels because it is the same question - what energy costs this month -
# but the one that lands hardest here: KOH comes out of an electrolysis cell.
if ($power) { $priceCards += $power }
# Right after the caustic-soda card: NaOH is the Chinese futures read on where the caustic pair
# is heading, this is what Korean producers actually realised on the same shelf of chemicals.
$priceCards += @($ecosSeries)
$priceCards += @($customsSeries)
if ($kcl) { $priceCards += $kcl }
$priceCards = @($priceCards)

# --- Cards that were expected but did not arrive ------------------------------------------
# Every fetcher returns $null on failure and the callers filter those out, so a card that
# fails simply vanishes: eleven become ten, and nothing on the page says which one left or
# whether it was ever meant to be there. That is the worst failure mode here, because the
# page still looks complete.
#
# The staleness tag already established the principle - a figure two months old says so in
# amber rather than passing as this morning's. Absence deserves the same treatment, so a
# missing card keeps its slot and says it failed, carrying the last value seen on a previous
# run so the reader is not left with nothing.
$expectedCards = [ordered]@{}
foreach ($y in @($config.yahooSeries))  { $expectedCards[[string]$y.Id] = $y.DisplayName }
foreach ($d in @($config.dceSeries))    { $expectedCards[[string]$d.Id] = $d.DisplayName }
foreach ($e in @($config.ecosSeries))   { $expectedCards[[string]$e.Id] = $e.DisplayName }
foreach ($u in @($config.customsSeries)){ $expectedCards[[string]$u.Id] = $u.DisplayName }
$expectedCards["kcl"]   = "KCl (염화칼륨)"
$expectedCards["power"] = "산업용 전기요금"
# Opinet's two only count as expected when a key exists - without one they are deliberately
# skipped, and calling that a failure would cry wolf on every keyless run.
if ($env:OPINET_API_KEY) {
    $expectedCards["D047"] = "국내 경유 (전국평균)"
    $expectedCards["B027"] = "국내 휘발유 (전국평균)"
}

# Remember what each card last looked like, so tomorrow's failure can still show a number.
foreach ($c in $priceCards) {
    $pts = @($c.points)
    if ($pts.Count -eq 0) { continue }
    $historyStore["lastSeen-$($c.id)"] = @{
        $pts[-1].label = $pts[-1].value
    }
}

$arrived = @($priceCards | ForEach-Object { [string]$_.id })
$missingCards = @(foreach ($id in $expectedCards.Keys) {
    if ($arrived -contains [string]$id) { continue }
    $last = $historyStore["lastSeen-$id"]
    $lastLabel = $null; $lastValue = $null
    if ($last -and $last.Keys.Count -gt 0) {
        $lastLabel = @($last.Keys)[0]
        $lastValue = $last[$lastLabel]
    }
    [PSCustomObject]@{
        id          = $id
        displayName = $expectedCards[$id]
        failed      = $true
        lastLabel   = $lastLabel
        lastValue   = $lastValue
        points      = @()
        note        = "오늘 데이터를 가져오지 못했습니다"
        source      = ""
        unit        = ""
        currency    = ""
    }
})
if ($missingCards.Count -gt 0) {
    Write-Warning "수집 실패 카드 $($missingCards.Count)개: $(($missingCards | ForEach-Object { $_.displayName }) -join ', ')"
    $priceCards = @($priceCards) + $missingCards
}
Write-HistoryStore -store $historyStore

# Attach the long-form explanations by card id, after the list is assembled rather than inside
# each fetcher. The cards arrive from six different sources - Yahoo, DCE, ECOS, Opinet, EPSIS,
# World Bank - and half of them are built in code rather than from config, so keying off id here
# is the one place that reaches all of them and keeps the prose in config.json.
foreach ($c in $priceCards) {
    $about = $config.cardAbout.($c.id)
    if ($about) { $c | Add-Member -NotePropertyName about -NotePropertyValue $about -Force }
}

# Sort key rather than a fixed assembly order, because the freight cards are built in the page
# rather than here - ordering by hand would mean keeping two lists in step, and they had already
# drifted: KCl, the feedstock this company converts, was rendering last.
$orderList = @($config.cardOrder)
function Get-CardSort {
    param($id)
    $i = [array]::IndexOf($orderList, [string]$id)
    # Unlisted ids keep their existing relative position, after everything listed.
    if ($i -lt 0) { 900 } else { $i }
}
foreach ($c in $priceCards) {
    $c | Add-Member -NotePropertyName sort -NotePropertyValue (Get-CardSort $c.id) -Force
}
$priceCards = @($priceCards | Sort-Object sort)
$scfiSort = Get-CardSort "scfi"
$laneSort = Get-CardSort "ccfi-lanes"
if ($scfi -and $config.cardAbout.scfi) {
    $scfi | Add-Member -NotePropertyName about -NotePropertyValue $config.cardAbout.scfi -Force
}
# The lane card is one card built from several series, so its text is keyed by the card rather
# than by any single lane id.
$laneAbout = $config.cardAbout.'ccfi-lanes'

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

# Seasonality is a 47-year statistic, not a daily reading, so it ships as a file rather than
# a fetch - IBTrACS is a 109MB CSV and re-deriving the same table every morning would be a
# lot of bandwidth to arrive at yesterday's answer. Regenerate it when a season's worth of
# new storms is worth folding in; the numbers move slowly.
$climatologyJson = "null"
$climPath = Join-Path $root "typhoon-climatology.json"
if (Test-Path $climPath) {
    $climatologyJson = (Get-Content -Path $climPath -Raw -Encoding UTF8).Trim()
} else {
    Write-Warning "typhoon-climatology.json 없음 - 계절성 표시를 건너뜁니다."
}
$pricesJson = ConvertTo-Json -InputObject @($priceCards) -Depth 6
$scfiJson = ConvertTo-JsonOrNull -InputObject $scfi -Depth 4
$sseLanesJson = ConvertTo-Json -InputObject @($sseLanes) -Depth 4
$laneAboutJson = ConvertTo-JsonOrNull -InputObject $laneAbout -Depth 2
$sortsJson = ConvertTo-Json -InputObject ([PSCustomObject]@{ scfi = $scfiSort; lanes = $laneSort }) -Depth 2 -Compress
$hasFuelKey = if ($env:OPINET_API_KEY) { "true" } else { "false" }
# A failed KCl fetch used to just not append a card, so the page came back one card shorter
# with nothing saying so - indistinguishable from "we never tracked potash". Say it instead.
$hasKcl = if ($kcl) { "true" } else { "false" }
$materialsJson = ConvertTo-Json -InputObject @($materials) -Depth 6
$fetchedAt = $nowKst.ToString("yyyy-MM-ddTHH:mm:ss") + "+09:00"

$template = Get-Content -Path (Join-Path $root "template.html") -Raw -Encoding UTF8
$output = $template.Replace("__WEATHER_JSON__", $weatherJson).Replace("__HOLIDAY_JSON__", $holidayJson).Replace("__TYPHOON_JSON__", $typhoonJson).Replace("__CLIMATOLOGY_JSON__", $climatologyJson).Replace("__PRICES_JSON__", $pricesJson).Replace("__SCFI_JSON__", $scfiJson).Replace("__SSE_LANES_JSON__", $sseLanesJson).Replace("__LANE_ABOUT_JSON__", $laneAboutJson).Replace("__CARD_SORTS_JSON__", $sortsJson).Replace("__HAS_FUEL_KEY__", $hasFuelKey).Replace("__HAS_KCL__", $hasKcl).Replace("__MATERIALS_JSON__", $materialsJson).Replace("__FETCHED_AT__", $fetchedAt)

$outPath = Join-Path $root "dashboard.html"
Set-Content -Path $outPath -Value $output -Encoding UTF8

Write-Host "Dashboard updated: $outPath"
if (-not $env:CI) {
    Start-Process $outPath
}

# --- Email summary -----------------------------------------------------------------
# Surfaced rather than silent: if this drops to zero for a long stretch the filter has
# probably stopped matching what the farms now publish, and that is worth noticing.
if ($spamBlocked -gt 0) { Write-Host "스팸 헤드라인 ${spamBlocked}건 차단됨" }

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
            # The mail is where this warning gets acted on, and the page's tooltip cannot be
            # reached from here - so a verdict built from one point has to say so in the mail too.
            $trackWarn = if ($t.trackOk -eq $false) { " <span style='font-size:10.5px;font-weight:700;color:#8a5a00;background:#fdf3dd;padding:1px 5px;'>경로 미확인</span>" } else { "" }
            @"
<div style="margin-top:9px;padding:9px 11px;background:#ffffff;border:1px solid #f3caca;">
      <div>$(Get-TyphoonBadge $t.impact) <b style="font-size:14px;color:#0b0b0b;">$($t.name)</b> <span style="font-size:11px;color:#898781;">경보등급 $($t.alertLevel)</span></div>
      <div style="font-size:12.5px;color:#0b0b0b;font-weight:600;margin-top:4px;">$(Get-TyphoonWhere $t)$trackWarn</div>
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
    # 16 bars, not 24: each bar is a nested table costing ~250 bytes, and at 24 the nine charts
    # alone were 45KB of an 85KB mail - 83% of the 102KB Gmail clips at, so one more card would
    # have truncated the news off the bottom. Two years across 16 buckets is coarser per bar but
    # the shape survives, and the dashboard still carries the full-resolution chart.
    param($values, $accent = "#2a78d6", $maxBars = 16, $height = 44)

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
        # Trimmed, not restructured. Outlook has been confirmed to render this shape, so the
        # nesting and the spacer row stay exactly as they are; what goes is repetition the
        # renderer never needed. The outer <td> holds no text node - only the inner table - so
        # its font-size/line-height reset was guarding nothing, and border-collapse is already
        # implied by cellspacing='0'. About 90 bytes a bar, and there are ~170 of them.
        $spacer = if ($pad -gt 0) { "<tr><td height='$pad' style='font-size:0;line-height:0'>&nbsp;</td></tr>" } else { "" }
        "<td style='padding:0 1px'><table cellpadding='0' cellspacing='0' border='0'>$spacer<tr><td height='$h' width='$barW' bgcolor='$fill' style='font-size:0;line-height:0'>&nbsp;</td></tr></table></td>"
    }
    "<table cellpadding='0' cellspacing='0' border='0'><tr>$($cells -join '')</tr></table>"
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

# Rows carry their sort key so the mail can interleave the freight blocks, which are built
# separately below, at the position config.cardOrder gives them. Concatenating the three groups
# instead is what left the mail showing 운임 first while the page had already moved it into the
# logistics group - the same two-lists-drift the page-side sort was meant to end.
$priceRowsHtml = foreach ($c in $priceCards) {
    $pts = @($c.points)
    if ($pts.Count -eq 0) { continue }
    $latest = $pts[-1]
    $prior = if ($pts.Count -gt 1) { $pts[-2] } else { $null }
    $change = Get-PriceChangeHtml -latestValue $latest.value -priorValue $(if ($prior) { $prior.value } else { $null })
    $chartHtml = Get-PriceChartHtml -points $pts -accent $change.accent -currency $c.currency
    [PSCustomObject]@{ sort = $c.sort; html = @"
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
"@ }
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

$laneHtml = ""
if ($sseLanes.Count -gt 0) {
    # One row per lane in a single card, so the mail shows which lane moved rather than five
    # separate blocks the reader has to line up themselves.
    $laneRows = foreach ($l in $sseLanes) {
        $flat = [math]::Abs($l.changePct) -lt 0.05
        $up = $l.change -ge 0
        $color = if ($flat) { "#6e6c66" } elseif ($up) { "#b3221f" } else { "#0a6b0a" }
        $chg = if ($flat) { "보합" } else {
            $arrow = if ($up) { "▲" } else { "▼" }
            "$arrow $(Format-PriceValue ([math]::Abs($l.change))) ($([math]::Abs($l.changePct))%)"
        }
        @"
<tr>
  <td style="padding:5px 8px 5px 0;font-size:12.5px;font-weight:600;color:#0b0b0b;">$($l.displayName)</td>
  <td style="padding:5px 8px 5px 0;font-size:13px;font-weight:700;color:#0b0b0b;text-align:right;white-space:nowrap;">$(Format-PriceValue $l.current)</td>
  <td style="padding:5px 0;font-size:12px;font-weight:700;color:$color;text-align:right;white-space:nowrap;">$chg</td>
</tr>
"@
    }
    $laneHtml = @"
<tr>
  <td style="padding:14px 16px;border-bottom:1px solid #e1e0d9;">
    <div style="font-weight:700;font-size:13.5px;color:#0b0b0b;">CCFI 항로별 운임지수</div>
    <div style="font-size:11px;color:#898781;margin-top:2px;">$($sseLanes[0].currentDate) 기준 · 전주 대비</div>
    <table style="width:100%;border-collapse:collapse;margin-top:7px;">$($laneRows -join "")</table>
    <div style="font-size:11px;color:#898781;margin-top:7px;">중국발 수출 컨테이너 운임(계약운임 포함) · Shanghai Shipping Exchange</div>
  </td>
</tr>
"@
}

# One ordered list, same keys the page sorts by, so the mail and the dashboard cannot disagree
# about what comes first.
$priceSectionRows = @()
$priceSectionRows += @($priceRowsHtml)
if ($scfiHtml) { $priceSectionRows += [PSCustomObject]@{ sort = $scfiSort; html = $scfiHtml } }
if ($laneHtml) { $priceSectionRows += [PSCustomObject]@{ sort = $laneSort; html = $laneHtml } }
$priceSectionHtml = (@($priceSectionRows | Sort-Object sort | ForEach-Object { $_.html }) -join "`n")

# Collection failures go near the top of the mail, above the news. Someone maintaining this
# needs to know a source went quiet on the day it happens - finding out weeks later, from a
# chart with a hole in it, is how a broken feed becomes permanent.
$failureHtml = ""
if ($missingCards.Count -gt 0) {
    $rows = foreach ($m in $missingCards) {
        $last = if ($null -ne $m.lastValue) {
            "<span style='color:#6e6c66;'>마지막 수집값 $($m.lastValue)$(if ($m.lastLabel) { " ($($m.lastLabel) 기준)" })</span>"
        } else { "<span style='color:#6e6c66;'>이전 수집값 없음</span>" }
        "<div style='margin-top:6px;font-size:12.5px;color:#0b0b0b;'>· <b>$($m.displayName)</b> — $last</div>"
    }
    $failureHtml = @"
<div style="margin:16px 0;padding:13px 15px;background:#fdf6e7;border:1px solid #f0dcb4;border-radius:8px;">
  <div style="font-size:12px;font-weight:700;color:#a15c00;">⚠ 오늘 수집하지 못한 항목 $($missingCards.Count)건</div>
  $($rows -join "")
  <div style="font-size:10.5px;color:#898781;margin-top:9px;">출처가 응답하지 않았거나 형식이 바뀌었을 수 있습니다. 다음 실행에서 자동 재시도하며, 계속 반복되면 점검이 필요합니다.</div>
</div>
"@
}

# Flagged headlines lifted to the top of the mail. The mail is what most people actually read,
# and the 수급 뉴스 section sits below weather and a dozen price cards - a headline worth acting
# on should not depend on scrolling that far. Nothing is duplicated away: these still appear in
# their own card below.
$highlights = @($materials | ForEach-Object { $_.news } | Where-Object { $_ -and $_.flag } |
    Sort-Object score -Descending | Select-Object -First 3)

$highlightHtml = ""
if ($highlights.Count -gt 0) {
    $rows = foreach ($h in $highlights) {
        $chip = if ($h.reason) {
            "<span style='display:inline-block;font-size:10px;font-weight:700;background:#b3221f;color:#ffffff;padding:1px 7px;border-radius:4px;margin-right:6px;'>$($h.reason)</span>"
        } else { "" }
        $meta = (@($h.source, $h.date) | Where-Object { $_ }) -join " · "
        "<div style='margin-top:8px;'>$chip<a href='$($h.link)' style='font-size:13px;font-weight:700;color:#0b0b0b;text-decoration:none;'>$($h.title)</a><div style='font-size:11px;color:#898781;margin-top:2px;'>$meta</div></div>"
    }
    $highlightHtml = @"
<div style="margin:16px 0;padding:13px 15px;background:#fdeeee;border:1px solid #f3caca;border-radius:8px;">
  <div style="font-size:12px;font-weight:700;color:#b3221f;">오늘 눈여겨볼 기사 $($highlights.Count)건</div>
  $($rows -join "")
  <div style="font-size:10.5px;color:#898781;margin-top:9px;">제목 키워드로 매긴 중요도입니다 — 기사를 읽고 판단한 것이 아니니 참고로만 보세요.</div>
</div>
"@
}

$materialsHtml = foreach ($m in $materials) {
    $newsLines = foreach ($n in ($m.news | Select-Object -First 3)) {
        # Outlet and date were already fetched but thrown away here, leaving three unattributed
        # blue lines - knowing who ran it and when is most of what makes a headline worth trusting.
        $meta = (@($n.source, $n.date) | Where-Object { $_ }) -join " · "
        $metaHtml = if ($meta) { "<div style='font-size:11px;color:#898781;margin-top:1px;'>$meta</div>" } else { "" }
        # Same left rule and reason chip the page uses, so a headline flagged there is
        # recognisable here. Inline styles only - mail clients drop stylesheets.
        if ($n.flag) {
            $chip = if ($n.reason) {
                "<span style='display:inline-block;font-size:10px;font-weight:700;background:#b3221f;color:#ffffff;padding:1px 7px;border-radius:4px;'>$($n.reason)</span><br>"
            } else { "" }
            @"
<div style="margin-top:9px;border-left:3px solid #b3221f;padding-left:9px;">
      $chip<a href="$($n.link)" style="font-size:12.5px;color:#0b0b0b;font-weight:700;text-decoration:none;line-height:1.45;">$($n.title)</a>
      $metaHtml
    </div>
"@
        } else {
            @"
<div style="margin-top:7px;">
      <a href="$($n.link)" style="font-size:12.5px;color:#2a78d6;text-decoration:none;line-height:1.45;">$($n.title)</a>
      $metaHtml
    </div>
"@
        }
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
  $failureHtml
  $highlightHtml
  $typhoonHtml
  $(Get-EmailSection "날씨 · 온습도" ($weatherRowsHtml -join "`n"))
  $(Get-EmailSection "원자재 · 물류 가격" $priceSectionHtml)
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

# --- Output checks -------------------------------------------------------------------------
# Everything above was verified by running it and reading the result. That worked while
# someone was watching; on a schedule nobody is. These are the checks that were being made by
# eye - and each one here is a mistake that actually shipped: a single-point series rendering
# as a JSON object instead of an array and blanking its chart, headlines years old passing as
# today's, a gambling link reaching the mail.
#
# Failing is the point. The workflow stops before the deploy step, so a bad page is never
# published and yesterday's good one stays up. Losing a day of freshness beats publishing
# something wrong to people who trust it.
$problems = New-Object System.Collections.Generic.List[string]

$renderedHtml = Get-Content -Path $outPath -Raw -Encoding UTF8

foreach ($token in @("__WEATHER_JSON__", "__PRICES_JSON__", "__MATERIALS_JSON__", "__FETCHED_AT__")) {
    if ($renderedHtml -like "*$token*") { $problems.Add("템플릿 치환 누락: $token") }
}

# A page with almost no cards means the run half-failed; publishing it looks like the sources
# went away rather than that this run did.
$liveCards = @($priceCards | Where-Object { -not $_.failed })
if ($liveCards.Count -lt 5) {
    $problems.Add("정상 가격 카드가 $($liveCards.Count)개뿐입니다 (최소 5개 기대)")
}
if ($missingCards.Count -gt 3) {
    $problems.Add("수집 실패 카드가 $($missingCards.Count)개입니다 (3개 초과)")
}

# Every chartable card must carry a real array. The one-element-array collapse produced a
# JSON object here and left the chart blank without erroring.
foreach ($c in $liveCards) {
    if (@($c.points).Count -eq 0) { $problems.Add("$($c.displayName): 시계열이 비어 있습니다") }
}

# Recency is the whole claim of the news cards, and spam is the thing that must never reach
# the mail - both are cheap to assert and both have been wrong before.
$allNews = @($materials | ForEach-Object { $_.news } | Where-Object { $_ })
$staleCut = $nowKst.Date.AddDays(-45)
foreach ($n in $allNews) {
    [DateTime]$nd = Get-Date
    if ([DateTime]::TryParse($n.date, [ref]$nd) -and $nd -lt $staleCut) {
        $problems.Add("오래된 기사가 남아 있습니다 ($($n.date)): $($n.title)")
    }
    if (Test-SpamHeadline -title $n.title -source $n.source) {
        $problems.Add("차단 대상 기사가 통과했습니다: $($n.title)")
    }
}
if ($allNews.Count -eq 0) { $problems.Add("수급 뉴스가 한 건도 없습니다") }

if ($problems.Count -gt 0) {
    Write-Host ""
    Write-Host "생성물 점검 실패 - 배포를 중단합니다:" -ForegroundColor Red
    foreach ($p in $problems) { Write-Host "  · $p" -ForegroundColor Red }
    if ($env:CI) { Write-Host "::error::생성물 점검 실패 $($problems.Count)건" }
    throw "생성물 점검 $($problems.Count)건 실패 - 이전 배포본을 유지합니다."
}
Write-Host "생성물 점검 통과 (카드 $($liveCards.Count)개 · 뉴스 $($allNews.Count)건)"
