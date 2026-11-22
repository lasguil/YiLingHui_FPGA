@echo off
setlocal
cd /d "%~dp0"
if not exist build mkdir build
call C:\Efinity\2026.1\bin\setup.bat
if errorlevel 1 exit /b 1
rem This entry only checks interfaces and synthesis; it never programs a board.
call efx_run.bat ti60f225_oob.xml --flow interface --timeout 300 --output_dir outflow > build\interface_windows.log 2>&1
if errorlevel 1 exit /b 1
call efx_run.bat ti60f225_oob.xml --flow map --timeout 900 --map_opts max_threads=16 --output_dir outflow --work_dir build/work_syn > build\map_windows.log 2>&1
if errorlevel 1 exit /b 1
echo PASS: interface and synthesis; routing and timing signoff still required.
exit /b 0
