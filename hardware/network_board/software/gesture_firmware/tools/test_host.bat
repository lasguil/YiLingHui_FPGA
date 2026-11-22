@echo off
setlocal
set "FW_ROOT=%~dp0.."
for %%I in ("%FW_ROOT%") do set "FW_ROOT=%%~fI"
set "TMP=%FW_ROOT%\..\..\tmp\firmware_host"
set "TEMP=%TMP%"
if not exist "%TMP%" mkdir "%TMP%"
set "PYTHONHOME="
set "PYTHONPATH="
if not exist "%FW_ROOT%\build" mkdir "%FW_ROOT%\build"
"C:\Users\29966\AppData\Local\Programs\Python\Python312\python.exe" -E "%FW_ROOT%\tools\package_model.py"
if errorlevel 1 exit /b %errorlevel%
"C:\Program Files\mingw64\bin\gcc.exe" -std=c11 -Wall -Wextra -Werror -I"%FW_ROOT%\include" "%FW_ROOT%\src\gesture_fw.c" "%FW_ROOT%\tests\test_gesture_fw.c" -o "%FW_ROOT%\build\test_gesture_fw.exe"
if errorlevel 1 exit /b %errorlevel%
"%FW_ROOT%\build\test_gesture_fw.exe"
if errorlevel 1 exit /b %errorlevel%
"C:\Program Files\mingw64\bin\gcc.exe" -std=c11 -Wall -Wextra -Werror -DGESTURE_HOST_TEST -DGESTURE_APP_NO_MAIN -DNPU_WAIT_SPINS=2 -DROI_WAIT_SPINS=4 -I"%FW_ROOT%\include" "%FW_ROOT%\src\gesture_fw.c" "%FW_ROOT%\src\main.c" "%FW_ROOT%\src\gesture_flash_loader.c" "%FW_ROOT%\tests\test_gesture_app.c" -o "%FW_ROOT%\build\test_gesture_app.exe"
if errorlevel 1 exit /b %errorlevel%
"%FW_ROOT%\build\test_gesture_app.exe"
if errorlevel 1 exit /b %errorlevel%
"C:\Program Files\mingw64\bin\gcc.exe" -std=c11 -Wall -Wextra -Werror -DGESTURE_HOST_TEST -DFLASH_WORD_TIMEOUT_SPINS=1024 -I"%FW_ROOT%\include" "%FW_ROOT%\src\gesture_flash_loader.c" "%FW_ROOT%\tests\test_gesture_flash_loader.c" -o "%FW_ROOT%\build\test_gesture_flash_loader.exe"
if errorlevel 1 exit /b %errorlevel%
"%FW_ROOT%\build\test_gesture_flash_loader.exe" "%FW_ROOT%\model\weights_hw.bin" "%FW_ROOT%\model\param_hw.bin"
if errorlevel 1 exit /b %errorlevel%
"C:\Program Files\mingw64\bin\gcc.exe" -std=c11 -Wall -Wextra -Werror -DGESTURE_HOST_TEST -I"%FW_ROOT%\include" "%FW_ROOT%\src\gesture_return.c" "%FW_ROOT%\tests\test_gesture_return.c" -o "%FW_ROOT%\build\test_gesture_return.exe"
if errorlevel 1 exit /b %errorlevel%
"%FW_ROOT%\build\test_gesture_return.exe"
if errorlevel 1 exit /b %errorlevel%
"C:\Program Files\mingw64\bin\gcc.exe" -std=c11 -Wall -Wextra -Werror -I"%FW_ROOT%\include" "%FW_ROOT%\tests\test_gesture_geometry.c" -o "%FW_ROOT%\build\test_gesture_geometry.exe"
if errorlevel 1 exit /b %errorlevel%
"%FW_ROOT%\build\test_gesture_geometry.exe"
if errorlevel 1 exit /b %errorlevel%
endlocal
