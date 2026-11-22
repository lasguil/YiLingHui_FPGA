param([string[]]$ServerArgs = @())
$ErrorActionPreference = 'Stop'
$env:PYTHONHOME = $null
$env:PYTHONPATH = $null
$python = 'C:\Users\29966\AppData\Local\Programs\Python\Python312\python.exe'
& $python (Join-Path $PSScriptRoot 'server.py') @ServerArgs
