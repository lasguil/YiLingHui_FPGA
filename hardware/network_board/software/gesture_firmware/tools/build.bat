@echo off
setlocal
set "FW_ROOT=%~dp0.."
for %%I in ("%FW_ROOT%") do set "FW_ROOT=%%~fI"
set "PYTHONHOME="
set "PYTHONPATH="
if not exist "%FW_ROOT%\build" mkdir "%FW_ROOT%\build"
set "TMP=%FW_ROOT%\..\..\tmp\firmware_build"
set "TEMP=%TMP%"
if not exist "%TMP%" mkdir "%TMP%"

set "EFINITY_RISCV=C:\Efinity\efinity-riscv-ide-2026.1"
pushd "%EFINITY_RISCV%"
call setup_standalone.bat < nul
popd

"C:\Users\29966\AppData\Local\Programs\Python\Python312\python.exe" -E "%FW_ROOT%\tools\package_model.py"
if errorlevel 1 exit /b %errorlevel%

riscv-none-elf-gcc.exe -march=rv32im_zicsr -mabi=ilp32 -Os -ffreestanding -fno-builtin -ffunction-sections -fdata-sections -nostartfiles -I"%FW_ROOT%\include" -Wl,--gc-sections -Wl,-T,"%FW_ROOT%\software\link.ld" "%FW_ROOT%\src\startup.S" "%FW_ROOT%\src\main.c" "%FW_ROOT%\src\gesture_fw.c" "%FW_ROOT%\src\gesture_return.c" "%FW_ROOT%\src\gesture_flash_loader.c" -lgcc -o "%FW_ROOT%\build\gesture_demo.elf"
if errorlevel 1 exit /b %errorlevel%
riscv-none-elf-objcopy.exe -O binary "%FW_ROOT%\build\gesture_demo.elf" "%FW_ROOT%\build\gesture_demo.bin"
if errorlevel 1 exit /b %errorlevel%
riscv-none-elf-objdump.exe -h "%FW_ROOT%\build\gesture_demo.elf" > "%FW_ROOT%\build\gesture_demo_sections.txt"
if errorlevel 1 exit /b %errorlevel%
"C:\Users\29966\AppData\Local\Programs\Python\Python312\python.exe" -I -B "%FW_ROOT%\tools\pack_ocr_rom.py" build/gesture_demo.bin
if errorlevel 1 exit /b %errorlevel%
riscv-none-elf-size.exe "%FW_ROOT%\build\gesture_demo.elf"
endlocal
