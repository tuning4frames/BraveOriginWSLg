<#
.SYNOPSIS
    Shared logic for the Brave Origin (native WSLg) setup.
    Dot-sourced by Setup.ps1 (GUI) and Test-Setup.ps1 (headless test).

    Contains only pure functions + helpers — no Windows.Forms, no GUI — so it
    can be imported and exercised without a display.
#>

$distroName = "linbox-Brave"
$appDir     = $PSScriptRoot
$rootfs     = Join-Path $appDir "linux\ubuntu-base.tar.gz"
$installLoc = Join-Path $env:USERPROFILE "brave-distro"
$braveExe   = Join-Path $appDir "Brave.exe"

function ConvertTo-WslPath($p) {
    $p = $p.Replace('\', '/')
    if ($p -match '^([A-Za-z]):(.*)$') {
        return '/mnt/' + $Matches[1].ToLower() + $Matches[2]
    }
    return $p
}

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $pr = New-Object Security.Principal.WindowsPrincipal($id)
    return $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-WSL2 {
    try {
        # wsl.exe emits UTF-16 with embedded NUL bytes; also strip any other
        # non-ASCII/control chars in case output encoding differs (e.g. GUI host).
        $v = & wsl --version 2>$null
        $s = ($v -join "`n") -replace "`0", '' -replace '[^\x20-\x7E]', ''
        return $s -match 'WSL version'
    } catch { return $false }
}

function Test-WSLg {
    try {
        $v = & wsl --version 2>$null
        $s = ($v -join "`n") -replace "`0", '' -replace '[^\x20-\x7E]', ''
        return $s -match 'WSLg version'
    } catch { return $false }
}

function Test-WebView2 {
    $paths = @(
        'C:\Program Files (x86)\Microsoft\EdgeWebView\Application',
        'C:\Program Files\Microsoft\EdgeWebView\Application'
    )
    foreach ($p in $paths) { if (Test-Path $p) { return $true } }
    if (Get-ItemProperty -Path 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}' -ErrorAction SilentlyContinue) {
        return $true
    }
    return $false
}

function Test-Disk {
    try {
        $free = (Get-PSDrive C).Free / 1GB
        return $free -ge 1.5
    } catch { return $false }
}

function Test-Internet {
    # Fast TCP connect probe (max ~4s) instead of Test-NetConnection,
    # which can stall 10-30s on slow DNS and makes preflight feel hung.
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $iar = $tcp.BeginConnect('api.github.com', 443, $null, $null)
        $ok  = $iar.AsyncWaitHandle.WaitOne(4000)
        if ($ok) { $tcp.EndConnect($iar) }
        $tcp.Close()
        return $ok
    } catch { return $false }
}

function Distro-Exists {
    try {
        $list = & wsl --list --quiet 2>$null
        $clean = $list | ForEach-Object { ($_ -replace "`0", '').Trim() }
        return $clean -contains $distroName
    } catch { return $false }
}

function Invoke-WslInDistro($script) {
    & wsl -d $distroName -e bash -lc $script
}

# Returns a hashtable of all preflight results (used by GUI + tests).
function Get-Preflight {
    return [ordered]@{
        WSL2     = Test-WSL2
        WSLg     = Test-WSLg
        WebView2 = Test-WebView2
        Disk     = Test-Disk
        Internet = Test-Internet
        NeedAdmin = (-not (Test-WSL2)) -or (-not (Test-WSLg))
    }
}
