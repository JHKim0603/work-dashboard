<#
  Update-WorkDashboard.ps1
  Fetches weather + heat/cold advisories (wttr.in), the nearest upcoming Korean holiday block
  (Nager.Date), Vietnam-area typhoon activity relative to the 하노이/호치민 hubs (GDACS), and
  commodity/material news headlines (Google News RSS) listed in config.json, then regenerates
  dashboard.html.
  Run manually by double-clicking run.bat, or right-click > Run with PowerShell.
#>

$ErrorActionPreference = "Stop"
$root = $PSScriptRoot
$headers = @{ "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36" }

$config = Get-Content -Path (Join-Path $root "config.json") -Raw -Encoding UTF8 | ConvertFrom-Json

# --- Weather ------------------------------------------------------------------------
# wttr.in's own `lang=ko` translation table is inconsistent (falls back to English for
# many phrases), so weather codes are mapped to Korean here instead - the codes themselves
# (from World Weather Online) are stable regardless of language.
$weatherCodeKo = @{
    "113" = "맑음"; "116" = "부분 흐림"; "119" = "흐림"; "122" = "매우 흐림"
    "143" = "안개"; "176" = "약한 비 가능"; "179" = "약한 눈 가능"; "182" = "진눈깨비 가능"
    "185" = "약한 착빙성 이슬비 가능"; "200" = "뇌우 가능"; "227" = "눈날림"; "230" = "눈보라"
    "248" = "안개"; "260" = "착빙 안개"; "263" = "약한 이슬비"; "266" = "이슬비"
    "281" = "착빙성 이슬비"; "284" = "강한 착빙성 이슬비"; "293" = "약한 비"; "296" = "약한 비"
    "299" = "간헐적 보통 비"; "302" = "보통 비"; "305" = "간헐적 강한 비"; "308" = "강한 비"
    "311" = "약한 착빙성 비"; "314" = "보통·강한 착빙성 비"; "317" = "약한 진눈깨비"
    "320" = "보통·강한 진눈깨비"; "323" = "약한 눈"; "326" = "약한 눈"; "329" = "약한·보통 눈"
    "332" = "보통 눈"; "335" = "강한 눈 가능"; "338" = "강한 눈"; "350" = "우박"
    "353" = "약한 소나기"; "356" = "보통·강한 소나기"; "359" = "폭우"; "362" = "약한 진눈깨비 소나기"
    "365" = "보통·강한 진눈깨비 소나기"; "368" = "약한 눈 소나기"; "371" = "보통·강한 눈 소나기"
    "374" = "약한 우박 소나기"; "377" = "보통·강한 우박 소나기"; "386" = "약한 비+뇌우"
    "389" = "보통·강한 비+뇌우"; "392" = "약한 눈+뇌우"; "395" = "보통·강한 눈+뇌우"
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

    $uri = "https://wttr.in/$($loc.Lat),$($loc.Lon)?format=j1"
    try {
        $resp = Invoke-RestMethod -Uri $uri -Headers $headers
        $cur = $resp.current_condition[0]

        $days = @(foreach ($d in ($resp.weather | Select-Object -First 3)) {
            # midday (12:00) hourly slot best represents "the day's weather" for the icon/description
            $midday = $d.hourly | Where-Object { $_.time -eq "1200" } | Select-Object -First 1
            if (-not $midday) { $midday = $d.hourly[[math]::Floor($d.hourly.Count / 2)] }
            # max across the day's hourly slots, not just noon - a rain risk at any point in the
            # working day matters more here than the single midday reading
            $maxRainChance = ($d.hourly | ForEach-Object { [int]$_.chanceofrain } | Measure-Object -Maximum).Maximum
            $maxC = [int]$d.maxtempC
            $minC = [int]$d.mintempC
            [PSCustomObject]@{
                date         = $d.date
                maxC         = $maxC
                minC         = $minC
                desc         = Get-WeatherDescKo $midday.weatherCode
                chanceOfRain = $maxRainChance
                advisories   = Get-TempAdvisories -heatRefC $maxC -minC $minC
            }
        })

        $curAdvisories = Get-TempAdvisories -heatRefC ([int]$cur.FeelsLikeC) -minC $null

        [PSCustomObject]@{
            id          = $loc.Id
            displayName = $loc.DisplayName
            country     = $loc.Country
            tempC       = [int]$cur.temp_C
            feelsLikeC  = [int]$cur.FeelsLikeC
            humidity    = [int]$cur.humidity
            desc        = Get-WeatherDescKo $cur.weatherCode
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
        $recentCutoff = (Get-Date).AddDays(-10)
        $recent = @($items | Where-Object { -not $_.isCurrent -and $_.toDate -and ([DateTime]$_.toDate) -ge $recentCutoff } |
            Sort-Object { [DateTime]$_.toDate } -Descending | Select-Object -First 3)

        [PSCustomObject]@{
            active = $active
            recent = $recent
        }
    } catch {
        Write-Warning "Typhoon watch fetch failed: $($_.Exception.Message)"
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
$materialsJson = ConvertTo-Json -InputObject @($materials) -Depth 6
$fetchedAt = $nowKst.ToString("yyyy-MM-ddTHH:mm:ss") + "+09:00"

$template = Get-Content -Path (Join-Path $root "template.html") -Raw -Encoding UTF8
$output = $template.Replace("__WEATHER_JSON__", $weatherJson).Replace("__HOLIDAY_JSON__", $holidayJson).Replace("__TYPHOON_JSON__", $typhoonJson).Replace("__MATERIALS_JSON__", $materialsJson).Replace("__FETCHED_AT__", $fetchedAt)

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
    $daysHtml = foreach ($d in ($w.days | Select-Object -First 3)) {
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
if ($typhoon -and $typhoon.active.Count -gt 0) {
    $rows = foreach ($t in $typhoon.active) {
        "<div style='margin-top:6px;'><b>$($t.name)</b> ($($t.alertLevel)) · $($t.nearestHub)까지 약 $($t.distanceKm)km · $($t.severityText)</div>"
    }
    $typhoonHtml = @"
<div style="margin:16px 0;padding:12px 14px;background:#fdeeee;border:1px solid #f3caca;border-radius:8px;">
  <div style="font-weight:650;font-size:13px;color:#b3221f;">⚠ 베트남 인근 태풍 활동 중 - 부자재 입고 지연 가능성 주의</div>
  $($rows -join "")
</div>
"@
} elseif ($typhoon -and $typhoon.recent.Count -gt 0) {
    $rows = foreach ($t in $typhoon.recent) {
        "<div style='margin-top:6px;'>$($t.name) · $($t.toDate.Substring(0,10)) 소멸 · $($t.nearestHub) 인근</div>"
    }
    $typhoonHtml = @"
<div style="margin:16px 0;padding:12px 14px;background:#f5f4f0;border:1px solid #e1e0d9;border-radius:8px;">
  <div style="font-weight:650;font-size:13px;color:#0b0b0b;">베트남 인근 활성 태풍 없음 · 최근 소멸된 태풍 (여파 참고)</div>
  $($rows -join "")
</div>
"@
} elseif ($typhoon) {
    $typhoonHtml = @"
<div style="margin:16px 0;padding:12px 14px;background:#f5f4f0;border:1px solid #e1e0d9;border-radius:8px;">
  <div style="font-size:13px;color:#0b0b0b;">베트남 인근 태풍 활동 없음 · 부자재 입고 일정 영향 없음</div>
</div>
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
    $($materialsHtml -join "`n")
  </table>
  <div style="margin-top:16px;font-size:11px;color:#898781;line-height:1.6;">
    날씨 출처: wttr.in. 공휴일 출처: Nager.Date. 태풍 정보 출처: GDACS. 원자재 뉴스 출처: Google 뉴스. 업무 참고용 요약입니다.<br>
    자세한 내용은 <a href="$dashboardUrl" style="color:#2a78d6;">대시보드</a>에서 확인하세요.
  </div>
</div>
</body></html>
"@

$utf8NoBom = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllText((Join-Path $root "email-summary.html"), $emailHtml, $utf8NoBom)
[System.IO.File]::WriteAllText((Join-Path $root "email-subject.txt"), "업무 참고자료 Dashboard - $emailDateStr", $utf8NoBom)
Write-Host "Email summary written: email-summary.html"
