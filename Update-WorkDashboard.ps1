<#
  Update-WorkDashboard.ps1
  Fetches a 7-day forecast + heat/cold advisories (Open-Meteo), the nearest upcoming Korean
  holiday block (Nager.Date), Vietnam-area typhoon activity and history relative to the
  하노이/호치민 hubs (GDACS), KCl monthly prices (World Bank Pink Sheet), and commodity/material
  news headlines (Google News RSS) listed in config.json, then regenerates dashboard.html.
  Run manually by double-clicking run.bat, or right-click > Run with PowerShell.
#>

$ErrorActionPreference = "Stop"
$root = $PSScriptRoot
$headers = @{ "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36" }

$config = Get-Content -Path (Join-Path $root "config.json") -Raw -Encoding UTF8 | ConvertFrom-Json

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
                date         = $daily.time[$i]
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
# Vietnam-sourced 부자재 shipments get delayed when a typhoon crosses the South China
# Sea / Vietnam coast, so this tracks tropical cyclones near the two reference hubs
# (하노이/호치민) instead of showing daily Vietnam weather.
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

function Get-TyphoonWatch {
    param($hubs)

    try {
        $uri = "https://www.gdacs.org/gdacsapi/api/events/geteventlist/SEARCH?eventtypes=TC"
        $resp = Invoke-RestMethod -Uri $uri -Headers $headers
        $tcs = @($resp.features | Where-Object { $_.properties.eventtype -eq "TC" })

        $items = @(foreach ($f in $tcs) {
            $p = $f.properties
            $lon = $f.geometry.coordinates[0]
            $lat = $f.geometry.coordinates[1]

            $distances = foreach ($hub in $hubs) {
                [PSCustomObject]@{ hub = $hub.DisplayName; km = Get-HaversineKm -lat1 $lat -lon1 $lon -lat2 $hub.Lat -lon2 $hub.Lon }
            }
            $nearest = $distances | Sort-Object km | Select-Object -First 1

            # "relevant" = GDACS already lists Vietnam among affected countries, or the storm's
            # current/last position is within 800km of either hub (close enough to matter for
            # inbound shipping even before Vietnam is formally listed as impacted).
            $mentionsVietnam = $p.country -match "Viet ?Nam"
            if (-not ($mentionsVietnam -or $nearest.km -le 800)) { continue }

            [PSCustomObject]@{
                name         = ($p.name -replace "^Tropical Cyclone ", "")
                alertLevel   = $p.alertlevel
                isCurrent    = ($p.iscurrent -eq "true")
                severityText = $p.severitydata.severitytext
                country      = $p.country
                fromDate     = $p.fromdate
                toDate       = $p.todate
                nearestHub   = $nearest.hub
                distanceKm   = $nearest.km
                reportUrl    = $p.url.report
            }
        })

        $active = @($items | Where-Object { $_.isCurrent } | Sort-Object distanceKm)

        # Not time-limited (unlike an "active" check) - showing when the last few Vietnam-relevant
        # typhoons actually happened, regardless of age, is what lets 부자재 shipping schedules be
        # extrapolated against typhoon-season timing rather than only reacting to a live storm.
        $today = (Get-Date).Date
        $past = @($items | Where-Object { -not $_.isCurrent -and $_.toDate } |
            Sort-Object { [DateTime]$_.toDate } -Descending | Select-Object -First 3 |
            ForEach-Object {
                $daysAgo = [math]::Round(($today - [DateTime]$_.toDate).TotalDays)
                $_ | Add-Member -NotePropertyName daysAgo -NotePropertyValue $daysAgo -PassThru
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
            $pubDate = [System.DateTimeOffset]::Parse($it.pubDate)
            [PSCustomObject]@{
                title  = $title
                source = $source
                date   = $pubDate.ToString("yyyy-MM-dd")
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
$typhoon = Get-TyphoonWatch -hubs $config.typhoonWatchHubs

Write-Host "Fetching KCl price history..."
$kcl = Get-KclPriceHistory

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
$kclJson = ConvertTo-JsonOrNull -InputObject $kcl -Depth 4
$materialsJson = ConvertTo-Json -InputObject @($materials) -Depth 6
$fetchedAt = $nowKst.ToString("yyyy-MM-ddTHH:mm:ss") + "+09:00"

$template = Get-Content -Path (Join-Path $root "template.html") -Raw -Encoding UTF8
$output = $template.Replace("__WEATHER_JSON__", $weatherJson).Replace("__HOLIDAY_JSON__", $holidayJson).Replace("__TYPHOON_JSON__", $typhoonJson).Replace("__KCL_JSON__", $kclJson).Replace("__MATERIALS_JSON__", $materialsJson).Replace("__FETCHED_AT__", $fetchedAt)

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
    $daysHtml = foreach ($d in $w.days) {
        $dAdvisoryHtml = Get-AdvisoryHtml $d.advisories
        "<div style='margin-top:2px;'><span style='display:inline-block;margin-right:10px;'>$($d.date.Substring(5)) $($d.desc) $($d.minC)°/$($d.maxC)°C · 강수확률 $($d.chanceOfRain)%</span>$dAdvisoryHtml</div>"
    }
    @"
<tr>
  <td style="padding:10px 12px;border-bottom:1px solid #e1e0d9;">
    <div style="font-weight:600;font-size:13px;color:#0b0b0b;">$($w.displayName)</div>
    <div style="font-size:12px;color:#52514e;margin-top:2px;">$($w.desc) · 현재 $($w.tempC)°C (체감 $($w.feelsLikeC)°C) · 습도 $($w.humidity)% $curAdvisoryHtml</div>
    <div style="font-size:11px;color:#898781;margin-top:4px;">$($daysHtml -join "")</div>
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

$typhoonHtml = ""
if ($typhoon) {
    $pastRows = foreach ($t in $typhoon.past) {
        "<div style='margin-top:4px;font-size:12px;color:#6e6c66;'>$($t.name) · $($t.toDate.Substring(0,10)) 소멸 (D+$($t.daysAgo)) · $($t.nearestHub) 인근</div>"
    }
    $pastBlockHtml = if ($pastRows) {
        "<div style='margin-top:8px;font-size:11px;color:#898781;'>최근 발생 이력 (다음 시기 가늠용)</div>" + ($pastRows -join "")
    } else { "" }

    if ($typhoon.active.Count -gt 0) {
        $activeRows = foreach ($t in $typhoon.active) {
            "<div style='margin-top:6px;'><b>$($t.name)</b> ($($t.alertLevel)) · $($t.nearestHub)까지 약 $($t.distanceKm)km · $($t.severityText)</div>"
        }
        $typhoonHtml = @"
<div style="margin:16px 0;padding:12px 14px;background:#fdeeee;border:1px solid #f3caca;border-radius:8px;">
  <div style="font-weight:650;font-size:13px;color:#b3221f;">⚠ 베트남 인근 태풍 활동 중 - 부자재 입고 지연 가능성 주의</div>
  $($activeRows -join "")
  $pastBlockHtml
</div>
"@
    } elseif ($pastRows) {
        $typhoonHtml = @"
<div style="margin:16px 0;padding:12px 14px;background:#f5f4f0;border:1px solid #e1e0d9;border-radius:8px;">
  <div style="font-weight:650;font-size:13px;color:#0b0b0b;">베트남 인근 활성 태풍 없음</div>
  $pastBlockHtml
</div>
"@
    } else {
        $typhoonHtml = @"
<div style="margin:16px 0;padding:12px 14px;background:#f5f4f0;border:1px solid #e1e0d9;border-radius:8px;">
  <div style="font-size:13px;color:#0b0b0b;">베트남 인근 태풍 활동 없음 · 부자재 입고 일정 영향 없음</div>
</div>
"@
    }
}

function Get-Sparkline {
    # Email clients can't reliably render inline SVG/canvas, but a plain-text sparkline made of
    # Unicode block characters works everywhere - the same trick used by CLI tools.
    param($values)
    $blocks = [char[]]"▁▂▃▄▅▆▇█"
    $min = ($values | Measure-Object -Minimum).Minimum
    $max = ($values | Measure-Object -Maximum).Maximum
    $range = $max - $min
    -join ($values | ForEach-Object {
        $idx = if ($range -eq 0) { 0 } else { [math]::Floor((($_ - $min) / $range) * ($blocks.Count - 1)) }
        $blocks[[int]$idx]
    })
}

$kclHtml = ""
if ($kcl -and $kcl.points.Count -gt 0) {
    $pts = $kcl.points
    $latest = $pts[-1]
    $prior = if ($pts.Count -gt 1) { $pts[-2] } else { $null }
    $changeText = if ($prior) {
        $diff = $latest.value - $prior.value
        $sign = if ($diff -ge 0) { "+" } else { "" }
        $color = if ($diff -ge 0) { "#b3221f" } else { "#0a6b0a" }
        "<span style='color:$color;font-weight:600;'>$sign$([math]::Round($diff,1)) (전월비)</span>"
    } else { "" }
    $spark = Get-Sparkline ($pts | ForEach-Object { $_.value })
    $kclHtml = @"
<tr>
  <td style="padding:10px 12px;border-bottom:1px solid #e1e0d9;">
    <div style="font-weight:600;font-size:13px;color:#0b0b0b;">KCl (염화칼륨) 국제가격</div>
    <div style="font-size:12px;color:#52514e;margin-top:3px;">$($latest.label) 기준 <b>`$$($latest.value)/mt</b> $changeText</div>
    <div style="font-size:16px;letter-spacing:1px;margin-top:4px;color:#2a78d6;">$spark</div>
    <div style="font-size:11px;color:#898781;margin-top:2px;">최근 $($pts.Count)개월, World Bank Pink Sheet</div>
  </td>
</tr>
"@
}

$materialsHtml = foreach ($m in $materials) {
    $newsLines = foreach ($n in ($m.news | Select-Object -First 3)) {
        "<div style='font-size:12px;color:#52514e;margin-top:3px;'>· <a href='$($n.link)' style='color:#2a78d6;text-decoration:none;'>$($n.title)</a></div>"
    }
    @"
<tr>
  <td style="padding:10px 12px;border-bottom:1px solid #e1e0d9;">
    <div style="font-weight:600;font-size:13px;color:#0b0b0b;">$($m.displayName)</div>
    $($newsLines -join "")
  </td>
</tr>
"@
}

$dashboardUrl = "https://jhkim0603.github.io/work-dashboard/"

$emailHtml = @"
<!DOCTYPE html>
<html><body style="margin:0;padding:0;background:#f9f9f7;font-family:'Malgun Gothic',sans-serif;">
<div style="max-width:600px;margin:0 auto;padding:24px 16px;">
  <h2 style="margin:0 0 4px;color:#0b0b0b;">업무 참고자료 Dashboard</h2>
  <div style="font-size:12px;color:#898781;margin-bottom:14px;">$emailDateStr 기준</div>
  <div style="margin-bottom:16px;">
    <a href="$dashboardUrl" style="display:inline-block;background:#2a78d6;color:#ffffff;font-size:13px;font-weight:bold;text-decoration:none;padding:10px 18px;border-radius:6px;">📋 대시보드 열기 →</a>
  </div>
  $holidayHtml
  $typhoonHtml
  <table style="width:100%;border-collapse:collapse;background:#ffffff;border:1px solid #e1e0d9;border-radius:8px;">
    $($weatherRowsHtml -join "`n")
    $kclHtml
    $($materialsHtml -join "`n")
  </table>
  <div style="margin-top:16px;font-size:11px;color:#898781;line-height:1.6;">
    날씨 출처: Open-Meteo. 공휴일 출처: Nager.Date. 태풍 정보 출처: GDACS. KCl 가격 출처: World Bank. 원자재 뉴스 출처: Google 뉴스. 업무 참고용 요약입니다.<br>
    자세한 내용은 <a href="$dashboardUrl" style="color:#2a78d6;">대시보드</a>에서 확인하세요.
  </div>
</div>
</body></html>
"@

$utf8NoBom = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllText((Join-Path $root "email-summary.html"), $emailHtml, $utf8NoBom)
[System.IO.File]::WriteAllText((Join-Path $root "email-subject.txt"), "업무 참고자료 Dashboard - $emailDateStr", $utf8NoBom)
Write-Host "Email summary written: email-summary.html"
