# Brave Origin (Native WSLg)

> **Beta**: a personal project; more improvements are coming. Not affiliated with Brave Software, Inc.

Run **Brave Origin Nightly** as a real, native Windows window using **WSLg**: no
VNC, no RDP, GPU-accelerated: packaged as a portable Windows app with a small
manager UI (Logs / Terminal / Settings).

![beta](https://img.shields.io/badge/status-beta-orange)

## Why

Most "run Linux apps on Windows" setups pipe a Linux desktop through VNC or RDP
into a Windows window. That adds a whole desktop stack and usually looks and feels
wrong. WSLg already gives WSL distros a real Wayland/XWayland display with GPU
access, so a browser can just… be a window. This project wires that up for
**Brave Origin Nightly** and bundles a tiny manager so you can launch, stop,
watch logs, and update it without touching WSL by hand.

## Features

- **Native WSLg window** for Brave Origin Nightly (Wayland/XWayland, GPU-accelerated).
- **Portable & disposable**: a dedicated WSL distro (`linbox-Brave`), no `sudo`
  password prompts, easy to throw away.
- **Manager UI** (a WebView2 window) with **Logs**, **Terminal**, and **Settings** tabs.
- **Launch / Stop / Relaunch** Brave from the UI.
- **Auto-update check** for the latest `brave-origin-nightly` build.
- **Audio** through WSLg's PulseAudio bridge.

## Status: Beta

This is an early, beta-stage project. The core works (Brave runs as a native
window, the manager UI controls it), but expect rough edges. More improvements
are planned: see [Roadmap](#roadmap).

### Known limitations

- **WSLg `[WARN:COPY MODE]` quirk (self-healing).** WSLg runs the RDP
  compositor `weston` in the **system** distro. Its `/mnt/shared_memory`
  (`virtiofs` mount) intermittently fails with `Input/output error`, forcing
  weston into `[WARN:COPY MODE]` (the window renders via the slow RDP pixel
  path). A weston-only restart just re-mounts the *same* broken virtiofs, so it
  does **not** help. The only reliable cure is a **clean WSLg reset**
  (`wsl --shutdown`), which re-initializes the virtiofs mount from a fresh
  state. `Start-BraveOrigin.ps1` launches Brave, then inspects the live window
  title for `[WARN:COPY MODE]`; if found it resets WSLg and relaunches (up to
  twice). A healthy session is never disrupted. Known WSLg bug
  (microsoft/wslg#1456, microsoft/WSL#40618).
- **Tested on**: Windows 11, WSL `2.7.11.0`, WSLg `1.0.73.2`.
- The packaged `Brave.exe` / `webview.dll` binaries are **not in the repo** (they
  are build outputs); they ship inside `Brave.zip` (see [Building](#building-bravezip)).

## Requirements

- Windows 10 (21H2+) or Windows 11
- WSL 2 with **WSLg** enabled (the GUI layer)
- ~2 GB free disk (plus space for the distro)
- Internet access for the first-run install
- The **WebView2 runtime** for the manager UI (Evergreen bootstrapper is installed
  automatically if missing)

## Quick start (manual setup)

There is no packaged `Brave.zip` release yet, so build the distro by hand:

### 1. WSL2 + WSLg

```powershell
wsl --install   # first time: also enables the VM platform (reboot required)
wsl --update    # already have WSL: grab the latest WSLg
```

### 2. A `linbox-Brave` distro

The launcher expects a dedicated distro named **`linbox-Brave`**. You need an
Ubuntu 22.04 rootfs tarball (this repo does not ship one). Export an existing
Ubuntu distro, or download a tarball, then import it:

```powershell
wsl --import linbox-Brave "$env:USERPROFILE\brave-distro" "linux\ubuntu-base.tar.gz"
```

### 3. Stage the scripts

```powershell
# From this repo folder, copy the app files into the distro:
wsl -d linbox-Brave -u root bash -lc "mkdir -p /opt/app && cp /mnt/c/Users/<YOU>/Workspace/Brave*/{*.sh,*.py,index.html} /opt/app/ && chmod +x /opt/app/*.sh"
```

(Adjust the `/mnt/c/...` path to where you cloned this repo.)

### 4. First-run setup

```powershell
wsl -d linbox-Brave -e bash /opt/app/setup.sh
```

Installs Brave's dependencies, the nightly apt repo, and `brave-origin-nightly`.

### 5. Launch

```powershell
wsl -d linbox-Brave -e bash /opt/app/start.sh
```

Brave opens as its own Windows window; the manager UI API runs at
`http://localhost:9612/` (open it in a browser for now: the `Brave.exe` WebView2
loader is not packaged yet).

Full step-by-step with troubleshooting: [`MANUAL_SETUP.md`](MANUAL_SETUP.md).

## How it works

```
Brave.exe  (WebView2 manager UI on Windows)
   │  http://localhost:9612   (WSL2 localhost forwarding)
   ▼
control.py  (sidecar API in the WSL distro `linbox-Brave`, port 9612)
   │
launch-brave.sh
   │  exec
   ▼
brave-origin-nightly  ──►  native WSLg window (Wayland/XWayland)
```

- `Brave.exe` is a thin WebView2 loader that shows the manager UI and points it at
  the `control.py` sidecar.
- `control.py` runs inside the dedicated WSL distro and exposes the manager API
  (`/api/logs`, `/api/exec`, `/api/settings`, `/api/brave/launch`,
  `/api/brave/stop`, `/api/update`, …).
- `launch-brave.sh` starts `brave-origin-nightly` directly as a WSLg window (no VNC).

## Project layout

| Path | Purpose |
|------|---------|
| `Setup.ps1` / `setup-core.ps1` | Windows installer GUI + shared logic (requirements, import, launch). |
| `Setup.exe` | Compiled loader (built from the `portable-linux-in-a-box` template). |
| `setup.sh` | First-run install inside the distro (deps, Brave apt repo, `.deb`). |
| `start.sh` | Boots audio + Brave window + `control.py` sidecar. |
| `stop.sh` | Stops Brave and the sidecar. |
| `launch-brave.sh` | Launches `brave-origin-nightly` as a native WSLg window. |
| `update.sh` | Updates `brave-origin-nightly` via apt. |
| `control.py` | Manager sidecar API. |
| `bridge.py` | Redirects the root URL to the staged UI. |
| `index.html` | Manager UI (Logs / Terminal / Settings). |
| `app.json` | Launcher config consumed by `Brave.exe` (distro, ports, commands). |
| `build-zip.ps1` | Packages the release `Brave.zip`. |
| `linux/ubuntu-base.tar.gz` | Ubuntu 22.04 rootfs seed (bundled in `Brave.zip`). |
| `MANUAL_SETUP.md` | Step-by-step manual install. |

## Building `Brave.zip`

`Brave.exe` and `webview.dll` are not in the repository (binary build outputs from
the `portable-linux-in-a-box` template). To produce a release:

1. Obtain `Brave.exe` + `webview.dll` (build the template, or grab them from a
   previous release).
2. Drop them into this folder next to `build-zip.ps1`.
3. Run:

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\build-zip.ps1
   ```

It bundles the scripts, `index.html`, `app.json`, the rootfs, and the two binaries
into `Brave.zip`. (`linux/ubuntu-base.tar.gz` must already be present: it is
normally committed/bundled; if missing, `Setup.ps1` falls back to downloading an
Ubuntu 22.04 rootfs.)

## Roadmap

- Per-user vs. system install options.
- Richer manager UI (update progress, one-click repair).
- Signed installer.
- More Linux apps wired up the same way.

## License

**Non-commercial / personal use only.** See [`LICENSE`](LICENSE). You may use,
modify, and share this project for personal, non-commercial purposes; commercial
use requires the copyright holder's permission.

## Disclaimer

This project is **not** affiliated with, endorsed by, or sponsored by Brave
Software, Inc. "Brave" is a trademark of Brave Software. This project downloads
and runs the **Brave Origin Nightly** browser, which is distributed under its own
license (MPL-2.0). Use at your own risk.
