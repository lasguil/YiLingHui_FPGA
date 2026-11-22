@echo off
setlocal
set "PYTHONHOME="
set "PYTHONPATH="
"C:\Users\29966\AppData\Local\Programs\Python\Python312\python.exe" -X utf8 -I -B "%~dp0launch.py" %*
set "RESULT=%ERRORLEVEL%"
if "%~1"=="" if not "%RESULT%"=="0" pause
exit /b %RESULT%
