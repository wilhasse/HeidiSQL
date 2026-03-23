@echo off
setlocal

set "SCRIPT_DIR=%~dp0"
set "SOURCE_EXE=%SCRIPT_DIR%out\heidisql.exe"
set "TARGET_DIR=C:\Program Files\HeidiSQL"
set "TARGET_EXE=%TARGET_DIR%\heidisql.exe"

if not exist "%SOURCE_EXE%" (
  echo Source file not found:
  echo   %SOURCE_EXE%
  exit /b 1
)

if not exist "%TARGET_DIR%" (
  echo Target directory not found:
  echo   %TARGET_DIR%
  exit /b 1
)

net session >nul 2>&1
if errorlevel 1 (
  echo Requesting administrator privileges...
  powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -Verb RunAs -WorkingDirectory '%SCRIPT_DIR%'"
  exit /b %errorlevel%
)

copy /Y "%SOURCE_EXE%" "%TARGET_EXE%" >nul
if errorlevel 1 (
  echo Failed to copy:
  echo   %SOURCE_EXE%
  echo to:
  echo   %TARGET_EXE%
  exit /b 1
)

echo Copied:
echo   %SOURCE_EXE%
echo to:
echo   %TARGET_EXE%

endlocal
