@echo off
setlocal
rem Uses the same proven FTDI/BSP configuration as the RISC-V experiment.
rem Briefly halt CPU for APB reads, then resume. CPU does not own DDR traffic.
for %%I in ("%~dp0..\support\debug") do set "diag_soc_root=%%~fI"
cd /d C:\Efinity\efinity-riscv-ide-2026.1
call setup_standalone.bat <nul
cd /d "%diag_soc_root%\soc\bsp"
openocd.exe -f "%diag_soc_root%\ftdi_ti_nofilter.cfg" -f "%diag_soc_root%\soc\bsp\efinix\EfxSapphireSoc\openocd\debug_ti.cfg" -c halt -c "wait_halt 1000" -c "reg pc" -c "mdw 0xf8100000 8" -c "mdw 0xf8015004" -c resume -c shutdown
exit /b %errorlevel%
