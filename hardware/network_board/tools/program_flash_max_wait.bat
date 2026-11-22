@echo off
setlocal
if not defined EFINITY_HOME call C:\Efinity\2026.1\bin\setup.bat
if errorlevel 1 exit /b %errorlevel%
call C:\Efinity\2026.1\bin\python3.bat tools\program_flash_max_wait.py %*
exit /b %errorlevel%
