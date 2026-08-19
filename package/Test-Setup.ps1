<#
.SYNOPSIS
    Headless self-test for the Brave Origin setup logic (no GUI).
    Runs all preflight checks and prints results. Useful to verify detection
    on any machine without clicking through the GUI.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File Test-Setup.ps1
#>

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'setup-core.ps1')

Write-Host "=== Brave Origin setup - preflight self-test ===" -ForegroundColor Cyan
$r = Get-Preflight

Write-Host ("WSL2 installed:        {0}" -f $(if ($r.WSL2) { 'YES' } else { 'NO' }))
Write-Host ("WSLg (GUI) available:  {0}" -f $(if ($r.WSLg) { 'YES' } else { 'NO' }))
Write-Host ("WebView2 runtime:      {0}" -f $(if ($r.WebView2) { 'YES' } else { 'NO' }))
Write-Host ("Disk free (C:) >=1.5G: {0}" -f $(if ($r.Disk) { 'YES' } else { 'NO' }))
Write-Host ("Internet (github):     {0}" -f $(if ($r.Internet) { 'YES' } else { 'NO' }))
Write-Host ("Running as admin:      {0}" -f $(if (Test-Admin) { 'YES' } else { 'NO' }))
Write-Host ("Needs admin install:   {0}" -f $(if ($r.NeedAdmin) { 'YES' } else { 'NO' }))
Write-Host ("Distro '$distroName' exists: {0}" -f $(if (Distro-Exists) { 'YES' } else { 'NO' }))
Write-Host ("Rootfs present:        {0}" -f $(if (Test-Path $rootfs) { 'YES' } else { 'NO' }))
Write-Host "=== Done (no errors) ===" -ForegroundColor Green
