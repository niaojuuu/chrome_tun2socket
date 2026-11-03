# 本地指纹检测服务：在容器内以 127.0.0.1:8000 运行（流量不出容器）
import http.server, os, sys, uuid
HERE = os.path.dirname(os.path.abspath(__file__))
OUT = sys.argv[1] if len(sys.argv) > 1 else "/tmp/fp-report.json"

class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def _send(self, code, body, ctype="text/plain", extra=()):
        self.send_response(code); self.send_header("Content-Type", ctype)
        for k, v in extra: self.send_header(k, v)
        self.end_headers(); self.wfile.write(body)
    def do_GET(self):
        if self.path == "/accept-language":
            self._send(200, self.headers.get("Accept-Language", "").encode())
        elif self.path == "/cache-probe":  # 浏览器若带 If-None-Match，说明 HTTP 缓存从上次会话保留了下来
            seen = "If-None-Match" in self.headers
            self._send(200, b"revalidated" if seen else b"fresh", extra=[("ETag", f'"{uuid.uuid4().hex}"'), ("Cache-Control", "no-cache")])
        else:
            self._send(200, open(os.path.join(HERE, "fp.html"), "rb").read(), "text/html; charset=utf-8")
    def do_POST(self):
        data = self.rfile.read(int(self.headers["Content-Length"]))
        open(OUT, "wb").write(data); self._send(204, b"")

http.server.ThreadingHTTPServer(("127.0.0.1", 8000), H).serve_forever()
