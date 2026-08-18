#!/bin/bash
# Mount /mnt/shared_memory as tmpfs if it isn't already.
#
# WSLg needs a tmpfs at /mnt/shared_memory, otherwise the compositor (weston)
# falls back to [WARN:COPY MODE] and renders nothing (a taskbar icon only).
# This runs at distro boot via /etc/wsl.conf [boot] and is also a fallback in
# launch-brave.sh, so the window always has real shared memory available.
if ! mountpoint -q /mnt/shared_memory 2>/dev/null; then
    mkdir -p /mnt/shared_memory
    if mount -t tmpfs -o size=256M tmpfs /mnt/shared_memory 2>/dev/null; then
        echo "$(date -Iseconds) ensure-shm: mounted tmpfs at /mnt/shared_memory" >> /var/log/ensure-shm.log
    else
        echo "$(date -Iseconds) ensure-shm: FAILED to mount tmpfs at /mnt/shared_memory" >> /var/log/ensure-shm.log
    fi
else
    echo "$(date -Iseconds) ensure-shm: /mnt/shared_memory already mounted" >> /var/log/ensure-shm.log
fi
