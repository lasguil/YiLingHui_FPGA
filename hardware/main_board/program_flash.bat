@echo off
setlocal
cd /d "%~dp0"
call C:\Efinity\2026.1\bin\setup.bat
if errorlevel 1 exit /b %errorlevel%
call C:\Efinity\2026.1\bin\python3.bat tools\program_flash.py %*
exit /b %errorlevel%
