param([Parameter(Mandatory=$true)][string]$TimingReport)
$ErrorActionPreference = 'Stop'
$timing = Get-Content -LiteralPath $TimingReport -Raw
$setupStart = $timing.IndexOf('Setup (Max) Clock Relationship')
$holdStart = $timing.IndexOf('Hold (Min) Clock Relationship')
$pathsEnd = $timing.IndexOf('---------- 3. Path Details')
if ($setupStart -lt 0 -or $holdStart -le $setupStart -or $pathsEnd -le $holdStart) { throw 'Timing relationship sections missing; refusing trial PGM.' }
$setupText = $timing.Substring($setupStart, $holdStart - $setupStart)
$holdText = $timing.Substring($holdStart, $pathsEnd - $holdStart)
$pattern = '(?m)^\s*\S+\s+\S+\s+[-+]?\d+(?:\.\d+)?\s+([-+]?\d+(?:\.\d+)?)\s+\(R-R\)\s*$'
$setup = @([regex]::Matches($setupText, $pattern) | ForEach-Object { [double]$_.Groups[1].Value })
$hold = @([regex]::Matches($holdText, $pattern) | ForEach-Object { [double]$_.Groups[1].Value })
if ($setup.Count -ne 15 -or $hold.Count -ne 15) { throw "Expected all 15 relationships (setup=$($setup.Count)/15, hold=$($hold.Count)/15); refusing trial PGM." }
$minSetup = ($setup | Measure-Object -Minimum).Minimum
$minHold = ($hold | Measure-Object -Minimum).Minimum
if ($minSetup -lt -0.200 -or $minHold -lt -0.050) { Write-Output "TRIAL_TIMING_REJECT setup_min=$minSetup ns hold_min=$minHold ns rows=$($setup.Count)/$($hold.Count) limits=-0.200/-0.050"; exit 2 }
$clean = $minSetup -ge 0 -and $minHold -ge 0
Write-Output "TRIAL_TIMING_ACCEPT setup_min=$minSetup ns hold_min=$minHold ns timing_clean=$($clean.ToString().ToLower()) rows=$($setup.Count)/$($hold.Count) limits=-0.200/-0.050"
