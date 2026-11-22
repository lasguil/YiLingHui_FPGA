@echo off
setlocal
cd /d "%~dp0"
call C:\Efinity\2026.1\bin\setup.bat
if errorlevel 1 exit /b %errorlevel%
call efx_run.bat ti60f225_oob.xml --flow sta_tclsh --output_dir outflow --work_dir build/work_pnr --tcl_script tools/signoff.tcl > build\signoff.log 2>&1
exit /b %errorlevel%
