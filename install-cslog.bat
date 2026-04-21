@echo off
setlocal

set "SCRIPT_DIR=%~dp0"
set "TARGET_DIR=C:\Program Files\HeidiSQL CSLOG"
set "TARGET_EXE=%TARGET_DIR%\heidisql.exe"
set "REG_KEY=HKCU\Software\HeidiSQL CSLOG"
set "SQLMONITOR_URL=%HEIDISQL_CSLOG_SQLMONITOR_URL%"
set "SQLMONITOR_API_KEY=%HEIDISQL_CSLOG_SQLMONITOR_API_KEY%"
set "SOURCE_EXE="

if "%SQLMONITOR_URL%"=="" set "SQLMONITOR_URL=https://monitorsql.cslog.com.br"
if "%SQLMONITOR_API_KEY%"=="" set "SQLMONITOR_API_KEY=X_GT1Lw1jSj0H5OH72xYY42M_z9ZhY3kuud6UShpq4U"

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


powershell -NoProfile -ExecutionPolicy Bypass -Command "$out=Join-Path '%SCRIPT_DIR%' 'out'; $target='%TARGET_DIR%'; $map=[ordered]@{'libeay32-64.dll'='libeay32.dll';'ssleay32-64.dll'='ssleay32.dll';'libmariadb-64.dll'='libmariadb.dll';'libmysql-64.dll'='libmysql.dll';'libmysql-6.1-64.dll'='libmysql-6.1.dll';'libmysql-8.4.0-64.dll'='libmysql-8.4.0.dll';'libmysql-9.4.0-64.dll'='libmysql-9.4.0.dll';'libpq-15-64.dll'='libpq-15.dll';'libpq-17-64.dll'='libpq-17.dll';'libintl-9-64.dll'='libintl-9.dll';'libssl-3-x64.dll'='libssl-3-x64.dll';'libcrypto-3-x64.dll'='libcrypto-3-x64.dll';'libiconv-2-64.dll'='libiconv-2.dll';'libwinpthread-1-64.dll'='libwinpthread-1.dll';'sqlite3-64.dll'='sqlite3.dll';'sqlite3mc-64.dll'='sqlite3mc.dll';'ibclient64-14.1.dll'='ibclient64-14.1.dll';'fbclient-4.0-64.dll'='fbclient-4.0.dll'}; foreach($item in $map.GetEnumerator()){ $src=Join-Path $out $item.Key; if(Test-Path $src){ Copy-Item $src (Join-Path $target $item.Value) -Force } }"
if errorlevel 1 (
  echo Failed to copy runtime DLLs.
  exit /b 1
)

if exist "%SCRIPT_DIR%out\plugins64" (
  powershell -NoProfile -ExecutionPolicy Bypass -Command "$targetPlugins=Join-Path '%TARGET_DIR%' 'plugins'; if(-not (Test-Path $targetPlugins)){ New-Item -ItemType Directory -Path $targetPlugins -Force | Out-Null }; Copy-Item -Path (Join-Path '%SCRIPT_DIR%' 'out\plugins64\*') -Destination $targetPlugins -Force"
  if errorlevel 1 (
    echo Failed to copy MySQL authentication plugins.
    exit /b 1
  )
)

if exist "%SCRIPT_DIR%out\locale" (
  powershell -NoProfile -ExecutionPolicy Bypass -Command "Copy-Item -Path (Join-Path '%SCRIPT_DIR%' 'out\locale') -Destination '%TARGET_DIR%' -Recurse -Force"
  if errorlevel 1 (
    echo Failed to copy locale files.
    exit /b 1
  )
)

reg add "%REG_KEY%" /v SqlMonitorUrl /t REG_SZ /d "%SQLMONITOR_URL%" /f >nul
if errorlevel 1 (
  echo Failed to write SqlMonitorUrl to registry.
  exit /b 1
)

reg add "%REG_KEY%" /v SqlMonitorApiKey /t REG_SZ /d "%SQLMONITOR_API_KEY%" /f >nul
if errorlevel 1 (
  echo Failed to write SqlMonitorApiKey to registry.
  exit /b 1
)

reg add "%REG_KEY%" /v SqlMonitorCentralAuthEnabled /t REG_DWORD /d 1 /f >nul
if errorlevel 1 (
  echo Failed to write SqlMonitorCentralAuthEnabled to registry.
  exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -Command "$key='HKCU:\Software\HeidiSQL CSLOG'; if(-not (Test-Path $key)){ New-Item -Path $key -Force | Out-Null }; $lang=(Get-ItemProperty -Path $key -Name Language -ErrorAction SilentlyContinue).Language; if([string]::IsNullOrWhiteSpace($lang)){ New-ItemProperty -Path $key -Name Language -PropertyType String -Value 'pt_BR' -Force | Out-Null }"
if errorlevel 1 (
  echo Failed to initialize default language.
  exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -Command "$desktop=[Environment]::GetFolderPath('Desktop'); $shortcut=Join-Path $desktop 'HeidiSQL CSLOG.lnk'; $wsh=New-Object -ComObject WScript.Shell; $lnk=$wsh.CreateShortcut($shortcut); $lnk.TargetPath='%TARGET_EXE%'; $lnk.WorkingDirectory='%TARGET_DIR%'; $lnk.IconLocation='%TARGET_EXE%,0'; $lnk.Description='HeidiSQL CSLOG managed database client'; $lnk.Save()"
if errorlevel 1 (
  echo Failed to create desktop shortcut.
  exit /b 1
)
echo Installed HeidiSQL CSLOG:
echo   %TARGET_EXE%
echo.
echo Configured SQL monitor:
echo   %SQLMONITOR_URL%
echo.
echo Registry profile:
echo   %REG_KEY%

endlocal
