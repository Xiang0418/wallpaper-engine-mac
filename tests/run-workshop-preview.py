#!/usr/bin/env python3
"""Run native GIF preview checks with a loopback-only HTTP fixture."""
import base64, pathlib, subprocess, tempfile, threading, time, json
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
ROOT = pathlib.Path(__file__).resolve().parents[1]
GIF = base64.b64decode("R0lGODlhUAAoAIEAAP8AAAAAAAAAAAAAACH/C05FVFNDQVBFMi4wAwEAAAAh+QQADAAAACwAAAAAUAAoAAAIXQABCBxIsKDBgwgTKlzIsKHDhxAjSpxIsaLFixgzatzIsaPHjyBDihxJsqTJkyhTqlzJsqXLlzBjypxJs6bNmzhz6tzJs6fPn0CDCh1KtKjRo0iTKl3KtKnTpygDAgAh+QQBDAABACwAAAAAUAAoAIEAAP8AAAAAAAAAAAAIXQABCBxIsKDBgwgTKlzIsKHDhxAjSpxIsaLFixgzatzIsaPHjyBDihxJsqTJkyhTqlzJsqXLlzBjypxJs6bNmzhz6tzJs6fPn0CDCh1KtKjRo0iTKl3KtKnTpygDAgA7")
class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/order':
            data = json.dumps(order).encode()
            self.send_response(200); self.end_headers(); self.wfile.write(data); return
        if self.path == '/stats':
            data = json.dumps(counts).encode()
            self.send_response(200); self.end_headers(); self.wfile.write(data); return
        with counter_lock:
            counts[self.path] = counts.get(self.path, 0) + 1
            order.append(self.path)
        if self.path.startswith('/slow'):
            with counter_lock:
                counts['active'] = counts.get('active', 0) + 1
                counts['peak'] = max(counts.get('peak', 0), counts['active'])
            time.sleep(0.2)
            with counter_lock: counts['active'] -= 1
        if self.path == '/preview.gif' or self.path.startswith('/slow'):
            self.send_response(200); self.send_header('Content-Length',str(len(GIF))); self.end_headers(); self.wfile.write(GIF)
        elif self.path == '/oversized':
            self.send_response(200); self.send_header('Content-Length',str(20*1024*1024)); self.end_headers()
        else:
            self.send_response(404); self.end_headers()
    def log_message(self,*args): pass
counts = {}
order = []
counter_lock = threading.Lock()
with ThreadingHTTPServer(('127.0.0.1',0),Handler) as server, tempfile.TemporaryDirectory(prefix='we-preview-') as temporary:
    threading.Thread(target=server.serve_forever,daemon=True).start()
    try:
        source = (ROOT/'Open Wallpaper Engine/ContentView/Components/WorkshopView.swift').read_text()
        source = source[source.index('private struct WorkshopImagePreview:'):]
        checks = (ROOT/'tests/WorkshopPreviewTests.swift').read_text().replace('18749',str(server.server_port))
        generated = pathlib.Path(temporary)/'Checks.swift'
        generated.write_text('import SwiftUI\nimport ImageIO\nimport CryptoKit\nstruct WorkshopItem { let title: String; let previewImageURL: URL? }\n'+source+checks)
        binary = pathlib.Path(temporary)/'checks'
        subprocess.run(['xcrun','swiftc','-parse-as-library','-module-cache-path',temporary+'/cache',str(generated),'-o',str(binary)],check=True,cwd=ROOT)
        (ROOT/'build/preview-tests').mkdir(parents=True,exist_ok=True)
        subprocess.run([str(binary)],check=True,cwd=ROOT)
    finally:
        server.shutdown()
