# 뽑아 낸 함수로 시험 사례를 계산해 JSON 으로 낸다. 사례 파일은 Python 쪽이 만든다.
param([string]$funcs, [string]$cases, [string]$out)
$ErrorActionPreference = "Stop"
. $funcs
function To-Hash($o) { $h = @{}; foreach ($p in $o.PSObject.Properties) { $h[$p.Name] = [double]$p.Value }; $h }
$all = Get-Content -Raw -Encoding UTF8 $cases | ConvertFrom-Json
$res = @(foreach ($c in $all) {
    $daily = To-Hash $c.daily
    $today = [DateTime]::ParseExact($c.today, "yyyy-MM-dd", $null)
    if ($c.kind -eq "window") {
        $q = Get-QuarterInfo ([DateTime]::ParseExact($c.qstart, "yyyy-MM-dd", $null))
        $sa = if ($c.stepAfter) { [DateTime]::ParseExact($c.stepAfter, "yyyy-MM-dd", $null) } else { $null }
        $w = Get-FuelWindowAverage -daily $daily -quarter $q -today $today -projBase ([double]$c.proj) -stepAfter $sa -stepWon ([double]$c.stepWon)
        $v = if ($null -ne $w.avg) { Get-FuelVerdict $w.avg ([double]$c.base) 50 } else { $null }
        [PSCustomObject]@{ id = $c.id; avg = $w.avg; months = @($w.months | ForEach-Object { $_.avg }); actualDays = $w.actualDays; projectedDays = $w.projectedDays
            diff = if ($v) { $v.diff } else { $null }; verdict = if ($v) { $v.verdict } else { $null } }
    } elseif ($c.kind -eq "outlook") {
        $cfg = $c.cfg
        $o = Get-SafeFreightOutlook -cfg $cfg -daily $daily -today $today
        [PSCustomObject]@{ id = $c.id; outlook = $o }
    }
})
[IO.File]::WriteAllText($out, (ConvertTo-Json -InputObject $res -Depth 10), (New-Object Text.UTF8Encoding $false))
"ran $($res.Count) cases"
