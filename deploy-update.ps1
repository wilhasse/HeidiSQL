param(
    [switch]$Mandatory,
    [string]$Notes = "Correcoes da versao CSLOG."
)

$ErrorActionPreference = "Stop"

# ── Configuration ──────────────────────────────────────────────────
$RemoteUser = "cslog"
$RemoteHost = "192.168.20.11"
$RemotePort = "2225"
$RemoteDir  = "/home/cslog/heidisql_bin"
$ExePath    = "D:\git\HeidiSQL\out\heidisql64.exe"
$RepoDir    = "D:\git\HeidiSQL"
$Filename   = "heidisql64.exe"
$Channel    = "stable"

# ── Validate exe exists ───────────────────────────────────────────
if (-not (Test-Path $ExePath)) {
    Write-Error "$ExePath not found. Run build.bat first."
    exit 1
}

# ── Extract version from exe ──────────────────────────────────────
$vi = (Get-Item $ExePath).VersionInfo
$Version  = $vi.FileVersionRaw.ToString()
$Revision = $vi.FilePrivatePart

if (-not $Version -or $Version -eq "0.0.0.0") {
    Write-Error "Could not read version from $ExePath"
    exit 1
}

# ── Get git commit ────────────────────────────────────────────────
$Commit = git -c safe.directory=$RepoDir -C $RepoDir rev-parse --short HEAD
if ($LASTEXITCODE -ne 0) {
    Write-Error "Failed to get git commit hash."
    exit 1
}

# ── Compute SHA-256 ───────────────────────────────────────────────
$Sha256 = (Get-FileHash -Algorithm SHA256 $ExePath).Hash.ToLower()

# ── Generate manifest.json ────────────────────────────────────────
$ManifestPath = Join-Path (Split-Path $ExePath) "manifest.json"

$manifest = @{
    enabled       = $true
    channel       = $Channel
    version       = $Version
    revision      = [int]$Revision
    commit        = $Commit
    filename      = $Filename
    package_type  = "exe"
    sha256        = $Sha256
    mandatory     = [bool]$Mandatory
    release_notes = $Notes
} | ConvertTo-Json -Depth 1

[System.IO.File]::WriteAllText($ManifestPath, $manifest, (New-Object System.Text.UTF8Encoding $false))

Write-Host "── manifest.json ──" -ForegroundColor Cyan
Write-Host $manifest
Write-Host ""

# ── Deploy to server ──────────────────────────────────────────────
Write-Host "Uploading $Filename + manifest.json to ${RemoteHost}:${RemoteDir} ..." -ForegroundColor Cyan
scp -P $RemotePort $ExePath $ManifestPath "${RemoteUser}@${RemoteHost}:${RemoteDir}/"

if ($LASTEXITCODE -ne 0) {
    Write-Error "SCP failed."
    exit 1
}

Write-Host ""
Write-Host "Done. Version $Version (rev $Revision, commit $Commit) deployed." -ForegroundColor Green
