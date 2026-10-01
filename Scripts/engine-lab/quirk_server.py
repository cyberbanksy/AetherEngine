#!/usr/bin/env python3
"""Debrid-quirk HTTP fixture server for the engine lab.

Serves local corpus files the way misbehaving debrid / CDN origins do. URL shape:

    http://127.0.0.1:<port>/q/<quirk>/<session>/<name>

<session> is any token; each (quirk, session) pair has its own request counter, so the
engine run and the ffprobe oracle never share state. <name> is a file name under the
corpus root (the lab passes the corpus-relative path, URL-quoted).

Quirks:
  plain                  well-behaved origin (206 ranges, correct type), the control
  redirect-chain         302 -> 307 -> 302 -> the media (relative and absolute Location)
  slow-first-byte        every response holds its first byte for SLOW_SECONDS (7 s)
  403-after-n            the first N_ALLOWED (6) requests work, every later one is 403
  range-ignored          Range is ignored: 200 + the whole body, no Accept-Ranges
  drop-mid-stream        each response is cut after DROP_AFTER bytes (3 MB), socket closed
  wrong-content-type     media served as text/html
  wrong-content-type-hls media served as application/vnd.apple.mpegurl
  html-200               an HTML "file not found" page with status 200
  status-404             404 with an HTML body
  no-content-length      200, chunked transfer, no Content-Length, no Accept-Ranges
  503-every-3rd          every 3rd request answers 503 with Retry-After: 1
  ua-waf                 403 when the User-Agent is missing or a tool's (Lavf, curl, python, Go, okhttp, Wget)

  python3 Scripts/engine-lab/quirk_server.py [--port 8765] [--root <corpus>]
"""
import argparse
import http.server
import os
import re
import socketserver
import threading
import time
import urllib.parse

SLOW_SECONDS = 7.0
N_ALLOWED = 6
DROP_AFTER = 3 * 1024 * 1024
HTML_PAGE = (b"<!DOCTYPE html><html><head><title>File not found</title></head><body>"
             b"<h1>Oops! This file is no longer available.</h1><p>The link has expired or the "
             b"torrent was removed from your account.</p></body></html>")

CTYPES = {".mp4": "video/mp4", ".m4v": "video/mp4", ".mov": "video/quicktime", ".mkv": "video/x-matroska",
          ".webm": "video/webm", ".ts": "video/mp2t", ".m2ts": "video/mp2t", ".avi": "video/x-msvideo"}


class State:
    def __init__(self):
        self.lock = threading.Lock()
        self.counts = {}
        self.log = []

    def bump(self, key):
        with self.lock:
            self.counts[key] = self.counts.get(key, 0) + 1
            return self.counts[key]


