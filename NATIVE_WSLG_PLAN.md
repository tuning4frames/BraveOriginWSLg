# Brave Origin for Windows: Native WSLg Rewrite Plan

> Goal: drop the slow, VNC-based integrated launcher and run Brave Origin Nightly as a
> **native WSLg window**, with Logs / Terminal / Settings in a separate small window.
> Priorities: **fast and working** over a pretty all-in-one launcher.

## STATUS: IMPLEMENTED (2026-08-17)
All Linux-side scripts + UI rewritten in `brave-origin-native/`:
- `setup.sh`: no VNC stack; WSLg preflight added.
- `start.sh`: launches Brave natively + `control.py`; no Xtigervnc/openbox/websockify/iptables-mirror.
- `launch-brave.sh`: shared Brave invocation (GPU enabled).
- `stop.sh`: drops VNC refs; kills brave + control (9612).
- `control.py`: serves `index.html` at `/`, adds `/api/brave/status` + `/api/brave/launch`, drops VNC logs.
- `bridge.py`: simplified to a redirect to `control.py:9612` (no DISTRO_IP hacks).
- `index.html`: VNC pane replaced by a Brave status/Launch panel.
- `app.json`: `port` = 9612 (manager UI).
- `README.md` + `MANUAL_SETUP.md`: native-mode docs.
- `build-zip.ps1`: now includes `launch-brave.sh`.
TODO: the Windows `.exe` (portable-linux-in-a-box) rebuild is the only remaining piece: it belongs to the template.

## Context / Why

Current design (`start.sh`, `bridge.py`) runs Brave inside `Xtigervnc` (VNC framebuffer)
with `--disable-gpu` (software rendering), then VNC-encodes → `websockify` → WebSocket →
browser canvas inside a WebView2 tab. Problems:

- No GPU (software render only): `start.sh:215` `--disable-gpu`.
- Heavy frame path: capture + encode + socket + JS decode + WebView2 repaint.
- Fragile WSL2 localhost forwarding (`bridge.py` documents `ERR_EMPTY_RESPONSE` race).
- An `iptables` mirror-guard (`start.sh:21-43`) exists only to stop Brave loading its own
  loopback UI: a problem created by the embedding approach.

WSLg gives Brave a native Wayland/XWayland surface with **GPU-PV acceleration**, composited
directly by Windows (RDP). No VNC, no WebSocket, no browser canvas. Audio already uses
WSLg's PulseServer today, so unchanged.

## Decisions (from discussion)

1. **Drop the integrated tabbed launcher.** Brave = its own native window. Logs/Terminal/
   Settings = a separate management window (the existing `control.py` sidecar on `9612`).
2. **Use WSLg, not noVNC.** Remove the entire VNC stack (Xtigervnc, openbox, novnc,
   websockify) from setup and start.
3. **Break the "no admin rights" promise.** New rule:
   - If WSL2 + WSLg + WebView2 are **already present** → silent, **no elevation**.
   - If missing → installer elevates *only* to run `wsl --install` / `wsl --update` + reboot,
     then resumes.
4. **Add a manual setup guide** (markdown) covering the exact same steps for users who
   prefer doing it by hand or who hit the UAC prompt.
5. **Keep Ubuntu (Debian-family).** Brave ships a native `.deb` + apt repo for
   Debian/Ubuntu; Alpine (musl) is incompatible; Fedora/Arch add friction for no gain.
   Ubuntu is also the best WSLg-tested distro. Keep the existing minimal
   `ubuntu-base.tar.gz` rootfs.

## Implementation Steps

### 1. `setup.sh`: Brave-only, WSLg-aware
- **Remove** from the apt install (`setup.sh:71-78`): `tigervnc-standalone-server`,
  `tigervnc-common`, `novnc`, `websockify`, `openbox`, `xterm`, `xauth`, `x11-utils`.
  Keep: `curl ca-certificates`, PulseAudio client libs (`libpulse0 pulseaudio-utils
  libasound2-plugins`), `iptables psmisc` (psmisc still useful for stop.sh; iptables can
  be dropped unless reused for something else).
- Keep the Brave nightly apt repo + keyring (`setup.sh:80-91`) and the GitHub `.deb`
  download (`setup.sh:93-106`).
- **Add WSLg preflight**: after distro import, verify GUI support is available:
  - `WAYLAND_DISPLAY` set and/or `/mnt/wslg` mounted (run via `wsl -e`).
  - If absent, print a clear message: enable/upgrade WSL (`wsl --update`) and relaunch.
- Keep preflights: connectivity to `api.github.com` (`setup.sh:33-52`), disk ≥ 2 GB
  (`setup.sh:54-64`).
