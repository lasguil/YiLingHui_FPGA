param(
    [string]$QuestaBin='C:\altera\25.1std\questa_fse\win64',
    [string]$EfinityRoot='C:\Efinity\2026.1',
    [switch]$FullPhase
)
$ErrorActionPreference='Stop'
$Project=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$Repo=(Resolve-Path (Join-Path $Project '..\..\..\..\..')).Path
$Run=Join-Path (Join-Path $Repo 'tmp') ('capture_fixed_geometry_' + (Get-Date -Format 'yyyyMMdd_HHmmss'))
New-Item -ItemType Directory -Path $Run | Out-Null
Push-Location $Run
try {
    $vlib=Join-Path $QuestaBin 'vlib.exe'
    $vlog=Join-Path $QuestaBin 'vlog.exe'
    $vsim=Join-Path $QuestaBin 'vsim.exe'
    foreach($exe in @($vlib,$vlog,$vsim)) { if(-not (Test-Path -LiteralPath $exe)) { throw "Questa executable missing: $exe" } }
    & $vlib work
    if($LASTEXITCODE -ne 0) { throw "vlib failed ($LASTEXITCODE)" }
    $rtl=Join-Path $Project 'rtl'
    $test=if($FullPhase){'tb_gesture_capture_phase'}else{'tb_capture_fixed_geometry'}
    $tb=Join-Path $PSScriptRoot ($test+'.sv')
    $srlModel=Join-Path $EfinityRoot 'sim_models/verilog/efx_srl8.v'
    if(-not (Test-Path -LiteralPath $srlModel)){throw "Official SRL8 model missing: $srlModel"}
    & $vlog -sv -work work "+incdir+$rtl" $srlModel (Join-Path $rtl 'demo_bus_pkg.sv') (Join-Path $rtl 'gesture_async_fifo.sv') (Join-Path $rtl 'gesture_sync_fifo.sv') (Join-Path $rtl 'gesture_frame_capture.sv') $tb *> (Join-Path $Run 'compile.log')
    if($LASTEXITCODE -ne 0) { Get-Content (Join-Path $Run 'compile.log'); throw "vlog failed ($LASTEXITCODE)" }
    $args=@('-c','-onfinish','exit','-l','simulation.log',('work.'+$test),'-do','"run -all"')
    $sim=Start-Process -FilePath $vsim -ArgumentList $args -WorkingDirectory $Run -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $Run 'vsim.stdout.log') -RedirectStandardError (Join-Path $Run 'vsim.stderr.log')
    $timeout=if($FullPhase){240000}else{120000}
    if(-not $sim.WaitForExit($timeout)) {
        & "$env:WINDIR\System32\taskkill.exe" /PID $sim.Id /T /F | Out-Null
        throw "vsim timeout; terminated only launched PID $($sim.Id) tree"
    }
    $log=Join-Path $Run 'simulation.log'
    $marker=if($FullPhase){'PASS modulo-three phases freeze'}else{'PASS fixed 1080p'}
    if($sim.ExitCode -ne 0 -or (Get-Content -Raw $log) -notmatch $marker) {
        Get-Content $log -Tail 60
        Get-Content (Join-Path $Run 'vsim.stderr.log')
        throw "fixed geometry simulation failed (exit $($sim.ExitCode)); see $Run"
    }
    Get-Content $log -Tail 20
} finally { Pop-Location }
