"""Loopback-only HTTP fixture for URLSession progress, cancellation and retry tests."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import sys
import signal
import time

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        if self.path == '/missing':
            self.send_error(404)
            return
        total = 262144
        resumable = self.path in ['/resumable', '/interrupted', '/expired']
        offset = 0
        if resumable and self.path != '/expired' and self.headers.get('Range'):
            offset = int(self.headers['Range'].split('=')[1].split('-')[0])
        self.send_response(206 if offset else 200)
        if self.path != '/unknown':
            self.send_header('Content-Length', str(total - offset))
        if resumable:
            self.send_header('Accept-Ranges', 'bytes')
            self.send_header('ETag', '"fixture-v1"')
            self.send_header('Last-Modified', 'Sun, 15 Nov 2026 00:00:00 GMT')
            if offset:
                self.send_header('Content-Range', f'bytes {offset}-{total-1}/{total}')
        self.send_header('Connection', 'close')
        self.end_headers()
        try:
            for position in range(offset, total, 8192):
                if self.path == '/interrupted' and offset == 0 and position >= 65536:
                    self.close_connection = True
                    return
                self.wfile.write(b'a' * min(8192, total-position))
                self.wfile.flush()
                time.sleep(0.04 if self.path in ['/slow', '/resumable', '/expired'] else 0.002)
        except (BrokenPipeError, ConnectionResetError):
            pass

signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
Path(sys.argv[1]).write_text(f'http://127.0.0.1:{server.server_port}')
server.serve_forever()
