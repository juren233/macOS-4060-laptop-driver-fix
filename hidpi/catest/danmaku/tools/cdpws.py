# minimal Chrome DevTools client (stdlib only): cdp.py <ws-url> <js-expression>  -> prints the value (awaitPromise)
import sys, socket, base64, os, json, struct, urllib.parse
def ws_connect(url):
    u = urllib.parse.urlparse(url); s = socket.create_connection((u.hostname, u.port), timeout=600)
    key = base64.b64encode(os.urandom(16)).decode()
    s.sendall((f"GET {u.path} HTTP/1.1\r\nHost: {u.hostname}:{u.port}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
               f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n").encode())
    buf = b""
    while b"\r\n\r\n" not in buf: buf += s.recv(4096)
    return s, buf.split(b"\r\n\r\n", 1)[1]
def send(s, txt):
    d = txt.encode(); m = os.urandom(4); n = len(d)
    h = bytes([0x81]) + (bytes([0x80|n]) if n < 126 else bytes([0x80|126]) + struct.pack(">H", n) if n < 65536 else bytes([0x80|127]) + struct.pack(">Q", n))
    s.sendall(h + m + bytes(b ^ m[i % 4] for i, b in enumerate(d)))
class R:
    def __init__(self, s, pre): self.s, self.b = s, pre
    def need(self, n):
        while len(self.b) < n:
            c = self.s.recv(65536)
            if not c: raise EOFError
            self.b += c
        r, self.b = self.b[:n], self.b[n:]; return r
    def msg(self):
        out = b""
        while True:
            h = self.need(2); fin = h[0] & 0x80; n = h[1] & 0x7f
            if n == 126: n = struct.unpack(">H", self.need(2))[0]
            elif n == 127: n = struct.unpack(">Q", self.need(8))[0]
            out += self.need(n)
            if fin: return out
