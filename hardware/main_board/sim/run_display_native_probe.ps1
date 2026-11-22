$ErrorActionPreference='Stop'
$p=(Resolve-Path "$PSScriptRoot/..").Path
$q='C:/altera/25.1std/questa_fse/win64'
$r="$p/tmp/display_row_reserve"
New-Item -ItemType Directory -Force $r | Out-Null
Push-Location $r
try {
 & "$q/vlib.exe" work | Out-Null
 $files=@('rtl/demo_model_asset_pkg.sv','rtl/demo_bus_pkg.sv','rtl/ddr_rewrite/axi4_bus_ctl_stream.sv','sim/display_native_bridge_model.sv','rtl/demo_axi_merge.sv',
 'rtl/display/display_cfg_csr.sv','rtl/display/display_renderer.sv','rtl/display/display_axi_shared_reader.sv',
 'rtl/display/display_ui_catalog_ram.sv','rtl/display/pipeline_luna_ui_text_rom.sv','rtl/display/pipeline_luna_ui_glyph_rom.sv',
 'rtl/display/display_system_top.sv','rtl/tmds_encode.v','rtl/accelerator/npu/host/ngm_weight_dma.sv',
 'rtl/accelerator/npu/host/ngm_axi_master.sv','sim/tb_display_row_reserve.sv') | ForEach-Object {Join-Path $p $_}
 & "$q/vlog.exe" -sv -timescale 1ns/1ps -svinputport=net @files C:/Efinity/2026.1/sim_models/verilog/efx_ram10.v C:/Efinity/2026.1/sim_models/verilog/efx_ff.v *> compile.log
 if($LASTEXITCODE){Get-Content compile.log -Tail 25;throw 'compile failed'}
 foreach($gap in @(2,3)) {
  & "$q/vsim.exe" -c work.tb_display_row_reserve -gREAL_BRIDGE=1 -gDISPLAY_CAP=64 -gMAX_CAPTURE_AW_WAIT=512 -gNPU_LEN=64 -gTEST_WIDTH=1920 -gTEST_HEIGHT=8 -gSTEP_X=131141 -gSTEP_Y=131194 "-gREAD_GAP=$gap" -gDYNAMIC=1 -gONE_PASS=1 '-gAXI_HALF_NS=2.7778' -gCHECK_DIAGNOSTICS=1 -gWRITE_COMPETITOR=1 -gPEER_WRITE_COMPETITOR=1 -do 'run -all; quit -f' -l "native64_gap$gap.log" *> "native64_gap$gap.console.log"
  $log=Get-Content "native64_gap$gap.log" -Raw
  if($LASTEXITCODE -or $log -match '\*\* (Error|Fatal)' -or $log -notmatch 'PASS DISPLAY_VIEWPORT'){Get-Content "native64_gap$gap.log" -Tail 20;throw "native64_gap$gap failed"}
  Select-String -Path "native64_gap$gap.log" -Pattern 'NPU_COMPLETED|PASS DISPLAY_VIEWPORT' | ForEach-Object {$_.Line}
 }
} finally {Pop-Location}


