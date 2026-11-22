@echo off
setlocal
cd /d "%~dp0.."
set "TEMP=%CD%\tmp\firmware_cleanup_host"
set "TMP=%TEMP%"
if not exist "%TEMP%" mkdir "%TEMP%"
"C:\Program Files\mingw64\bin\gcc.exe" -std=c11 -Os -Wall -Wextra -Werror -DSTYLE_CAMERA_HOST_TEST -ffunction-sections -fdata-sections -Wl,--gc-sections -I software sim\firmware_cleanup\equivalence.c sim\firmware_cleanup\reference_pipeline.c sim\firmware_cleanup\current_pipeline.c sim\firmware_cleanup\reference_input.c software\style_input.c -o tmp\firmware_cleanup_host\test.exe
if errorlevel 1 exit /b %errorlevel%
tmp\firmware_cleanup_host\test.exe
exit /b %errorlevel%
