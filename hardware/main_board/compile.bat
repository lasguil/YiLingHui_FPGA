@echo off
setlocal
cd /d "%~dp0"
if not exist build mkdir build
if not defined EFX_MAX_THREADS set "EFX_MAX_THREADS=-1"
if not defined EFX_MAP_TIMEOUT set "EFX_MAP_TIMEOUT=3600"
rem Titanium high-utilization routing adds 10 iterations to this internal cap.
rem The previous signed-off route needed more than the default effective 60.
if not defined EFX_ROUTE_ITERATIONS set "EFX_ROUTE_ITERATIONS=190"
rem Always build the firmware that will be embedded, then regenerate both
rem the artifact mirror and the project-root readmemh inputs before Efinity.
set "PYTHONHOME="
set "PYTHONPATH="
call software\build_multi_style_24k.bat
if errorlevel 1 exit /b %errorlevel%
"C:\Users\29966\AppData\Local\Programs\Python\Python312\python.exe" -I -B tools\audit_firmware_counter_csrs.py software\build\product_ui_24k.objdump.txt > build\counter_csr_audit.log 2>&1
if errorlevel 1 (type build\counter_csr_audit.log & exit /b 1)
"C:\Users\29966\AppData\Local\Programs\Python\Python312\python.exe" -I -B tools\update_firmware_rom.py > build\firmware_rom.log 2>&1
if errorlevel 1 (type build\firmware_rom.log & exit /b 1)
"C:\Users\29966\AppData\Local\Programs\Python\Python312\python.exe" -I -B software\pack_24k_lanes.py >> build\firmware_rom.log 2>&1
if errorlevel 1 (type build\firmware_rom.log & exit /b 1)
"C:\Users\29966\AppData\Local\Programs\Python\Python312\python.exe" -I -B software\pack_24k_lanes.py --check-only >> build\firmware_rom.log 2>&1
if errorlevel 1 (type build\firmware_rom.log & exit /b 1)
"C:\Users\29966\AppData\Local\Programs\Python\Python312\python.exe" -I -B tools\verify_firmware_rom.py >> build\firmware_rom.log 2>&1
if errorlevel 1 (type build\firmware_rom.log & exit /b 1)
type build\firmware_rom.log
call C:\Efinity\2026.1\bin\setup.bat
if errorlevel 1 exit /b %errorlevel%
call efx_run.bat ti60f225_oob.xml --flow interface --timeout 300 --output_dir outflow > build\interface.log 2>&1
if errorlevel 1 exit /b %errorlevel%
call efx_run.bat ti60f225_oob.xml --flow map --timeout %EFX_MAP_TIMEOUT% --map_opts max_threads=%EFX_MAX_THREADS% --output_dir outflow --work_dir build/work_syn > build\map.log 2>&1
if errorlevel 1 exit /b %errorlevel%
"C:\Users\29966\AppData\Local\Programs\Python\Python312\python.exe" -I -B tools\verify_firmware_rom.py --map outflow\ti60f225_oob.map.v --map-log outflow\ti60f225_oob.info.log > build\mapped_rom_verify.json 2>&1
if errorlevel 1 (type build\mapped_rom_verify.json & exit /b 1)
"C:\Users\29966\AppData\Local\Programs\Python\Python312\python.exe" -I -B tools\check_sdc_cpu_async_sr.py outflow\ti60f225_oob.map.v > build\sdc_cpu_async_sr.log 2>&1
if errorlevel 1 (type build\sdc_cpu_async_sr.log & exit /b 1)
call efx_run.bat ti60f225_oob.xml --flow pnr --timeout 7200 --pnr_opts max_threads=%EFX_MAX_THREADS% troute_options=max_iterations=%EFX_ROUTE_ITERATIONS% --output_dir outflow --work_dir build/work_pnr > build\pnr.log 2>&1
if errorlevel 1 exit /b %errorlevel%
call efx_run.bat ti60f225_oob.xml --flow sta_tclsh --timeout 300 --output_dir outflow --work_dir build/work_pnr --tcl_script tools\signoff.tcl > build\signoff.log 2>&1
if errorlevel 1 exit /b %errorlevel%
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools\check_timing_gate.ps1 -TimingReport outflow\ti60f225_oob.timing.rpt > build\timing_gate.log 2>&1
if errorlevel 1 (type build\timing_gate.log & exit /b 1)
if not exist outflow\ti60f225_oob.signoff_cdc.rpt (if not exist outflow\signoff_cdc.rpt (echo CDC signoff report missing & exit /b 1))
call efx_run.bat ti60f225_oob.xml --flow pgm --timeout 300 --output_dir outflow --work_dir build/work_pnr > build\pgm.log 2>&1
if errorlevel 1 exit /b %errorlevel%
"C:\Users\29966\AppData\Local\Programs\Python\Python312\python.exe" -I -B tools\verify_firmware_rom.py --map outflow\ti60f225_oob.map.v --map-log outflow\ti60f225_oob.info.log --pgm outflow\ti60f225_oob.pgm.out > build\pgm_rom_verify.json 2>&1
if errorlevel 1 (type build\pgm_rom_verify.json & exit /b 1)
"C:\Users\29966\AppData\Local\Programs\Python\Python312\python.exe" -I -B tools\record_current_build.py --bit outflow\ti60f225_oob.bit --hex outflow\ti60f225_oob.hex --pgm outflow\ti60f225_oob.pgm.out --pgm-log build\pgm.log --rom-verification build\pgm_rom_verify.json
exit /b %errorlevel%
