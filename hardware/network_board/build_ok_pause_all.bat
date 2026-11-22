@echo off
setlocal
set "P=%~dp0"
cd /d "%~dp0"
for %%I in ("%P%.") do set "P=%%~fI"
set "PY=C:\Users\29966\AppData\Local\Programs\Python\Python312\python.exe"
set "RUN=%P%\tmp\ok_pause_full_build_20261115"
set "WORK=%RUN%\work"
set "TMP=%RUN%\temp"
set "TEMP=%TMP%"
if not exist "%TMP%" mkdir "%TMP%"
set "PYTHONHOME="
set "PYTHONPATH="
if not exist "%P%\build" mkdir "%P%\build"
if not exist "%P%\outflow" mkdir "%P%\outflow"
if not exist "%RUN%" mkdir "%RUN%"
call "%P%\software\gesture_firmware\tools\test_host.bat" > "%P%\build\host_firmware_regression.log" 2>&1
if errorlevel 1 exit /b 11
call "%P%\software\gesture_firmware\tools\test_board1_compat.bat" > "%RUN%\board1_compat.log" 2>&1
if errorlevel 1 exit /b 14
call "%P%\software\gesture_firmware\tools\build_hand_marker.bat" > "%P%\build\firmware_hand_marker.log" 2>&1
if errorlevel 1 exit /b 12
"%PY%" -I -B "%P%\tools\integrate_hand_marker_rom.py" > "%P%\build\firmware_rom_integration.log" 2>&1
if errorlevel 1 exit /b 13
call C:\Efinity\2026.1\bin\setup.bat <nul
if errorlevel 1 exit /b 10
call efx_run.bat ti60f225_oob.xml --flow interface --timeout 300 --output_dir outflow --work_dir "%WORK%" > "%RUN%\interface.log" 2>&1
if errorlevel 1 exit /b 21
call efx_run.bat ti60f225_oob.xml --flow map --timeout 900 --map_opts max_threads=8 --output_dir outflow --work_dir "%WORK%" > "%RUN%\map.log" 2>&1
if errorlevel 1 exit /b 22
call efx_run.bat ti60f225_oob.xml --flow pnr --timeout 2700 --pnr_opts max_threads=8 --output_dir outflow --work_dir "%WORK%" > "%RUN%\pnr.log" 2>&1
if errorlevel 1 exit /b 23
"%PY%" -I -B tools\verify_cdc_payloads.py generate --map outflow\ti60f225_oob.map.v --sdc ti60f225_oob.sdc --out build\cdc_payload_signoff > "%RUN%\cdc_payload_generation.log" 2>&1
if errorlevel 1 exit /b 31
"%PY%" -I -B tools\verify_ddr_gray_cdc.py generate --map outflow\ti60f225_oob.map.v --sdc ti60f225_oob.sdc --out build\cdc_payload_signoff > "%RUN%\cdc_gray_generation.log" 2>&1
if errorlevel 1 exit /b 32
call efx_run.bat ti60f225_oob --prj --flow sta_tclsh -t "%P%\tools\integration_timing.tcl" --timeout 1200 --output_dir outflow --work_dir "%WORK%" > "%RUN%\timing.log" 2>&1
if errorlevel 1 exit /b 33
if not exist outflow\final_timing.rpt exit /b 34
copy /Y outflow\final_timing.rpt build\final_timing.rpt > nul
copy /Y "%RUN%\timing.log" build\timing.log > nul
"%PY%" -I -B tools\verify_cdc_payloads.py validate --log build\timing.log --out build\cdc_payload_signoff > "%RUN%\cdc_payload_validation.log" 2>&1
if errorlevel 1 exit /b 35
"%PY%" -I -B tools\verify_ddr_gray_cdc.py validate --log build\timing.log --out build\cdc_payload_signoff > "%RUN%\cdc_gray_validation.log" 2>&1
if errorlevel 1 exit /b 36
"%PY%" -I -B tools\check_integration_timing.py > "%RUN%\strict_timing_validation.log" 2>&1
if errorlevel 1 exit /b 37
call efx_run.bat ti60f225_oob.xml --flow pgm --timeout 300 --output_dir outflow --work_dir "%WORK%" > "%RUN%\pgm.log" 2>&1
if errorlevel 1 exit /b 41
endlocal
exit /b 0