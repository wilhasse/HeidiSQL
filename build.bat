@echo off
setlocal
cd /d "%~dp0"

if not defined SKIP_TX_PULL if not defined TX_TOKEN (
  echo TX_TOKEN is not defined. Set it before running this script.
  echo Example in cmd.exe: set "TX_TOKEN=your-token"
  echo Example in PowerShell: $env:TX_TOKEN = 'your-token'
  echo.
  echo If you want to build without downloading fresh Transifex locales, set "SKIP_TX_PULL=1" too.
  exit /b 1
)

set "GIT_CONFIG_COUNT=1"
set "GIT_CONFIG_KEY_0=safe.directory"
set "GIT_CONFIG_VALUE_0=%CD:\=/%"
set "XDEBUG_MODE=off"

if defined SKIP_TX_PULL (
  echo SKIP_TX_PULL is enabled. The build will reuse existing locale files and skip Transifex download.
)

php build.php
if errorlevel 1 exit /b %ERRORLEVEL%

if defined SKIP_SIGN (
  echo SKIP_SIGN is enabled. Skipping code signing upload.
  exit /b 0
)

if /I not "%ENABLE_SIGN%"=="1" if /I not "%ENABLE_SIGN%"=="true" if /I not "%ENABLE_SIGN%"=="yes" (
  echo Signing is disabled by default. Set ENABLE_SIGN=1 to upload the EXE for signing.
  exit /b 0
)

set "SIGN_FILENAME=heidisql64.exe"
set "SIGN_OUTPUT_FILE=%CD%\out\%SIGN_FILENAME%"
if not defined SIGN_SERVICE_HOST set "SIGN_SERVICE_HOST=10.88.0.46"
if not defined SIGN_SERVICE_PORT set "SIGN_SERVICE_PORT=5000"
set "SIGN_SERVICE_URL=http://%SIGN_SERVICE_HOST%:%SIGN_SERVICE_PORT%/sign/upload/%SIGN_FILENAME%"
set "SIGN_TEMP_FILE=%SIGN_OUTPUT_FILE%.signed"

if not exist "%SIGN_OUTPUT_FILE%" (
  echo Expected output file not found: "%SIGN_OUTPUT_FILE%"
  exit /b 1
)

echo Uploading %SIGN_FILENAME% to %SIGN_SERVICE_URL%
if exist "%SIGN_TEMP_FILE%" del /f /q "%SIGN_TEMP_FILE%" >nul 2>&1
curl.exe --fail --silent --show-error -H "Expect:" -T "%SIGN_OUTPUT_FILE%" "%SIGN_SERVICE_URL%" -o "%SIGN_TEMP_FILE%"
if errorlevel 1 (
  echo Signing upload failed.
  exit /b 1
)
if not exist "%SIGN_TEMP_FILE%" (
  echo Signed file was not returned by the signing service.
  exit /b 1
)

move /Y "%SIGN_TEMP_FILE%" "%SIGN_OUTPUT_FILE%" >nul
if errorlevel 1 (
  echo Failed to replace the unsigned output with the signed file.
  exit /b 1
)

echo Signing completed successfully.
exit /b 0
