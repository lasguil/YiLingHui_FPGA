@echo off
setlocal
cd /d "%~dp0.."
set "TMP=%CD%\tmp\post_apply_host"
set "TEMP=%TMP%"
if not exist "%TMP%" mkdir "%TMP%"
"C:\Program Files\mingw64\bin\gcc.exe" -std=c11 -Os -DSTYLE_CAMERA_HOST_TEST -ffunction-sections -fdata-sections -Wl,--gc-sections -I software sim\post_apply_host_test.c software\gesture_uart.c software\style_input.c software\ch9350_touch.c software\ch9350_uart.c software\style_fps.c -o tmp\post_apply_host\test.exe
if errorlevel 1 exit /b %errorlevel%
tmp\post_apply_host\test.exe
exit /b %errorlevel%
