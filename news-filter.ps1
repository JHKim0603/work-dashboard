# 뉴스 제목 거르기 - stockdashboard 와 work-dashboard 가 똑같은 이 파일을 함께 쓴다.
#
# 두 저장소의 생성 스크립트가 이 파일을 점(.)으로 불러 쓴다(. (Join-Path $PSScriptRoot "news-filter.ps1")).
# 예전에는 같은 함수가 두 스크립트에 따로 있어서 한쪽만 고치는 일이 생겼다(2026-10-30 'META_TITLE_QUOTE' 거르기를
# 양쪽에 따로 넣었다). 고칠 때는 두 저장소의 이 파일을 똑같이 고친다. 워크플로가 실행 때마다 다른 저장소의 이 파일과
# 비교해 다르면 경고를 남긴다.
#
# 거를 낱말과 출처 목록은 저장소마다 다르다(주식 기사와 물류 기사에서 걸리는 낱말이 다르다). 부르는 스크립트가
# $spamKeywords, $spamSources(정규식 목록)를 먼저 정해 둔다. 걸러낸 수는 $script:spamBlocked 에 센다.

function Test-SpamHeadline {
    param([string]$title, [string]$source)
    # 언론사 페이지의 빈 틀 글자가 제목 자리에 그대로 오는 일이 있다(2026-10-30 알파벳 'META_TITLE_QUOTE').
    # 대문자·숫자를 밑줄로 이은 한 단어나 빈 제목은 기사 제목이 아니므로 스팸처럼 거른다.
    if ([string]::IsNullOrWhiteSpace($title) -or $title.Trim() -cmatch '^[A-Z0-9]+(_[A-Z0-9]+)+$') {
        $script:spamBlocked++
        Write-Host "    (제목 아님 차단: $source | $title)"
        return $true
    }
    $haystack = "$title $source"
    $hit = @($spamKeywords | Where-Object { $_ -and $haystack -match $_ }) + @($spamSources | Where-Object { $_ -and $source -and $source -match $_ })
    if (-not $hit.Count) { return $false }
    # 걸러낸 제목을 실행 기록에 남긴다. 정상 기사가 잘못 걸리면 여기서 보인다.
    $script:spamBlocked++
    Write-Host "    (스팸 차단 '$($hit[0])': $source | $title)"
    return $true
}
