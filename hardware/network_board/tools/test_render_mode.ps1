param([ValidateRange(0,3)][int]$Mode,[string]$Port='COM9')
$ErrorActionPreference='Stop'
$serial=[System.IO.Ports.SerialPort]::new($Port,115200,[System.IO.Ports.Parity]::None,8,[System.IO.Ports.StopBits]::One)
$serial.DtrEnable=$false
$serial.RtsEnable=$false
$capture=[Text.StringBuilder]::new()
try {
    $serial.Open()
    [void]$capture.Append($serial.ReadExisting())
    $serial.Write([string]$Mode)
    $timer=[Diagnostics.Stopwatch]::StartNew()
    while($timer.Elapsed.TotalSeconds -lt 20){
        [void]$capture.Append($serial.ReadExisting())
        Start-Sleep -Milliseconds 100
    }
}finally{
    if($serial.IsOpen){$serial.Close()}
    $serial.Dispose()
    [IO.File]::WriteAllText((Join-Path $PSScriptRoot "../build/render_uart_mode_$Mode.log"),$capture.ToString(),[Text.UTF8Encoding]::new($false))
}
$log=$capture.ToString()
$log
if($log -notmatch "MODE $Mode " -or $log -match 'FAULT|TIMEOUT|STOP'){
    throw "Mode $Mode was not confirmed or firmware reported a fault; inspect retained UART log"
}
