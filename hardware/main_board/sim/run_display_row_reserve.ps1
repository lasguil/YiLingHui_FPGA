param([switch]$Extended)
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
  & "$q/vsim.exe" -c work.tb_display_row_reserve -gNPU_LEN=64 -gTEST_WIDTH=1920 -gTEST_HEIGHT=8 -gSTEP_X=131141 -gSTEP_Y=131194 "-gREAD_GAP=$gap" -gDYNAMIC=1 -gONE_PASS=1 '-gAXI_HALF_NS=2.7778' -gCHECK_DIAGNOSTICS=1 -gWRITE_COMPETITOR=1 -gPEER_WRITE_COMPETITOR=1 -do 'run -all; quit -f' -l "gap$gap.log" *> "gap$gap.console.log"
  $log=Get-Content "gap$gap.log" -Raw
  if($LASTEXITCODE -or $log -match '\*\* (Error|Fatal)' -or $log -notmatch 'PASS DISPLAY_VIEWPORT'){Get-Content "gap$gap.log" -Tail 20;throw "gap$gap failed"}
  Select-String -Path "gap$gap.log" -Pattern 'NPU_COMPLETED|PASS DISPLAY_VIEWPORT' | ForEach-Object {$_.Line}
 }
 if($Extended){
  $common=@('-gDISPLAY_CAP=64','-gNPU_LEN=64','-gTEST_WIDTH=1920','-gTEST_HEIGHT=8',
   '-gSTEP_X=131141','-gSTEP_Y=131194','-gREAD_GAP=2','-gDYNAMIC=1','-gONE_PASS=1',
   '-gAXI_HALF_NS=2.7778','-gCHECK_DIAGNOSTICS=1','-gWRITE_COMPETITOR=1','-gPEER_WRITE_COMPETITOR=1')
  foreach($name in @('geometry','stall_recover')){
   $extra=if($name -eq 'geometry'){@('-gGEOMETRY_SWITCH=1','-gCHECK_EVENT_Y=1')}else{@('-gSTALL_ONCE=1','-gEXPECT_UNDERFLOW=1')}
   & "$q/vsim.exe" -c work.tb_display_row_reserve @common @extra -do 'run -all; quit -f' -l "$name.log" *> "$name.console.log"
   $log=Get-Content "$name.log" -Raw
   $pass=if($name -eq 'geometry'){'PASS DISPLAY_GEOMETRY_VS_ATOMIC'}else{'PASS DISPLAY_OVERDEADLINE'}
   if($LASTEXITCODE -or $log -match '\*\* (Error|Fatal)' -or $log -notmatch $pass){Get-Content "$name.log" -Tail 20;throw "$name failed"}
   Select-String -Path "$name.log" -Pattern 'PASS |NPU_COMPLETED' | ForEach-Object {$_.Line}
  }
 }
} finally {Pop-Location}

