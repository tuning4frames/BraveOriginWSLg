#!/usr/bin/env python3
"""Control sidecar for the Brave Origin Nightly app.

JSON API served on 0.0.0.0:9612 (configurable) and consumed by the UI:

    GET  /api/ping           - liveness probe
    GET  /api/version        - {installed: "1.91.43"}
    GET  /api/update-check   - {installed, latest, updateAvailable, running}
    GET  /api/update/status  - {running: bool}
    GET  /api/brave/status   - {running: bool}  (native WSLg window alive?)
    GET  /api/logs           - {files: [{name, path, size, content}, ...]}
    GET  /api/settings       - current settings (auto_update, snooze_until)
    POST /api/settings       - merge + persist a settings patch
    POST /api/update         - run update.sh in the background
    POST /api/exec           - run a bash -lc command (Terminal tab backend)
    POST /api/brave/launch   - (re)launch Brave as a native WSLg window
    POST /api/shutdown       - run stop.sh (kills the whole app tree)

Bound to 0.0.0.0 (not 127.0.0.1) so Windows-side WebView2 can reach it
through WSL2's localhost forwarding. WSL2 only forwards ports bound to
the wildcard address.

Security note on POST /api/exec:
    This endpoint intentionally runs arbitrary `bash -lc` commands with a
    30-second timeout. It is the backend for the in-app Terminal tab. The
    sidecar binds 0.0.0.0:9612 so the Windows-side WebView can reach it,
    but every /api/* request must include the per-launch token stamped into
    the staged UI by start.sh. That blocks random localhost webpages from
    calling the command endpoint while the app is running.
"""
import http.server
import hmac
import json
import os
import re
import signal
import subprocess
import sys
import threading
import time
import urllib.request

APP_DIR       = "/opt/app"
STOP_SCRIPT   = os.path.join(APP_DIR, "stop.sh")
UPDATE_SCRIPT = os.path.join(APP_DIR, "update.sh")
SETTINGS_PATH = "/root/brave-settings.json"
LOG_DIR       = "/root/.vnc"
TOKEN_PATH    = "/run/brave-api-token"

# Logs exposed to the UI. Order matches the dropdown in the Logs tab.
# (Native WSLg mode: no Xtigervnc/openbox/websockify logs.)
LOG_FILES = [
    ("setup",   os.path.join(LOG_DIR, "setup.log")),
    ("start",   os.path.join(LOG_DIR, "start.log")),
    ("update",  os.path.join(LOG_DIR, "update.log")),
    ("brave",   os.path.join(LOG_DIR, "brave.log")),
    ("control", os.path.join(LOG_DIR, "control.log")),
]

UI_INDEX = "/opt/brave-ui/index.html"
LAUNCH_SCRIPT = os.path.join(APP_DIR, "launch-brave.sh")

DEFAULT_SETTINGS = {
    "auto_update":  False,  # run update automatically on startup if set
    "snooze_until": 0,      # unix ts; banner is suppressed while now < this
}

GITHUB_API = "https://api.github.com/repos/brave/brave-browser/releases?per_page=30"
DEB_RE     = re.compile(r"brave-origin-nightly_([0-9.]+)_amd64\.deb$")


# ----- version lookup ------------------------------------------------------

_latest_cache = {"version": None, "url": None, "ts": 0.0}
_latest_lock  = threading.Lock()


def fetch_latest_from_github():
    """Return (version, url) for the most recent brave-origin-nightly amd64 .deb.
    Cached for 5 minutes to avoid hammering api.github.com."""
    now = time.time()
    with _latest_lock:
        if _latest_cache["version"] and now - _latest_cache["ts"] < 300:
            return _latest_cache["version"], _latest_cache["url"]

    try:
        req = urllib.request.Request(
            GITHUB_API, headers={"User-Agent": "brave-app-sidecar/1"}
        )
        with urllib.request.urlopen(req, timeout=10) as r:
            releases = json.loads(r.read().decode("utf-8"))
    except Exception as e:
        sys.stderr.write(f"[control] github fetch failed: {e}\n")
        return None, None

    for release in releases:
        for asset in release.get("assets", []):
            m = DEB_RE.match(asset.get("name", ""))
            if m:
                with _latest_lock:
                    _latest_cache.update({
                        "version": m.group(1),
                        "url":     asset.get("browser_download_url"),
                        "ts":      now,
                    })
                return m.group(1), asset.get("browser_download_url")
    return None, None


