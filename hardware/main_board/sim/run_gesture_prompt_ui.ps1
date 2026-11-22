$ErrorActionPreference='Stop'
$p=(Resolve-Path "$PSScriptRoot\..").Path
$run="$p\tmp\gesture_prompt_ui";New-Item -ItemType Directory -Force $run|Out-Null
Push-Location $run
try {
$q='C:\altera\25.1std\questa_fse\win64'
& "$q/vlib.exe" work|Out-Null
& "$q/vlog.exe" -sv -timescale 1ns/1ps C:\Efinity\2026.1\sim_models\verilog\efx_ram10.v "$p/rtl/demo_model_asset_pkg.sv" "$p/rtl/display/pipeline_luna_ui_text_rom.sv" "$p/rtl/display/pipeline_luna_ui_glyph_rom.sv" "$p/rtl/display/display_renderer.sv" "$p/sim/tb_gesture_prompt_ui.sv" *> compile.log
if($LASTEXITCODE){Get-Content compile.log;throw 'compile failed'}
& "$q/vsim.exe" -c work.tb_gesture_prompt_ui -do 'run -all; quit -f' -l run.log *>console.log
if($LASTEXITCODE -or (Get-Content run.log -Raw) -notmatch 'PASS UI hide/layout/colors'){Get-Content run.log -Tail 40;throw 'simulation failed'}
Get-Content run.log -Tail 8
}finally{Pop-Location}
