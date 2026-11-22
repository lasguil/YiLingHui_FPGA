@echo off
setlocal
call C:\Efinity\2026.1\bin\setup.bat
if errorlevel 1 exit /b %errorlevel%
cd /d "%~dp0..\build\render_takeover_20261011\window_original"
call efx_run.bat window_probe.xml --flow compile > compile.log 2>&1
if errorlevel 1 exit /b %errorlevel%
cd /d "%~dp0..\build\render_takeover_20261011\window_decode"
call efx_run.bat window_probe.xml --flow compile > compile.log 2>&1
exit /b %errorlevel%
