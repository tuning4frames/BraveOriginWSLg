#!/bin/bash
# Brave Origin Nightly setup: runs once inside linbox-Brave after provisioning.
# Idempotent: re-running short-circuits if already installed.
#
# All output is tee'd to /root/.vnc/setup.log so the Logs tab in the app UI
# can show the full install transcript.
#
# Ordering is deliberate:
#   1. preflight (connectivity + disk + WSLg)
#   2. apt-get update + install base packages (curl, ca-certificates, audio)
#   3. THEN use curl to grab the Brave keyring and .deb
#
# NATIVE MODE: This build runs Brave as a native WSLg window. The VNC stack
# (tigervnc / novnc / websockify / openbox) is intentionally NOT installed :
# WSLg provides the display, so those packages would be dead weight.
set -e

mkdir -p /root/.vnc
exec > >(tee -a /root/.vnc/setup.log) 2>&1
echo "[brave/setup] === $(date -Iseconds) ==="

# --- fast short-circuit if already installed --------------------------------
if [ -f /opt/.brave-installed ] && command -v brave-origin-nightly >/dev/null 2>&1; then
    echo "[brave/setup] already installed: $(brave-origin-nightly --version)"
    exit 0
fi

# --- preflight: WSLg (GUI support) ------------------------------------------
# WSLg mounts /mnt/wslg into the distro. That directory's presence is the
# reliable signal that the GUI stack is available (DISPLAY/WAYLAND_DISPLAY are
# only exported into interactive shells, so we don't gate on them here). If
# /mnt/wslg is missing, Brave has no display to attach to. We warn loudly but
# do NOT hard-fail: the user may still be mid-install (wsl --update pending).
echo "[brave/setup] preflight: checking WSLg GUI support ..."
if [ -d /mnt/wslg ]; then
    echo "[brave/setup] preflight: WSLg OK (/mnt/wslg present)"
else
    echo "[brave/setup] WARNING: WSLg GUI support not detected (/mnt/wslg missing)."
    echo "[brave/setup]   Brave needs a display. On Windows, run 'wsl --update' and"
    echo "[brave/setup]   relaunch. (WSLg ships with current WSL on Win10 21H2+/Win11.)"
fi

# --- preflight: connectivity ------------------------------------------------
echo "[brave/setup] preflight: checking connectivity to api.github.com ..."
if command -v curl >/dev/null 2>&1; then
    if ! curl -fsS --max-time 5 https://api.github.com/zen >/dev/null 2>&1; then
        echo "[brave/setup] ERROR: api.github.com is unreachable."
        echo "[brave/setup]        This app needs GitHub access on first launch"
        echo "[brave/setup]        to download Brave Origin Nightly (~120 MB)."
        echo "[brave/setup]        Reconnect and try again."
        exit 2
    fi
else
    if ! (exec 3<>/dev/tcp/api.github.com/443) 2>/dev/null; then
        echo "[brave/setup] ERROR: cannot reach api.github.com on 443."
        echo "[brave/setup]        This app needs GitHub access on first launch"
        echo "[brave/setup]        to download Brave Origin Nightly (~120 MB)."
        echo "[brave/setup]        Reconnect and try again."
        exit 2
    fi
    exec 3>&- 3<&-
fi
echo "[brave/setup] preflight: connectivity OK"

# --- preflight: disk space --------------------------------------------------
avail_kb=$(df --output=avail / 2>/dev/null | tail -1 | tr -d ' ')
if [ -n "$avail_kb" ] && [ "$avail_kb" -lt 2000000 ]; then
    avail_mb=$((avail_kb / 1024))
    echo "[brave/setup] ERROR: less than 2 GB free on / (only ${avail_mb} MB)."
    echo "[brave/setup]        Brave + deps need ~1.5 GB. Free some space and retry."
    exit 2
fi
echo "[brave/setup] preflight: disk space OK"

export DEBIAN_FRONTEND=noninteractive

