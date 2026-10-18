#!/usr/bin/env python3
"""下载引擎集成测试用的本地服务器：Range、无 Range、慢速、HLS。"""
import http.server, re, sys, time, socketserver

def payload(size):
    return bytes((i * 7 + 3) % 251 for i in range(size))

CACHE = {}

def data_for(size):
    if size not in CACHE:
        CACHE[size] = payload(size)
    return CACHE[size]

class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def send_bytes(self, status, body, extra=None):
        self.send_response(status)
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":
            slow = "slow=1" in self.path
            step = 64 * 1024
            for i in range(0, len(body), step):
                try:
                    self.wfile.write(body[i:i + step])
                except (BrokenPipeError, ConnectionResetError):
                    return
                if slow:
                    time.sleep(0.05)

    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        path = self.path.split("?")[0]
        m = re.match(r"^/(file|norange)/(\d+)$", path)
        if m:
            data = data_for(int(m.group(2)))
            rng = self.headers.get("Range")
            if m.group(1) == "file" and rng:
                r = re.match(r"bytes=(\d+)-(\d*)", rng)
                start = int(r.group(1))
                end = int(r.group(2)) if r.group(2) else len(data) - 1
                end = min(end, len(data) - 1)
                if start >= len(data):
                    return self.send_bytes(416, b"", {"Content-Range": f"bytes */{len(data)}"})
                return self.send_bytes(206, data[start:end + 1], {
                    "Content-Range": f"bytes {start}-{end}/{len(data)}", "Accept-Ranges": "bytes",
                    "Content-Type": "application/octet-stream"})
            return self.send_bytes(200, data, {"Content-Type": "application/octet-stream"})
        if path == "/hls/master.m3u8":
            body = b"#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=100000\nlow.m3u8\n#EXT-X-STREAM-INF:BANDWIDTH=900000\nmedia.m3u8\n"
            return self.send_bytes(200, body, {"Content-Type": "application/vnd.apple.mpegurl"})
        if path == "/hls/media.m3u8":
            lines = ["#EXTM3U", "#EXT-X-TARGETDURATION:4", "#EXT-X-MEDIA-SEQUENCE:0"]
            for i in range(5):
                lines += ["#EXTINF:4.0,", f"seg{i}.ts"]
            lines.append("#EXT-X-ENDLIST")
            return self.send_bytes(200, ("\n".join(lines) + "\n").encode())
        m = re.match(r"^/hls/seg(\d+)\.ts$", path)
        if m:
            return self.send_bytes(200, bytes([int(m.group(1))]) * 1000)
        if path == "/1/clouddrive/share/sharepage/detail":
            q = self.path
            assert "stoken=ST%2B%2F%3D" in q, q
            files = [{"fid": "d1", "file_name": "目录", "dir": True, "pdir_fid": "0"},
                     {"fid": "f1", "file_name": "a.mp4", "size": 10, "dir": False, "pdir_fid": "0", "share_fid_token": "tok1"}]
            return self.send_json({"status": 200, "data": {"list": files}})
        if path == "/forbidden":
            return self.send_bytes(403, b"no")
        self.send_bytes(404, b"not found")

    def do_POST(self):
        import json
        length = int(self.headers.get("Content-Length") or 0)
        body = json.loads(self.rfile.read(length) or b"{}")
        path = self.path.split("?")[0]
        if path == "/1/clouddrive/share/sharepage/token":
            if body.get("passcode") != "abcd":
                return self.send_json({"status": 400, "code": 41008, "message": "提取码错误"})
            return self.send_json({"status": 200, "data": {"stoken": "ST+/=", "title": "测试分享"}})
        if path == "/1/clouddrive/file/download":
            if body.get("fids_token") != ["tok1"] or body.get("stoken") != "ST+/=":
                return self.send_json({"status": 400, "code": 41020, "message": "bad token"})
            if "Cookie" in self.headers and "__pus=" in self.headers["Cookie"]:
                return self.send_json({"status": 200, "data": [{"fid": "f1", "file_name": "a.mp4", "download_url": "https://cdn/login", "size": 10}]},
                                      {"Set-Cookie": "__puus=renewed; Path=/; Domain=127.0.0.1"})
            return self.send_json({"status": 200, "data": [{"fid": "f1", "file_name": "a.mp4", "download_url": "https://cdn/guest", "size": 10}]},
                                  {"Set-Cookie": "__pugs=guest123; Path=/; Expires=Wed, 21 Oct 2026 07:28:00 GMT; HttpOnly"})
        self.send_bytes(404, b"")

    def send_json(self, obj, extra=None):
        import json
        headers = {"Content-Type": "application/json"}
        headers.update(extra or {})
        self.send_bytes(200, json.dumps(obj).encode(), headers)

class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True

if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8765
    Server(("127.0.0.1", port), Handler).serve_forever()
