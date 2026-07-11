#!/usr/bin/env python3
"""click-bridge — tarayıcı tıklama olaylarını terminal AI agent'ı için diske yazan localhost köprüsü.

Tarayıcı tarafı (react-dev-inspector callback'i, custom overlay, userscript...) buraya
POST /click atar; server son tıklamayı <dir>/last.json'a atomik yazar ve
<dir>/history.jsonl'a ekler. Claude Code hook'u last.json'ı prompt bağlamına enjekte eder.

Sadece stdlib. Sadece 127.0.0.1'e bind olur.
"""
import argparse
import json
import os
import subprocess
import sys
import threading
import tempfile
import time
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

MAX_BODY = 262144  # 256 KB

CORS_HEADERS = {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Methods": "POST, GET, OPTIONS",
    "Access-Control-Allow-Headers": "Content-Type",
}


class ClickBridgeHandler(BaseHTTPRequestHandler):
    data_dir: Path  # make_server atar

    # -- yardımcılar ---------------------------------------------------------
    def _send(self, status: int, payload=None):
        body = b"" if payload is None else json.dumps(payload, ensure_ascii=False).encode()
        self.send_response(status)
        for k, v in CORS_HEADERS.items():
            self.send_header(k, v)
        if body:
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if body:
            self.wfile.write(body)

    def log_message(self, fmt, *args):  # tek satır stderr log
        sys.stderr.write("click-bridge: %s %s\n" % (self.command, fmt % args))

    # -- HTTP metotları ------------------------------------------------------
    def do_OPTIONS(self):
        self._send(204)

    def do_GET(self):
        try:
            if self.path == "/health":
                self._send(200, {"ok": True, "service": "click-bridge"})
            elif self.path == "/snippet.js":
                snip = Path(__file__).resolve().parent / "snippet" / "click-bridge.js"
                if not snip.exists():
                    self._send(404, {"ok": False, "error": "snippet not found"})
                    return
                body = snip.read_bytes()
                self.send_response(200)
                for k, v in CORS_HEADERS.items():
                    self.send_header(k, v)
                self.send_header("Content-Type", "application/javascript; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
            elif self.path == "/last":
                last = self.data_dir / "last.json"
                if not last.exists():
                    self._send(404, {"ok": False, "error": "no click yet"})
                else:
                    self._send(200, json.loads(last.read_text()))
            else:
                self._send(404, {"ok": False, "error": "not found"})
        except Exception as e:  # asla crash etme
            self._send(500, {"ok": False, "error": str(e)})

    def do_POST(self):
        try:
            if self.path != "/click":
                self._send(404, {"ok": False, "error": "not found"})
                return
            length = int(self.headers.get("Content-Length") or 0)
            if length > MAX_BODY:
                self._send(413, {"ok": False, "error": "body too large (max %d)" % MAX_BODY})
                return
            raw = self.rfile.read(length)
            try:
                obj = json.loads(raw)
                if not isinstance(obj, dict):
                    raise ValueError("JSON object expected")
            except (json.JSONDecodeError, ValueError) as e:
                self._send(400, {"ok": False, "error": "invalid JSON: %s" % e})
                return

            now = time.time()
            obj["ts"] = now
            obj["iso"] = datetime.fromtimestamp(now).isoformat(timespec="seconds")

            self._write_atomic(obj)
            with (self.data_dir / "history.jsonl").open("a", encoding="utf-8") as f:
                f.write(json.dumps(obj, ensure_ascii=False) + "\n")

            self._send(200, {"ok": True})
        except Exception as e:
            self._send(500, {"ok": False, "error": str(e)})

    def _write_atomic(self, obj: dict):
        fd, tmp = tempfile.mkstemp(dir=self.data_dir, prefix=".last-", suffix=".tmp")
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                json.dump(obj, f, ensure_ascii=False, indent=2)
            os.replace(tmp, self.data_dir / "last.json")
        except Exception:
            os.unlink(tmp)
            raise


def make_server(host: str, port: int, data_dir) -> ThreadingHTTPServer:
    d = Path(data_dir).expanduser()
    d.mkdir(mode=0o700, parents=True, exist_ok=True)
    handler = type("BoundHandler", (ClickBridgeHandler,), {"data_dir": d})
    return ThreadingHTTPServer((host, port), handler)


def _tailscale_ip():
    """Tailscale IPv4'u dondur (yoksa None) — uzak cihazlardan tiklama kabulu icin."""
    try:
        out = subprocess.run(["tailscale", "ip", "-4"], capture_output=True, text=True, timeout=3)
        line = out.stdout.strip().splitlines()
        return line[0] if line else None
    except Exception:
        return None


def main():
    ap = argparse.ArgumentParser(description="click-bridge server (localhost + tailscale)")
    ap.add_argument("--port", type=int, default=7823)
    ap.add_argument("--dir", default="~/.click-bridge")
    ap.add_argument("--bind", action="append",
                    help="ek bind adresi (tekrarlanabilir); default: 127.0.0.1 + tailscale-otomatik")
    ap.add_argument("--no-tailscale", action="store_true")
    args = ap.parse_args()

    binds = args.bind or ["127.0.0.1"]
    if not args.no_tailscale and not args.bind:
        ts = _tailscale_ip()
        if ts:
            binds.append(ts)

    servers = [make_server(b, args.port, args.dir) for b in binds]
    for extra in servers[1:]:
        threading.Thread(target=extra.serve_forever, daemon=True).start()
    sys.stderr.write("click-bridge: listening on %s port %d, dir=%s\n"
                     % (", ".join(binds), args.port, Path(args.dir).expanduser()))
    try:
        servers[0].serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
