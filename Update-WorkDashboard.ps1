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
# 제한 시간을 따로 적지 않은 요청의 기본값. 없으면 무기한이라, 2026-09-26 CI 에서 SSE 운임 한 건이
# 응답 없이 296초를 붙잡았다(실행 344초 중). 568초까지 걸린 실행들도 같은 모양이다. -TimeoutSec 을
# 직접 적은 호출(GDACS 45초, Pink Sheet 60초 등)은 그 값이 우선한다.
$PSDefaultParameterValues['Invoke-RestMethod:TimeoutSec'] = 30
$PSDefaultParameterValues['Invoke-WebRequest:TimeoutSec'] = 30

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
        foreach ($name in @("OPINET_API_KEY", "DATA_GO_KR_KEY", "CARD_TARGETS_JSON")) {
            $val = $localSecrets.$name
            # CARD_TARGETS_JSON may be written in the local file as an object rather than a string.
            if ($val -and $val -isnot [string]) { $val = ConvertTo-Json -InputObject $val -Depth 4 -Compress }
            if ($val -and -not (Get-Item "env:$name" -ErrorAction SilentlyContinue)) {
                Set-Item "env:$name" $val
                Write-Host "  secrets.local.json에서 $name 로드"
            }
        }
    } catch {
        Write-Warning "secrets.local.json을 읽지 못했습니다 (JSON 형식 확인): $($_.Exception.Message)"
    }
}

# Contract / budget reference prices per card, e.g. {"kcl": {"ref": 380, "label": "계약가", "alertPct": 3}}.
# They come from the CARD_TARGETS_JSON secret (or secrets.local.json) and are used in the mail
# only, never written into the page: this repo and its Pages site are public, and a contract
# price is exactly what must not be. config.json holds nothing here for the same reason.
$cardTargets = @{}
if ($env:CARD_TARGETS_JSON) {
    try {
        $rawTargets = $env:CARD_TARGETS_JSON | ConvertFrom-Json
        foreach ($p in $rawTargets.PSObject.Properties) {
            if ($null -ne $p.Value.ref -and [double]$p.Value.ref -gt 0) { $cardTargets[$p.Name] = $p.Value }
        }
        Write-Host "  기준가 설정 $($cardTargets.Count)개 (메일 전용)"
    } catch {
        Write-Warning "CARD_TARGETS_JSON 형식 오류 - 기준가 없이 진행합니다: $($_.Exception.Message)"
    }
}

# Per-card threshold for the subject's price-move flag; cards not listed keep the default.
# Public config, since a threshold says nothing about what is paid.
function Get-ChangeAlertPct {
    param($id)
    $v = $config.cardAlertPct.$id
    if ($null -ne $v -and [double]$v -gt 0) { return [double]$v }
    5
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
        # Nager.Date reports a substituted holiday on its substitute date under the original name
        # and drops the real date: 개천절 2026 comes back as 10-05 (a Monday) because 10-03 is a
        # Saturday. The block arithmetic is unaffected - the real date is a weekend anyway - but
        # the list read "개천절 10/05". Solar-calendar holidays have a fixed date to compare
        # against, so those are labelled; 설날·추석·부처님 오신 날 move with the lunar calendar
        # and cannot be told apart this way, so they keep Nager's name.
        $fixedDates = @{
            "새해" = "01-01"; "3·1절" = "03-01"; "노동절" = "05-01"; "어린이날" = "05-05"
            "현충일" = "06-06"; "제헌절" = "07-17"; "광복절" = "08-15"; "개천절" = "10-03"
            "한글날" = "10-09"; "크리스마스" = "12-25"
        }
        $holidayByDate = @{}
        foreach ($h in $holidays) {
            $d = [DateTime]::Parse($h.date)
            if ($d -lt $today -or $d -gt $horizon) { continue }
            $name = $h.localName
            if ($fixedDates.ContainsKey($name) -and $d.ToString("MM-dd") -ne $fixedDates[$name]) {
                $name = "$name 대체공휴일"
            }
            $holidayByDate[$d.ToString("yyyy-MM-dd")] = $name
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

# --- Vietnam / China holidays --------------------------------------------------------------
# 부자재 comes out of Vietnam and much of the freight runs through China, and both countries stop
# for a week at a time - 뗏, 국경절, 춘절 - which delays loading and pauses the SSE freight
# indices. The Korean card could not show any of that.
#
# Nager.Date, which the Korean card uses, is not good enough here: checked 2026-09, its Vietnam
# list has no 뗏 at all for 2027 and China's 국경절 is a single day instead of 10/1~10/7. Google's
# public holiday calendars carry the real blocks and mark each day "Public holiday" or
# "Observance", so only the former are kept. Keyless ICS, fetched once per run.
$foreignHolidayKo = [ordered]@{
    "Tet|Vietnamese New Year|Lunar New Year" = "뗏(음력 설)"
    "Spring Festival|Chinese New Year"       = "춘절"
    "Golden Week|National Day"               = "국경절"
    "Mid-Autumn"                             = "중추절"
    "Independence Day"                       = "독립기념일"
    "Reunification|Liberation Day"           = "통일기념일"
    "Hung Kings"                             = "훙왕 기념일"
    "Labou?r Day"                            = "노동절"
    "Qingming|Tomb[- ]Sweeping"              = "청명절"
    "Dragon Boat"                            = "단오절"
    "New Year"                               = "신정"
    "Culture Day"                            = "문화의 날"
}

function Get-ForeignHolidays {
    param($calendars, $todayKst, $horizonDays = 200)
    $out = @()
    foreach ($cal in @($calendars)) {
        try {
            $url = "https://calendar.google.com/calendar/ical/$([uri]::EscapeDataString($cal.Calendar))/public/basic.ics"
            $ics = (Invoke-WebRequest -Uri $url -Headers $headers -UseBasicParsing -TimeoutSec 30).Content
            $today = $todayKst.Date
            $horizon = $today.AddDays($horizonDays)
            $days = @{}
            foreach ($m in [regex]::Matches($ics, '(?s)BEGIN:VEVENT.*?END:VEVENT')) {
                $e = $m.Value
                if ($e -notmatch 'DESCRIPTION:Public holiday') { continue }
                $ds = [regex]::Match($e, 'DTSTART;VALUE=DATE:(\d{8})').Groups[1].Value
                if (-not $ds) { continue }
                $d = [datetime]::ParseExact($ds, "yyyyMMdd", [Globalization.CultureInfo]::InvariantCulture)
                if ($d -lt $today.AddDays(-10) -or $d -gt $horizon) { continue }
                $days[$d] = [regex]::Match($e, 'SUMMARY:([^\r\n]+)').Groups[1].Value.Trim()
            }

            # Consecutive days become one block. The block is named after its main day - the entry
            # without "Holiday"/"Eve" in it (Google lists 10/2~10/7 as "National Day Holiday").
            $blocks = @()
            foreach ($d in ($days.Keys | Sort-Object)) {
                $last = if ($blocks.Count) { $blocks[-1] } else { $null }
                if ($last -and ($d - $last.End).Days -eq 1) { $last.End = $d; $last.Names += $days[$d] }
                else { $blocks += [PSCustomObject]@{ Start = $d; End = $d; Names = @($days[$d]) } }
            }
            foreach ($b in $blocks) {
                if ($b.End -lt $today) { continue }
                $main = @($b.Names | Where-Object { $_ -notmatch 'Holiday|Eve' } | Select-Object -First 1)
                $en = if ($main.Count) { $main[0] } else { $b.Names[0] }
                $ko = $en
                foreach ($pat in $foreignHolidayKo.Keys) { if ($en -match $pat) { $ko = $foreignHolidayKo[$pat]; break } }
                $out += [PSCustomObject]@{
                    country   = $cal.Label
                    impact    = $cal.Impact
                    name      = $ko
                    nameEn    = $en
                    startDate = $b.Start.ToString("yyyy-MM-dd")
                    endDate   = $b.End.ToString("yyyy-MM-dd")
                    days      = ($b.End - $b.Start).Days + 1
                    dDay      = ($b.Start - $today).Days
                }
            }
        } catch {
            Write-Warning "해외 공휴일 조회 실패 ($($cal.Label)): $($_.Exception.Message)"
        }
    }
    @($out | Sort-Object startDate)
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
            Write-Warning "  태풍 경로 조회 실패 ($($attempts)회 시도, event $eventId): $($_.Exception.Message)"
            return @()
        }
    }
    return @()
}

# 끝난 태풍의 경로 캐시. 경로 조회 한 건이 2.5~7.7초라, 최근 이력 10건을 매번 다시 받느라
# 실행 시간의 절반이 여기서 나갔다. 끝난 태풍의 마지막 에피소드는 다시 바뀌지 않으므로 한 번
# 받은 것을 typhoon-tracks.json 에 두고(워크플로가 커밋) 다음부터는 네트워크를 타지 않는다.
# 진행 중인 태풍은 에피소드마다 경로와 예보가 바뀌므로 캐시하지 않고 매번 받는다. 부수 효과로
# GDACS 가 느리거나 죽은 날에도 지난 태풍 이력은 경로 기준 판정을 유지한다.
$trackCachePath = Join-Path $root "typhoon-tracks.json"

function Read-TrackCache {
    $cache = @{}
    if (-not (Test-Path $trackCachePath)) { return $cache }
    try {
        $raw = Get-Content -Path $trackCachePath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($p in $raw.PSObject.Properties) {
            $cache[$p.Name] = @(foreach ($pt in $p.Value) { [PSCustomObject]@{ lat = [double]$pt[0]; lon = [double]$pt[1] } })
        }
    } catch {
        Write-Warning "typhoon-tracks.json 을 읽지 못해 경로를 새로 받습니다: $($_.Exception.Message)"
    }
    $cache
}

