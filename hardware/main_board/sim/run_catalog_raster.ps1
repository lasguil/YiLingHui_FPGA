$ErrorActionPreference='Stop'
$p=(Resolve-Path "$PSScriptRoot/..").Path
$r="$p/tmp/catalog_29_raster"
$q='C:/altera/25.1std/questa_fse/win64'
New-Item -ItemType Directory -Force $r | Out-Null
Push-Location $r
try {
 & "$q/vlib.exe" work | Out-Null
 $files=@('rtl/demo_model_asset_pkg.sv','rtl/display/display_ui_catalog_ram.sv',
 'rtl/display/pipeline_luna_ui_text_rom.sv','rtl/display/pipeline_luna_ui_glyph_rom.sv',
 'rtl/display/display_renderer.sv','sim/tb_catalog_table_raster.sv') | ForEach-Object {Join-Path $p $_}
 & "$q/vlog.exe" -sv -timescale 1ns/1ps -svinputport=net @files C:/Efinity/2026.1/sim_models/verilog/efx_ram10.v *> compile.log
 if($LASTEXITCODE){Get-Content compile.log -Tail 20;throw 'compile failed'}
 & "$q/vsim.exe" -c work.tb_catalog_table_raster -do 'run -all; quit -f' -l run.log *> run.console.log
 $log=Get-Content run.log -Raw
 if($LASTEXITCODE -or $log -match '\*\* (Error|Fatal)' -or $log -notmatch 'PASS catalog raster'){Get-Content run.log -Tail 20;throw 'catalog raster failed'}
 Select-String -Path run.log -Pattern 'PASS catalog raster' | ForEach-Object {$_.Line}
} finally {Pop-Location}

