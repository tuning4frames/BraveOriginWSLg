#!/usr/bin/env python3
"""Bridge shim for the Brave app (native WSLg mode).

The portable-linux-in-a-box template requires every app to ship a bridge.py.
The template launches it, polls /api/status, then navigates the webview to
this server.

In native mode the real UI is served by control.py on port 9612 (Logs /
Terminal / Settings + the staged index.html). This bridge's only jobs are:

    1. Serve /api/status (200 once control.py is reachable on 9612).
    2. Serve /: an HTML page that redirects the webview to control.py.

We redirect to the SAME hostname the browser already used to load this page
(control.py binds 0.0.0.0, so it's reachable via localhost or the distro IP).
No DISTRO_IP / localhost-forwarding hacks: those existed only to work around
the old VNC/websockify stack, which is gone.
"""
import http.server
import os
import socket
import sys
import time

# Port this bridge listens on (the template points the webview here).
BRIDGE_PORT  = int(os.environ.get("BRIDGE_PORT", 9091))
# Where the real management UI lives.
CONTROL_PORT = 9612


def is_port_up(port, host="127.0.0.1", timeout=0.4):
    try:
        s = socket.socket()
        s.settimeout(timeout)
        s.connect((host, port))
        s.close()
        return True
    except Exception:
        return False


_REDIRECT_HTML = (
    "<!DOCTYPE html>\n"
    "<html><head><meta charset='utf-8'><title>Brave</title>\n"
    "<style>html,body{margin:0;height:100%;background:#0b0b0e;color:#888;"
    "font:14px -apple-system,sans-serif;display:flex;align-items:center;"
    "justify-content:center}</style></head>\n"
    "<body>Loading Brave manager&hellip;\n"
    "<script>\n"
    "(function(){ var target = location.protocol + '//' + location.hostname "
    "+ ':" + str(CONTROL_PORT) + "/';\n"
    "  function go(){ location.replace(target); }\n"
    "  function probe(){ fetch(target,{mode:'no-cors',cache:'no-store'})"
    ".then(go).catch(function(){ setTimeout(probe,500);}); }\n"
    "  probe();\n"
    "})();\n"
    "</script></body></html>\n"
).encode("utf-8")


class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "BraveBridge/2"

    def _send(self, code, body=b"", ctype="text/plain"):
        if isinstance(body, str):
            body = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if body:
            self.wfile.write(body)

    def do_GET(self):
        if self.path == "/api/status":
            if is_port_up(CONTROL_PORT):
                return self._send(200, b"ok")
            return self._send(503, b"starting")
        return self._send(200, _REDIRECT_HTML, "text/html; charset=utf-8")

    def log_message(self, fmt, *args):
        sys.stderr.write(f"[bridge] {fmt % args}\n")


def main():
    httpd = http.server.ThreadingHTTPServer(("0.0.0.0", BRIDGE_PORT), Handler)
    sys.stderr.write(f"[bridge] listening on 0.0.0.0:{BRIDGE_PORT} -> :{CONTROL_PORT}\n")
    sys.stderr.flush()
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
