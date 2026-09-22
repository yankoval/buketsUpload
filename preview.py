"""Serve only browser/SignJS static assets on loopback; no API proxy or credentials."""
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parent
SIGN = ROOT.parent / 'SignJS'
FILES = {name: ROOT / name for name in ['index.html', 'refresh-controller.js']}
FILES.update({name: SIGN / name for name in ['cloud-sign.html', 'CloudSignApp.js', 'style.css']})
FILES['browser-fixture.js'] = ROOT / 'tests' / 'browser-fixture.js'

class Handler(SimpleHTTPRequestHandler):
    def do_GET(self):
        name = urlsplit(self.path).path.lstrip('/') or 'index.html'
        if name == 'cadesplugin_api.js':
            self.send_response(302)
            self.send_header('Location', 'https://storage.yandexcloud.net/20ab2a0c-2726-4ba1-9c7c-7deae82941ff/cadesplugin_api.js')
            self.end_headers()
            return
        path = FILES.get(name)
        if path is None or not path.is_file():
            self.send_error(404)
            return
        if name == 'index.html' and urlsplit(self.path).query == 'fixture=1':
            text = path.read_text()
            text = text.replace("const API_URL = localStorage.getItem('ymq_gw_url') || '';", "const API_URL = 'https://fixture.invalid/api';")
            text = text.replace("const API_KEY = localStorage.getItem('ymq_api_key') || '';", "const API_KEY = 'fixture-key';")
            text = text.replace('<h1>Bucket Browser</h1>', '<h1>Bucket Browser — тестовые данные</h1>')
            text = text.replace('<script src="refresh-controller.js', '<script src="browser-fixture.js"></script><script src="refresh-controller.js')
            content = text.encode()
            self.send_response(200)
            self.send_header('Content-Type', 'text/html; charset=utf-8')
            self.send_header('Content-Length', str(len(content)))
            self.end_headers()
            self.wfile.write(content)
            return
        self.send_response(200)
        self.send_header('Content-Type', self.guess_type(str(path)))
        self.send_header('Cache-Control', 'no-store')
        self.send_header('Content-Length', str(path.stat().st_size))
        self.end_headers()
        with path.open('rb') as source:
            self.copyfile(source, self.wfile)

if __name__ == '__main__':
    ThreadingHTTPServer(('127.0.0.1', 8765), Handler).serve_forever()
