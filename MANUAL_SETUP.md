# Manual Setup Guide: Brave Origin for Windows (Native WSLg)

Prefer doing it by hand, or hit a UAC prompt you'd rather handle yourself? This
guide reproduces exactly what the launcher does, step by step. You end up with
the same result: Brave Origin Nightly running as a native WSLg window plus the
manager UI (Logs / Terminal / Settings).

## 1. Install WSL2 + WSLg (only if not already present)

Open **PowerShell as Administrator** and run:

```powershell
wsl --install
```

- On current Windows 10 (21H2+) and Windows 11 this installs WSL2, a default
  Ubuntu distro, **and WSLg** (the GUI layer) in one shot.
- A **reboot is required** the first time the VM platform is enabled.
- Already have WSL but Brave's window won't appear? Update it:

```powershell
wsl --update
```

Verify WSLg is available (after a distro is running):

```powershell
wsl -e sh -c 'ls /mnt/wslg && echo WSLG_OK'
```

If `WSLG_OK` prints, you're good. If `/mnt/wslg` is missing, run `wsl --update`
and reboot.

## 2. Import the Ubuntu rootfs

The `Brave.zip` release ships `linux/ubuntu-base.tar.gz` (a minimal Ubuntu 22.04
rootfs). Import it as a dedicated distro (no `sudo` password prompts, disposable):

```powershell
# From the extracted Brave/ folder:
wsl --import linbox-Brave "$env:USERPROFILE\brave-distro" "linux\ubuntu-base.tar.gz"
```

This creates a distro named `linbox-Brave`. To open a shell in it:

```powershell
wsl -d linbox-Brave
```

## 3. Copy the app scripts into the distro

The launcher normally stages the scripts to `/opt/app`. Do it manually:

```powershell
# Inside a wsl -d linbox-Brave shell:
sudo mkdir -p /opt/app
sudo cp /mnt/c/Users/<YOU>/.../Brave/*.sh /opt/app/
sudo cp /mnt/c/Users/<YOU>/.../Brave/*.py /opt/app/
sudo cp /mnt/c/Users/<YOU>/.../Brave/index.html /opt/app/
sudo chmod +x /opt/app/*.sh
```

(Adjust the `/mnt/c/...` path to wherever you extracted `Brave.zip`.)

## 4. Run the first-time setup

```powershell
wsl -d linbox-Brave -e bash /opt/app/setup.sh
```

This: checks WSLg + connectivity + disk space, `apt`-installs Brave's
dependencies (curl, ca-certificates, PulseAudio client: **no VNC stack**),
adds the Brave nightly apt repo, and downloads + installs the latest
`brave-origin-nightly` `.deb` from GitHub. Needs internet (~120 MB).

Watch `/root/.vnc/setup.log` for progress.

## 5. Launch

```powershell
wsl -d linbox-Brave -e bash /opt/app/start.sh
```

`start.sh` will:

1. Configure PulseAudio through WSLg (`/mnt/wslg/PulseServer`).
2. Launch `brave-origin-nightly` as a **native WSLg window**.
3. Launch `control.py` on port `9612` (the manager UI API).

Brave appears as its own Windows window. To open the **manager UI** (Logs /
Terminal / Settings / Brave launch), point a browser (or the WebView2 loader)
at the control sidecar:

```
http://localhost:9612/
```

The included `Brave.exe` does exactly this automatically.

## 6. Everyday use

- **Launch / relaunch Brave:** open the manager UI → **Brave** tab → *Launch Brave*.
- **Shut everything down:** manager UI → *Shut down* (runs `stop.sh`), or:

  ```powershell
  wsl -d linbox-Brave -e bash /opt/app/stop.sh
  ```

- **Update Brave:** manager UI → *Settings* → *Check & update*, or:

  ```powershell
  wsl -d linbox-Brave -e bash /opt/app/update.sh
  ```

## Uninstall

```powershell
wsl --unregister linbox-Brave
Remove-Item -Recurse "$env:USERPROFILE\brave-distro"
```

That removes the distro and its files. Delete the extracted `Brave/` folder too
if you want a clean slate.

## Troubleshooting

- **No Brave window:** confirm WSLg (`/mnt/wslg` exists) and check Logs → `brave`
  source in the manager UI. Most "no window" cases are missing/outdated WSLg →
  `wsl --update` + reboot.
- **No sound:** Logs → `start` should say `audio: PulseAudio reachable`. If not,
  `wsl --update` and relaunch.
- **Manager UI won't load:** ensure `control.py` is up: Logs → `control`, or
  `wsl -d linbox-Brave -e pgrep -af control.py`.
