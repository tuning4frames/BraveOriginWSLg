# Rebuild Brave.zip from the contents of this folder.
# Writes the zip to the PARENT directory (next to other app folders).
#
# Usage:   powershell -ExecutionPolicy Bypass -File .\build-zip.ps1

$src   = $PSScriptRoot
$out   = Join-Path (Split-Path $src -Parent) 'Brave.zip'
$stage = Join-Path $env:TEMP ('Brave-zip-' + [Guid]::NewGuid().ToString('N'))

if (Test-Path $out)   { Remove-Item $out -Force }
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }

# Stage a clean copy: whitelist only runtime files. Dev tooling
# (.gitignore, build-zip.ps1) is deliberately excluded, and
# transient state (wsl/, cache/, __pycache__/, *.log, rootfs.tar.gz) never
# gets a chance to be picked up.
$dst = Join-Path $stage 'Brave'
New-Item -ItemType Directory -Path $dst               -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $dst 'linux') -Force | Out-Null

$files = @(
    'app.json',
    'Brave.exe',
    'brave.ico',
    'bridge.py',
    'control.py',
    'fix-shm.sh',
    'index.html',
    'LICENSE',
    'MANUAL_SETUP.md',
    'README.md',
    'setup.sh',
    'setup-core.ps1',
    'Setup.ps1',
    'Start-BraveOrigin.cmd',
    'Start-BraveOrigin.ps1',
    'Test-Setup.ps1',
    'start.sh',
    'stop.sh',
    'update.sh',
    'webview.dll'
)

$missing = @()
foreach ($f in $files) {
    $srcPath = Join-Path $src $f
    if (Test-Path $srcPath) {
        Copy-Item $srcPath (Join-Path $dst $f)
    } else {
        $missing += $f
    }
}

# README references no binary screenshots in this build (kept out of the repo
# for now); nothing to copy here. The Ubuntu rootfs below is still required.

$base = Join-Path $src 'linux\ubuntu-base.tar.gz'
if (Test-Path $base) {
    Copy-Item $base (Join-Path $dst 'linux\ubuntu-base.tar.gz')
} else {
    $missing += 'linux\ubuntu-base.tar.gz'
}

if ($missing.Count -gt 0) {
    Remove-Item $stage -Recurse -Force
    $msg = "Cannot build Brave.zip - missing files:`n  " + ($missing -join "`n  ")
    $msg += "`n`nIf you only have a git clone, download the latest Brave.zip"
    $msg += " from Releases and copy Brave.exe, webview.dll, and"
    $msg += " linux/ubuntu-base.tar.gz into this folder."
    Write-Error $msg
    exit 1
}

Compress-Archive -Path (Join-Path $dst '*') -DestinationPath $out -CompressionLevel Optimal
Remove-Item $stage -Recurse -Force

$info = Get-Item $out
Write-Host ("out : {0}" -f $info.FullName)
$sizeMb = [math]::Round($info.Length / 1MB, 2)
Write-Host ("size: {0} MB ({1} bytes)" -f $sizeMb, $info.Length)
