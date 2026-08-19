<#
  .SYNOPSIS
     Windows-side launcher for Brave Origin (native WSLg), with self-heal
     for the known [WARN:COPY MODE] rendering bug.

  .DESCRIPTION
     WSLg runs weston (the RDP compositor) inside the SYSTEM distro. Its
     /mnt/shared_memory (a virtiofs mount) intermittently fails with
     "Input/output error", forcing weston into RAIL/COPY MODE (windows render
     via the slow RDP pixel path). The only reliable cure is a CLEAN WSLg
     reset (wsl --shutdown), which re-initializes the virtiofs mount from a
     fresh state. A weston-only restart just re-mounts the same broken
     virtiofs, so it does NOT help - this is why we reset the whole WSLg.

     This launcher starts Brave, then inspects the live window title for
     "[WARN:COPY MODE]". If present, it resets WSLg and relaunches. A healthy
     session is never disrupted.
#>
$ErrorActionPreference = 'Stop'

$appDir   = Split-Path -Parent $MyInvocation.MyCommand.Definition
$braveExe = Join-Path $appDir 'Brave.exe'
$distro   = 'linbox-Brave'
$maxRepair = 2

Add-Type @"
using System; using System.Runtime.InteropServices; using System.Text;
public class WinApi {
  public delegate bool CB(IntPtr h, IntPtr p);
  [DllImport("user32.dll")] public static extern bool EnumWindows(CB f, IntPtr p);
  [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
}
"@

function Start-App {
    if (Test-Path $braveExe) {
        Start-Process -FilePath $braveExe
    } else {
        # Dev fallback: this checkout has no Brave.exe, so start the distro directly.
        & wsl -d $distro -u root /bin/bash -lc "setsid bash /opt/app/start.sh >/root/.vnc/start-outer.log 2>&1 </dev/null & sleep 2"
    }
}

function Test-CopyMode {
    $global:titles = New-Object System.Collections.ArrayList
    $global:cb = {
        param($h, $p)
        if ([WinApi]::IsWindowVisible($h)) {
            $s = New-Object System.Text.StringBuilder 2048
            [WinApi]::GetWindowText($h, $s, 2048) | Out-Null
            $t = $s.ToString()
            if ($t.Trim() -ne '') { [void]$global:titles.Add($t) }
        }
        return $true
    }
    [WinApi]::EnumWindows($global:cb, [IntPtr]::Zero) | Out-Null
    foreach ($t in $global:titles) {
        if ($t -match '\[WARN:COPY MODE\]') { return $true }
    }
    return $false
}

function Reset-Wslg {
    Write-Host '[launcher] Resetting WSLg (wsl --shutdown)...'
    & wsl --shutdown
    Start-Sleep -Seconds 6
}

# --- main ---
Write-Host '[launcher] Starting Brave Origin...'
Start-App
Start-Sleep -Seconds 12

if (-not (Test-CopyMode)) {
    Write-Host '[launcher] OK: WSLg running in VAIL mode (no COPY MODE).'
    exit 0
}

Write-Host '[launcher] COPY MODE detected.'
for ($i = 1; $i -le $maxRepair; $i++) {
    Reset-Wslg
    Write-Host "[launcher] Relaunch attempt $i..."
    Start-App
    Start-Sleep -Seconds 14
    if (-not (Test-CopyMode)) {
        Write-Host '[launcher] COPY MODE cleared after reset.'
        exit 0
    }
    Write-Host '[launcher] Still COPY MODE; retrying reset...'
}
Write-Warning '[launcher] COPY MODE persisted after reset. A full Windows reboot may be required.'
