@echo off
setlocal
set "APP=%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%APP%Start-BraveOrigin.ps1"
endlocal
