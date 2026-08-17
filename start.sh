#!/bin/bash
# Brave Origin Nightly start (NATIVE WSLg mode).
#
# Launches:
#   1. Brave Origin Nightly as a NATIVE WSLg window  (launch-brave.sh)
#   2. control.py sidecar on 9612  (Logs / Terminal / Settings UI API)
#
# There is NO VNC server, no openbox, no websockify. WSLg gives Brave a real
# Wayland/XWayland display with GPU acceleration; the management UI is a
# separate web window served by control.py (and reached via bridge.py).
#
# Every service's output is redirected to its own file in /root/.vnc/ so the
# app's Logs tab can show everything that's happening.
mkdir -p /root/.vnc /opt/brave-ui /run

# Start-script output itself goes to start.log so the Logs tab sees boot steps.
exec > >(tee -a /root/.vnc/start.log) 2>&1
echo
echo "[brave/start] === $(date -Iseconds) ==="

# Belt-and-suspenders cleanup of anything left behind from a previous run.
pkill -9 -f brave-origin-nightly 2>/dev/null || true
fuser -k 9612/tcp 2>/dev/null || true
sleep 1

# Configure browser audio through WSLg's PulseAudio bridge when available.
ensure_audio_support() {
    if [ ! -S /mnt/wslg/PulseServer ]; then
        echo "[brave/start] audio: WSLg PulseAudio socket not found; browser sound unavailable"
        return
    fi

    export PULSE_SERVER=unix:/mnt/wslg/PulseServer
    export XDG_RUNTIME_DIR=/mnt/wslg/runtime-dir
    echo "[brave/start] audio: using $PULSE_SERVER"

    missing_audio_pkgs=""
    for pkg in libpulse0 pulseaudio-utils libasound2-plugins; do
        if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "install ok installed"; then
            missing_audio_pkgs="$missing_audio_pkgs $pkg"
        fi
    done

    if [ -n "$missing_audio_pkgs" ]; then
        echo "[brave/start] audio: installing missing packages:$missing_audio_pkgs"
        apt-get update -qq
        if ! apt-get install -y -qq --no-install-recommends $missing_audio_pkgs; then
            echo "[brave/start] WARNING: audio package install failed; browser sound may not work"
            return
        fi
    fi

    mkdir -p /etc/pulse/client.conf.d
    cat > /etc/pulse/client.conf.d/99-wslg.conf <<'EOF'
default-server = unix:/mnt/wslg/PulseServer
autospawn = no
EOF

    cat > /etc/asound.conf <<'EOF'
pcm.!default {
    type pulse
}

ctl.!default {
    type pulse
}
EOF

    if command -v pactl >/dev/null 2>&1; then
        if pactl info >/tmp/brave-pactl-info 2>&1; then
            pulse_server_name=$(awk -F': ' '/Server Name/ {print $2}' /tmp/brave-pactl-info | head -1)
            default_sink=$(pactl get-default-sink 2>/dev/null || true)
            echo "[brave/start] audio: PulseAudio reachable (${pulse_server_name:-unknown}, sink ${default_sink:-unknown})"
        else
            echo "[brave/start] WARNING: PulseAudio socket exists but pactl cannot connect"
            sed 's/^/[brave/start]   pactl: /' /tmp/brave-pactl-info 2>/dev/null || true
        fi
        rm -f /tmp/brave-pactl-info
    fi
}

ensure_audio_support

# Save our PID so stop.sh can walk the process tree from here.
echo $$ > /run/brave.pid
echo "[brave/start] pid=$$"

# Pull the fresh UI wrapper (tabs + banner) from the app folder so the author
# can edit index.html on disk and see changes on next start without re-running
# setup.sh. Stamp a per-launch API token into the staged copy so random
# localhost webpages cannot call the control sidecar.
API_TOKEN=$(od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')
if [ -z "$API_TOKEN" ]; then
    API_TOKEN="$(date +%s%N)"
fi
printf '%s' "$API_TOKEN" > /run/brave-api-token
chmod 600 /run/brave-api-token
sed "s|__BRAVE_API_TOKEN__|$API_TOKEN|g" /opt/app/index.html > /opt/brave-ui/index.html
echo "[brave/start] UI wrapper staged at /opt/brave-ui/index.html"

# Launch Brave as a native WSLg window (background — control.py is the
# long-running foreground service below).
echo "[brave/start] launching brave-origin-nightly (native window)"
bash /opt/app/launch-brave.sh &
sleep 2

# Control sidecar — /api/shutdown, /api/update, /api/logs, /api/settings,
# /api/brave/status, /api/brave/launch. Binds 0.0.0.0:9612 so the Windows-side
# WebView2 can reach it through WSL2's localhost forwarding.
echo "[brave/start] launching control sidecar on 9612"
python3 /opt/app/control.py 9612 > /root/.vnc/control.log 2>&1 &
CONTROL_PID=$!
sleep 1

echo "[brave/start] ========================================"
echo "[brave/start] SERVICES UP"
echo "[brave/start]   brave-origin-nightly  (native WSLg window)"
echo "[brave/start]   control.py            (management UI API on 9612)"
echo "[brave/start] ----"
echo "[brave/start] For ongoing output switch the Source dropdown to one of:"
echo "[brave/start]   brave    — Chromium stdout/stderr"
echo "[brave/start]   control  — sidecar API access log"
echo "[brave/start]   setup    — first-run install transcript"
echo "[brave/start]   start    — this boot log"
echo "[brave/start] ========================================"

# Keep this script alive so /run/brave.pid stays valid and the app is
# considered "running" until the user shuts it down (stop.sh kills the tree).
wait "$CONTROL_PID"
