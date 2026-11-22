@echo off
setlocal
call C:\Efinity\2026.1\bin\setup.bat
if errorlevel 1 exit /b %errorlevel%
cd /d "%~dp0.."
if errorlevel 1 exit /b %errorlevel%
set "ROOT=%CD%"
set "SIGNOFF=%ROOT%\build\cdc_payload_signoff"
set "STA_DIR=%SIGNOFF%\sta_work"
if not exist "%STA_DIR%\work_pnr" mkdir "%STA_DIR%\work_pnr"
copy /Y "%ROOT%\outflow\ti60f225_oob.netlist" "%STA_DIR%\ti60f225_oob.netlist" > nul
if errorlevel 1 exit /b %errorlevel%
copy /Y "%ROOT%\outflow\ti60f225_oob.rs" "%STA_DIR%\ti60f225_oob.rs" > nul
if errorlevel 1 exit /b %errorlevel%
copy /Y "%ROOT%\outflow\ti60f225_oob.clstdb" "%STA_DIR%\ti60f225_oob.clstdb" > nul
if errorlevel 1 exit /b %errorlevel%
copy /Y "%ROOT%\outflow\ti60f225_oob.htree" "%STA_DIR%\ti60f225_oob.htree" > nul
if errorlevel 1 exit /b %errorlevel%
copy /Y "%ROOT%\work_pnr\ti60f225_oob.primplace" "%STA_DIR%\work_pnr\ti60f225_oob.primplace" > nul
if errorlevel 1 exit /b %errorlevel%
copy /Y "%ROOT%\work_pnr\ti60f225_oob.net_proto" "%STA_DIR%\work_pnr\ti60f225_oob.net_proto" > nul
if errorlevel 1 exit /b %errorlevel%
copy /Y "%ROOT%\work_pnr\ti60f225_oob.io_place" "%STA_DIR%\work_pnr\ti60f225_oob.io_place" > nul
if errorlevel 1 exit /b %errorlevel%
copy /Y "%ROOT%\outflow\ti60f225_oob.troutingtraces" "%STA_DIR%\work_pnr\ti60f225_oob.troutingtraces" > nul
if errorlevel 1 exit /b %errorlevel%
set "CDC_PAYLOAD_STA_TCL=%SIGNOFF%\verify_cdc_payloads.generated.tcl"
set "CDC_PAYLOAD_SDC=%ROOT%\ti60f225_oob.sdc"
pushd "%STA_DIR%"
call efx_sta --prj "%ROOT%\ti60f225_oob.xml" -t "%ROOT%\tools\verify_cdc_payloads.tcl" > "%SIGNOFF%\sta.log" 2>&1
set "RESULT=%ERRORLEVEL%"
popd
if not "%RESULT%"=="0" exit /b %RESULT%
if not exist "%STA_DIR%\ti60f225_oob.timing.rpt" exit /b 1
copy /Y "%STA_DIR%\ti60f225_oob.timing.rpt" "%SIGNOFF%\signoff_timing_summary.rpt" > nul
if errorlevel 1 exit /b %ERRORLEVEL%
exit /b %RESULT%