- Keep idempotency short-circuit (`setup.sh:22-26`).

### 2. `start.sh`: native Brave launch
- **Remove** `Xtigervnc` launch (`start.sh:129-148`), `openbox` (`start.sh:150-152`),
  `websockify` exec (`start.sh:249`), and the `iptables` mirror-guard (`start.sh:21-43`).
- **Remove** the session/cache "mirror scrub" block (`start.sh:154-199`): no loopback UI
  to protect anymore.
- **Keep** `ensure_audio_support()` (`start.sh:52-107`): WSLg PulseServer audio stays.
- **Launch Brave natively** on WSLg's display:
  - Rely on `$WAYLAND_DISPLAY` / `$DISPLAY` (WSLg sets these automatically).
  - **Remove** `--disable-gpu` and `--disable-features=UseOzonePlatform`
    (`start.sh:215-217`) so GPU acceleration is used. Optionally add
    `--ozone-platform=wayland` (or let Chromium auto-detect); keep
    `--no-sandbox --test-type --no-first-run --no-default-browser-check
    --disable-session-crashed-bubble --disable-dev-shm-usage --user-data-dir=/root/brave-data`.
- **Keep** `control.py` sidecar on `9612` (`start.sh:227`) for Logs/Terminal/Settings.
- Keep `echo $$ > /run/brave.pid` + stop.sh tree-kill compatibility.

### 3. Windows-side setup GUI (PowerShell) with progress bar
- A front-end (PowerShell, or fed into the `portable-linux-in-a-box` `.exe` template)
  showing a simple window + progress bar with stages:
  1. **Preflight** (no elevation): WSL2 (`wsl --version`), WSLg (boot distro, check
     `/mnt/wslg`/`WAYLAND_DISPLAY`), WebView2 runtime, disk ≥ 2 GB, internet.
  2. **If WSL/WSLg missing** → elevate (UAC) and run `wsl --install` (Win11) or
     `wsl --update` + enable features, then reboot; resume after reboot.
  3. **Import** Ubuntu rootfs (`wsl --import linbox-Brave ... ubuntu-base.tar.gz`).
  4. **Setup** → run `setup.sh` (apt + Brave `.deb`).
  5. **Launch** → run `start.sh`; Brave appears as a native window; open the management
     window (control.py UI on `9612`).
- Progress bar maps to stages above.
- **Only elevate when actually needed** (step 2). If everything present, run fully
  un-elevated.

### 4. `app.json` / `bridge.py` adjustments
- `app.json`: `port` should point at the `control.py` management UI (`9612`), not the old
  noVNC `9611`. Remove VNC-specific width/height (native window sizes itself) or repurpose
  for the management window.
- `bridge.py`: **simplify**: remove `DISTRO_IP` / `get_distro_ip()` localhost-forwarding
  hacks (the whole `ERR_EMPTY_RESPONSE` mitigation). It only needs to serve/redirect to the
  management UI on `9612`, or the launcher can navigate directly. Keep SIGTERM → stop.sh.

### 5. README + Manual Guide
- Update README "How it works" diagram: Brave → WSLg native window; management UI →
  control.py `9612`. Remove VNC/TigerVNC/noVNC/websockify mentions.
- Update Requirements: WSL2 **with WSLg**; note admin is only required if WSL/WSLg must be
  installed; provide the manual step-by-step guide (enable WSL, `wsl --update`, import
  rootfs, run `setup.sh`, launch Brave) as a separate section / `MANUAL_SETUP.md`.
- Update Known limitations / Troubleshooting (drop VNC-specific rows; add WSLg-specific
  checks like "Brave opens off-screen / blank → confirm `/mnt/wslg` present, `wsl --update`").

## Open Scope Notes
- Building the actual Windows GUI **binary** (`.exe`) lives in the
  `portable-linux-in-a-box` template and needs compiling there. This plan covers the
  Linux-side scripts (`setup.sh`, `start.sh`, `control.py` wiring) and a PowerShell setup
  GUI; the `.exe` rebuild is delegated to that template (rename + icon stamp, as today).
- GPU in WSLg for Chromium: should work via ANGLE/D3D through XWayland or native Wayland;
  verify after first native run (check `chrome://gpu`).

## Acceptance / Verification
- Fresh machine, WSLg already present: launch with **no UAC prompt**, Brave opens as a
  native Windows window, smooth scrolling, GPU active in `chrome://gpu`, audio works.
- Management window shows live Logs, a working Terminal, and Settings.
- Machine without WSL: launcher prompts UAC, installs/updates WSL + WSLg, reboots, resumes,
  then same result.
- `MANUAL_SETUP.md` reproduces the above by hand.