function Write-TrackCache {
    # 이번 실행에서 쓴 태풍만 남긴다. 목록은 최신순 상위 N건이라 한 번 밀려난 태풍은 돌아오지
    # 않고, 그래서 파일이 자라지 않는다. 내용이 같으면 쓰지 않아야 매 실행이 커밋을 만들지 않는다.
    param($cache, $usedKeys)
    $ordered = [ordered]@{}
    foreach ($k in ($usedKeys | Where-Object { $cache.ContainsKey($_) } | Sort-Object -Unique)) {
        # 소수 셋째 자리(약 100m)면 400~500km 판정에 충분하고 파일이 작아진다.
        $ordered[$k] = @(foreach ($pt in $cache[$k]) { , @([math]::Round($pt.lat, 3), [math]::Round($pt.lon, 3)) })
    }
    $json = ConvertTo-Json -InputObject $ordered -Depth 4 -Compress
    $old = if (Test-Path $trackCachePath) { [System.IO.File]::ReadAllText($trackCachePath) } else { "" }
    if ($json -ne $old) {
        [System.IO.File]::WriteAllText($trackCachePath, $json, (New-Object System.Text.UTF8Encoding $false))
        Write-Host "  태풍 경로 캐시 갱신: $($ordered.Count)건"
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

        $trackCache = Read-TrackCache
        $usedKeys = @()
        $cacheHits = 0
        $items = @(foreach ($cand in $candidates) {
            $p = $cand.p
            $cacheKey = "$($p.eventid):$($p.episodeid)"
            $ended = ($p.iscurrent -ne "true")
            if ($ended -and $trackCache.ContainsKey($cacheKey)) {
                $track = $trackCache[$cacheKey]
                $cacheHits++
            } else {
                $track = Get-StormTrackPoints -eventId $p.eventid -episodeId $p.episodeid
                if ($ended -and $track.Count -gt 0) { $trackCache[$cacheKey] = $track }
                Start-Sleep -Milliseconds 250
            }
            if ($ended) { $usedKeys += $cacheKey }
            # Falling back is not the same as judging on a track, and the page has to say so:
            # a one-point verdict is the one this card exists to have stopped making.
            $trackOk = $track.Count -gt 0
            if (-not $trackOk) { $track = @([PSCustomObject]@{ lat = $cand.lat; lon = $cand.lon }) }

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

        # $(...) 로 감싼다 - 그냥 $cacheHits건 이라고 쓰면 PowerShell 이 '건'까지 변수 이름으로 읽는다.
        Write-Host "  태풍 경로: 후보 $($candidates.Count)건 중 캐시 $($cacheHits)건, 조회 $($candidates.Count - $cacheHits)건"
        Write-TrackCache -cache $trackCache -usedKeys $usedKeys

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
            # 간헐적 시간 초과(10월 정상 실행 12회 중 2회)라 한 번 더 시도한다.
            $resp = $null
            for ($try = 1; $try -le 2 -and -not $resp; $try++) {
                try { $resp = Invoke-RestMethod -Uri $uri -Headers $headers -TimeoutSec 30 }
                catch { if ($try -eq 2) { throw }; Start-Sleep -Seconds 3 }
            }

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
        # CCFI 항로가 간헐적으로 시간 초과·SSL 오류로 빠져(10월 12회 중 3회) 한 번 더 시도한다.
        $resp = $null
        for ($try = 1; $try -le 2 -and -not $resp; $try++) {
            try { $resp = Invoke-RestMethod -Uri "https://en.sse.net.cn/currentIndex?indexName=$indexName" -Headers $sseHeaders }
            catch { if ($try -eq 2) { throw }; Start-Sleep -Seconds 3 }
        }

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

# --- 경향성 분석 ---------------------------------------------------------------------------
# 물류팀 운영 참고지표의 '추이와 경향성 분석' 부분. 카드마다 숫자와 차트는 있었지만, 지금이 오름세인지
# 내림세인지, 1년 중 어디쯤인지는 보는 사람이 차트를 보고 판단해야 했다. 판단 근거로 쓰려면 같은
# 규칙으로 매일 똑같이 매겨진 판정이 있어야 하므로, 간단하고 설명 가능한 규칙으로 계산한다.
#
#   짧은 창(주간·일간 계열 4주, 월간 계열 1개월)과 긴 창(13주 / 3개월) 변화율을,
#   그 지표의 평소 흔들림(과거 짧은 창 변화율 표준편차의 절반, 최소 0.5%)과 비교한다.
#   환율은 한 달에 1~2%, 벌크 운임 ETF 는 10% 넘게 움직이므로 같은 2% 를 쓰면 한쪽은 늘 보합,
#   다른 쪽은 늘 급변이 된다. 긴 창 기준은 짧은 창 기준 × √(긴 창/짧은 창).
#   1년(기록이 짧으면 관측 기간) 안에서 지금 값이 몇 번째인지로 위치를 붙인다.
#
# 연간 계열(산업용 전기요금)은 정책으로 계단식으로 바뀌어 경향 판정이 맞지 않아 뺀다.
function ConvertTo-LabelDate {
    param($label)
    $s = [string]$label
    $ci = [Globalization.CultureInfo]::InvariantCulture
    if ($s -match '^\d{4}-\d{2}-\d{2}') { return [DateTime]::ParseExact($s.Substring(0, 10), "yyyy-MM-dd", $ci) }
    if ($s -match '^\d{4}-\d{2}$') { return [DateTime]::ParseExact("$s-01", "yyyy-MM-dd", $ci) }
    $null
}

function Find-PointBefore {
    # rows[0..idx-1] 가운데 rows[idx] 보다 $days 앞에 가장 가까운 점. 창의 1/3 넘게 벗어나면 없음.
    param($rows, [int]$idx, [double]$days)
    if ($idx -lt 1) { return $null }
    $target = $rows[$idx].d.AddDays(-$days)
    $lo = 0; $hi = $idx - 1
    while ($lo -lt $hi) {
        $mid = [int][math]::Floor(($lo + $hi) / 2)
        if ($rows[$mid].d -lt $target) { $lo = $mid + 1 } else { $hi = $mid }
    }
    $best = $null; $bestDist = [double]::MaxValue
    foreach ($j in @(($lo - 1), $lo)) {
        if ($j -lt 0 -or $j -ge $idx) { continue }
        $dist = [math]::Abs(($rows[$j].d - $target).TotalDays)
        if ($dist -lt $bestDist) { $bestDist = $dist; $best = $rows[$j] }
    }
    if ($null -eq $best -or $bestDist -gt $days / 3) { return $null }
    $best
}

function Get-TrendStats {
    param($points)
    $rows = @(foreach ($p in @($points)) {
        if ($null -eq $p -or $null -eq $p.value) { continue }
        $d = ConvertTo-LabelDate $p.label
        if ($d) { [PSCustomObject]@{ d = $d; v = [double]$p.value } }
    })
    $rows = @($rows | Sort-Object d)
    if ($rows.Count -lt 3) { return $null }
    $gaps = @(for ($i = 1; $i -lt $rows.Count; $i++) { ($rows[$i].d - $rows[$i - 1].d).TotalDays }) | Sort-Object
    $gap = @($gaps)[[int][math]::Floor(@($gaps).Count / 2)]
    if ($gap -ge 200) { return $null }
    $monthly = $gap -ge 25
    $sDays = if ($monthly) { 31 } else { 28 }
    $lDays = if ($monthly) { 92 } else { 91 }

    $n = $rows.Count - 1
    $last = $rows[$n]
    $chg = {
        param($from)
        if ($null -eq $from -or $from.v -eq 0) { return $null }
        [math]::Round(($last.v - $from.v) / [math]::Abs($from.v) * 100, 1)
    }
    $chS = & $chg (Find-PointBefore $rows $n $sDays)
    $chL = & $chg (Find-PointBefore $rows $n $lDays)

    $hist = @(for ($i = 1; $i -le $n; $i++) {
        $f = Find-PointBefore $rows $i $sDays
        if ($f -and $f.v -ne 0) { ($rows[$i].v - $f.v) / [math]::Abs($f.v) * 100 }
    })
    $sd = $null
    if ($hist.Count -ge 6) {
        $mean = ($hist | Measure-Object -Average).Average
        $sd = [math]::Sqrt((($hist | ForEach-Object { ($_ - $mean) * ($_ - $mean) }) | Measure-Object -Sum).Sum / ($hist.Count - 1))
    }
    $thrS = if ($sd) { [math]::Max(0.5, 0.5 * $sd) } else { 2.0 }
    $thrL = [math]::Max(1.0, $thrS * [math]::Sqrt($lDays / $sDays))

    $upS = ($null -ne $chS) -and ($chS -ge $thrS); $dnS = ($null -ne $chS) -and ($chS -le -$thrS)
    $upL = ($null -ne $chL) -and ($chL -ge $thrL); $dnL = ($null -ne $chL) -and ($chL -le -$thrL)
    if ($upL -and $dnS)     { $trend = "상승 후 조정"; $tone = "mixed" }
    elseif ($dnL -and $upS) { $trend = "하락 후 반등"; $tone = "mixed" }
    elseif ($upL -and $upS) { $trend = "상승 추세"; $tone = "up" }
    elseif ($dnL -and $dnS) { $trend = "하락 추세"; $tone = "down" }
    elseif ($upL -or $upS)  { $trend = "상승"; $tone = "up" }
    elseif ($dnL -or $dnS)  { $trend = "하락"; $tone = "down" }
    else                    { $trend = "보합"; $tone = "flat" }

    $yr = @($rows | Where-Object { $_.d -ge $last.d.AddDays(-365) })
    $span = ($last.d - $yr[0].d).TotalDays
    $rangeName = if ($span -ge 300) { "1년" } else { "관측 $([int]$span)일" }
    $vals = @($yr | ForEach-Object { $_.v })
    $max = ($vals | Measure-Object -Maximum).Maximum
    $min = ($vals | Measure-Object -Minimum).Minimum
    $pctile = [int][math]::Round(@($vals | Where-Object { $_ -le $last.v }).Count / $vals.Count * 100)
    $band = if ($vals.Count -lt 3 -or $max -eq $min) { "중간" }
            elseif ($last.v -ge $max) { "최고" } elseif ($last.v -le $min) { "최저" }
            elseif ($pctile -ge 80) { "상단" } elseif ($pctile -ge 60) { "중상단" }
            elseif ($pctile -ge 40) { "중간" } elseif ($pctile -ge 20) { "중하단" } else { "하단" }

    [PSCustomObject]@{
        shortLabel = if ($monthly) { "1개월" } else { "4주" }
        shortPct   = $chS
        longLabel  = if ($monthly) { "3개월" } else { "13주" }
        longPct    = $chL
        normalMove = [math]::Round($thrS * 2, 1)    # 평소 짧은 창 변동폭(표준편차)
        trend      = $trend
        tone       = $tone
        rangeName  = $rangeName
        percentile = $pctile
        band       = $band
        position   = "$rangeName $band"
        points     = $rows.Count
    }
}

# --- 앞으로의 예상치 (통계적 예측) -----------------------------------------------------------
# 경향은 지난 흐름이라 "그래서 다음 달은?"에 답하지 못한다. 그렇다고 그럴듯한 숫자 하나를 내면 판단 근거로서
# 위험하다. 환율·유가·운임은 사건 하나에 크게 움직이고, 짧은 기간에는 '지금 값 유지'가 정교한 모형보다
# 잘 맞는 경우가 많다. 그래서 예상치에는 항상 범위와 그 방법의 과거 성적을 함께 붙인다.
#
#   1) 감쇠 추세 지수평활(Damped Holt): 최근 수준과 추세를 따라가되 먼 미래일수록 추세를 줄인다.
#      수요예측에서 널리 쓰이고, 추세를 끝없이 뻗지 않아 과한 예측을 막는다.
#   2) 롤링 백테스트: 과거 각 시점에서 그때까지 자료만으로 h 기간 뒤를 예측해 실제와 비교한다.
#      앞쪽 절반 시점으로 계수(α, β, φ)를 고르고, 뒤쪽 절반으로 채점한다(고른 자료로 채점하면 성적이 부풀려진다).
#      '지금 값 유지'보다 평균 오차가 3% 이상 작을 때만 추세 방법을 쓰고, 아니면 '지금 값 유지'를 쓴다.
#   3) 예상 범위: 뒤쪽 절반 시험에서 실제로 난 오차의 10~90% 구간(80% 범위). 정규분포를 가정하지 않는다.
#   방향은 80% 범위가 지금 값을 벗어날 때만 '상승 예상'·'하락 예상'이라 하고, 아니면 '보합권'이다.
#
# 로그값으로 계산해 오르내림을 비율로 다룬다. 사건·정책(유류세, 관세, 전쟁 등)은 반영하지 않는다.
function Get-ForecastPath {
    # 로그값 y 를 한 번 훑으며 각 시점의 수준 L, 추세 B 를 남긴다.
    # 주의: PowerShell 변수는 대소문자를 가리지 않는다. 계수를 $b, 추세 배열을 $B 로 두면 같은 변수가 된다.
    param([double[]]$y, [double]$alpha, [double]$beta, [double]$phi)
    $n = $y.Count
    $lv = New-Object double[] $n
    $tr = New-Object double[] $n
    $lv[0] = $y[0]; $tr[0] = 0.0
    for ($t = 1; $t -lt $n; $t++) {
        $pl = $lv[$t - 1]; $pb = $tr[$t - 1]
        $lv[$t] = $alpha * $y[$t] + (1 - $alpha) * ($pl + $phi * $pb)
        $tr[$t] = $beta * ($lv[$t] - $pl) + (1 - $beta) * $phi * $pb
    }
    , @($lv, $tr)
}

function Get-Quantile {
    param([double[]]$arr, [double]$q)
    $sorted = [double[]]@($arr | Sort-Object)
    if ($sorted.Count -eq 0) { return 0.0 }
    $pos = ($sorted.Count - 1) * $q
    $lo = [int][math]::Floor($pos); $hi = [int][math]::Ceiling($pos)
    if ($lo -eq $hi) { return $sorted[$lo] }
    $sorted[$lo] + ($sorted[$hi] - $sorted[$lo]) * ($pos - $lo)
}

function Get-Forecast {
    param($points)
    $rows = @(foreach ($p in @($points)) {
        if ($null -eq $p -or $null -eq $p.value) { continue }
        $d = ConvertTo-LabelDate $p.label
        if ($d -and [double]$p.value -gt 0) { [PSCustomObject]@{ d = $d; v = [double]$p.value } }
    })
    $rows = @($rows | Sort-Object d)
    if ($rows.Count -lt 30) { return $null }
    $gaps = @(for ($i = 1; $i -lt $rows.Count; $i++) { ($rows[$i].d - $rows[$i - 1].d).TotalDays }) | Sort-Object
    $gap = @($gaps)[[int][math]::Floor(@($gaps).Count / 2)]
    if ($gap -le 2) {
        $unit = "day";   $hs = @(@{ h = 28; label = "4주 후" }, @{ h = 91; label = "13주 후" })
    } elseif ($gap -le 10) {
        $unit = "week";  $hs = @(@{ h = 4; label = "4주 후" }, @{ h = 13; label = "13주 후" })
    } elseif ($gap -le 40) {
        $unit = "month"; $hs = @(@{ h = 1; label = "1개월 후" }, @{ h = 3; label = "3개월 후" })
    } else { return $null }

    $n = $rows.Count
    $y = [double[]]@($rows | ForEach-Object { [math]::Log($_.v) })
    $minTrain = 20
    $grid = @(foreach ($ga in 0.2, 0.4, 0.6, 0.8, 1.0) { foreach ($gb in 0.0, 0.05, 0.15, 0.3) { foreach ($gp in 0.8, 0.9, 0.98) {
        $path = Get-ForecastPath -y $y -alpha $ga -beta $gb -phi $gp
        [PSCustomObject]@{ a = $ga; b = $gb; phi = $gp; lv = $path[0]; tr = $path[1] }
    } } })
    $last = $rows[$n - 1]
    # 한 기간(하루·한 주·한 달) 로그 변화의 표준편차. 범위 하한을 정하는 데 쓴다.
    $d1 = [double[]]@(for ($i = 1; $i -lt $n; $i++) { $y[$i] - $y[$i - 1] })
    $m1 = ($d1 | Measure-Object -Average).Average
    $sig1 = [math]::Sqrt((($d1 | ForEach-Object { ($_ - $m1) * ($_ - $m1) }) | Measure-Object -Sum).Sum / [math]::Max(1, $d1.Count - 1))

    $out = @(foreach ($hz in $hs) {
        $h = [int]$hz.h
        $firstO = $minTrain - 1; $lastO = $n - 1 - $h
        if ($lastO - $firstO + 1 -lt 10) { continue }       # 시험할 시점이 10개 미만이면 예측하지 않는다
        $origins = @($firstO..$lastO)
        $half = [int][math]::Floor($origins.Count / 2)
        $sel = @($origins[0..($half - 1)])
        $ev = @($origins[$half..($origins.Count - 1)])

        $best = $null; $bestErr = [double]::MaxValue
        foreach ($g in $grid) {
            $S = 0.0; for ($k = 1; $k -le $h; $k++) { $S += [math]::Pow($g.phi, $k) }
            $sum = 0.0
            foreach ($t in $sel) { $sum += [math]::Abs($y[$t + $h] - ($g.lv[$t] + $S * $g.tr[$t])) }
            if ($sum -lt $bestErr) { $bestErr = $sum; $best = $g; $bestS = $S }
        }
        $eH = [double[]]@(foreach ($t in $ev) { $y[$t + $h] - ($best.lv[$t] + $bestS * $best.tr[$t]) })
        $eN = [double[]]@(foreach ($t in $ev) { $y[$t + $h] - $y[$t] })
        $maeH = ($eH | ForEach-Object { [math]::Abs($_) } | Measure-Object -Average).Average
        $maeN = ($eN | ForEach-Object { [math]::Abs($_) } | Measure-Object -Average).Average
        $useHolt = $maeH -lt 0.97 * $maeN
        $errs = if ($useHolt) { $eH } else { $eN }
        $f = if ($useHolt) { $best.lv[$n - 1] + $bestS * $best.tr[$n - 1] } else { $y[$n - 1] }
        # 80% 범위의 반폭 = max(과거 실제 오차의 10~90% 구간 반폭, 한 기간 변동폭 × √h × 1.28).
        # 먼 기간(13주)은 겹치는 시험 구간이 많아 독립 사례가 적고, 그 구간에 마침 한쪽으로 흐른 시기만
        # 있으면 범위가 4주보다 좁게 잡히기도 했다. 시간이 길수록 불확실성이 커진다는 하한을 둔다.
        # 중간값 기준으로 실제 오차의 80% 가 들어오는 폭(|오차|의 80번째 백분위). 오차가 한쪽으로 쏠린 시기에도
        # '80% 이상'이라는 화면 설명과 실제 적중률이 어긋나지 않게 한다(원/달러: 10~90% 구간 반폭이면 71%).
        if ($errs.Count -ge 6) {
            $hwEmp = Get-Quantile ([double[]]@($errs | ForEach-Object { [math]::Abs($_) })) 0.8
        } else {
            $hwEmp = 1.2816 * [math]::Sqrt((($errs | ForEach-Object { $_ * $_ }) | Measure-Object -Sum).Sum / $errs.Count)
        }
        $hw = [math]::Max($hwEmp, 1.2816 * $sig1 * [math]::Sqrt($h))
        # 과거 시험(뒤쪽 절반)에서 실제값이 이 범위 안에 든 비율. 화면에 그대로 보여 준다.
        $cov = [int][math]::Round(@($errs | Where-Object { [math]::Abs($_) -le $hw }).Count / $errs.Count * 100)
        $mid = [math]::Exp($f)
        $low = [math]::Exp($f - $hw)
        $high = [math]::Exp($f + $hw)
        $dir = if ($low -gt $last.v) { "상승 예상" } elseif ($high -lt $last.v) { "하락 예상" } else { "보합권" }
        $when = switch ($unit) {
            "day"   { $last.d.AddDays($h).ToString("yyyy-MM-dd") }
            "week"  { $last.d.AddDays(7 * $h).ToString("yyyy-MM-dd") }
            "month" { $last.d.AddMonths($h).ToString("yyyy-MM") }
        }
        $pc = { param($v) [math]::Round(($v / $last.v - 1) * 100, 1) }
        # 값 크기에 맞춰 반올림한다(환율 1,271.8~1,376.14 → 1,272~1,376). 변화율은 반올림 전 값으로 낸다.
        $dg = if ($last.v -ge 1000) { 0 } elseif ($last.v -ge 100) { 1 } elseif ($last.v -ge 10) { 2 } else { 3 }
        [PSCustomObject]@{
            label     = $hz.label
            steps     = $h
            date      = $when
            mid       = [math]::Round($mid, $dg)
            low       = [math]::Round($low, $dg)
            high      = [math]::Round($high, $dg)
            pct       = & $pc $mid
            lowPct    = & $pc $low
            highPct   = & $pc $high
            direction = $dir
            method    = if ($useHolt) { "감쇠 추세" } else { "현재 유지" }
            params    = if ($useHolt) { "α $($best.a) · β $($best.b) · φ $($best.phi)" } else { "" }
            mae       = [math]::Round($(if ($useHolt) { $maeH } else { $maeN }) * 100, 1)
            naiveMae  = [math]::Round($maeN * 100, 1)
            trendMae  = [math]::Round($maeH * 100, 1)
            tests     = $ev.Count
            coverage  = $cov
        }
    })
    if ($out.Count -eq 0) { return $null }
    [PSCustomObject]@{
        unit      = $unit
        lastLabel = $last.d.ToString($(if ($unit -eq "month") { "yyyy-MM" } else { "yyyy-MM-dd" }))
        lastValue = $last.v
        horizons  = $out
        note      = "과거 자료의 흐름만으로 낸 통계적 예상입니다. 사건·정책 변화(유류세, 관세, 전쟁, 파업 등)는 반영하지 않습니다."
    }
}

# --- 컨테이너 내륙운송료 (화물자동차 안전운임 유가연동) 전망 --------------------------------
# 수출입 컨테이너의 내륙운송은 2026~2028년 다시 시행된 안전운임제 대상이라, 화주가 내는 최저
# 운임(안전운송운임)이 고시로 정해진다. 고시는 유가에 연동된다: 분기(3개월) 경유 평균이 현재
# 운임표에 반영된 유가보다 50원 이상 오르거나 내리면 그 평균으로 운임을 다시 고시하고, 분기가
# 끝난 뒤 둘째 달 1일부터 반영한다(7~9월 → 11/1, 2026-578호 행정예고가 이 모양이다).
#
# 규칙이 정해져 있고 재료가 이미 여기 쌓이고 있으므로(오피넷 일별 경유가) 행정예고가 나오기 전에
# 판정을 미리 계산할 수 있다. 이 블록이 그 계산이다. 실제 고시와 어긋날 수 있는 지점은 카드에
# 그대로 적는다 - 기준 유가가 추정이면 '추정', 남은 날짜를 채운 가정이 무엇인지까지.
#
# 운임 변동액은 연료 몫만 움직인다고 보고 왕복거리 ÷ 연비 × 유가 변동으로 근사한다. 고시 운임의
# 다른 원가(인건비·감가상각 등)는 유가 고시에서 바뀌지 않기 때문이다. 연비(kmPerLiter)는 11월
# 개정의 실제 변동폭으로 맞춘 추정치라 config 에 두었다.
function Format-MonthSpan {
    # 업무 표(평균유가 산정 기준)와 같은 표기: "26년 07월~09월", 해를 넘기면 "26년 11월~27년 01월"
    param([DateTime]$first)
    $last = $first.AddMonths(2)
    $a = "{0:00}년 {1:00}월" -f ($first.Year % 100), $first.Month
    if ($last.Year -eq $first.Year) { return "$a~$('{0:00}' -f $last.Month)월" }
    "$a~$('{0:00}년 {1:00}월' -f ($last.Year % 100), $last.Month)"
}

function Get-QuarterInfo {
    param([DateTime]$date)
    $q = [int][math]::Floor(($date.Month - 1) / 3)
    $start = New-Object DateTime $date.Year, ($q * 3 + 1), 1
    [PSCustomObject]@{
        key        = "$($date.Year)-Q$($q + 1)"
        start      = $start
        end        = $start.AddMonths(3).AddDays(-1)
        # 산정 기간이 끝난 뒤 두 달째부터 3개월 적용: 1~3월 → 5~7월, 4~6월 → 8~10월,
        # 7~9월 → 11~1월, 10~12월 → 2~4월 (26년 실제 고시 세 번과 같은 모양)
        effective  = $start.AddMonths(4)
        label      = Format-MonthSpan $start                  # 평균유가 산정 기간
        applyLabel = Format-MonthSpan $start.AddMonths(4)     # 안전운임 적용 기간
    }
}

function Get-FuelWindowAverage {
    # 분기 평균 = 월평균 3개의 단순평균(행정예고와 엑셀 Tool 이 쓰는 방식). 월평균은 그달에 쌓인
    # 일별 전국 평균의 평균이다. 아직 오지 않은 날은 가정값으로 채운다: 기본은 마지막 값 유지,
    # $stepAfter 다음 날부터는 $stepWon 만큼 더한 값(유류세 인하 종료 같은 계단).
    # 지나간 날인데 값이 없으면(수집 공백) 그날은 평균에서 뺀다.
    param($daily, $quarter, [DateTime]$today, [double]$projBase, $stepAfter = $null, [double]$stepWon = 0)
    $months = @()
    $actualDays = 0; $projDays = 0; $pastDays = 0
    for ($i = 0; $i -lt 3; $i++) {
        $mStart = $quarter.start.AddMonths($i)
        $mEnd = $mStart.AddMonths(1).AddDays(-1)
        $sum = 0.0; $n = 0; $act = 0; $proj = 0
        for ($d = $mStart; $d -le $mEnd; $d = $d.AddDays(1)) {
            $k = $d.ToString("yyyy-MM-dd")
            if ($d -le $today) { $pastDays++ }
            if ($daily.ContainsKey($k)) {
                $sum += [double]$daily[$k]; $n++; $act++
            } elseif ($d -gt $today) {
                $v = $projBase
                if ($null -ne $stepAfter -and $d -gt $stepAfter) { $v += $stepWon }
                $sum += $v; $n++; $proj++
            }
        }
        $actualDays += $act; $projDays += $proj
        $months += [PSCustomObject]@{
            label         = "$($mStart.Month)월"
            avg           = if ($n -gt 0) { [math]::Round($sum / $n, 1) } else { $null }
            actualDays    = $act
            projectedDays = $proj
            days          = ($mEnd - $mStart).Days + 1
        }
    }
    $valid = @($months | Where-Object { $null -ne $_.avg })
    [PSCustomObject]@{
        months        = $months
        avg           = if ($valid.Count -eq 3) { [math]::Round((($valid | Measure-Object -Property avg -Sum).Sum) / 3, 1) } else { $null }
        actualDays    = $actualDays
        projectedDays = $projDays
        pastDays      = $pastDays
    }
}

function Get-FuelVerdict {
    param($avg, [double]$baseFuel, [double]$threshold)
    $diff = [math]::Round([double]$avg - $baseFuel, 1)
    $verdict = if ($diff -ge $threshold) { "인상" } elseif ($diff -le -$threshold) { "인하" } else { "동결" }
    [PSCustomObject]@{ avg = [double]$avg; base = $baseFuel; diff = $diff; verdict = $verdict }
}

function Get-RouteImpacts {
    # 고시 운임은 100원 단위라 같은 단위로 맞춘다.
    param($routes, [double]$fuelDelta, [double]$kmPerLiter)
    @(foreach ($r in @($routes)) {
        $rate = [double]$r.rate
        $raw = $rate + ([double]$r.km / $kmPerLiter) * $fuelDelta
        $newRate = [math]::Round($raw / 100, [MidpointRounding]::AwayFromZero) * 100
        $chg = $newRate - $rate
        [PSCustomObject]@{
            name      = $r.name
            km        = [double]$r.km
            rate      = $rate
            newRate   = $newRate
            change    = $chg
            changePct = if ($rate -gt 0) { [math]::Round($chg / $rate * 100, 2) } else { 0 }
        }
    })
}

function Get-SafeFreightOutlook {
    param($cfg, $daily, [DateTime]$today)

    if (-not $cfg -or -not $daily -or $daily.Count -eq 0) { return $null }
    try {
        $threshold = if ($cfg.threshold) { [double]$cfg.threshold } else { 50 }
        $kmPerLiter = if ($cfg.kmPerLiter) { [double]$cfg.kmPerLiter } else { 3.65 }

        $keys = @($daily.Keys | Sort-Object)
        $latestLabel = $keys[-1]
        $latest = [double]$daily[$latestLabel]

        # 산정 이력: config 의 history(확인된 산정 결과)에, 그 뒤로 끝난 분기를 쌓인 값으로 이어 붙인다.
        # 판정 기준은 "지금 운임에 반영된 산정 기간의 유가", 곧 마지막으로 인상·인하된 산정 기간의
        # 평균이다. 동결된 분기(26년 1~3월)는 기준을 바꾸지 않는다.
        $rows = @(foreach ($h in @($cfg.history)) {
            if ([string]$h.window -notmatch '^(\d{4})-Q([1-4])$') { continue }
            $hq = Get-QuarterInfo (New-Object DateTime ([int]$matches[1]), (([int]$matches[2] - 1) * 3 + 1), 1)
            [PSCustomObject]@{ q = $hq; avg = [double]$h.avg; verdict = [string]$h.verdict
                note = [string]$h.note; provisional = [bool]$h.provisional; computed = $false }
        })
        if (@($rows | Where-Object { $_.verdict -ne "동결" }).Count -eq 0) { throw "history 에 인상·인하된 산정 기간이 없습니다" }
        $q = Get-QuarterInfo $rows[-1].q.start.AddMonths(3)
        while ($q.end -lt $today) {
            $w = Get-FuelWindowAverage -daily $daily -quarter $q -today $today -projBase $latest
            # 하루라도 크게 비면 평균이 틀어지므로, 80% 이상 모인 분기만 이어 계산한다.
            if ($null -eq $w.avg -or $w.actualDays -lt [math]::Ceiling($w.pastDays * 0.8)) { break }
            $baseNow = @($rows | Where-Object { $_.verdict -ne "동결" })[-1].avg
            $vd = Get-FuelVerdict $w.avg $baseNow $threshold
            $rows += [PSCustomObject]@{ q = $q; avg = $w.avg; verdict = $vd.verdict
                note = "대시보드 계산(오피넷 일별 평균의 월평균)"; provisional = $true; computed = $true }
            $q = Get-QuarterInfo $q.start.AddMonths(3)
        }

        $changes = @($rows | Where-Object { $_.verdict -ne "동결" })
        $last = $changes[-1]
        $baseFuel = $last.avg
        # 적용 시작일이 아직 안 온 조정은 '적용 예정'으로 따로 둔다. 10/22 현재 7~9월 인하분이 11/1 부터
        # 적용될 예정이고, 지금 시행 중인 것은 4~6월 인상분이다. 다음 판정의 기준은 예정분(7~9월)이다.
        $inForceList = @($changes | Where-Object { $_.q.effective -le $today })
        $inForce = if ($inForceList.Count) { $inForceList[-1] } else { $null }
        $applied = if ($inForce) {
            [PSCustomObject]@{ fuel = $inForce.avg; window = $inForce.q.label; applyLabel = $inForce.q.applyLabel
                since = $inForce.q.effective.ToString("yyyy-MM-dd"); estimated = $inForce.provisional }
        } else { $null }
        $pending = if ($last.q.effective -gt $today) {
            [PSCustomObject]@{ fuel = $last.avg; verdict = $last.verdict; window = $last.q.label; applyLabel = $last.q.applyLabel
                effective = $last.q.effective.ToString("yyyy-MM-dd"); provisional = $last.provisional }
        } else { $null }
        $historyOut = @($rows | ForEach-Object {
            [PSCustomObject]@{ window = $_.q.label; applyLabel = $_.q.applyLabel; avg = $_.avg; verdict = $_.verdict
                note = $_.note; provisional = $_.provisional; computed = $_.computed }
        })

        # 진행 중인 분기 (기본 가정: 남은 날은 마지막 값 유지)
        $cur = Get-QuarterInfo $today
        $wBase = Get-FuelWindowAverage -daily $daily -quarter $cur -today $today -projBase $latest
        $base = Get-FuelVerdict $wBase.avg $baseFuel $threshold
        $baseImpact = if ($base.verdict -ne "동결") { Get-RouteImpacts $cfg.routes $base.diff $kmPerLiter } else { @() }

        # 시나리오: 유류세 인하가 예정일에 끝나면 다음 날부터 경유가 그만큼 오른다고 본다.
        # 이번 분기에 다 반영되지 않으면(12월 한 달만 오르는 식) 다음 분기 판정까지 이어 본다.
        $scenario = $null
        $tc = $cfg.fuelTaxCut
        if ($tc -and $tc.until -and $tc.dieselWon) {
            $until = [DateTime]::ParseExact([string]$tc.until, "yyyy-MM-dd", [Globalization.CultureInfo]::InvariantCulture)
            if ($until -ge $today) {
                $won = [double]$tc.dieselWon
                $sCur = Get-FuelWindowAverage -daily $daily -quarter $cur -today $today -projBase $latest -stepAfter $until -stepWon $won
                $sv = Get-FuelVerdict $sCur.avg $baseFuel $threshold
                $nxt = Get-QuarterInfo $cur.start.AddMonths(3)
                $sNext = Get-FuelWindowAverage -daily $daily -quarter $nxt -today $today -projBase $latest -stepAfter $until -stepWon $won
                $nextBase = if ($sv.verdict -ne "동결") { $sCur.avg } else { $baseFuel }
                $svNext = Get-FuelVerdict $sNext.avg $nextBase $threshold
                # 처음 걸리는 조정의 운임 영향을 보여 준다.
                $trigger = $null
                if ($sv.verdict -ne "동결") {
                    $trigger = [PSCustomObject]@{ window = $cur.label; applyLabel = $cur.applyLabel; effective = $cur.effective.ToString("yyyy-MM-dd")
                        verdict = $sv.verdict; diff = $sv.diff; impact = (Get-RouteImpacts $cfg.routes $sv.diff $kmPerLiter) }
                } elseif ($svNext.verdict -ne "동결") {
                    $trigger = [PSCustomObject]@{ window = $nxt.label; applyLabel = $nxt.applyLabel; effective = $nxt.effective.ToString("yyyy-MM-dd")
                        verdict = $svNext.verdict; diff = $svNext.diff; impact = (Get-RouteImpacts $cfg.routes $svNext.diff $kmPerLiter) }
                }
                $scenario = [PSCustomObject]@{
                    label     = "$($tc.label) $($until.ToString('M/d', [Globalization.CultureInfo]::InvariantCulture)) 종료 시"
                    until     = $until.ToString("yyyy-MM-dd")
                    dDay      = ($until - $today).Days
                    won       = $won
                    current   = [PSCustomObject]@{ window = $cur.label; applyLabel = $cur.applyLabel; avg = $sv.avg; diff = $sv.diff; verdict = $sv.verdict
                        effective = $cur.effective.ToString("yyyy-MM-dd"); months = $sCur.months }
                    next      = [PSCustomObject]@{ window = $nxt.label; applyLabel = $nxt.applyLabel; avg = $svNext.avg; diff = $svNext.diff; verdict = $svNext.verdict
                        effective = $nxt.effective.ToString("yyyy-MM-dd"); base = $nextBase }
                    trigger   = $trigger
                }
            }
        }

        [PSCustomObject]@{
            id          = "safe-freight"
            displayName = "컨테이너 내륙운송료 (안전운임 유가연동)"
            threshold   = $threshold
            kmPerLiter  = $kmPerLiter
            rateBasis   = $cfg.rateBasis
            rateFrom    = $cfg.rateFrom
            notice      = $cfg.notice
            applied     = $applied
            pending     = $pending
            baseFuel    = $baseFuel
            baseWindow  = $last.q.label
            baseProvisional = $last.provisional
            history     = $historyOut
            latest      = [PSCustomObject]@{ label = $latestLabel; value = $latest }
            window      = [PSCustomObject]@{ key = $cur.key; label = $cur.label; applyLabel = $cur.applyLabel
                months = $wBase.months; actualDays = $wBase.actualDays; projectedDays = $wBase.projectedDays
                effective = $cur.effective.ToString("yyyy-MM-dd") }
            base        = [PSCustomObject]@{ avg = $base.avg; diff = $base.diff; verdict = $base.verdict
                assumption = "남은 기간은 마지막 값($(Format-Won $latest)원/L) 유지 가정"; impact = $baseImpact }
            scenario    = $scenario
            routes      = @($cfg.routes | ForEach-Object { [PSCustomObject]@{ name = $_.name; km = [double]$_.km; rate = [double]$_.rate } })
            source      = "한국석유공사 오피넷(경유 전국평균) · 국토교통부 안전운임 고시"
        }
    } catch {
        Write-Warning "안전운임 전망 계산 실패: $($_.Exception.Message)"
        $null
    }
}

function Format-Won {
    param($v)
    if ($null -eq $v) { return "" }
    $d = [double]$v
    if ($d -eq [math]::Round($d)) { return $d.ToString("N0") }
    # 1,994.68 처럼 확정 평균유가는 소수 둘째 자리까지 그대로 보여 준다(업무 표와 같은 표기).
    if ($d -eq [math]::Round($d, 1)) { return $d.ToString("N1") }
    $d.ToString("N2")
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

# --- 동시 선조회 ------------------------------------------------------------------------
# 뉴스 23건을 하나씩 받고 사이마다 쉬던 것이 실행 시간의 4분의 1 이었다. 주소는 설정에서 미리
# 다 알 수 있으므로 몇 건씩 동시에 받아 두고, 아래 함수들은 받아 둔 것이 있으면 그것을 쓴다.
# 동시 조회에서 실패한 주소(429/503 포함)는 받아 두지 않으므로 원래의 순차 경로가 재시도와
# 함께 그대로 처리한다 - 이 층이 망가져도 느려질 뿐 결과가 비지는 않는다.
# 동시 3건으로 묶는 이유: 러너 IP 는 Google 이 집 회선보다 빡빡하게 조이고, 한꺼번에 다 보내면
# 오늘 아낀 시간을 503 재시도로 도로 잃는다.
Add-Type -AssemblyName System.Net.Http
$script:prefetched = @{}
# 구글 뉴스 차단기. 구글이 러너 IP 를 막은 날은 쿼리마다 세 번씩 기다리느라 실행이 16분까지 늘고
# (10-18), 결국 뉴스 0건 점검에 걸려 가격·날씨·태풍까지 그날 배포가 멈췄다(10-18, 10-25).
$script:newsThrottleFails = 0     # 503/429 로 끝내 실패한 쿼리 수
$script:newsConsecThrottle = 0    # 연달아 막힌 쿼리 수
$script:newsBreaker = $false      # true 면 남은 쿼리는 네트워크를 타지 않는다

function Invoke-Prefetch {
    param([string[]]$urls, [int]$concurrency = 3, [int]$timeoutSec = 25, [int]$pauseMs = 300)
    $urls = @($urls | Where-Object { $_ } | Select-Object -Unique)
    if ($urls.Count -eq 0) { return }
    $handler = New-Object System.Net.Http.HttpClientHandler
    $handler.AutomaticDecompression = [System.Net.DecompressionMethods]::GZip -bor [System.Net.DecompressionMethods]::Deflate
    $client = New-Object System.Net.Http.HttpClient($handler)
    $client.Timeout = [TimeSpan]::FromSeconds($timeoutSec)
    [void]$client.DefaultRequestHeaders.TryAddWithoutValidation("User-Agent", $headers["User-Agent"])
    $got = 0
    try {
        for ($i = 0; $i -lt $urls.Count; $i += $concurrency) {
            $batch = @($urls[$i..([Math]::Min($i + $concurrency, $urls.Count) - 1)])
            $tasks = @(foreach ($u in $batch) { $client.GetAsync($u) })
            # 하나라도 실패하면 WaitAll 이 던진다. 개별 상태를 아래에서 보므로 여기서는 삼킨다.
            try { [System.Threading.Tasks.Task]::WaitAll([System.Threading.Tasks.Task[]]$tasks) } catch { }
            for ($j = 0; $j -lt $batch.Count; $j++) {
                $t = $tasks[$j]
                if ($t.Status -ne [System.Threading.Tasks.TaskStatus]::RanToCompletion) { continue }
                if (-not $t.Result.IsSuccessStatusCode) { continue }
                $script:prefetched[$batch[$j]] = $t.Result.Content.ReadAsStringAsync().Result
                $got++
            }
            if ($i + $concurrency -lt $urls.Count) { Start-Sleep -Milliseconds $pauseMs }
        }
    } finally {
        $client.Dispose()
    }
    Write-Host "  동시 조회 $got/$($urls.Count)건 (나머지는 순차 조회로 재시도)"
}

function Get-Prefetched {
    param([string]$url)
    if (-not $script:prefetched.ContainsKey($url)) { return $null }
    $content = $script:prefetched[$url]
    $script:prefetched.Remove($url)
    $content
}

function Get-NewsUri {
    param($query, $withinDays = 21)
    $scoped = if ($withinDays -gt 0) { "$query when:${withinDays}d" } else { $query }
    "https://news.google.com/rss/search?q=" + [uri]::EscapeDataString($scoped) + "&hl=ko&gl=KR&ceid=KR:ko"
}

function Get-NewsHeadlines {
    # Google News RSS ranks by relevance, not date, and honours no recency unless the query
    # says so. Taking the first N items therefore returned whatever matched best across all
    # time: the 수급 뉴스 cards were showing headlines 322 and even 1,569 days old, with the
    # freshest item on the page a month behind. Asking for a window and then sorting and
    # filtering by date is what makes "오늘의 뉴스" actually mean today's.
    param($query, $max = 4, $withinDays = 21)

    $uri = Get-NewsUri -query $query -withinDays $withinDays
    # 호출한 쪽이 요청 사이 쉬는 시간을 건너뛸 수 있게, 네트워크를 탔는지 남겨 둔다.
    $content = Get-Prefetched $uri
    $script:newsFromPrefetch = [bool]$content
    # 연달아 세 쿼리가 막혔으면 남은 검색은 기다리지 않고 건너뛴다(호출한 쪽의 쉬는 시간도 건너뛰게 한다).
    if (-not $content -and $script:newsBreaker) { $script:newsFromPrefetch = $true; return @() }
    # 러너 IP 에서 Google 이 503 을 뿌리는 구간이 있다. 2026-09-10 에만 두 번, 모든 쿼리가 통째로
    # 503 이었고 그때마다 "수급 뉴스 0건"으로 생성물 점검이 배포와 메일을 막았다. 점검은 제 일을
    # 한 것이지만, 한 번 튕겼다고 그날 요약을 통째로 포기할 이유는 없다 — 재시도가 없어서 503
    # 한 번에 그 쿼리가 통째로 사라지고 있었다.
    #
    # 번역 엔드포인트의 429 와 같은 계열이다. 러너는 수많은 워크플로가 공유하는 클라우드 IP 를
    # 쓰고, Google 은 그 IP 를 집 회선보다 훨씬 빡빡하게 조인다.
    for ($try = 1; $try -le 3 -and -not $content; $try++) {
        try {
            $content = (Invoke-WebRequest -Uri $uri -Headers $headers -UseBasicParsing -TimeoutSec 25).Content
        } catch {
            $status = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
            # 스로틀이 아닌 오류는 다시 물어도 나아지지 않는다.
            if (($status -ne 503 -and $status -ne 429) -or $try -eq 3) {
                if ($status -eq 503 -or $status -eq 429) {
                    $script:newsThrottleFails++
                    $script:newsConsecThrottle++
                    if ($script:newsConsecThrottle -ge 3 -and -not $script:newsBreaker) {
                        $script:newsBreaker = $true
                        Write-Warning "구글 뉴스가 연달아 응답하지 않아(HTTP $status) 남은 뉴스 검색을 건너뜁니다."
                    }
                }
                Write-Warning "News fetch failed for '$query' (HTTP $status): $($_.Exception.Message)"
                return @()
            }
            Start-Sleep -Seconds ($try * 4)
        }
    }
    if ($content) { $script:newsConsecThrottle = 0 }

    try {
        [xml]$rss = $content
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
        if (-not $script:newsFromPrefetch) { Start-Sleep -Milliseconds 300 }
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

Write-Host "Fetching Vietnam/China holidays..."
$foreignHolidays = @(Get-ForeignHolidays -calendars $config.foreignHolidayCalendars -todayKst $nowKst)
Write-Host "  $($foreignHolidays.Count)건"

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
# 예전 SMP 카드가 남긴 기록. 카드를 산업용 전기요금으로 바꾼 뒤로 아무도 읽지 않는다.
[void]$historyStore.Remove("smp")
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
# The lanes have exactly SCFI's problem - this week and last, nothing older - and they are the
# numbers this cargo actually pays, where the composite averages Europe and the Americas in.
# Only SCFI was being kept, so the lane card could never show more than one week's move.
foreach ($l in $sseLanes) {
    $lanePoints = @(
        [PSCustomObject]@{ label = $l.lastDate;    value = $l.previous }
        [PSCustomObject]@{ label = $l.currentDate; value = $l.current }
    ) | Where-Object { $_.label }
    $laneHistory = @(Merge-HistorySeries -store $historyStore -key $l.id -points $lanePoints)
    $l | Add-Member -NotePropertyName points -NotePropertyValue $laneHistory -Force
}

Write-HistoryStore -store $historyStore

# 안전운임 유가연동 전망. 오피넷 키가 없는 로컬 실행에서도 저장소에 쌓인 경유 기록으로 계산된다.
$safeFreight = $null
if ($config.safeFreight) {
    Write-Host "Computing 안전운임 유가연동 전망..."
    $safeFreight = Get-SafeFreightOutlook -cfg $config.safeFreight -daily $historyStore["fuel-D047"] -today $nowKst.Date
    if ($safeFreight) {
        $sc = if ($safeFreight.scenario -and $safeFreight.scenario.trigger) { " / 시나리오: $($safeFreight.scenario.trigger.window) $($safeFreight.scenario.trigger.verdict)" } else { "" }
        Write-Host "  $($safeFreight.window.label) 평균 $($safeFreight.base.avg)원, 기준 $($safeFreight.baseFuel)원 대비 $($safeFreight.base.diff)원 → $($safeFreight.base.verdict)$sc"
    }
}

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
# 벌크 운임. SCFI·CCFI 는 전부 컨테이너라, 벌크선으로 들어오는 KCl 의 인바운드 운임은 지금까지
# 어느 카드에도 없었다. 최종 자리는 cardOrder 가 정하므로 여기서는 그냥 목록에 넣기만 한다.
$priceCards += @($yahooSeries | Where-Object { $_.id -eq "drybulk" })
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
# Any Yahoo series in config.json that the explicit picks above do not name. Those picks exist to
# place a card, not to decide whether it exists - but that is what they did: a series added only
# to config was fetched, then dropped here, then reported as "수집 실패" by the missing-card pass
# below although its data had arrived fine (drybulk, 2026-09). Final order comes from cardOrder,
# so appending is enough.
$placedIds = @($priceCards | ForEach-Object { [string]$_.id })
$priceCards += @($yahooSeries | Where-Object { $placedIds -notcontains [string]$_.id })
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

# 덮어쓰기 전의 라벨을 떠 둔다. 메일 제목의 특이사항이 "이번 실행에 새로 들어온 값"만 고르는 데
# 쓴다. 라벨을 보지 않고 직전 대비 변화폭만 보면 갱신 주기가 긴 계열이 영구히 눌러앉는다 —
# 산업용 전기요금은 연간 시계열이라 '직전 대비'가 곧 '작년 대비'이고, 2025년의 +8.2% 가 다음
# 연간치가 나올 때까지 1년 내내 매일 제목에 붙는다. 그러면 예외를 알리는 표시가 상수가 되고,
# 세 자리뿐인 제목에서 정작 오늘 새로 생긴 소식을 밀어낸다.
$prevSeenLabels = @{}
foreach ($key in @($historyStore.Keys | Where-Object { $_ -like "lastSeen-*" })) {
    $entry = $historyStore[$key]
    if ($entry -and $entry.Keys.Count -gt 0) { $prevSeenLabels[$key] = [string]@($entry.Keys)[0] }
}

# 다만 '새로 들어온 값'의 기준은 직전 실행이 아니라 마지막으로 실제 나간 메일이다. 실행은 하루
# 여섯 번이고 메일은 그중 한 번뿐이라, 메일이 아닌 실행에 들어온 새 값은 그 실행이 lastSeen 을
# 덮어써 버려 어떤 메일에도 실리지 못했다 — 월간 KCl 이 11:23 실행에 들어오면 이튿날 아침 메일은
# 그것을 '이미 본 값'으로 건너뛴다. 워크플로가 발송 성공 직후에 mailed-labels.next.json 을
# mailed-labels.json 으로 승격한다(.last-digest 와 같은 방식). 파일이 없거나 거기 없는 카드는
# 예전처럼 직전 실행 기준으로 떨어진다.
$mailedLabelsPath = Join-Path $root "mailed-labels.json"
$mailedLabels = @{}
if (Test-Path $mailedLabelsPath) {
    try {
        $rawMailed = Get-Content -Path $mailedLabelsPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($p in $rawMailed.PSObject.Properties) { $mailedLabels[$p.Name] = [string]$p.Value }
    } catch {
        Write-Warning "mailed-labels.json을 읽지 못해 직전 실행 기준으로 판정합니다: $($_.Exception.Message)"
    }
}
function Get-BaselineLabel {
    param($id)
    if ($mailedLabels.ContainsKey([string]$id)) { return $mailedLabels[[string]$id] }
    $prevSeenLabels["lastSeen-$id"]
}

# Remember what each card last looked like, so tomorrow's failure can still show a number.
#
# Rewritten only when the label moves. The FX and oil cards end on an intraday point whose value
# shifts every run while its date stays put, so rewriting unconditionally changed this file on
# all six runs a day and each one became a commit - a history of 'accumulate price history'
# with the actual work buried in it. The fallback shows the first reading of that date instead
# of the last, a few tenths of a percent apart, beside a label saying which date it is.
function Set-LastSeen {
    param($id, $label, $value)
    $key = "lastSeen-$id"
    $prev = $historyStore[$key]
    if ($prev -and $prev.ContainsKey([string]$label)) { return }
    $historyStore[$key] = @{ [string]$label = $value }
}
foreach ($c in $priceCards) {
    $pts = @($c.points)
    if ($pts.Count -eq 0) { continue }
    Set-LastSeen $c.id $pts[-1].label $pts[-1].value
}
# SCFI 는 $priceCards 밖에서 따로 조립되므로 같은 기록을 여기서 남긴다 - 주간 지수라 위 문제를
# 그대로 안고 있다(새 주차가 나오지 않은 날에도 지난주 변동률이 계속 잡힌다).
if ($scfi -and $scfi.currentDate) {
    Set-LastSeen "scfi" $scfi.currentDate $scfi.current
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

# 경향성: 시계열이 있는 카드마다 붙인다. 페이지 카드·상세 팝업·핵심 지표 요약·메일이 모두 이 값을 읽는다.
foreach ($c in $priceCards) {
    if ($c.failed) { continue }
    $t = Get-TrendStats $c.points
    if ($t) { $c | Add-Member -NotePropertyName trend -NotePropertyValue $t -Force }
    # 예상치. 기록이 30개 미만이거나 시험할 시점이 모자라면(SCFI·CCFI 처럼 쌓는 중인 계열) 붙지 않는다.
    $fc = Get-Forecast $c.points
    if ($fc) { $c | Add-Member -NotePropertyName forecast -NotePropertyValue $fc -Force }
}
if ($scfi -and $scfi.points) {
    $t = Get-TrendStats $scfi.points
    if ($t) { $scfi | Add-Member -NotePropertyName trend -NotePropertyValue $t -Force }
    $fc = Get-Forecast $scfi.points
    if ($fc) { $scfi | Add-Member -NotePropertyName forecast -NotePropertyValue $fc -Force }
}
foreach ($l in $sseLanes) {
    $t = Get-TrendStats $l.points
    if ($t) { $l | Add-Member -NotePropertyName trend -NotePropertyValue $t -Force }
}

# 물류 운영 핵심 지표 요약. 카드가 열 개 넘게 흩어져 있으면 운임·환율·유가·내륙운송료를 서로 비교하려고
# 화면을 오르내려야 한다. 물류팀이 판단에 쓰는 지표만 config.opsSummary.items 순서대로 한 표에 모은다.
function Get-OpsSummaryRow {
    param([string]$id)
    $row = [ordered]@{ id = $id; detail = $id; name = $id; value = $null; currency = ""; unit = ""; label = ""
        shortLabel = ""; shortPct = $null; longLabel = ""; longPct = $null; trend = ""; tone = "flat"; position = ""; note = ""
        fc = $null }
    $t = $null
    $fcSrc = $null
    if ($id -eq "safe-freight") {
        if (-not $safeFreight) { return $null }
        $sf = $safeFreight
        $row.name = "컨테이너 내륙운송료"
        $row.label = "적용 $($sf.window.applyLabel)"
        $row.trend = "$($sf.base.verdict) 예상"
        $row.tone = if ($sf.base.verdict -eq "인상") { "up" } elseif ($sf.base.verdict -eq "인하") { "down" } else { "flat" }
        $sign = if ($sf.base.diff -gt 0) { "+" } else { "" }
        $row.note = "산정 $($sf.window.label) 평균 $(Format-Won $sf.base.avg)원, 기준 대비 $sign$(Format-Won $sf.base.diff)원"
        if ($sf.scenario -and $sf.scenario.trigger) {
            $row.note += " · 유류세 인하 종료 시 $($sf.scenario.trigger.applyLabel) $($sf.scenario.trigger.verdict)"
        }
        return [PSCustomObject]$row
    }
    if ($id -eq "scfi") {
        if (-not $scfi) { return $null }
        $row.name = "SCFI 컨테이너 운임"; $row.value = $scfi.current; $row.unit = "pt"; $row.label = $scfi.currentDate
        $t = $scfi.trend; $fcSrc = $scfi.forecast
    } elseif ($id -like "ccfi-*") {
        $l = @($sseLanes | Where-Object { $_.id -eq $id })[0]
        if (-not $l) { return $null }
        $row.name = "CCFI $($l.displayName)"; $row.value = $l.current; $row.unit = "pt"; $row.label = $l.currentDate
        $row.detail = "ccfi-lanes"; $t = $l.trend
    } else {
        $c = @($priceCards | Where-Object { [string]$_.id -eq $id })[0]
        if (-not $c) { return $null }
        $row.name = $c.displayName
        if ($c.failed) {
            $row.trend = "수집 실패"; $row.note = "오늘 데이터를 가져오지 못했습니다"
            return [PSCustomObject]$row
        }
        $pts = @($c.points)
        $row.value = $pts[-1].value; $row.currency = [string]$c.currency; $row.unit = [string]$c.unit; $row.label = $pts[-1].label
        $t = $c.trend; $fcSrc = $c.forecast
    }
    if ($t) {
        $row.shortLabel = $t.shortLabel; $row.shortPct = $t.shortPct; $row.longLabel = $t.longLabel; $row.longPct = $t.longPct
        $row.trend = $t.trend; $row.tone = $t.tone; $row.position = $t.position
    } else {
        $row.trend = "기록 부족"
    }
    if ($fcSrc -and @($fcSrc.horizons).Count -gt 0) { $row.fc = @($fcSrc.horizons)[0] }
    [PSCustomObject]$row
}

$opsSummary = $null
if ($config.opsSummary -and @($config.opsSummary.items).Count -gt 0) {
    $opsRows = @(@(foreach ($id in @($config.opsSummary.items)) { Get-OpsSummaryRow ([string]$id) }) | Where-Object { $_ })
    # 한 문장 흐름 요약: 판정별로 지표 이름을 묶는다.
    $groups = [ordered]@{ "상승 흐름" = @(); "하락 흐름" = @(); "엇갈림" = @(); "보합" = @() }
    foreach ($r in $opsRows) {
        if ($r.trend -eq "수집 실패" -or $r.trend -eq "기록 부족") { continue }
        $k = switch ($r.tone) { "up" { "상승 흐름" } "down" { "하락 흐름" } "mixed" { "엇갈림" } default { "보합" } }
        $groups[$k] += $r.name
    }
    $sentence = (@(foreach ($k in $groups.Keys) { if ($groups[$k].Count) { "$k`: $($groups[$k] -join ', ')" } }) -join " / ")
    $opsSummary = [PSCustomObject]@{
        title    = if ($config.opsSummary.title) { $config.opsSummary.title } else { "물류 운영 핵심 지표" }
        rows     = $opsRows
        sentence = $sentence
        method   = "경향은 최근 4주·13주(월간 지표는 1·3개월) 변화율을 지표마다 평소 변동폭과 비교해 매일 같은 규칙으로 자동 판정한 값입니다. 판단 근거로 쓸 때는 상세 화면의 원자료와 함께 확인하세요."
        dashboardUrl = "https://jhkim0603.github.io/work-dashboard/"
    }
    Write-Host "  핵심 지표 요약 $($opsRows.Count)개 · $sentence"
}
$scfiSort = Get-CardSort "scfi"
$laneSort = Get-CardSort "ccfi-lanes"
$sfSort = Get-CardSort "safe-freight"
if ($safeFreight -and $config.cardAbout.'safe-freight') {
    $safeFreight | Add-Member -NotePropertyName about -NotePropertyValue $config.cardAbout.'safe-freight' -Force
}
if ($scfi -and $config.cardAbout.scfi) {
    $scfi | Add-Member -NotePropertyName about -NotePropertyValue $config.cardAbout.scfi -Force
}
# The lane card is one card built from several series, so its text is keyed by the card rather
# than by any single lane id.
$laneAbout = $config.cardAbout.'ccfi-lanes'

# Attach "왜 움직였나" headlines to each price card - shown in the detail popup, so a move on
# the chart can be read against what was reported around it rather than left unexplained.
Write-Host "Fetching price driver news..."
# 이 아래에서 부를 뉴스 검색 전부 - 가격 카드, SCFI, 수급 뉴스 - 를 먼저 동시에 받아 둔다.
$newsQueries = @(
    foreach ($c in $priceCards) { if ($c.newsQuery) { $c.newsQuery } else { $config.priceNewsQueries.($c.id) } }
    if ($scfi) { $config.priceNewsQueries.scfi }
    if ($safeFreight) { $config.priceNewsQueries.'safe-freight' }
    foreach ($mat in $config.materials) { $mat.NewsQueries }
)
Invoke-Prefetch -urls @($newsQueries | Where-Object { $_ } | ForEach-Object { Get-NewsUri -query $_ })

foreach ($c in $priceCards) {
    $q = $c.newsQuery
    if (-not $q) { $q = $config.priceNewsQueries.($c.id) }
    if (-not $q) { continue }
    Write-Host "  - $($c.displayName)"
    $driverNews = @(Get-NewsHeadlines -query $q -max 5)
    $c | Add-Member -NotePropertyName news -NotePropertyValue $driverNews -Force
    if (-not $script:newsFromPrefetch) { Start-Sleep -Milliseconds 300 }
}
if ($scfi) {
    $q = $config.priceNewsQueries.scfi
    if ($q) {
        Write-Host "  - $($scfi.displayName)"
        $scfi | Add-Member -NotePropertyName news -NotePropertyValue @(Get-NewsHeadlines -query $q -max 5) -Force
    }
}
if ($safeFreight) {
    $q = $config.priceNewsQueries.'safe-freight'
    if ($q) {
        Write-Host "  - $($safeFreight.displayName)"
        $safeFreight | Add-Member -NotePropertyName news -NotePropertyValue @(Get-NewsHeadlines -query $q -max 5) -Force
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

# Every JSON below lands inside a <script> block, where the HTML parser ends the block at the
# first "</script>" even inside a JS string. Windows PowerShell escapes < on its own; pwsh on the
# runner does not, so a headline carrying that text would blank the whole page. "<\/" is the same
# string to JSON and never closes a tag.
function ConvertTo-JsonOrNull {
    param($InputObject, $Depth = 6)
    if ($null -eq $InputObject) { return "null" }
    $json = ConvertTo-Json -InputObject $InputObject -Depth $Depth
    if ($null -eq $json -or $json -eq "") { return "null" }
    return $json.Replace("</", "<\/")
}

$weatherJson = ConvertTo-JsonOrNull -InputObject @($weather) -Depth 6
$holidayJson = ConvertTo-JsonOrNull -InputObject $holiday -Depth 4
$foreignHolidaysJson = ConvertTo-JsonOrNull -InputObject @($foreignHolidays) -Depth 3
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
$pricesJson = ConvertTo-JsonOrNull -InputObject @($priceCards) -Depth 6
$scfiJson = ConvertTo-JsonOrNull -InputObject $scfi -Depth 4
$sseLanesJson = ConvertTo-JsonOrNull -InputObject @($sseLanes) -Depth 4
$laneAboutJson = ConvertTo-JsonOrNull -InputObject $laneAbout -Depth 2
$sortsJson = ConvertTo-Json -InputObject ([PSCustomObject]@{ scfi = $scfiSort; lanes = $laneSort; safeFreight = $sfSort }) -Depth 2 -Compress
$safeFreightJson = ConvertTo-JsonOrNull -InputObject $safeFreight -Depth 8
$hasFuelKey = if ($env:OPINET_API_KEY) { "true" } else { "false" }
# A failed KCl fetch used to just not append a card, so the page came back one card shorter
# with nothing saying so - indistinguishable from "we never tracked potash". Say it instead.
$hasKcl = if ($kcl) { "true" } else { "false" }
# 구글 뉴스가 막혀 뉴스가 한 건도 없는 날. 뉴스 때문에 가격·날씨·태풍까지 그날 갱신을 멈출 이유는
# 없으므로 뉴스 칸에 안내만 띄우고 배포한다. 막힌 기록 없이 0건이면(읽어 오는 부분 고장) 아래 점검이 막는다.
$newsOutage = (@($materials | ForEach-Object { $_.news } | Where-Object { $_ }).Count -eq 0) -and ($script:newsThrottleFails -gt 0)
if ($newsOutage) {
    Write-Warning "구글 뉴스 응답 없음 - 오늘은 뉴스 없이 배포합니다."
    if ($env:CI) { Write-Host "::warning::구글 뉴스가 응답하지 않아 오늘은 뉴스 없이 배포합니다" }
}
$materialsJson = ConvertTo-JsonOrNull -InputObject @($materials) -Depth 6
$opsSummaryJson = ConvertTo-JsonOrNull -InputObject $opsSummary -Depth 6
$fetchedAt = $nowKst.ToString("yyyy-MM-ddTHH:mm:ss") + "+09:00"

$template = Get-Content -Path (Join-Path $root "template.html") -Raw -Encoding UTF8
$output = $template.Replace("__WEATHER_JSON__", $weatherJson).Replace("__HOLIDAY_JSON__", $holidayJson).Replace("__FOREIGN_HOLIDAYS_JSON__", $foreignHolidaysJson).Replace("__TYPHOON_JSON__", $typhoonJson).Replace("__CLIMATOLOGY_JSON__", $climatologyJson).Replace("__PRICES_JSON__", $pricesJson).Replace("__SCFI_JSON__", $scfiJson).Replace("__SSE_LANES_JSON__", $sseLanesJson).Replace("__LANE_ABOUT_JSON__", $laneAboutJson).Replace("__CARD_SORTS_JSON__", $sortsJson).Replace("__SAFE_FREIGHT_JSON__", $safeFreightJson).Replace("__HAS_FUEL_KEY__", $hasFuelKey).Replace("__HAS_KCL__", $hasKcl).Replace("__MATERIALS_JSON__", $materialsJson).Replace("__OPS_SUMMARY_JSON__", $opsSummaryJson).Replace("__NEWS_OUTAGE__", $(if ($newsOutage) { "true" } else { "false" })).Replace("__FETCHED_AT__", $fetchedAt)

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

# Headlines, outlets and links come from whoever Google News indexed: an & or < in one is markup
# once it is pasted into the mail, and a quote in a link ends the href early.
function Get-HtmlText {
    param($text)
    [System.Net.WebUtility]::HtmlEncode([string]$text)
}

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

# Vietnam/China blocks starting within 30 days (or under way). Further out they are planning
# material, which the page lists; the mail is for what touches this month's shipments.
$foreignSoon = @($foreignHolidays | Where-Object { $_.dDay -le 30 })

$holidayHtml = ""
if ($holiday -or $foreignSoon.Count -gt 0) {
    $krHtml = ""
    if ($holiday) {
        $names = ($holiday.holidayNames | Select-Object -Unique) -join ", "
        $dDayText = if ($holiday.dDay -eq 0) { "오늘부터" } else { "D-$($holiday.dDay)" }
        $krHtml = @"
  <div style="font-weight:650;font-size:13px;color:#0b0b0b;">가장 빠른 연휴: $($holiday.startDate) ~ $($holiday.endDate) ($($holiday.days)일, $dDayText)</div>
  <div style="font-size:12px;color:#52514e;margin-top:4px;">$names</div>
"@
    }
    $fRows = foreach ($f in $foreignSoon) {
        $dText = if ($f.dDay -le 0) { "진행 중" } else { "D-$($f.dDay)" }
        "<div style='font-size:12px;color:#3d3b37;margin-top:4px;'><b>$($f.country) $($f.name)</b> $($f.startDate.Substring(5)) ~ $($f.endDate.Substring(5)) ($($f.days)일, $dText) <span style='color:#898781;'>· $($f.impact)</span></div>"
    }
    $fHtml = if ($fRows) { "<div style='margin-top:9px;padding-top:8px;border-top:1px solid #cfe0f5;font-size:11px;font-weight:700;color:#6e6c66;'>베트남·중국 휴무 (30일 이내)</div>$($fRows -join '')" } else { "" }
    $holidayHtml = @"
<div style="margin:16px 0;padding:12px 14px;background:#eef4fc;border:1px solid #cfe0f5;border-radius:8px;">
$krHtml
  $fHtml
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
} else {
    # GDACS 가 끝내 응답하지 않은 날. 전에는 $typhoonHtml 이 빈 채로 남아 메일에서 이 블록이
    # 통째로 사라졌다 - 페이지는 "가져오지 못했습니다"라고 말하는데 메일은 침묵했고, 태풍이
    # 없는 날의 메일과 구분되지 않았다. 이 섹션이 있는 이유가 입고 지연을 미리 잡는 것이니
    # "확인 못 함"은 "없음"과 반드시 달라 보여야 한다.
    $typhoonHtml = @"
<div style="margin:16px 0;padding:13px 15px;background:#fdf6e7;border:1px solid #f0dcb4;border-left:4px solid #a15c00;">
  <div style="font-weight:700;font-size:14px;color:#a15c00;">⚠ 오늘 태풍 정보를 가져오지 못했습니다 — 태풍이 없다는 뜻이 아닙니다</div>
  <div style="font-size:12px;color:#52514e;margin-top:5px;">GDACS 가 응답하지 않았습니다. 다음 실행에서 자동 재시도합니다. 급하면 <a href="https://www.gdacs.org/" style="color:#2a78d6;">GDACS</a> 에서 직접 확인하세요.</div>
</div>
"@
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
        # 두 번째 정리(2026-09): 막대 사이 간격을 막대마다의 padding:0 1px 대신 바깥 표의
        # cellspacing 으로 한 번만 적고, 숫자·색 속성의 따옴표를 뺐다(HTML 에서 공백 없는 값은
        # 따옴표가 필요 없다). 막대당 36바이트, 메일 전체로 약 6KB. style 값은 ; 가 있어 그대로 둔다.
        $spacer = if ($pad -gt 0) { "<tr><td height=$pad style='font-size:0;line-height:0'>&nbsp;</td></tr>" } else { "" }
        "<td><table cellpadding=0 cellspacing=0 border=0>$spacer<tr><td height=$h width=$barW bgcolor=$fill style='font-size:0;line-height:0'>&nbsp;</td></tr></table></td>"
    }
    "<table cellpadding=0 cellspacing=2 border=0><tr>$($cells -join '')</tr></table>"
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
    # Reference price line (mail only - see $cardTargets). Above the reference is the costly side,
    # so it takes the same red the up-is-bad badges use.
    $targetHtml = ""
    $tg = $cardTargets[[string]$c.id]
    if ($tg) {
        $ref = [double]$tg.ref
        $dev = (([double]$latest.value - $ref) / $ref) * 100
        $tLabel = if ($tg.label) { Get-HtmlText $tg.label } else { "기준가" }
        $tColor = if ($dev -ge 0) { "#b3221f" } else { "#0a6b0a" }
        $tSign = if ($dev -ge 0) { "+" } else { "" }
        $targetHtml = "<div style='font-size:12px;margin-top:4px;color:#52514e;'>$tLabel $($c.currency)$(Format-PriceValue $ref) 대비 <b style='color:$tColor;'>$tSign$($dev.ToString('N1'))%</b></div>"
    }
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
    $targetHtml
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

# 안전운임 유가연동 전망. 페이지 카드와 같은 내용을 메일 표 한 칸에 줄여 담는다.
$sfHtml = ""
if ($safeFreight) {
    $sf = $safeFreight
    $vColor = @{ "인상" = "#b3221f"; "인하" = "#0a6b0a"; "동결" = "#6e6c66" }
    function Get-SignedWon { param($v) $d = [double]$v; $s = if ($d -gt 0) { "+" } elseif ($d -lt 0) { "-" } else { "" }; "$s$(Format-Won ([math]::Abs($d)))" }
    $estTag = if ($sf.baseProvisional) { ", 잠정" } else { "" }
    $baseLine = "<b style='color:$($vColor[$sf.base.verdict]);'>$($sf.base.verdict) 예상</b> (적용 기간 $($sf.window.applyLabel)) · 산정 기간 $($sf.window.label) 평균 $(Format-Won $sf.base.avg)원, 기준 $(Format-Won $sf.baseFuel)원($($sf.baseWindow)$estTag) 대비 $(Get-SignedWon $sf.base.diff)원 (±$(Format-Won $sf.threshold)원 기준)"
    if ($sf.pending -and $sf.applied) {
        $pd = [DateTime]$sf.pending.effective
        $baseLine = "현재 적용 $(Format-Won $sf.applied.fuel)원($($sf.applied.window) 산정) → $($pd.Month)/$($pd.Day)부터 $(Format-Won $sf.pending.fuel)원 $($sf.pending.verdict) 적용 예정<br>" + $baseLine
    }
    $scLine = ""
    $impactRows = @()
    $impactTitle = ""
    if ($sf.base.verdict -ne "동결") {
        $impactRows = @($sf.base.impact)
        $impactTitle = "적용 기간 $($sf.window.applyLabel) 예상 운임"
    }
    if ($sf.scenario) {
        $s = $sf.scenario
        $scLine = "$($s.label)(D-$($s.dDay)): $($s.current.window) $(Format-Won $s.current.avg)원($(Get-SignedWon $s.current.diff)원, $($s.current.verdict))"
        if ($s.current.verdict -eq "동결") {
            $scLine += " → $($s.next.window) $(Format-Won $s.next.avg)원($(Get-SignedWon $s.next.diff)원, $($s.next.verdict))"
        }
        if ($s.trigger) {
            $scLine += " → <b style='color:$($vColor[$s.trigger.verdict]);'>$($s.trigger.applyLabel) 적용분 $($s.trigger.verdict) 예상</b>"
            if ($impactRows.Count -eq 0) {
                $impactRows = @($s.trigger.impact)
                $impactTitle = "시나리오: 적용 기간 $($s.trigger.applyLabel) 예상 운임"
            }
        }
    }
    $impactHtml = ""
    if ($impactRows.Count -gt 0) {
        $rows = foreach ($r in $impactRows) {
            $c = if ($r.change -gt 0) { "#b3221f" } elseif ($r.change -lt 0) { "#0a6b0a" } else { "#6e6c66" }
            "<tr><td style='padding:3px 8px 3px 0;font-size:12.5px;font-weight:600;color:#0b0b0b;'>$($r.name) $(Format-Won $r.km)km</td><td style='padding:3px 8px 3px 0;font-size:12.5px;text-align:right;white-space:nowrap;color:#52514e;'>$(Format-Won $r.rate) → $(Format-Won $r.newRate)원</td><td style='padding:3px 0;font-size:12px;font-weight:700;text-align:right;white-space:nowrap;color:$c;'>$(Get-SignedWon $r.change)원 ($(Get-SignedWon ([math]::Round($r.changePct, 1)))%)</td></tr>"
        }
        $impactHtml = "<div style='font-size:11px;color:#898781;margin-top:8px;'>$impactTitle</div><table style='width:100%;border-collapse:collapse;margin-top:3px;'>$($rows -join '')</table>"
    }
    $scHtml = if ($scLine) { "<div style='font-size:12px;color:#52514e;margin-top:5px;'>$scLine</div>" } else { "" }
    $sfHtml = @"
<tr>
  <td style="padding:14px 16px;border-bottom:1px solid #e1e0d9;">
    <div style="font-weight:700;font-size:13.5px;color:#0b0b0b;">$($sf.displayName)</div>
    <div style="font-size:12.5px;color:#0b0b0b;margin-top:5px;">$baseLine</div>
    $scHtml
    $impactHtml
    <div style="font-size:11px;color:#898781;margin-top:7px;">$($sf.rateBasis). 운임 변동은 왕복거리 ÷ 연비 $($sf.kmPerLiter)km/L × 유가 변동으로 계산한 근사치입니다.</div>
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
if ($sfHtml) { $priceSectionRows += [PSCustomObject]@{ sort = $sfSort; html = $sfHtml } }
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
        $meta = Get-HtmlText ((@($h.source, $h.date) | Where-Object { $_ }) -join " · ")
        "<div style='margin-top:8px;'>$chip<a href='$(Get-HtmlText $h.link)' style='font-size:13px;font-weight:700;color:#0b0b0b;text-decoration:none;'>$(Get-HtmlText $h.title)</a><div style='font-size:11px;color:#898781;margin-top:2px;'>$meta</div></div>"
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
        $meta = Get-HtmlText ((@($n.source, $n.date) | Where-Object { $_ }) -join " · ")
        $nTitle = Get-HtmlText $n.title
        $nLink = Get-HtmlText $n.link
        $metaHtml = if ($meta) { "<div style='font-size:11px;color:#898781;margin-top:1px;'>$meta</div>" } else { "" }
        # Same left rule and reason chip the page uses, so a headline flagged there is
        # recognisable here. Inline styles only - mail clients drop stylesheets.
        if ($n.flag) {
            $chip = if ($n.reason) {
                "<span style='display:inline-block;font-size:10px;font-weight:700;background:#b3221f;color:#ffffff;padding:1px 7px;border-radius:4px;'>$($n.reason)</span><br>"
            } else { "" }
            @"
<div style="margin-top:9px;border-left:3px solid #b3221f;padding-left:9px;">
      $chip<a href="$nLink" style="font-size:12.5px;color:#0b0b0b;font-weight:700;text-decoration:none;line-height:1.45;">$nTitle</a>
      $metaHtml
    </div>
"@
        } else {
            @"
<div style="margin-top:7px;">
      <a href="$nLink" style="font-size:12.5px;color:#2a78d6;text-decoration:none;line-height:1.45;">$nTitle</a>
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

# 물류 운영 핵심 지표 요약. 메일 맨 위쪽에 둔다 - 가격 카드 열 개를 내려 읽지 않아도 오늘 흐름이 보이게.
# 메일 용량(Gmail 102KB)을 생각해 스타일은 표에 한 번 걸고 칸마다 정렬만 준다.
$opsHtml = ""
if ($opsSummary -and @($opsSummary.rows).Count -gt 0) {
    $toneColor = @{ up = "#b3221f"; down = "#0a6b0a"; mixed = "#a15c00"; flat = "#6e6c66" }
    function Get-PctText {
        param($v)
        if ($null -eq $v) { return "-" }
        $d = [double]$v
        $sg = if ($d -gt 0) { "+" } else { "" }
        "$sg$($d.ToString('N1'))%"
    }
    $opsRowHtml = foreach ($r in $opsSummary.rows) {
        $val = if ($null -ne $r.value) { "$($r.currency)$(Format-PriceValue $r.value)" } else { "" }
        $tc = $toneColor[[string]$r.tone]
        if (-not $tc) { $tc = "#6e6c66" }
        $sub = if ($r.note) { $r.note } elseif ($r.position) { $r.position } else { "" }
        # 칸마다 style 을 반복하면 행 하나가 700B 가까이 된다. 여백은 표의 cellpadding, 줄바꿈 막기는
        # nowrap 속성으로 넘겨 행당 크기를 절반 아래로 줄였다(메일이 Gmail 잘림 기준 102KB 에 가깝다).
        $subHtml = if ($sub) { "<br><font size=1 color=#898781>$(Get-HtmlText $sub)</font>" } else { "" }
        $fcHtml = if ($r.fc) { "<br><font size=1 color=#52514e>$($r.fc.label) $($r.currency)$(Format-PriceValue $r.fc.low)~$(Format-PriceValue $r.fc.high)</font>" } else { "" }
        "<tr><td><b>$($r.name)</b>$subHtml</td><td align=right nowrap>$val</td><td align=right nowrap>$(Get-PctText $r.shortPct)</td><td align=right nowrap>$(Get-PctText $r.longPct)</td><td align=right nowrap><b><font color=$tc>$($r.trend)</font></b>$fcHtml</td></tr>"
    }
    $opsHtml = @"
<div style="margin:16px 0;padding:13px 15px;background:#ffffff;border:1px solid #e1e0d9;border-radius:8px;">
  <div style="font-size:12px;font-weight:700;color:#0b0b0b;">$($opsSummary.title)</div>
  <div style="font-size:12px;color:#52514e;margin-top:4px;">$($opsSummary.sentence)</div>
  <table width="100%" cellpadding=4 cellspacing=0 style="margin-top:6px;font-size:12.5px;color:#0b0b0b;">
    <tr style="font-size:10.5px;color:#898781;"><td>지표</td><td align=right>현재</td><td align=right>단기</td><td align=right>중기</td><td align=right>경향</td></tr>
    $($opsRowHtml -join "")
  </table>
  <div style="font-size:10.5px;color:#898781;margin-top:8px;">단기 4주·중기 13주(월간 지표는 1·3개월). $($opsSummary.method) 경향 아래 범위는 과거 예측 오차로 낸 80% 예상 범위입니다(사건·정책 미반영).</div>
</div>
"@
}

# 구글 뉴스 장애로 뉴스가 없는 날은 수급 뉴스 칸에 그 사실을 적는다(빈 카드만 늘어서 있으면 고장처럼 보인다).
if ($newsOutage) {
    $materialsHtml = @("<tr><td style=`"padding:14px 16px;font-size:12.5px;color:#52514e;`">구글 뉴스가 응답하지 않아 오늘은 뉴스를 싣지 못했습니다. 다음 실행에서 자동으로 다시 가져옵니다.</td></tr>")
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

# The color-scheme meta pair says this mail is designed for light and only light. Without it,
# Gmail's and Apple Mail's dark modes decide for themselves which colours to invert, and they
# invert backgrounds more eagerly than text - which is how a card ends up dark grey with the
# near-black heading still sitting on it. Declaring one scheme opts the message out of that
# guesswork. Kept as a PowerShell comment rather than an HTML one: every byte inside the
# heredoc is mailed, and this mail is at 78% of the size Gmail clips at.
$emailHtml = @"
<!DOCTYPE html>
<html lang="ko">
<head>
<meta charset="utf-8">
<meta name="color-scheme" content="light">
<meta name="supported-color-schemes" content="light">
</head>
<body style="margin:0;padding:0;background:#f9f9f7;font-family:'Malgun Gothic',sans-serif;">
<div style="max-width:600px;margin:0 auto;padding:24px 16px;">
  <h2 style="margin:0 0 4px;color:#0b0b0b;">물류팀 운영 참고지표 Dashboard</h2>
  <div style="font-size:12px;color:#898781;margin-bottom:14px;">$emailDateStr 기준</div>
  <div style="margin-bottom:16px;">
    <a href="$dashboardUrl" style="display:inline-block;background:#2a78d6;color:#ffffff;font-size:13px;font-weight:bold;text-decoration:none;padding:10px 18px;border-radius:6px;">📋 대시보드 열기 →</a>
    <a href="$updateUrl" style="display:inline-block;margin-left:8px;background:#ffffff;color:#2a78d6;border:1px solid #cfe0f5;font-size:13px;font-weight:bold;text-decoration:none;padding:9px 16px;border-radius:6px;">🔄 지금 업데이트</a>
  </div>
  $holidayHtml
  $failureHtml
  $opsHtml
  $highlightHtml
  $typhoonHtml
  $(Get-EmailSection "날씨 · 온습도" ($weatherRowsHtml -join "`n"))
  $(Get-EmailSection "원자재 · 물류 가격" $priceSectionHtml)
  $(Get-EmailSection "수급 뉴스" ($materialsHtml -join "`n"))
  <div style="margin-top:16px;font-size:11px;color:#898781;line-height:1.6;">
    날씨: Open-Meteo · 공휴일: Nager.Date · 베트남·중국 휴무: Google 캘린더 · 태풍: GDACS · 유가/목재: Yahoo Finance · KCl: World Bank · 운임지수: Shanghai Shipping Exchange · 뉴스: Google 뉴스. 업무 참고용 요약입니다.<br>
    자세한 내용은 <a href="$dashboardUrl" style="color:#2a78d6;">대시보드</a>에서 확인하세요.
  </div>
</div>
</body></html>
"@

# 제목 특이사항. 본문은 이미 태풍·특보·연휴·가격을 각 블록에서 보여주지만 그건 메일을 열어야
# 보인다. 매일 같은 제목이 오면 오늘이 열어볼 날인지를 받은편지함에서 구분할 수 없고, 그래서
# 정작 태풍이 뜬 날의 메일도 여느 날과 똑같이 지나치게 된다.
#
# 우선순위는 "얼마나 시급히 일정을 바꿔야 하는가" 순이다. 태풍은 이미 떠 있는 배와 입고일에
# 걸리니 가장 위, 기상특보는 당일 작업에 걸리니 그 다음, 연휴는 미리 알수록 좋지만 D-7 안쪽이
# 아니면 매일 띄울 이유가 없고, 가격은 급변했을 때만 올린다.
$wdHighlights = New-Object System.Collections.ArrayList

if ($typhoon -and $typhoon.active.Count -gt 0) {
    $anyDirect = @($typhoon.active | Where-Object { $_.impact -eq "direct" }).Count -gt 0
    $names = (@($typhoon.active | ForEach-Object { $_.name }) -join ", ")
    $kind = if ($anyDirect) { "직접영향" } else { "항로영향" }
    [void]$wdHighlights.Add([PSCustomObject]@{ text = "태풍 $names $kind"; priority = 100 })
}

foreach ($w in $weather) {
    # 오늘 특보만 제목에 올린다. 예보 특보까지 넣으면 한여름엔 거의 매일 붙어서 신호가 죽는다.
    foreach ($a in @($w.advisories)) {
        if (-not $a) { continue }
        $short = ($a.text -split ' ·')[0]
        $pri = if ($a.tone -eq "danger") { 95 } else { 90 }
        [void]$wdHighlights.Add([PSCustomObject]@{ text = "$($w.displayName) $short"; priority = $pri })
    }
}

if ($holiday -and $holiday.dDay -le 7) {
    $names = ($holiday.holidayNames | Select-Object -Unique) -join "/"
    $dText = if ($holiday.dDay -eq 0) { "오늘부터" } else { "D-$($holiday.dDay)" }
    [void]$wdHighlights.Add([PSCustomObject]@{ text = "$names 연휴 $dText"; priority = 70 })
}

# A Vietnam/China block of three days or more, from ten days out. Shorter ones (a single 문화의 날)
# rarely move a shipment; a week-long 국경절 or 뗏 does, and ten days is when it can still be
# worked around.
foreach ($f in @($foreignHolidays | Where-Object { $_.days -ge 3 -and $_.dDay -le 10 })) {
    $dText = if ($f.dDay -le 0) { "진행 중" } else { "D-$($f.dDay)" }
    [void]$wdHighlights.Add([PSCustomObject]@{ text = "$($f.country) $($f.name) $dText"; priority = 68 })
}

# 가격은 주간·월간 시계열이라 주식처럼 흔들리지 않는다. 5%면 이 계열들에서는 충분히 드문 폭이다.
#
# 다만 폭보다 먼저 따지는 건 "이번에 새로 들어온 값인가"다. 계열마다 갱신 주기가 일간부터
# 연간까지 제각각이라, 폭만 보면 갱신이 느린 계열이 제 주기 내내 제목을 차지한다. 시점 라벨이
# 지난 실행과 같다면 값도 그대로이므로 오늘의 소식이 아니다.
# 기준은 카드마다 config.cardAlertPct 로 바꿀 수 있고, 없으면 5% 다.
foreach ($c in $priceCards) {
    $pts = @($c.points)
    if ($pts.Count -lt 2) { continue }
    $prevLabel = Get-BaselineLabel $c.id
    # 기록이 없으면(첫 실행) 새 값인지 알 수 없으므로 올리지 않는다 - 모르는 쪽을 조용히 둔다.
    if (-not $prevLabel -or $prevLabel -eq [string]$pts[-1].label) { continue }
    $lv = $pts[-1].value; $pv = $pts[-2].value
    if (-not $pv) { continue }
    $pctChg = (($lv - $pv) / $pv) * 100
    if ([math]::Abs($pctChg) -ge (Get-ChangeAlertPct $c.id)) {
        $sign = if ($pctChg -ge 0) { "+" } else { "" }
        [void]$wdHighlights.Add([PSCustomObject]@{ text = "$($c.displayName) $sign$($pctChg.ToString('N1'))%"; priority = [math]::Abs($pctChg) })
    }
    # 기준가(계약·예산 단가)에서 alertPct 이상 벗어난 새 값. 같은 '새 값' 게이트를 거치므로
    # 기준을 넘은 채 머무는 동안 매일 제목을 차지하지는 않는다 - 새 시점이 들어올 때마다 한 번.
    $tg = $cardTargets[[string]$c.id]
    if ($tg) {
        $dev = (([double]$lv - [double]$tg.ref) / [double]$tg.ref) * 100
        $limit = if ($null -ne $tg.alertPct) { [double]$tg.alertPct } else { 5 }
        if ([math]::Abs($dev) -ge $limit) {
            $tLabel = if ($tg.label) { $tg.label } else { "기준가" }
            $sign = if ($dev -ge 0) { "+" } else { "" }
            [void]$wdHighlights.Add([PSCustomObject]@{ text = "$($c.displayName) $tLabel 대비 $sign$($dev.ToString('N1'))%"; priority = 85 })
        }
    }
}
# 안전운임: 다음 조정 판정이 지난 메일과 달라진 날(동결 → 인상 등)에만 제목에 올린다. 판정은
# 분기 내내 같은 값이라 '새 값' 게이트 없이 올리면 석 달 동안 매일 제목을 차지한다. 기록이 없는
# 첫 메일은 다른 카드처럼 올리지 않는다. 유류세 인하 종료는 연휴처럼 D-7 안쪽에서만 올린다.
$sfState = $null
if ($safeFreight) {
    $sfState = "$($safeFreight.window.key):$($safeFreight.base.verdict)"
    if ($mailedLabels.ContainsKey("safe-freight") -and $mailedLabels["safe-freight"] -ne $sfState -and $safeFreight.base.verdict -ne "동결") {
        $ef = [DateTime]$safeFreight.window.effective
        [void]$wdHighlights.Add([PSCustomObject]@{ text = "안전운임 $($safeFreight.base.verdict) 예상($($ef.Month)~$($ef.AddMonths(2).Month)월 적용)"; priority = 80 })
    }
    $s = $safeFreight.scenario
    if ($s -and $s.dDay -ge 0 -and $s.dDay -le 7) {
        [void]$wdHighlights.Add([PSCustomObject]@{ text = "유류세 인하 종료 D-$($s.dDay)(안전운임 영향)"; priority = 66 })
    }
}

$scfiPrevLabel = Get-BaselineLabel "scfi"
if ($scfi -and $scfi.changePct -and $scfiPrevLabel -and $scfiPrevLabel -ne [string]$scfi.currentDate `
    -and [math]::Abs($scfi.changePct) -ge (Get-ChangeAlertPct "scfi")) {
    $sign = if ($scfi.changePct -ge 0) { "+" } else { "" }
    [void]$wdHighlights.Add([PSCustomObject]@{ text = "SCFI $sign$($scfi.changePct)%"; priority = [math]::Abs($scfi.changePct) })
}

$wdTop = @($wdHighlights | Sort-Object priority -Descending | Select-Object -First 3 -ExpandProperty text)
$wdSubjectSuffix = if ($wdTop.Count -gt 0) { " · ⚠ " + ($wdTop -join ", ") } else { "" }

# 태그 사이 줄바꿈+들여쓰기는 공백 한 칸과 같게 렌더링되므로 한 칸으로 줄인다. 없애지는 않는다 -
# <span>$386.9</span> <span>/mt</span> 처럼 인라인 요소 사이의 줄바꿈은 눈에 보이는 띄어쓰기다.
$emailHtml = [regex]::Replace($emailHtml, '>[ \t]*\r?\n\s*<', '> <')

$utf8NoBom = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllText((Join-Path $root "email-summary.html"), $emailHtml, $utf8NoBom)
[System.IO.File]::WriteAllText((Join-Path $root "email-subject.txt"), "업무 참고자료 Dashboard - $emailDateStr$wdSubjectSuffix", $utf8NoBom)
$emailKb = [math]::Round($utf8NoBom.GetByteCount($emailHtml) / 1KB, 1)
Write-Host "Email summary written: email-summary.html ($emailKb KB)"
# Gmail 은 본문이 102KB 를 넘으면 뒷부분을 '[메시지 잘림]'으로 접는다 - 이 메일에서는 맨 아래 수급
# 뉴스가 사라진다. 카드나 섹션이 늘 때마다 조금씩 차오르므로, 넘기 전에 실행 화면에 드러나게 한다.
# 배포는 막지 않는다: 잘릴 위험이 있다는 것이지 틀린 페이지가 아니다.
if ($emailKb -gt 90) {
    Write-Warning "메일 본문 $emailKb KB - Gmail 잘림 기준(102KB)에 가깝습니다. 차트 막대 수나 섹션을 줄이세요."
    if ($env:CI) { Write-Host "::warning::메일 본문 $emailKb KB - Gmail 잘림 기준 102KB 의 $([math]::Round($emailKb / 102 * 100))%" }
}

# 이 메일이 실제로 나가면 워크플로가 이 파일을 mailed-labels.json 으로 승격한다. 오늘 못 가져온
# 카드는 지난 메일의 라벨을 그대로 물려준다 — 빼 버리면 다음 메일이 그 카드를 직전 실행 기준으로
# 판정하게 되어, 바로 그 카드에서 위의 누락이 다시 생긴다.
$nextMailed = @{}
foreach ($k in $mailedLabels.Keys) { $nextMailed[$k] = $mailedLabels[$k] }
foreach ($c in $priceCards) {
    $pts = @($c.points)
    if ($pts.Count -gt 0) { $nextMailed[[string]$c.id] = [string]$pts[-1].label }
}
if ($scfi -and $scfi.currentDate) { $nextMailed["scfi"] = [string]$scfi.currentDate }
if ($sfState) { $nextMailed["safe-freight"] = $sfState }
$nextMailedOrdered = [ordered]@{}
foreach ($k in ($nextMailed.Keys | Sort-Object)) { $nextMailedOrdered[$k] = $nextMailed[$k] }
[System.IO.File]::WriteAllText((Join-Path $root "mailed-labels.next.json"), (ConvertTo-Json -InputObject $nextMailedOrdered), $utf8NoBom)

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
if ($allNews.Count -eq 0 -and -not $newsOutage) { $problems.Add("수급 뉴스가 한 건도 없습니다") }

if ($problems.Count -gt 0) {
    Write-Host ""
    Write-Host "생성물 점검 실패 - 배포를 중단합니다:" -ForegroundColor Red
    foreach ($p in $problems) { Write-Host "  · $p" -ForegroundColor Red }
    if ($env:CI) { Write-Host "::error::생성물 점검 실패 $($problems.Count)건" }
    throw "생성물 점검 $($problems.Count)건 실패 - 이전 배포본을 유지합니다."
}
Write-Host "생성물 점검 통과 (카드 $($liveCards.Count)개 · 뉴스 $($allNews.Count)건)"
