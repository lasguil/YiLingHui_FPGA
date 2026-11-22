$ErrorActionPreference='Stop'
$project=Split-Path $PSScriptRoot -Parent
$run=Join-Path $project 'tmp/ui_range_equivalence'
New-Item -ItemType Directory -Force $run | Out-Null
$old=Get-Content -LiteralPath "$project/support/before_ui_range_20261112/display_renderer.sv" -Raw
$old=$old.Replace('module display_renderer (','module display_renderer_before_ui_range (')
Set-Content -LiteralPath "$run/display_renderer_before_ui_range.sv" -Value $old -Encoding utf8
$q='C:\altera\25.1std\questa_fse\win64'
Push-Location $run
try {
    & "$q/vlib.exe" work | Out-Null
    & "$q/vlog.exe" -sv -timescale 1ns/1ps C:/Efinity/2026.1/sim_models/verilog/efx_ram10.v "$project/rtl/demo_model_asset_pkg.sv" "$project/rtl/display/pipeline_luna_ui_text_rom.sv" "$project/rtl/display/pipeline_luna_ui_glyph_rom.sv" "$project/rtl/display/display_renderer.sv" "$run/display_renderer_before_ui_range.sv" "$PSScriptRoot/tb_ui_range_equivalence.sv" *> compile.log
    if($LASTEXITCODE){Get-Content compile.log -Tail 35;throw 'compile failed'}
    & "$q/vsim.exe" -c work.tb_ui_range_equivalence -do 'run -all; quit -f' -l run.log *> console.log
    $log=Get-Content run.log -Raw
    if($LASTEXITCODE -or $log -match '\*\* (Error|Fatal)' -or $log -notmatch 'PASS UI RANGE EQUIVALENCE'){
        Get-Content run.log -Tail 35;throw 'equivalence failed'
    }
    Get-Content run.log | Select-String 'PASS UI RANGE'
} finally {Pop-Location}
