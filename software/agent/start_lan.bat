@echo off
setlocal
set "PYTHONHOME="
set "PYTHONPATH="
"C:\Users\29966\AppData\Local\Programs\Python\Python312\python.exe" "%~dp0server.py" --host 0.0.0.0 --port 8765
endlocal
pause
