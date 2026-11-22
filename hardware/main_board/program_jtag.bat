@echo off
setlocal
set "current_bit=%~dp0outflow\ti60f225_oob.bit"
if not "%~1"=="" set "current_bit=%~f1"
if not exist "%current_bit%" exit /b 2
if "%~1"=="" (
    "C:\Users\29966\AppData\Local\Programs\Python\Python312\python.exe" -I -B "%~dp0tools\verify_current_bit.py"
    if errorlevel 1 exit /b 3
)
echo JTAG bitstream: "%current_bit%"
call C:\Efinity\2026.1\bin\setup.bat
if errorlevel 1 exit /b %errorlevel%
rem Board1 is HiFTDI. Ordinary FTDI :fd belongs to Board2.
"C:\Users\29966\AppData\Local\Programs\Python\Python312\python.exe" -E -X utf8 "%~dp0tools\program_jtag_hiftdi.py" --bit "%current_bit%" > "%~dp0jtag_program.log" 2>&1
exit /b %errorlevel%
