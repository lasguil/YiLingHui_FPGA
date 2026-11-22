param(
    [string]$QuestaBin = 'C:\altera\25.1std\questa_fse\win64',
    [string]$EfinityRoot = 'C:\Efinity\2026.1'
)
$ErrorActionPreference = 'Stop'
$Project = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$Run = Join-Path $Project (Join-Path 'tmp' ('board_regression_' + (Get-Date -Format 'yyyyMMdd_HHmmss')))
New-Item -ItemType Directory -Path $Run | Out-Null
Push-Location $Run
try {
    $hostScript = Join-Path $Project 'software\gesture_firmware\tools\test_host.bat'
    & $env:ComSpec /d /c "call `"$hostScript`"" 2>&1 | Tee-Object -FilePath (Join-Path $Run 'firmware_host.log')
    if ($LASTEXITCODE -ne 0) { throw "firmware host regression failed ($LASTEXITCODE)" }

    $vlib = Join-Path $QuestaBin 'vlib.exe'
    $vlog = Join-Path $QuestaBin 'vlog.exe'
    $vsim = Join-Path $QuestaBin 'vsim.exe'
    $srlModel = Join-Path $EfinityRoot 'sim_models\verilog\efx_srl8.v'
    foreach ($exe in @($vlib, $vlog, $vsim)) {
        if (-not (Test-Path -LiteralPath $exe)) { throw "Questa executable missing: $exe" }
    }
    if (-not (Test-Path -LiteralPath $srlModel)) { throw "Efinity EFX_SRL8 simulation model missing: $srlModel" }
    & $vlib work
    if ($LASTEXITCODE -ne 0) { throw "vlib failed ($LASTEXITCODE)" }

    $rtl = Join-Path $Project 'rtl'
    $sim = Join-Path $Project 'sim'
    $common = @('-sv', '-work', 'work', "+incdir+$rtl")
    $sources = @(
        $srlModel,
        (Join-Path $rtl 'demo_bus_pkg.sv'),
        (Join-Path $rtl 'gesture_async_fifo.sv'),
        (Join-Path $rtl 'gesture_sync_fifo.sv'),
        (Join-Path $rtl 'gesture_frame_capture.sv'),
        (Join-Path $rtl 'gesture_roi_resize.sv'),
        (Join-Path $rtl 'cpu_axi32_ddr128.sv'),
        (Join-Path $rtl 'cpu_axi32_ddr128_cdc.sv'),
        (Join-Path $rtl 'demo_axi_merge.sv'),
        (Join-Path $rtl 'apb_csr_cdc.sv'),
        (Join-Path $rtl 'gesture_uart.sv'),
        (Join-Path $rtl 'gesture_clock_reset.sv'),
        (Join-Path $sim 'tb_cpu_axi32_ddr128.sv'),
        (Join-Path $sim 'tb_cpu_axi32_ddr128_cdc.sv'),
        (Join-Path $sim 'tb_gesture_clock_reset.sv'),
        (Join-Path $sim 'tb_apb_csr_cdc.sv'),
        (Join-Path $sim 'tb_gesture_uart.sv'),
        (Join-Path $sim 'tb_gesture_async_fifo.sv'),
        (Join-Path $sim 'tb_gesture_video.sv'),
        (Join-Path $sim 'tb_gesture_bus_integration.sv')
    )
    & $vlog @common @sources 2>&1 | Tee-Object -FilePath (Join-Path $Run 'vlog.log')
    if ($LASTEXITCODE -ne 0) { throw "vlog failed ($LASTEXITCODE)" }

    foreach ($test in @('tb_cpu_axi32_ddr128', 'tb_cpu_axi32_ddr128_cdc', 'tb_gesture_clock_reset', 'tb_apb_csr_cdc', 'tb_gesture_uart', 'tb_gesture_async_fifo', 'tb_gesture_video', 'tb_gesture_bus_integration')) {
        $log = Join-Path $Run ($test + '.log')
        & $vsim -c -work work $test -do 'run -all; quit -f' 2>&1 | Tee-Object -FilePath $log
        if ($LASTEXITCODE -ne 0) { throw "$test failed ($LASTEXITCODE); log: $log" }
        $content = Get-Content -Raw -LiteralPath $log
        if ($content -notmatch 'PASS(:|\s)') { throw "$test exited without PASS marker; log: $log" }
    }
    "PASS: all board regressions completed. Logs: $Run"
}
finally {
    Pop-Location
}
