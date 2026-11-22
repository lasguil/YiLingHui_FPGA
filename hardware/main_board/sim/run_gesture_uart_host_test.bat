@echo off
setlocal
cd /d "%~dp0.."
if not exist tmp mkdir tmp
set "TMP=%CD%\tmp\gesture_uart_host"
set "TEMP=%TMP%"
if not exist "%TMP%" mkdir "%TMP%"
"C:\Program Files\mingw64\bin\gcc.exe" -std=c11 -Wall -Wextra -Werror sim\gesture_uart_host_test.c software\gesture_uart.c software\style_input.c software\ch9350_touch.c -o tmp\gesture_uart_host_test.exe
if errorlevel 1 exit /b %errorlevel%
tmp\gesture_uart_host_test.exe
exit /b %errorlevel%
