@echo off
setlocal EnableExtensions
set "IDE_ROOT=C:\Efinity\efinity-riscv-ide-2026.1"
set "OCD=%IDE_ROOT%\openocd\bin\openocd.exe"
set "TOOLS=%~dp0"
set "ADAPTER_CFG=%TOOLS%gesture_ftdi.cfg"
set "SCAN_CFG=%TOOLS%gesture_jtag_scan.cfg"
set "TARGET_CFG=%TOOLS%gesture_debug_target.cfg"
set "LOAD_TCL=%TOOLS%gesture_load_model.tcl"
set "VALIDATOR=%TOOLS%validate_jtag_selector.ps1"
set "MODE=scan"
set "SELECTOR="
set "SELECTOR_KIND="

if /i "%~1"=="--load" (
    set "MODE=load"
    shift
    goto parse_args
) else if /i "%~1"=="--scan" (
    set "MODE=scan"
    shift
    goto parse_args
)

:parse_args
if "%~1"=="" goto args_done
if /i "%~1"=="--location" goto got_location
if /i "%~1"=="--serial" goto got_serial
if /i "%~1"=="--help" goto usage
echo ERROR: unknown argument %~1
goto usage_error

:got_location
if not "%SELECTOR_KIND%"=="" (
    echo ERROR: choose only one of --location or --serial
    goto usage_error
)
set "SELECTOR_KIND=location"
set "SELECTOR=%~2"
if "%SELECTOR%"=="" (
    echo ERROR: --location needs an OpenOCD USB location such as 1-4.2
    goto usage_error
)
shift
shift
goto parse_args

:got_serial
if not "%SELECTOR_KIND%"=="" (
    echo ERROR: choose only one of --location or --serial
    goto usage_error
)
set "SELECTOR_KIND=serial"
set "SELECTOR=%~2"
if "%SELECTOR%"=="" (
    echo ERROR: --serial needs a non-empty adapter serial
    goto usage_error
)
shift
shift
goto parse_args

:args_done
if /i "%MODE%"=="load" if "%SELECTOR_KIND%"=="" (
    echo ERROR: DDR load requires explicit --location or --serial
    goto usage_error
)
if not "%SELECTOR_KIND%"=="" (
    if /i "%SELECTOR_KIND%"=="location" echo OpenOCD USB location selector: %SELECTOR%
    if /i "%SELECTOR_KIND%"=="serial" echo OpenOCD FTDI serial selector: %SELECTOR%
    echo The value is passed to OpenOCD as a bus-port path, not an Efinity URI.
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%VALIDATOR%" -Kind "%SELECTOR_KIND%" -Value "%SELECTOR%"
    if errorlevel 1 (
        echo ERROR: invalid adapter selector syntax.
        exit /b 2
    )
)

if not exist "%OCD%" (
    echo ERROR: OpenOCD not found: %OCD%
    exit /b 2
)
cd /d "%IDE_ROOT%"
if errorlevel 1 (
    echo ERROR: cannot enter Efinity RISC-V IDE directory
    exit /b 2
)
call setup_standalone.bat <nul
ver >nul
cd /d "%TOOLS%"
if errorlevel 1 exit /b %errorlevel%

set "LOAD_TCL_TCL=%LOAD_TCL:\=/%"

if /i "%MODE%"=="scan" (
    echo Read-only JTAG TAP scan. No RISC-V target is created and no DDR is written.
    goto run_scan
)

set "GESTURE_DDR_LOAD=YES"
set "GESTURE_DDR_LOAD_TARGET=%SELECTOR_KIND%:%SELECTOR%"
echo WARNING: this will halt Sapphire and write the two validated model files to volatile DDR.
echo The operation requires DDR calibration and will be verified before firmware resumes.
goto run_load

:run_scan
if /i "%SELECTOR_KIND%"=="location" "%OCD%" -f "%ADAPTER_CFG%" -c "adapter usb location %SELECTOR%" -f "%SCAN_CFG%" -c init -c shutdown
if /i "%SELECTOR_KIND%"=="serial" "%OCD%" -f "%ADAPTER_CFG%" -c "adapter serial %SELECTOR%" -f "%SCAN_CFG%" -c init -c shutdown
if "%SELECTOR_KIND%"=="" "%OCD%" -f "%ADAPTER_CFG%" -f "%SCAN_CFG%" -c init -c shutdown
set "OCD_EXIT=%ERRORLEVEL%"
exit /b %OCD_EXIT%

:run_load
if /i "%SELECTOR_KIND%"=="location" "%OCD%" -f "%ADAPTER_CFG%" -c "adapter usb location %SELECTOR%" -f "%TARGET_CFG%" -c init -c "source {%LOAD_TCL_TCL%}"
if /i "%SELECTOR_KIND%"=="serial" "%OCD%" -f "%ADAPTER_CFG%" -c "adapter serial %SELECTOR%" -f "%TARGET_CFG%" -c init -c "source {%LOAD_TCL_TCL%}"
set "OCD_EXIT=%ERRORLEVEL%"
exit /b %OCD_EXIT%

:usage
echo Usage:
echo   gesture_load_model.bat                 ^(default: read-only JTAG TAP scan^)
echo   gesture_load_model.bat --scan [--location BUS-PORT[.PORT]... ^| --serial SERIAL^]
echo   gesture_load_model.bat --load --location BUS-PORT[.PORT]...
echo   gesture_load_model.bat --load --serial SERIAL
echo Load mode requires exactly one explicit adapter selector. Current board notes say
echo the FT4232 EEPROM has no serial, so --location is expected unless hardware differs.
echo USB location is OpenOCD's bus-port path, not an Efinity URI; do not guess it.
exit /b 0

:usage_error
call :usage
exit /b 2

