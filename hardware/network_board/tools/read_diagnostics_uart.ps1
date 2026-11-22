param([string]$Port='COM9',[int]$Seconds=3)
$ErrorActionPreference='Stop'
if($Seconds -lt 1 -or $Seconds -gt 30){throw 'Capture duration must be 1..30 seconds'}
$serial=New-Object System.IO.Ports.SerialPort($Port,115200,[System.IO.Ports.Parity]::None,8,[System.IO.Ports.StopBits]::One)
$serial.DtrEnable=$false
$serial.RtsEnable=$false
$capture=New-Object System.Text.StringBuilder
try {
    $serial.Open()
    $timer=[System.Diagnostics.Stopwatch]::StartNew()
    while($timer.Elapsed.TotalSeconds -lt $Seconds){
        [void]$capture.Append($serial.ReadExisting())
        Start-Sleep -Milliseconds 100
    }
} finally {
    if($serial.IsOpen){$serial.Close()}
    $serial.Dispose()
}
$capture.ToString()
$capture.ToString() | Set-Content -LiteralPath (Join-Path $PSScriptRoot '../build/uart_diagnostics.log') -Encoding utf8
