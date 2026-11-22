@echo off
setlocal
cd /d C:\Efinity\efinity-riscv-ide-2026.1
call setup_standalone.bat <nul
rem setup_standalone ends with SET /P; NUL stdin is expected in noninteractive builds.
cd /d "%~dp0"
set "TMP=%~dp0..\tmp\firmware_build"
set "TEMP=%~dp0..\tmp\firmware_build"
if not exist "%TMP%" mkdir "%TMP%"
if not exist build mkdir build
"C:\Users\29966\AppData\Local\Programs\Python\Python312\python.exe" -E -I -B -X utf8 ..\tools\validate_firmware_catalog.py
if errorlevel 1 exit /b %errorlevel%
riscv-none-elf-gcc -march=rv32im_zicsr -mabi=ilp32 -Oz -flto -msave-restore -fstack-usage -Wall -Wextra -Werror -ffreestanding -nostdlib -fno-builtin -msmall-data-limit=0 -ffunction-sections -fdata-sections -Wl,--gc-sections,--build-id=none,-Map=build\product_ui_24k.map -I . -T diag_link.ld style_start.S style_control.c style_input.c gesture_uart.c style_fps.c style_camera.c ch9350_touch.c ch9350_uart.c style_pipeline.c -lgcc -o build\product_ui_24k.elf
if errorlevel 1 exit /b %errorlevel%
riscv-none-elf-size build\product_ui_24k.elf
riscv-none-elf-objcopy -O binary build\product_ui_24k.elf build\product_ui_24k.bin
if errorlevel 1 exit /b %errorlevel%
riscv-none-elf-objdump -d build\product_ui_24k.elf > build\product_ui_24k.objdump.txt
riscv-none-elf-nm -S --size-sort build\product_ui_24k.elf > build\product_ui_24k.nm.txt
exit /b 0

