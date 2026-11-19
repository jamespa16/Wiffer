#!/usr/bin/env python3
"""Phase 8I: the harness's web server for /bin/browse.

Serves tests/web/ (fixture pages: layout features, images, forms) plus
dynamic endpoints, over plain HTTP or HTTPS (the test PKI in tests/certs):

  /echo                 GET or POST: a page whose <title> lists the fields
  /redir/301|302|303|307, /redir/chain, /redir/loop, /redir/ok
  /chunked              Transfer-Encoding: chunked, many small chunks
  /gzip, /deflate       Content-Encoding responses
  /cookie/set           Set-Cookie, then a redirect to /cookie/echo
  /cookie/echo          a page whose <title> shows the request's Cookie header
  /testca.der           the test CA (for `fetch -o /ca.der`)
  /hostile/stall-headers, stall-body, truncated, reset, garbage, hugeheaders,
  /hostile/endless, bomb, pngdims (+ lying.png)

Every response is HTTP/1.1 with Connection: close, written by hand so the
hostile ones can misbehave exactly. `srv.requests` records every request
(method, path, headers, body) for the harness to check what the browser sent.

    python3 tests/web_server.py [port]     serve on 127.0.0.1 until Ctrl-C
"""
import os, random, socket, ssl, struct, sys, threading, time, urllib.parse, zlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WEB = os.path.join(ROOT, "tests", "web")
CERTS = os.path.join(ROOT, "tests", "certs")

TYPES = {".html": "text/html; charset=utf-8", ".css": "text/css", ".png": "image/png", ".jpg": "image/jpeg",
         ".gif": "image/gif", ".svg": "image/svg+xml", ".txt": "text/plain", ".der": "application/x-x509-ca-cert"}

def html(title, body=""):
    return f"<!DOCTYPE html><html><head><meta charset=utf-8><title>{title}</title></head><body>{body}</body></html>".encode()

def escape(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")

def lying_png():
    """A valid-looking PNG claiming 60000x60000 pixels with a tiny IDAT."""
    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 60000, 60000, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(b"\0" * 64)) + chunk(b"IEND", b""))

