#!/bin/bash
# fix-shm.sh - user-distro shared-memory compat shim (harmless).
#
# IMPORTANT: This does NOT fix [WARN:COPY MODE]. That bug lives in the SYSTEM
# distro's /mnt/shared_memory (a virtiofs mount) and only a clean WSLg reset
# (wsl --shutdown) clears it - handled by the Windows launcher
# Start-BraveOrigin.ps1, which detects COPY MODE via the window title and
# resets WSLg if needed. A weston-only restart just re-mounts the same broken
# virtiofs, so it does not help and is intentionally avoided here.
#
# The user distro's own /mnt/shared_memory is a SEPARATE mount from the one
# weston uses, so this shim exists only for application compatibility and has
# no effect on weston. Background: microsoft/wslg#1456, microsoft/WSL#40618.

user_shim() {
    if ! mountpoint -q /mnt/shared_memory 2>/dev/null; then
        mkdir -p /mnt/shared_memory
        mount -t tmpfs -o size=256M tmpfs /mnt/shared_memory 2>/dev/null
    fi
}

user_shim
exit 0
