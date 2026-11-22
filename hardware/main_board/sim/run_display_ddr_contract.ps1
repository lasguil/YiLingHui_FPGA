param([int]$Pipelined=0,[int]$ReserveRow=1,[int]$Fair=0)
$ErrorActionPreference='Stop'
$p=(Resolve-Path "$PSScriptRoot/..").Path
$r="$p/tmp/display_ddr_contract"
$q='C:/altera/25.1std/questa_fse/win64'
New-Item -ItemType Directory -Force $r | Out-Null
Push-Location $r
try {
 & "$q/vlib.exe" work | Out-Null
 $files=@('rtl/demo_model_asset_pkg.sv','rtl/demo_bus_pkg.sv','rtl/demo_axi_merge.sv','rtl/ddr_rewrite/axi4_bus_ctl_stream.sv','sim/tb_display_ddr_contract.sv') | ForEach-Object {Join-Path $p $_}
 & "$q/vlog.exe" -sv -timescale 1ns/1ps -svinputport=net @files C:/Efinity/2026.1/sim_models/verilog/efx_ff.v *> compile.log
 if($LASTEXITCODE){Get-Content compile.log -Tail 25;throw 'compile failed'}
 & "$q/vsim.exe" -c work.tb_display_ddr_contract "-gPIPELINED=$Pipelined" "-gRESERVE_ROW=$ReserveRow" "-gFAIR=$Fair" -do 'run -all; quit -f' -l contract.log *> contract.console.log
 $log=Get-Content contract.log -Raw
 if($LASTEXITCODE -or $log -match '\*\* (Error|Fatal)' -or $log -notmatch 'PASS DDR_CONTRACT' -or $log -notmatch 'PASS DDR_RESET_INFLIGHT'){Get-Content contract.log -Tail 20;throw 'DDR contract failed'}
 Select-String -Path contract.log -Pattern 'PASS DDR_' | ForEach-Object {$_.Line}
} finally {Pop-Location}
