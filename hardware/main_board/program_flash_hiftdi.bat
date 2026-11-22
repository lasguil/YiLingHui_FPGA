@echo off
setlocal
cd /d "%~dp0"
call C:\Efinity\2026.1\bin\setup.bat
if errorlevel 1 exit /b %errorlevel%
set EFX_HIFTDI_ENABLE=1
set PYTHONPATH=%EFINITY_HOME%/debugger/bin;%EFINITY_HOME%/pgm/bin;%PYTHONPATH%
call C:\Efinity\2026.1\bin\python3.bat tools\program_flash_hiftdi.py %*
exit /b %errorlevel%
