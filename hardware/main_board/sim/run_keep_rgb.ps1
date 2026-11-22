$ErrorActionPreference='Stop'
$p=(Resolve-Path "$PSScriptRoot\..").Path
$run="$p\tmp\keep_rgb";New-Item -ItemType Directory -Force $run|Out-Null
Push-Location $run
try {
    $q='C:\altera\25.1std\questa_fse\win64'
    & "$q/vlib.exe" work | Out-Null
    & "$q/vlog.exe" -sv C:\Efinity\2026.1\sim_models\verilog\efx_dsp48.v "$p/rtl/accelerator/ipx/ipx_types.sv" "$p/rtl/accelerator/ipx/ipx_mult.sv" "$p/rtl/accelerator/ipx/ipx_saturation.sv" "$p/sim/tb_keep_rgb.sv" *> compile.log
    if($LASTEXITCODE){Get-Content compile.log;throw 'compile failed'}
    & "$q/vsim.exe" -c work.tb_keep_rgb -do 'run -all; quit -f' -l run.log *> console.log
    if($LASTEXITCODE -or (Get-Content run.log -Raw) -notmatch 'PASS RGB keep:'){Get-Content run.log -Tail 35;throw 'simulation failed'}
    Get-Content run.log -Tail 8
}finally{Pop-Location}
