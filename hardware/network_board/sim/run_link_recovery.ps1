[CmdletBinding()]
param(
    [string]$QuestaBin = 'C:\altera\25.1std\questa_fse\win64',
    [string]$EfinityRoot = 'C:\Efinity\2026.1',
    [string]$Python = 'C:\Users\29966\AppData\Local\Programs\Python\Python312\python.exe',
    [int]$TimeoutSeconds = 120
)

$ErrorActionPreference = 'Stop'
$Project = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$TmpRoot = Join-Path $Project 'tmp'
$RunName = 'link_recovery_' + (Get-Date -Format 'yyyyMMdd_HHmmss_fff')
$Run = Join-Path $TmpRoot $RunName
$PreviousPythonHome = $env:PYTHONHOME
$PreviousPythonPath = $env:PYTHONPATH
$sim = $null

New-Item -ItemType Directory -Path $Run | Out-Null
Push-Location $Run
try {
    if (-not (Test-Path -LiteralPath $Python)) { throw "System Python 3.12 missing: $Python" }
    $env:PYTHONHOME = $null
    $env:PYTHONPATH = $null

    $extractor = Join-Path $Project 'tools\extract_mjpeg_link_glue.py'
    $probe = Join-Path $Run 'mjpeg_top_glue_probe.sv'
    & $Python $extractor --out $probe *> (Join-Path $Run 'extract.log')
    if ($LASTEXITCODE -ne 0) {
        Get-Content -LiteralPath (Join-Path $Run 'extract.log') -Tail 40
        throw "MJPEG top-glue extraction failed ($LASTEXITCODE)"
    }

    $vlib = Join-Path $QuestaBin 'vlib.exe'
    $vmap = Join-Path $QuestaBin 'vmap.exe'
    $vlog = Join-Path $QuestaBin 'vlog.exe'
    $vsim = Join-Path $QuestaBin 'vsim.exe'
    foreach ($exe in @($vlib, $vmap, $vlog, $vsim)) {
        if (-not (Test-Path -LiteralPath $exe)) { throw "Questa executable missing: $exe" }
    }
    $srlModel = Join-Path $EfinityRoot 'sim_models\verilog\efx_srl8.v'
    if (-not (Test-Path -LiteralPath $srlModel)) { throw "Efinity EFX_SRL8 simulation model missing: $srlModel" }

    # Copy Questa's default mappings into this run directory, then bind work
    # locally. No simulator library/configuration files are written elsewhere.
    & $vmap -c *> (Join-Path $Run 'vmap_init.log')
    if ($LASTEXITCODE -ne 0) { throw "vmap -c failed ($LASTEXITCODE)" }
    & $vlib work *> (Join-Path $Run 'vlib.log')
    if ($LASTEXITCODE -ne 0) { throw "vlib failed ($LASTEXITCODE)" }
    & $vmap work work *> (Join-Path $Run 'vmap_work.log')
    if ($LASTEXITCODE -ne 0) { throw "vmap work failed ($LASTEXITCODE)" }

    $rtl = Join-Path $Project 'rtl'
    $encoderSources = @(Get-ChildItem -LiteralPath (Join-Path $rtl 'mjpegzero') -Filter '*.v' |
        Sort-Object FullName | ForEach-Object FullName)
    $sources = @($srlModel) + $encoderSources + @(
        (Join-Path $rtl 'gesture_async_fifo.sv'),
        (Join-Path $rtl 'network\net_route\vid_packet.v'),
        $probe,
        (Join-Path $PSScriptRoot 'tb_mjpeg_link_recovery.sv')
    )
    foreach ($source in $sources) {
        if (-not (Test-Path -LiteralPath $source)) { throw "Simulation source missing: $source" }
    }
    $compileArgs = @('-sv', '-work', 'work', "+incdir+$rtl") + $sources
    & $vlog @compileArgs *> (Join-Path $Run 'compile.log')
    if ($LASTEXITCODE -ne 0) {
        Get-Content -LiteralPath (Join-Path $Run 'compile.log') -Tail 80
        throw "Questa compile failed ($LASTEXITCODE)"
    }

    @'
onerror {quit -code 1}
onbreak {quit -code 1}
run -all
quit -code 0
'@ | Set-Content -LiteralPath (Join-Path $Run 'run_link_recovery.do') -Encoding ASCII

    # The process tree is owned by this runner. Timeout cleanup only targets
    # this exact vsim PID and its children, preventing a stale nodelocked seat.
    $argumentLine = '-c -onfinish exit -lib work tb_mjpeg_link_recovery -l simulation.log -do "do run_link_recovery.do"'
    $sim = Start-Process -FilePath $vsim -ArgumentList $argumentLine -WorkingDirectory $Run `
        -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput (Join-Path $Run 'vsim.stdout.log') `
        -RedirectStandardError (Join-Path $Run 'vsim.stderr.log')
    if (-not $sim.WaitForExit($TimeoutSeconds * 1000)) {
        & (Join-Path $env:WINDIR 'System32\taskkill.exe') /PID $sim.Id /T /F | Out-Null
        $sim.WaitForExit(10000) | Out-Null
        throw "Questa timeout after $TimeoutSeconds seconds; terminated only runner-owned PID $($sim.Id) tree"
    }
    $sim.Refresh()
    $simulationLog = Join-Path $Run 'simulation.log'
    if (-not (Test-Path -LiteralPath $simulationLog)) {
        throw "Questa did not create simulation.log; stdout: $(Join-Path $Run 'vsim.stdout.log')"
    }
    $logText = Get-Content -Raw -LiteralPath $simulationLog
    if ($sim.ExitCode -ne 0 -or $logText -notmatch 'PASS: extracted top link/FIFO/ready/abort/status glue' -or
        $logText -notmatch 'Errors:\s+0') {
        Get-Content -LiteralPath $simulationLog -Tail 60
        Get-Content -LiteralPath (Join-Path $Run 'vsim.stderr.log') -Tail 40
        throw "MJPEG link recovery test failed (exit $($sim.ExitCode)); logs: $Run"
    }
    Get-Content -LiteralPath $simulationLog -Tail 20
    "PASS: MJPEG link recovery. Run directory: $Run"
}
finally {
    if ($sim -and -not $sim.HasExited) {
        & (Join-Path $env:WINDIR 'System32\taskkill.exe') /PID $sim.Id /T /F | Out-Null
    }
    Pop-Location
    if ($null -eq $PreviousPythonHome) { Remove-Item Env:PYTHONHOME -ErrorAction SilentlyContinue }
    else { $env:PYTHONHOME = $PreviousPythonHome }
    if ($null -eq $PreviousPythonPath) { Remove-Item Env:PYTHONPATH -ErrorAction SilentlyContinue }
    else { $env:PYTHONPATH = $PreviousPythonPath }
}
