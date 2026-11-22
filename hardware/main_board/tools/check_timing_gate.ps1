param([Parameter(Mandatory=$true)][string]$TimingReport)
$ErrorActionPreference = 'Stop'
$timing = Get-Content -LiteralPath $TimingReport -Raw
$setupStart = $timing.IndexOf('Setup (Max) Clock Relationship')
$holdStart = $timing.IndexOf('Hold (Min) Clock Relationship')
$pathsEnd = $timing.IndexOf('---------- 3. Path Details')
if ($setupStart -lt 0 -or $holdStart -le $setupStart -or $pathsEnd -le $holdStart) { throw 'Timing relationship sections missing; refusing signoff.' }
$setupText = $timing.Substring($setupStart, $holdStart - $setupStart)
$holdText = $timing.Substring($holdStart, $pathsEnd - $holdStart)
$pattern = '(?m)^\s*\S+\s+\S+\s+[-+]?\d+(?:\.\d+)?\s+([-+]?\d+(?:\.\d+)?)\s+\(R-R\)\s*$'
$setup = @([regex]::Matches($setupText, $pattern) | ForEach-Object { [double]$_.Groups[1].Value })
$hold = @([regex]::Matches($holdText, $pattern) | ForEach-Object { [double]$_.Groups[1].Value })
if ($setup.Count -ne 15 -or $hold.Count -ne 15) { throw "Timing gate expected all 15 project relationships (setup=$($setup.Count)/15, hold=$($hold.Count)/15); refusing signoff." }
$minSetup = ($setup | Measure-Object -Minimum).Minimum
$minHold = ($hold | Measure-Object -Minimum).Minimum
if ($minSetup -lt 0 -or $minHold -lt 0) { Write-Output "TIMING_FAILED setup_min=$minSetup ns hold_min=$minHold ns rows=$($setup.Count)/$($hold.Count)"; exit 2 }
Write-Output "TIMING_PASS setup_min=$minSetup ns hold_min=$minHold ns rows=$($setup.Count)/$($hold.Count)"
