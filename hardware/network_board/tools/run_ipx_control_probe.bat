@echo off
setlocal
call C:\Efinity\2026.1\bin\setup.bat
if errorlevel 1 exit /b %errorlevel%
cd /d "%~dp0..\build\render_takeover_20261011\ipx_control_native"
call efx_run.bat ipx_control_probe.xml --flow compile > compile.log 2>&1
if errorlevel 1 exit /b %errorlevel%
cd /d "%~dp0..\build\render_takeover_20261011\ipx_control_tree"
call efx_run.bat ipx_control_probe.xml --flow compile > compile.log 2>&1
exit /b %errorlevel%
