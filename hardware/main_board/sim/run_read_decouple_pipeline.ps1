param([switch]$Timing,[switch]$Reference,[switch]$SkipCompile,[int]$Width=8,[int]$Height=8,[int]$Variant=2,[int]$Display=0,[int]$Camera=0,[int]$Phase=0,[int]$StartCycle=0,[switch]$Trace,[int]$BankLsb=24,[int]$BankXorLsb=-1,[int]$ReserveRow=1,[int]$Fair=0,[int]$Burst=64,[string]$Label="")
$ErrorActionPreference='Stop'
$p=(Resolve-Path "$PSScriptRoot/..").Path
$r=Join-Path $p 'tmp/display_signoff_20261114'
$q='C:/altera/25.1std/questa_fse/win64'
$lib=if($Timing){'pipe_timing'}elseif($Reference){'pipe_reference'}else{'pipe_real'}
Push-Location $r
try{
 if(!$SkipCompile){
  & "$q/vlib.exe" $lib | Out-Null
  $files=@('rtl/demo_model_asset_pkg.sv','rtl/demo_bus_pkg.sv','rtl/accelerator/npu/top/ngm_npu_types.sv','rtl/accelerator/ipx/ipx_types.sv') | ForEach-Object {Join-Path $p $_}
  foreach($f in Get-ChildItem "$p/rtl/accelerator" -Recurse -Filter '*.sv'){
   if($f.Name -in @('ngm_npu_types.sv','ipx_types.sv')){continue}
   $replacement=Join-Path $r "timing_stubs/$($f.Name)"
   $files+=if(($Timing -or ($Reference -and $f.Name -in @('ngm_weight_slots.sv'))) -and (Test-Path $replacement)){$replacement}else{$f.FullName}
  }
  $files+=@('rtl/ddr3_controller/common/efx_fifo_v2.3/efx_fifo_wrapper.v','rtl/ddr_rewrite/ddr_slim_fifo.sv','rtl/ddr_rewrite/axi4_bus_ctl_stream.sv','rtl/ddr_rewrite/lb2_axi_clk_stream.sv','rtl/ddr_rewrite/slim/local_bus_ctl_slim.sv','rtl/ddr_rewrite/slim/memory_bus_ctl_slim.sv','rtl/demo_npu_read_buffer.sv','rtl/demo_axi_merge.sv','rtl/display/display_axi_shared_reader.sv','sim/display_controller_timing_model.sv','sim/tb_read_decouple_pipeline.sv')|ForEach-Object {Join-Path $p $_}
  $files+=@('efx_dsp48.v','efx_srl8.v','efx_ram10.v','efx_dpram10.v','efx_ff.v') | ForEach-Object {"C:/Efinity/2026.1/sim_models/verilog/$_"}
  if($Timing){$files+=Join-Path $r 'timing_stubs/timing_ram.v'}
  & "$q/vlog.exe" -work $lib -sv -timescale 1ns/1ps -svinputport=net +define+SIM_ASSERT @files *> "$lib.compile.log"
  if($LASTEXITCODE){Get-Content "$lib.compile.log" -Tail 25;throw 'pipeline compile failed'}
 }
 $log="${Label}${lib}_${Width}x${Height}_v${Variant}_d${Display}_c${Camera}_p${Phase}.log"
 $traceArg=@();if($Trace){$traceArg+= "+TRACE=$log.trace"}
 & "$q/vsim.exe" -c -suppress 14408 "$lib.tb_read_decouple_pipeline" "-gW=$Width" "-gH=$Height" "-gVARIANT=$Variant" "-gDISPLAY=$Display" "-gCAMERA=$Camera" "-gPHASE=$Phase" "-gSTART_CYCLE=$StartCycle" "-gBANK_LSB=$BankLsb" "-gBANK_XOR_LSB=$BankXorLsb" "-gRESERVE=$ReserveRow" "-gFAIR=$Fair" "-gDISPLAY_BURST=$Burst" @traceArg -do 'run -all; quit -f' -l $log *> "$log.console"
 $s=Get-Content $log -Raw
 Select-String -Path $log -Pattern 'PIPE_FRAME|PIPE_PROGRESS|Fatal|Error|DDR_TIMING' | ForEach-Object {$_.Line}
 if($LASTEXITCODE -or $s -match '\*\* (Fatal|Error)' -or $s -notmatch 'PIPE_FRAME'){throw "$log failed"}
}finally{Pop-Location}


