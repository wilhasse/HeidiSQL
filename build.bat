@echo off
setlocal
cd /d "%~dp0"

if not defined TX_TOKEN (
  echo TX_TOKEN is not defined. Set it before running this script.
  echo Example in cmd.exe: set "TX_TOKEN=your-token"
  echo Example in PowerShell: $env:TX_TOKEN = 'your-token'
  exit /b 1
)

set "GIT_CONFIG_COUNT=1"
set "GIT_CONFIG_KEY_0=safe.directory"
set "GIT_CONFIG_VALUE_0=%CD:\=/%"
set "XDEBUG_MODE=off"

php build.php
exit /b %ERRORLEVEL%
