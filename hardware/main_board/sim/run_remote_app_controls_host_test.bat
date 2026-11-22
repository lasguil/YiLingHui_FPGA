@echo off
setlocal
cd /d "%~dp0..\..\.."
set "TMP=%CD%\tmp\app_controls_v2_20261115"
set "TEMP=%TMP%"
if not exist "%TMP%" mkdir "%TMP%"
set "FW=hardware\network_board\software\gesture_firmware"
set "B1=hardware\main_board"
"C:\Program Files\mingw64\bin\gcc.exe" -std=c11 -Wall -Wextra -Werror -DGESTURE_HOST_TEST -I"%FW%\include" -I"%B1%\software" "%FW%\src\gesture_return.c" "%B1%\software\gesture_uart.c" "%B1%\software\style_input.c" "%B1%\software\ch9350_touch.c" "%B1%\sim\remote_app_controls_host_test.c" -o "%TMP%\test_controls.exe"
if errorlevel 1 exit /b %errorlevel%
"%TMP%\test_controls.exe"
exit /b %errorlevel%
