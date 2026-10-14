#!/usr/bin/env python3
"""Tiny static server for Wortschatz: no caching, correct MIME types.

Serves this folder on http://localhost:4173 (IPv4 + IPv6 loopback only).
The port must stay the same, because the browser keeps your data per address.
"""
import functools
import http.server
import os
import socket
import sys
import threading

PORT = int(os.environ.get("PORT", "4173"))
ROOT = os.path.dirname(os.path.abspath(__file__))


class Handler(http.server.SimpleHTTPRequestHandler):
    extensions_map = {
        **http.server.SimpleHTTPRequestHandler.extensions_map,
        ".js": "text/javascript",
        ".mjs": "text/javascript",
        ".css": "text/css",
        ".svg": "image/svg+xml",
        ".json": "application/json",
        ".webmanifest": "application/manifest+json",
        ".txt": "text/plain; charset=utf-8",
    }

    def end_headers(self):
        self.send_header("Cache-Control", "no-store")
        super().end_headers()


class Server(http.server.ThreadingHTTPServer):
    # On Windows SO_REUSEADDR lets a second server bind the same port, so a
    # second start would not notice that Wortschatz is already running.
    allow_reuse_address = os.name != "nt"


class V6Server(Server):
    address_family = socket.AF_INET6


def main():
    handler = functools.partial(Handler, directory=ROOT)
    try:
        primary = Server(("127.0.0.1", PORT), handler)
    except OSError:
        print(f"Port {PORT} ist belegt – läuft Wortschatz bereits?")
        sys.exit(1)
    try:
        v6 = V6Server(("::1", PORT), handler)
        threading.Thread(target=v6.serve_forever, daemon=True).start()
    except OSError:
        pass
    print(f"Wortschatz läuft auf http://localhost:{PORT}/", flush=True)
    try:
        primary.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