# --- apt-get: base packages only (NO VNC stack) -----------------------------
# Native mode needs: curl + ca-certificates (downloads), PulseAudio client
# libs (sound via WSLg's PulseServer), and psmisc (fuser/pkill for stop.sh).
echo "[brave/setup] installing base packages (curl, ca-certificates, PulseAudio client)"
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
    curl ca-certificates \
    libpulse0 pulseaudio-utils libasound2-plugins \
    psmisc

# --- Brave nightly apt repo + keyring ---------------------------------------
echo "[brave/setup] adding Brave nightly apt repo (for brave-keyring dependency)"
curl -fsSL https://brave-browser-apt-nightly.s3.brave.com/brave-browser-nightly-archive-keyring.gpg \
    -o /usr/share/keyrings/brave-browser-nightly-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/brave-browser-nightly-archive-keyring.gpg arch=amd64] https://brave-browser-apt-nightly.s3.brave.com/ stable main" \
    > /etc/apt/sources.list.d/brave-browser-nightly.list
apt-get update -qq
apt-get install -y -qq brave-keyring

# --- Brave Origin Nightly .deb --------------------------------------------
# Prefer a local .deb copied in by Setup.ps1 (downloaded on the Windows side
# with real MB progress); otherwise fetch the latest from GitHub Releases.
LOCAL_DEB=$(ls /opt/app/brave-origin-nightly_*.deb /opt/app/*.deb 2>/dev/null | head -1)
if [ -n "$LOCAL_DEB" ]; then
    echo "[brave/setup] using local Brave .deb copied in by Setup.ps1: $LOCAL_DEB"
    apt-get install -y "$LOCAL_DEB"
else
    echo "[brave/setup] fetching latest brave-origin-nightly amd64 .deb from GitHub"
    BRAVE_URL=$(curl -fsSL "https://api.github.com/repos/brave/brave-browser/releases?per_page=30" \
        | grep -oE 'https://[^"]+brave-origin-nightly_[0-9.]+_amd64\.deb' \
        | head -1)
    if [ -z "$BRAVE_URL" ]; then
        echo "[brave/setup] ERROR: could not locate brave-origin-nightly .deb on GitHub." >&2
        echo "[brave/setup]        Either GitHub's API rate-limited this IP or Brave moved the release." >&2
        exit 1
    fi
    echo "[brave/setup] downloading $BRAVE_URL"
    curl -fL --progress-bar -o /tmp/brave.deb "$BRAVE_URL"
    apt-get install -y /tmp/brave.deb
    rm -f /tmp/brave.deb
fi

# --- COPY MODE hardening (Windows-side self-heal) --------------------------
# WSLg runs weston (the RDP compositor) in the SYSTEM distro. Its
# /mnt/shared_memory (a virtiofs mount) intermittently fails with
# "Input/output error", forcing weston into [WARN:COPY MODE] (the window
# renders via the slow RDP pixel path). A weston-only restart just re-mounts
# the same broken virtiofs and does NOT help; the only reliable cure is a
# clean WSLg reset (wsl --shutdown), which re-initializes the virtiofs from a
# fresh state.
#
# That reset is performed automatically by the Windows-side launcher
# Start-BraveOrigin.ps1: it launches Brave, inspects the live window title
# for "[WARN:COPY MODE]", and if found resets WSLg and relaunches.
#
# fix-shm.sh (copied into /opt/app by Setup.ps1) is a harmless user-distro
# compat shim: it only ensures a tmpfs at the user distro's /mnt/shared_memory
# (which does NOT affect weston). We still register it at boot via /etc/wsl.conf
# so the shim is present early; it deliberately does NOT touch the system
# distro or restart weston.
if [ -f /opt/app/fix-shm.sh ]; then
    chmod +x /opt/app/fix-shm.sh
    cat > /etc/wsl.conf <<'EOF'
[boot]
command = /opt/app/fix-shm.sh
EOF
    echo "[brave/setup] boot shim: /etc/wsl.conf -> /opt/app/fix-shm.sh"
else
    echo "[brave/setup] WARNING: /opt/app/fix-shm.sh missing; boot shim skipped"
fi

touch /opt/.brave-installed
echo "[brave/setup] done: $(brave-origin-nightly --version)"