def get_installed_version():
    """Installed brave-origin-nightly version, or None if not found."""
    try:
        out = subprocess.check_output(
            ["brave-origin-nightly", "--version"],
            stderr=subprocess.DEVNULL,
            timeout=5,
        ).decode().strip()
    except Exception:
        return None
    # "Brave Origin Nightly 147.1.91.43 nightly"  -> 1.91.43
    m = re.search(r"(\d+\.\d+\.\d+)\s*(?:nightly)?\s*$", out)
    return m.group(1) if m else (out or None)


def parse_version(v):
    if not v:
        return ()
    try:
        return tuple(int(x) for x in v.split("."))
    except Exception:
        return ()


# ----- Brave process control (native WSLg window) --------------------------

def brave_running():
    """True if a brave-origin-nightly process is alive.

    Uses -f (full command line) rather than -x: the kernel truncates the
    process comm to "brave-origin-ni" (15-char limit), so an exact comm
    match would never find it.
    """
    try:
        return subprocess.run(
            ["pgrep", "-f", "brave-origin-nightly"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            timeout=5,
        ).returncode == 0
    except Exception:
        return False


def launch_brave():
    """Spawn Brave as a native WSLg window via launch-brave.sh.

    If a Brave instance is already running, kill it first so the UI's
    "Relaunch" action actually restarts the window. Fire-and-forget;
    logging goes to brave.log.
    """
    try:
        if brave_running():
            sys.stderr.write("[control] brave already running; restarting\n")
            try:
                subprocess.run(["pkill", "-9", "-f", "brave-origin-nightly"], timeout=5)
            except Exception:
                pass
            # Wait for the old instance to fully exit before spawning, so
            # launch-brave.sh's "already running" guard doesn't bail out and
            # leave us with no Brave at all.
            for _ in range(10):
                if not brave_running():
                    break
                time.sleep(0.5)
        subprocess.Popen(
            ["bash", LAUNCH_SCRIPT],
            start_new_session=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        return True
    except Exception as e:
        sys.stderr.write(f"[control] launch_brave failed: {e}\n")
        return False


def stop_brave():
    """Kill the Brave window without tearing down control.py / the distro.

    Uses -f so it matches the real brave-origin-nightly processes (their comm
    is truncated to "brave-origin-ni"). Returns True if something was killed.
    """
    try:
        r = subprocess.run(
            ["pkill", "-9", "-f", "brave-origin-nightly"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5,
        )
        return r.returncode == 0
    except Exception as e:
        sys.stderr.write(f"[control] stop_brave failed: {e}\n")
        return False


def read_index_html():
    # Prefer the token-stamped copy staged by start.sh; fall back to the
    # source copy in /opt/app so GET / still works if start.sh hasn't run.
    for path in (UI_INDEX, os.path.join(APP_DIR, "index.html")):
        try:
            with open(path, "rb") as f:
                return f.read()
        except Exception:
            continue
    return b"<html><body>UI not available</body></html>"


# ----- settings ------------------------------------------------------------

_settings_lock = threading.Lock()


def load_settings():
    with _settings_lock:
        try:
            with open(SETTINGS_PATH) as f:
                data = json.load(f)
        except Exception:
            data = {}
        merged = dict(DEFAULT_SETTINGS)
        for k, v in data.items():
            if k in DEFAULT_SETTINGS:
                merged[k] = v
        return merged


def save_settings(patch):
    with _settings_lock:
        try:
            with open(SETTINGS_PATH) as f:
                data = json.load(f)
        except Exception:
            data = {}
        merged = dict(DEFAULT_SETTINGS)
        merged.update({k: v for k, v in data.items() if k in DEFAULT_SETTINGS})
        for k, v in (patch or {}).items():
            if k in DEFAULT_SETTINGS:
                merged[k] = v
        os.makedirs(os.path.dirname(SETTINGS_PATH), exist_ok=True)
        tmp = SETTINGS_PATH + ".tmp"
        with open(tmp, "w") as f:
            json.dump(merged, f, indent=2)
        os.replace(tmp, SETTINGS_PATH)
        return merged


# ----- log tailing ---------------------------------------------------------

def read_log_tail(path, max_bytes=256 * 1024):
    try:
        size = os.path.getsize(path)
        with open(path, "rb") as f:
            if size > max_bytes:
                f.seek(size - max_bytes)
                f.readline()  # skip the partial first line
            data = f.read()
        return data.decode("utf-8", errors="replace")
    except FileNotFoundError:
        return ""
    except Exception as e:
        return f"<error reading log: {e}>"


# ----- update runner -------------------------------------------------------

_update_lock    = threading.Lock()
_update_running = [False]


def run_update(from_auto=False):
    with _update_lock:
        if _update_running[0]:
            return
        _update_running[0] = True
    tag = "auto" if from_auto else "manual"
    try:
        os.makedirs(LOG_DIR, exist_ok=True)
        with open(os.path.join(LOG_DIR, "update.log"), "a") as log:
            log.write(f"\n=== update ({tag}) @ {time.strftime('%Y-%m-%d %H:%M:%S')} ===\n")
            log.flush()
            try:
                p = subprocess.Popen(
                    [UPDATE_SCRIPT],
                    stdout=log, stderr=subprocess.STDOUT,
                    start_new_session=True,
                )
                try:
                    p.wait(timeout=600)  # 10 min
                except subprocess.TimeoutExpired:
                    try:
                        os.killpg(p.pid, signal.SIGKILL)
                    except Exception:
                        p.kill()
                    p.wait()
                    log.write("=== update timed out after 10 minutes ===\n")
                log.write(f"=== exit {p.returncode} ===\n")
            except FileNotFoundError:
                log.write(f"[error] {UPDATE_SCRIPT} not found\n")
            except Exception as e:
                log.write(f"[error] {e}\n")
    finally:
        with _update_lock:
            _update_running[0] = False
        # Re-warm latest cache so /api/update-check reports freshly after a successful upgrade
        with _latest_lock:
            _latest_cache["ts"] = 0.0


def maybe_auto_update_on_startup():
    """If auto_update is enabled, kick off an update in the background."""
    def worker():
        time.sleep(4)  # let the rest of start.sh settle
        try:
            s = load_settings()
            if not s.get("auto_update"):
                return
            installed = get_installed_version()
            latest, _ = fetch_latest_from_github()
            if installed and latest and parse_version(latest) > parse_version(installed):
                sys.stderr.write(f"[control] auto-update: {installed} -> {latest}\n")
                run_update(from_auto=True)
            else:
                sys.stderr.write("[control] auto-update: up to date\n")
        except Exception as e:
            sys.stderr.write(f"[control] auto-update worker error: {e}\n")
    threading.Thread(target=worker, daemon=True).start()


# ----- HTTP handler --------------------------------------------------------

class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "BraveControl/1"

    def _cors(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "POST, GET, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type, X-Brave-Token")

    def _send_json(self, data, code=200):
        body = json.dumps(data).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self._cors()
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _send_text(self, code, text=""):
        body = text.encode("utf-8") if isinstance(text, str) else text
        self.send_response(code)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self._cors()
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if body:
            self.wfile.write(body)

    def _read_body(self):
        n = int(self.headers.get("Content-Length") or 0)
        if n <= 0:
            return {}
        try:
            return json.loads(self.rfile.read(n).decode("utf-8"))
        except Exception:
            return {}

    def _authorized(self):
        try:
            with open(TOKEN_PATH) as f:
                expected = f.read().strip()
        except Exception:
            expected = ""
        supplied = self.headers.get("X-Brave-Token", "")
        return bool(expected) and hmac.compare_digest(supplied, expected)

    def _require_auth(self):
        if self._authorized():
            return True
        self._send_json({"error": "forbidden"}, 403)
        return False

    def log_message(self, fmt, *args):
        sys.stderr.write(f"[{time.strftime('%H:%M:%S')}] {fmt % args}\n")

    def _handle_exec(self):
        """POST /api/exec: run a shell command through `bash -lc`.
        Body: {"cmd": "ls -la /opt"}
        Returns: {stdout, stderr, exit_code, duration_ms}.
        Each call spawns a fresh subshell, so state (cwd, env) doesn't persist
        between calls: chain with && or use `cd X && pwd` style."""
        data = self._read_body() or {}
        cmd = (data.get("cmd") or "").strip()
        if not cmd:
            return self._send_json({"error": "empty command"}, 400)
        t0 = time.time()
        try:
            r = subprocess.run(
                ["bash", "-lc", cmd],
                capture_output=True, text=True, timeout=30,
            )
            return self._send_json({
                "stdout":      r.stdout,
                "stderr":      r.stderr,
                "exit_code":   r.returncode,
                "duration_ms": int((time.time() - t0) * 1000),
            })
        except subprocess.TimeoutExpired:
            return self._send_json({
                "error":       "timed out after 30s",
                "duration_ms": int((time.time() - t0) * 1000),
            }, 408)
        except Exception as e:
            return self._send_json({"error": str(e)}, 500)

    # --- method dispatch ---

    def do_OPTIONS(self):
        self._send_text(204)

    def do_GET(self):
        try:
            if self.path.startswith("/api/") and not self._require_auth():
                return

            if self.path in ("/", "/index.html"):
                body = read_index_html()
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return

            if self.path == "/api/ping":
                return self._send_text(200, "pong")

            if self.path == "/api/status":
                return self._send_text(200, "ok")

            if self.path == "/api/brave/status":
                return self._send_json({"running": brave_running()})

            if self.path == "/api/version":
                return self._send_json({"installed": get_installed_version()})

            if self.path == "/api/update-check":
                installed = get_installed_version()
                latest, url = fetch_latest_from_github()
                avail = bool(
                    installed and latest
                    and parse_version(latest) > parse_version(installed)
                )
                return self._send_json({
                    "installed":       installed,
                    "latest":          latest,
                    "url":             url,
                    "updateAvailable": avail,
                    "running":         _update_running[0],
                })

            if self.path == "/api/update/status":
                return self._send_json({"running": _update_running[0]})

            if self.path == "/api/logs":
                files = []
                for name, path in LOG_FILES:
                    size = 0
                    try:
                        size = os.path.getsize(path)
                    except OSError:
                        pass
                    files.append({
                        "name":    name,
                        "path":    path,
                        "size":    size,
                        "content": read_log_tail(path),
                    })
                return self._send_json({"files": files})

            if self.path == "/api/settings":
                return self._send_json(load_settings())

            self._send_text(404, "not found")
        except Exception as e:
            self._send_text(500, f"error: {e}")

    def do_POST(self):
        try:
            if self.path.startswith("/api/") and not self._require_auth():
                return

            if self.path == "/api/exec":
                return self._handle_exec()
            if self.path == "/api/brave/launch":
                launched = launch_brave()
                return self._send_json({"ok": True, "launched": launched,
                                        "running": brave_running()})
            if self.path == "/api/brave/stop":
                stopped = stop_brave()
                return self._send_json({"ok": True, "stopped": stopped,
                                        "running": brave_running()})
            if self.path == "/api/shutdown":
                self._send_text(200, "ok")
                try:
                    self.wfile.flush()
                except Exception:
                    pass
                threading.Thread(target=_spawn_stop, daemon=True).start()
                return

            if self.path == "/api/update":
                if _update_running[0]:
                    return self._send_json({"ok": False, "error": "already running"}, 409)
                self._send_json({"ok": True, "running": True})
                try:
                    self.wfile.flush()
                except Exception:
                    pass
                threading.Thread(target=run_update, kwargs={"from_auto": False}, daemon=True).start()
                return

            if self.path == "/api/settings":
                merged = save_settings(self._read_body())
                return self._send_json(merged)

            self._send_text(404, "not found")
        except Exception as e:
            self._send_text(500, f"error: {e}")


def _spawn_stop():
    try:
        subprocess.Popen(
            [STOP_SCRIPT],
            start_new_session=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    except Exception as e:
        sys.stderr.write(f"[control] failed to spawn stop.sh: {e}\n")


# ----- main ----------------------------------------------------------------

def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 9612
    os.makedirs(LOG_DIR, exist_ok=True)
    # Warm the GitHub cache so /api/update-check is snappy the first time
    threading.Thread(target=fetch_latest_from_github, daemon=True).start()
    maybe_auto_update_on_startup()
    httpd = http.server.ThreadingHTTPServer(("0.0.0.0", port), Handler)
    sys.stderr.write(f"[control] listening on 0.0.0.0:{port}\n")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
