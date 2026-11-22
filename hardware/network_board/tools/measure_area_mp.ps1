# map + interface + pack area measurement (no place/route; for trim experiments).
#
# tools/measure_ddr_area.ps1 runs only map+pack, but efx_pnr --pack also needs
# outflow/ti60f225_oob.interface.csv, which the separate interface flow
# produces.  This wrapper runs map, then interface, then pack, and reports the
# packed XLR count plus the RAM10/DSP48 totals from the map report.
param([Parameter(Mandatory=$true)][ValidatePattern('^[a-z0-9_]+$')][string]$Tag)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Push-Location $root
try {
  $dest = "build/area/$Tag"
  New-Item -ItemType Directory -Force $dest | Out-Null
  $mapLog = "$dest/map.log"
  $ifLog = "$dest/interface.log"
  $packLog = "$dest/pack.log"
  $chain = "call C:\Efinity\2026.1\bin\setup.bat" +
           " && efx_run.bat ti60f225_oob.xml --flow map > `"$mapLog`" 2>&1" +
           " && efx_run.bat ti60f225_oob.xml --flow interface > `"$ifLog`" 2>&1" +
           " && efx_pnr.exe --circuit ti60f225_oob --family Titanium --device Ti60F225" +
           " --operating_conditions I3 --vdb_file outflow\ti60f225_oob.vdb --use_vdb_file on" +
           " --prj ti60f225_oob.xml --output_dir outflow --work_dir work_pnr" +
           " --sync_file outflow\ti60f225_oob.interface.csv --sdc_file ti60f225_oob.sdc --pack > `"$packLog`" 2>&1"
  & cmd /c $chain
  if ($LASTEXITCODE -ne 0) { throw "Area measurement failed: $dest (see map/interface/pack logs)" }
  Copy-Item outflow/ti60f225_oob.map.rpt, outflow/ti60f225_oob.res.csv -Destination $dest -Force
  $packed = (Select-String -Path $packLog -Pattern 'Packed into.*xlrs').Line
  Write-Output ("TAG       : " + $Tag)
  Write-Output ("PACKED    : " + $packed)
  Select-String -Path "$dest/ti60f225_oob.map.rpt" -Pattern '^EFX_(RAM10|DPRAM10|DSP48) ' | ForEach-Object { $_.Line }
} finally { Pop-Location }