class WebServer:
    def __init__(self, tls=False, bind="127.0.0.1", port=0):
        self.requests = []
        self.stopping = threading.Event()
        self.lock = threading.Lock()
        self.sock = socket.socket()
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.sock.bind((bind, port))
        self.sock.listen(64)
        self.sock.settimeout(0.2)
        self.port = self.sock.getsockname()[1]
        self.ctx = None
        if tls:
            self.ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            self.ctx.minimum_version = ssl.TLSVersion.TLSv1_3
            self.ctx.load_cert_chain(os.path.join(CERTS, "leaf-ec.chain.pem"), os.path.join(CERTS, "leaf-ec.key.pem"))
        with open(os.path.join(CERTS, "roots.der"), "rb") as f:
            self.ca = f.read()
        self.thread = threading.Thread(target=self.accept_loop, daemon=True)
        self.thread.start()

    def stop(self):
        self.stopping.set()
        self.thread.join(2)
        self.sock.close()

    def accept_loop(self):
        while not self.stopping.is_set():
            try:
                c, _ = self.sock.accept()
            except (socket.timeout, OSError):
                continue
            threading.Thread(target=self.serve, args=(c,), daemon=True).start()

    def count(self, prefix):
        with self.lock:
            return sum(1 for r in self.requests if r["path"].startswith(prefix))

    def last(self, prefix):
        with self.lock:
            for r in reversed(self.requests):
                if r["path"].startswith(prefix):
                    return r
        return None

    # -- one connection
    def serve(self, c):
        try:
            c.settimeout(30)
            if self.ctx:
                c = self.ctx.wrap_socket(c, server_side=True)
            buf = b""
            while b"\r\n\r\n" not in buf:
                d = c.recv(65536)
                if not d:
                    return
                buf += d
                if len(buf) > 1 << 20:
                    return
            head, _, rest = buf.partition(b"\r\n\r\n")
            lines = head.decode("latin-1").split("\r\n")
            method, target, _ = lines[0].split(" ", 2)
            headers = {}
            for ln in lines[1:]:
                k, _, v = ln.partition(":")
                headers[k.strip().lower()] = v.strip()
            n = int(headers.get("content-length", "0") or 0)
            body = rest
            while len(body) < n:
                d = c.recv(65536)
                if not d:
                    break
                body += d
            req = {"method": method, "path": target, "headers": headers, "body": body}
            with self.lock:
                self.requests.append(req)
            self.respond(c, req)
        except (OSError, ssl.SSLError, ValueError):
            pass
        finally:
            try:
                c.close()
            except OSError:
                pass

    def send(self, c, status, headers, body=b"", reason="OK"):
        h = f"HTTP/1.1 {status} {reason}\r\n"
        for k, v in headers:
            h += f"{k}: {v}\r\n"
        if not any(k.lower() in ("content-length", "transfer-encoding") for k, _ in headers):
            h += f"Content-Length: {len(body)}\r\n"
        h += "Connection: close\r\n\r\n"
        c.sendall(h.encode("latin-1") + body)

    def page(self, c, body, extra=(), status=200, reason="OK"):
        self.send(c, status, [("Content-Type", "text/html; charset=utf-8"), *extra], body, reason)

    def wait(self, c, seconds):
        """Hold the connection open (stalls); return early once the client goes away or we stop."""
        end = time.time() + seconds
        c.settimeout(0.2)
        while time.time() < end and not self.stopping.is_set():
            try:
                if c.recv(1) == b"":
                    return
            except socket.timeout:
                continue
            except (OSError, ssl.SSLError):
                return

    def respond(self, c, req):
        method, target = req["method"], req["path"]
        u = urllib.parse.urlsplit(target)
        path = u.path
        if path == "/echo":
            raw = u.query if method == "GET" else req["body"].decode("latin-1")
            fields = urllib.parse.parse_qsl(raw, keep_blank_values=True)
            text = "&".join(f"{k}={v}" for k, v in fields)
            ctype = req["headers"].get("content-type", "")
            self.page(c, html(escape(f"Echo {method} {text}"), f"<pre style='position:absolute;left:300px;top:0;margin:0'>{escape(method)} {escape(text)}\n{escape(ctype)}</pre>"))
        elif path == "/redir/ok":
            self.page(c, html("Redirect target", "<p>arrived"))
        elif path in ("/redir/301", "/redir/302", "/redir/303", "/redir/307"):
            code = int(path[-3:])
            self.send(c, code, [("Location", "/redir/ok")], b"", "Redirect")
        elif path == "/redir/chain":
            self.send(c, 301, [("Location", "/redir/c2")], b"", "Moved")
        elif path == "/redir/c2":
            self.send(c, 302, [("Location", "/redir/c3")], b"", "Found")
        elif path == "/redir/c3":
            self.send(c, 303, [("Location", "/redir/c4")], b"", "See Other")
        elif path == "/redir/c4":
            self.send(c, 307, [("Location", "/redir/ok")], b"", "Temporary Redirect")
        elif path in ("/redir/loop", "/redir/loop2"):
            self.send(c, 302, [("Location", "/redir/loop2" if path == "/redir/loop" else "/redir/loop")], b"", "Found")
        elif path == "/chunked":
            body = html("Chunked page", "<p>" + "chunked text. " * 400)
            head = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
            c.sendall(head.encode())
            i = 0
            while i < len(body):
                n = min(len(body) - i, 37 + (i % 301))
                c.sendall(b"%x\r\n" % n + body[i:i + n] + b"\r\n")
                i += n
            c.sendall(b"0\r\n\r\n")
        elif path == "/gzip":
            import gzip
            body = gzip.compress(html("Gzip page", "<p>" + "compressed text. " * 500))
            self.page(c, body, [("Content-Encoding", "gzip")])
        elif path == "/deflate":
            body = zlib.compress(html("Deflate page", "<p>" + "deflated text. " * 500))
            self.page(c, body, [("Content-Encoding", "deflate")])
        elif path == "/cookie/set":
            self.send(c, 302, [("Location", "/cookie/echo"), ("Set-Cookie", "sid=wiffer42; Path=/"),
                               ("Set-Cookie", "theme=dark; Path=/")], b"", "Found")
        elif path == "/cookie/echo":
            ck = req["headers"].get("cookie", "none")
            self.page(c, html(escape(f"Cookie {ck}"), f"<pre>{escape(ck)}</pre>"))
        elif path == "/testca.der":
            self.send(c, 200, [("Content-Type", "application/x-x509-ca-cert")], self.ca)
        elif path == "/ht":  # short alias of /hostile/truncated (guest command lines are short)
            self.hostile(c, req, "truncated")
        elif path.startswith("/hostile/"):
            self.hostile(c, req, path[len("/hostile/"):])
        else:
            self.static(c, path)

    def static(self, c, path):
        rel = urllib.parse.unquote(path).lstrip("/") or "index.html"
        full = os.path.normpath(os.path.join(WEB, rel))
        if not full.startswith(WEB + os.sep) or not os.path.isfile(full):
            self.page(c, html("Not found", "<p>nothing here"), status=404, reason="Not Found")
            return
        with open(full, "rb") as f:
            body = f.read()
        self.send(c, 200, [("Content-Type", TYPES.get(os.path.splitext(full)[1], "application/octet-stream"))], body)

    def hostile(self, c, req, what):
        title = html("Hostile body", "<p>partial")
        if what == "stall-headers":
            c.sendall(b"HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nX-Slow: yes\r\n")
            self.wait(c, 600)
        elif what == "stall-body":
            c.sendall(b"HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: 100000\r\nConnection: close\r\n\r\n"
                      + html("Stalled body", "<p>first part of a body that never finishes"))
            self.wait(c, 600)
        elif what == "truncated":
            c.sendall(b"HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: 5000\r\nConnection: close\r\n\r\n"
                      + html("Truncated body", "<p>cut off"))
        elif what == "reset":
            c.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
            c.close()
        elif what == "garbage":
            c.sendall(random.Random(5).randbytes(20000))
        elif what == "hugeheaders":
            c.sendall(b"HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n")
            line = b"X-Padding: " + b"a" * 1000 + b"\r\n"
            try:
                for _ in range(8192):  # 8 MiB of headers
                    c.sendall(line)
                c.sendall(b"\r\n" + title)
            except OSError:
                pass
        elif what == "endless":
            c.sendall(b"HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n")
            first = html("Endless page", "<p>this page never ends. ")
            c.sendall(b"%x\r\n" % len(first) + first + b"\r\n")
            filler = b"<p>" + b"endless filler text. " * 100 + b"</p>"
            try:
                while not self.stopping.is_set():
                    c.sendall(b"%x\r\n" % len(filler) + filler + b"\r\n")
                    time.sleep(0.002)
            except OSError:
                pass
        elif what == "bomb":
            z = zlib.compressobj(9, zlib.DEFLATED, 31)  # gzip wrapper
            out = [z.compress(html("Bomb", "<p>"))]
            zeros = b" " * (1 << 20)
            for _ in range(1024):  # 1 GiB of spaces
                out.append(z.compress(zeros))
            out.append(z.flush())
            body = b"".join(out)
            self.page(c, body, [("Content-Encoding", "gzip")])
        elif what == "pngdims":
            self.page(c, html("Lying PNG", "<p>an image that claims to be 60000 by 60000 pixels</p>"
                              "<img src=/hostile/lying.png><p id=after>still here</p>"))
        elif what == "lying.png":
            self.send(c, 200, [("Content-Type", "image/png")], lying_png())
        else:
            self.page(c, html("Not found"), status=404, reason="Not Found")


if __name__ == "__main__":
    srv = WebServer(port=int(sys.argv[1]) if len(sys.argv) > 1 else 0)
    print(f"http://127.0.0.1:{srv.port}/")
    try:
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        srv.stop()
