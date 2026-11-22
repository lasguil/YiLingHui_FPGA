param([string]$Case='candidate',[int]$Writes=1,[int]$CameraPeriod=153,[int]$PeerPeriod=1481,[int]$Gap=3,[int]$Hold=0,[int]$Period=1,[int]$Mode=3,[switch]$SkipCompile,[int]$BankLsb=24,[int]$BankXorLsb=-1,[int]$ReserveRow=1,[int]$Fair=0,[int]$Cap=64,[string]$Label="",[int]$GeometrySwitch=0,[int]$StallOnce=0,[int]$ExpectUnderflow=0)
$ErrorActionPreference='Stop'
$p=(Resolve-Path "$PSScriptRoot/..").Path
$q='C:/altera/25.1std/questa_fse/win64'
$r=Join-Path $p "tmp/display_signoff_20261114"
New-Item -ItemType Directory -Force $r | Out-Null
Push-Location $r
try {
 if(!$SkipCompile){
 & "$q/vlib.exe" work | Out-Null
 $files=@('rtl/demo_model_asset_pkg.sv','rtl/demo_bus_pkg.sv','rtl/ddr3_controller/common/efx_fifo_v2.3/efx_fifo_wrapper.v','rtl/demo_npu_read_buffer.sv','rtl/ddr_rewrite/ddr_slim_fifo.sv','rtl/ddr_rewrite/lb2_axi_clk_stream.sv','rtl/ddr_rewrite/slim/local_bus_ctl_slim.sv','rtl/ddr_rewrite/slim/memory_bus_ctl_slim.sv','sim/display_controller_timing_model.sv','rtl/ddr_rewrite/axi4_bus_ctl_stream.sv','sim/display_native_bridge_model.sv','rtl/demo_axi_merge.sv','rtl/display/display_cfg_csr.sv','rtl/display/display_renderer.sv','rtl/display/display_axi_shared_reader.sv','rtl/display/display_ui_catalog_ram.sv','rtl/display/pipeline_luna_ui_text_rom.sv','rtl/display/pipeline_luna_ui_glyph_rom.sv','rtl/display/display_system_top.sv','rtl/tmds_encode.v','rtl/accelerator/npu/host/ngm_weight_dma.sv','rtl/accelerator/npu/host/ngm_axi_master.sv','sim/tb_display_row_reserve.sv') | ForEach-Object {Join-Path $p $_}
 & "$q/vlog.exe" -sv -timescale 1ns/1ps -svinputport=net @files C:/Efinity/2026.1/sim_models/verilog/efx_ram10.v C:/Efinity/2026.1/sim_models/verilog/efx_ff.v C:/Efinity/2026.1/sim_models/verilog/efx_srl8.v *> compile.log
 if($LASTEXITCODE){Get-Content compile.log -Tail 25;throw 'compile failed'}
 }
 $pipe=if($Case -eq 'baseline'){0}else{1}
 $buf=if($Case -eq 'candidate'){1}else{0}
 $step=if($Mode -eq 3){131141}else{65536}
 $ystep=if($Mode -eq 3){131194}else{65536}
 $log="${Label}${Case}_cam${CameraPeriod}_peer${PeerPeriod}_gap${Gap}_hold${Hold}_period${Period}_mode${Mode}.log"
 & "$q/vsim.exe" -c work.tb_display_row_reserve "-gCAMERA_PERIOD=$CameraPeriod" "-gPEER_PERIOD=$PeerPeriod" "-gMODE=$Mode" "-gPIPELINED=$pipe" "-gBUFFERED_NPU=$buf" "-gNPU_CONSUMER_HOLD=$Hold" "-gNPU_CONSUMER_PERIOD=$Period" '-gPIX_HALF_NS=3.333333333' -gREAL_BRIDGE=2 "-gDISPLAY_CAP=$Cap" "-gBANK_LSB=$BankLsb" "-gBANK_XOR_LSB=$BankXorLsb" "-gRESERVE_ROW=$ReserveRow" "-gFAIR=$Fair" "-gGEOMETRY_SWITCH=$GeometrySwitch" "-gCHECK_EVENT_Y=$GeometrySwitch" "-gSTALL_ONCE=$StallOnce" "-gEXPECT_UNDERFLOW=$ExpectUnderflow" -gMAX_CAPTURE_AW_WAIT=512 -gNPU_LEN=64 -gTEST_WIDTH=1920 -gTEST_HEIGHT=8 "-gSTEP_X=$step" "-gSTEP_Y=$ystep" "-gREAD_GAP=$Gap" -gDYNAMIC=1 -gONE_PASS=1 '-gAXI_HALF_NS=2.777777778' -gCHECK_DIAGNOSTICS=1 "-gWRITE_COMPETITOR=$Writes" "-gPEER_WRITE_COMPETITOR=$Writes" -do 'run -all; quit -f' -l $log *> "$log.console"
 $content=Get-Content $log -Raw
 Select-String -Path $log -Pattern 'NPU_COMPLETED|PASS |Error|Fatal' | ForEach-Object {$_.Line}
 if($LASTEXITCODE -or $content -match '\*\* (Error|Fatal)' -or $content -notmatch 'PASS DISPLAY_VIEWPORT'){throw "$log failed"}
}finally{Pop-Location}





