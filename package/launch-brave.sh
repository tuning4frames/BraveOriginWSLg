#!/bin/bash
# launch-brave.sh: start Brave Origin Nightly as a NATIVE WSLg window.
#
# Used by start.sh on boot and by the management UI's "Launch / Relaunch"
# button (control.py -> POST /api/brave/launch). Kept separate so both
# code paths share the exact same flags.
#
# WSLg exports DISPLAY (XWayland at /mnt/wslg/X0) and WAYLAND_DISPLAY into the
# environment automatically, so we rely on those. Brave is Chromium: it talks
# to WSLg over X11/XWayland (GPU acceleration works through ANGLE/D3D), so we
# deliberately do NOT pass --disable-gpu: that's the whole point of going
# native.
set -e

export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/mnt/wslg/runtime-dir}

# Belt-and-suspenders: if WSLg didn't export DISPLAY, point at its socket.
if [ -z "$DISPLAY" ] && [ -S /mnt/wslg/.X11-unix/X0 ]; then
    export DISPLAY=:0
fi

mkdir -p /root/brave-data /root/.vnc /mnt/shared_memory
# Compat shim: ensure the user distro has a tmpfs at /mnt/shared_memory. This is
# a SEPARATE mount from the SYSTEM distro's /mnt/shared_memory that weston
# actually uses, so it does not affect weston - it only satisfies X11 clients
# that probe the path.
if ! mountpoint -q /mnt/shared_memory 2>/dev/null; then
    mount -t tmpfs tmpfs /mnt/shared_memory 2>/dev/null
fi

# Wait for the WSLg display to be ready before opening the window. A window
# created while weston is still initializing can latch into [WARN:COPY MODE];
# once latched, only a fresh window against a ready display clears it. (The
# actual COPY MODE cure is a clean WSLg reset performed by the Windows-side
# Start-BraveOrigin.ps1 if it detects the mode at launch.)
for i in $(seq 1 15); do
    if [ -n "$DISPLAY" ] && [ -S /mnt/wslg/.X11-unix/X0 ]; then
        break
    fi
    sleep 1
done

# If Brave is already running, don't spawn a second instance.
# Use -f: the process comm is truncated to "brave-origin-ni" (15-char limit),
# so -x (exact comm match) never matches the real "brave-origin-nightly".
if pgrep -f brave-origin-nightly >/dev/null 2>&1; then
    echo "[launch-brave] already running; not starting a second instance"
    exit 0
fi

# Clear any stale singleton lock left behind by a previously killed instance.
# Without this, the new Brave sees SingletonLock and bails with
# "Opening in existing browser session" instead of opening a window.
rm -f /root/brave-data/SingletonLock /root/brave-data/SingletonSocket 2>/dev/null

echo "[launch-brave] DISPLAY=${DISPLAY:-<unset>} WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-<unset>}"
echo "[launch-brave] launching brave-origin-nightly (native WSLg window)"

exec brave-origin-nightly \
    --no-sandbox \
    --test-type \
    --no-first-run \
    --no-default-browser-check \
    --disable-session-crashed-bubble \
    --disable-dev-shm-usage \
    --window-size=1280,800 \
    --user-data-dir=/root/brave-data \
    > /root/.vnc/brave.log 2>&1
