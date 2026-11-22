@echo off
setlocal
set "FW_ROOT=%~dp0.."
for %%I in ("%FW_ROOT%") do set "FW_ROOT=%%~fI"
for %%I in ("%FW_ROOT%\..\..\..\..") do set "REPO=%%~fI"
set "BOARD1=%REPO%\hardware\main_board\software"
set "TMP=%FW_ROOT%\..\..\tmp\firmware_host"
set "TEMP=%TMP%"
if not exist "%TMP%" mkdir "%TMP%"
if not exist "%FW_ROOT%\build" mkdir "%FW_ROOT%\build"
"C:\Program Files\mingw64\bin\gcc.exe" -DGESTURE_HOST_TEST -std=c11 -Wall -Wextra -Werror -Wno-unused-parameter -ffunction-sections -fdata-sections -Wl,--gc-sections -I"%FW_ROOT%\include" -I"%BOARD1%" "%FW_ROOT%\src\gesture_return.c" "%BOARD1%\gesture_uart.c" "%BOARD1%\style_input.c" "%FW_ROOT%\tests\test_board1_compat.c" -o "%FW_ROOT%\build\test_board1_compat.exe"
if errorlevel 1 exit /b %errorlevel%
"%FW_ROOT%\build\test_board1_compat.exe"
exit /b %errorlevel%
