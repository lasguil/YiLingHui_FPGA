$ErrorActionPreference='Stop'
$project=(Resolve-Path "$PSScriptRoot\..").Path
$q='C:\altera\25.1std\questa_fse\win64'
$run=Join-Path $project 'tmp/axi_read_cap16'
New-Item -ItemType Directory -Force $run | Out-Null
Push-Location $run
try {
    & "$q/vlib.exe" work | Out-Null
    & "$q/vlog.exe" -sv -timescale 1ns/1ps +define+SIM_ASSERT -work work `
        "$project/rtl/accelerator/npu/host/ngm_axi_master.sv" "$project/sim/tb_axi_read_cap16.sv" *>compile.log
    if($LASTEXITCODE -ne 0){Get-Content compile.log -Tail 20;throw 'AXI compile failed'}
    & "$q/vsim.exe" -c work.tb_axi -do 'run -all; quit -f' -l run.log *>console.log
    $log=Get-Content run.log -Raw
    if($LASTEXITCODE -ne 0 -or $log -match '\*\* (Error|Fatal)' -or $log -notmatch 'AXI TB PASS'){
        Get-Content run.log -Tail 25;throw 'AXI regression failed'
    }
    Select-String -Path run.log -Pattern 'AXI TB PASS' | ForEach-Object {$_.Line}
} finally {Pop-Location}
