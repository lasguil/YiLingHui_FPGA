param(
    [Parameter(Mandatory=$true)][string]$BitPath,
    [string]$Port='COM9'
)
$ErrorActionPreference='Stop'
$resolvedBit=(Resolve-Path -LiteralPath $BitPath).Path
if([IO.Path]::GetExtension($resolvedBit) -ne '.bit'){throw "Expected an explicit .bit file: $resolvedBit"}
$buildRoot=Split-Path -Parent (Split-Path -Parent $resolvedBit)
$verifier=Join-Path $buildRoot 'tools/build_record.py'
if(!(Test-Path -LiteralPath $verifier) -or !(Test-Path -LiteralPath (Join-Path $buildRoot 'build_accept.json'))){
    throw "Bit is not inside an accepted project snapshot: $resolvedBit"
}
$python='C:\Users\29966\AppData\Local\Programs\Python\Python312\python.exe'
Push-Location $buildRoot
try {
    & $python -I -B tools/build_record.py verify
    if($LASTEXITCODE -ne 0){throw "Build snapshot verification failed: $LASTEXITCODE"}
} finally { Pop-Location }
$serial=New-Object System.IO.Ports.SerialPort($Port,115200,[System.IO.Ports.Parity]::None,8,[System.IO.Ports.StopBits]::One)
$serial.DtrEnable=$false
$serial.RtsEnable=$false
$capture=New-Object System.Text.StringBuilder
try {
    $serial.Open()
    $programBat=(Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../program_jtag.bat')).Path
    $jtagCommand='"{0}" "{1}"' -f $programBat,$resolvedBit
    & cmd.exe /d /c $jtagCommand
    if($LASTEXITCODE -ne 0){throw "JTAG failed: $LASTEXITCODE"}
    $timer=[System.Diagnostics.Stopwatch]::StartNew()
    while($timer.Elapsed.TotalSeconds -lt 15){
        [void]$capture.Append($serial.ReadExisting())
        Start-Sleep -Milliseconds 100
    }
} finally {
    if($serial.IsOpen){$serial.Close()}
    $serial.Dispose()
    $capture.ToString() | Set-Content -LiteralPath (Join-Path $PSScriptRoot '../build/render_uart_boot.log') -Encoding utf8
}
$capture.ToString()
