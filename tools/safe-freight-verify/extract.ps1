# 대시보드 PS1 에서 안전운임 계산 함수만 그대로 뽑아 sf-funcs.ps1 로 저장한다(코드를 고쳐 쓰지 않는다).
param([string]$src, [string]$out)
$tokens = $null; $errs = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($src, [ref]$tokens, [ref]$errs)
if ($errs.Count) { throw "parse errors: $($errs.Count)" }
$names = 'Format-MonthSpan','Get-QuarterInfo','Get-FuelWindowAverage','Get-FuelVerdict','Get-RouteImpacts','Get-SafeFreightOutlook','Format-Won','Get-FuelThresholdPrice','Set-NoticeWindow'
$fns = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $names -contains $n.Name }, $true)
$text = ($fns | ForEach-Object { $_.Extent.Text }) -join "`r`n`r`n"
[IO.File]::WriteAllText($out, $text, (New-Object Text.UTF8Encoding $true))
"extracted: " + (($fns | ForEach-Object Name) -join ", ")
