@echo off
setlocal
set "PROJECT_ROOT=%~dp0.."
for %%I in ("%PROJECT_ROOT%") do set "PROJECT_ROOT=%%~fI"
set "FW_ROOT=%~dp0gesture_firmware"
call "%FW_ROOT%\tools\build.bat"
if errorlevel 1 exit /b %errorlevel%

for %%L in (0 1 2 3) do copy /y "%FW_ROOT%\build\gesture_demo_ram_symbol%%L.bin" "%PROJECT_ROOT%\EfxSapphireSoc.v_toplevel_system_ramA_logic_ram_symbol%%L.bin" > nul
if errorlevel 1 exit /b %errorlevel%
echo Gesture firmware and four Sapphire OCR lanes updated from %FW_ROOT%\build\gesture_demo.elf
endlocal
