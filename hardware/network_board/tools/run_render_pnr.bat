@echo off
setlocal
call C:\Efinity\2026.1\bin\setup.bat
if errorlevel 1 exit /b %errorlevel%
cd /d "%~dp0.."
"C:\Users\29966\AppData\Local\Programs\Python\Python312\python.exe" -I -B tools\prepare_pnr_retry.py verify
if errorlevel 1 exit /b %errorlevel%
"C:\Users\29966\AppData\Local\Programs\Python\Python312\python.exe" -I -B tools\build_record.py begin
if errorlevel 1 exit /b %errorlevel%
call efx_run.bat ti60f225_oob.xml --flow pnr > build_pnr.log 2>&1
if errorlevel 1 exit /b %errorlevel%
call efx_run.bat ti60f225_oob.xml --flow pgm > build_pgm.log 2>&1
if errorlevel 1 exit /b %errorlevel%
"C:\Users\29966\AppData\Local\Programs\Python\Python312\python.exe" -I -B tools\build_record.py accept
exit /b %errorlevel%
