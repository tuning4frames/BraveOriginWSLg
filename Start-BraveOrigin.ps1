<#
 .SYNOPSIS
    Windows-side launcher for Brave Origin (native WSLg).

    Applies the WSLg shared-memory fix, then starts Brave.exe.

 .DESCRIPTION
    WSLg's system-distro /mnt/shared_memory (a virtiofs mount) intermittently
    fails with "Input/output error", which forces weston into [WARN:COPY MODE]
    (windows render blank: only a taskbar icon shows). The fix MUST run from
    Windows (wsl --system) because wsl.exe invoked from inside the user distro
    runs in an isolated namespace and cannot touch the real system distro.

    This script remounts a tmpfs at /mnt/shared_memory in the system distro and
    restarts weston, then launches Brave.exe (which starts the linbox-Brave
    distro and shows the manager UI). The fix only runs when shared memory is
    actually broken, so a healthy session is never disrupted.
#>
$ErrorActionPreference = 'Stop'

$appDir   = Split-Path -Parent $MyInvocation.MyCommand.Definition
$braveExe = Join-Path $appDir 'Brave.exe'

# 1. Fix WSLg shared memory only when it is actually broken.
$rc = & wsl --system -u root /bin/bash -lc 'ls /mnt/shared_memory >/dev/null 2>&1; echo $?'
if ($rc.Trim() -ne '0') {
    Write-Host '[launcher] /mnt/shared_memory broken; remounting tmpfs + restarting weston'
    & wsl --system -u root /bin/bash -lc 'umount /mnt/shared_memory 2>/dev/null; umount /mnt/shared_memory 2>/dev/null; mount -t tmpfs tmpfs /mnt/shared_memory'
    & wsl --system -u root /bin/bash -lc 'pgrep weston | xargs kill -9'
    Start-Sleep -Seconds 5
} else {
    Write-Host '[launcher] /mnt/shared_memory OK; no fix needed'
}

# 2. Launch Brave.exe (starts the distro + shows the manager UI).
if (Test-Path $braveExe) {
    Start-Process -FilePath $braveExe
} else {
    Write-Warning "Brave.exe not found in: $appDir"
}
