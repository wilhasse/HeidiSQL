@echo off
setlocal

set "SCRIPT_DIR=%~dp0"
set "TARGET_DIR=C:\Program Files\HeidiSQL CSLOG"
set "TARGET_EXE=%TARGET_DIR%\heidisql.exe"
set "SOURCE_EXE="

for /f "usebackq delims=" %%F in (`powershell -NoProfile -ExecutionPolicy Bypass -Command "$c=@('%SCRIPT_DIR%out\heidisql64.exe','%SCRIPT_DIR%out\heidisql.exe') | Where-Object { Test-Path $_ } | Get-Item | Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName; if($c){$c}"`) do set "SOURCE_EXE=%%F"

if "%SOURCE_EXE%"=="" (
  echo Source file not found:
  echo   %SCRIPT_DIR%out\heidisql64.exe
  echo   %SCRIPT_DIR%out\heidisql.exe
  exit /b 1
)

net session >nul 2>&1
if errorlevel 1 (
  echo Requesting administrator privileges...
  powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -Verb RunAs -WorkingDirectory '%SCRIPT_DIR%'"
  exit /b %errorlevel%
)

if not exist "%TARGET_DIR%" (
  mkdir "%TARGET_DIR%"
  if errorlevel 1 (
    echo Failed to create target directory:
    echo   %TARGET_DIR%
    exit /b 1
  )
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