def make_handler(root, state):
    class H(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, fmt, *args):  # quiet; the lab keeps its own counters
            with state.lock:
                state.log.append(fmt % args)

        def do_HEAD(self):
            self.handle_req(head=True)

        def do_GET(self):
            self.handle_req(head=False)

        def send_simple(self, code, body, ctype="text/html; charset=utf-8", head=False, extra=None):
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            for k, v in (extra or {}).items():
                self.send_header(k, v)
            self.end_headers()
            if not head:
                self.wfile.write(body)

        def handle_req(self, head):
            parts = urllib.parse.urlsplit(self.path).path.split("/")
            # ['', 'q', quirk, session, name...]
            if len(parts) < 5 or parts[1] != "q":
                return self.send_simple(400, b"bad path", head=head)
            quirk, session = parts[2], parts[3]
            rest = parts[4:]
            hop = 0
            if rest and rest[0].startswith("hop"):
                hop = int(rest[0][3:] or 0)
                rest = rest[1:]
            name = urllib.parse.unquote("/".join(rest))
            path = os.path.realpath(os.path.join(root, name))
            if not path.startswith(os.path.realpath(root)) or not os.path.isfile(path):
                return self.send_simple(404, b"<html>no such fixture</html>", head=head)
            n = state.bump((quirk, session))

            if quirk == "redirect-chain" and hop < 3:
                codes = [302, 307, 302]
                base = f"/q/{quirk}/{session}/hop{hop + 1}/" + urllib.parse.quote(name)
                loc = base if hop % 2 == 0 else f"http://{self.headers.get('Host')}{base}"
                self.send_response(codes[hop])
                self.send_header("Location", loc)
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            if quirk == "html-200":
                return self.send_simple(200, HTML_PAGE, head=head)
            if quirk == "status-404":
                return self.send_simple(404, HTML_PAGE, head=head)
            if quirk == "403-after-n" and n > N_ALLOWED:
                return self.send_simple(403, b"<html><h1>403 Forbidden</h1>link expired</html>", head=head)
            if quirk == "503-every-3rd" and n % 3 == 0:
                return self.send_simple(503, b"<html>503 Service Unavailable</html>", head=head, extra={"Retry-After": "1"})
            if quirk == "ua-waf":
                ua = self.headers.get("User-Agent") or ""
                if not ua or re.search(r"lavf|curl|python|go-http|okhttp|wget", ua, re.I):
                    return self.send_simple(403, b"<html>403 Forbidden (bot protection)</html>", head=head)
            if quirk == "slow-first-byte":
                time.sleep(SLOW_SECONDS)

            size = os.path.getsize(path)
            ctype = CTYPES.get(os.path.splitext(path)[1].lower(), "application/octet-stream")
            if quirk == "wrong-content-type":
                ctype = "text/html; charset=utf-8"
            elif quirk == "wrong-content-type-hls":
                ctype = "application/vnd.apple.mpegurl"

            honour_range = quirk not in ("range-ignored", "no-content-length")
            start, end = 0, size - 1
            status = 200
            rng = self.headers.get("Range")
            if rng and honour_range:
                m = re.match(r"bytes=(\d*)-(\d*)", rng.strip())
                if m:
                    if m.group(1):
                        start = int(m.group(1))
                        if m.group(2):
                            end = min(int(m.group(2)), size - 1)
                    elif m.group(2):  # suffix range
                        start = max(0, size - int(m.group(2)))
                    if start >= size:
                        self.send_response(416)
                        self.send_header("Content-Range", f"bytes */{size}")
                        self.send_header("Content-Length", "0")
                        self.end_headers()
                        return
                    status = 206
            length = end - start + 1
            self.send_response(status)
            self.send_header("Content-Type", ctype)
            if quirk == "no-content-length":
                self.send_header("Transfer-Encoding", "chunked")
            else:
                self.send_header("Content-Length", str(length))
                if honour_range:
                    self.send_header("Accept-Ranges", "bytes")
                if status == 206:
                    self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
            self.end_headers()
            if head:
                return
            limit = DROP_AFTER if quirk == "drop-mid-stream" else None
            sent = 0
            try:
                with open(path, "rb") as f:
                    f.seek(start)
                    remaining = length
                    while remaining > 0:
                        chunk = f.read(min(256 * 1024, remaining))
                        if not chunk:
                            break
                        if limit is not None and sent + len(chunk) > limit:
                            chunk = chunk[: max(0, limit - sent)]
                            if chunk:
                                self.wfile.write(chunk)
                            self.wfile.flush()
                            self.close_connection = True
                            try:
                                self.connection.shutdown(2)
                            except OSError:
                                pass
                            return
                        if quirk == "no-content-length":
                            self.wfile.write(b"%x\r\n" % len(chunk) + chunk + b"\r\n")
                        else:
                            self.wfile.write(chunk)
                        sent += len(chunk)
                        remaining -= len(chunk)
                    if quirk == "no-content-length":
                        self.wfile.write(b"0\r\n\r\n")
            except (BrokenPipeError, ConnectionResetError):
                pass

    return H


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def start(root, port=0):
    state = State()
    srv = Server(("127.0.0.1", port), make_handler(root, state))
    t = threading.Thread(target=srv.serve_forever, daemon=True)
    t.start()
    return srv, state


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8765)
    ap.add_argument("--root", default=os.path.expanduser(os.environ.get(
        "ENGINE_LAB_CORPUS", "~/Developer/openstream-build/engine-lab/corpus")))
    a = ap.parse_args()
    srv, _ = start(a.root, a.port)
    print(f"quirk server on http://127.0.0.1:{srv.server_address[1]}/q/<quirk>/<session>/<file> (root {a.root})")
    try:
        while True:
            time.sleep(3600)
    except KeyboardInterrupt:
        pass
