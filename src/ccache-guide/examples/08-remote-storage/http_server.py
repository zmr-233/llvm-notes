#!/usr/bin/env python3
"""最小的 HTTP 对象存储，只为演示 ccache 的 http 远端存储。

GET/HEAD 读、PUT 写、DELETE 删；对象以文件形式落在 <根目录> 下，URL 路径就是相对路径。
没有鉴权、不做清理。真要部署请用 nginx（WebDAV 模块）、bazel-remote 之类的现成服务。

用法：http_server.py <根目录> <端口文件>
    绑定 127.0.0.1 上任意空闲端口，把实际端口号写进 <端口文件>，然后一直服务到被杀掉。
"""

import http.server
import os
import sys
import tempfile
from pathlib import Path

ROOT = Path(sys.argv[1]).resolve()
PORT_FILE = Path(sys.argv[2])


class Handler(http.server.BaseHTTPRequestHandler):
    # HTTP/1.1 才支持 keep-alive；代价是每个响应都必须带 Content-Length
    protocol_version = "HTTP/1.1"

    def target(self) -> Path:
        p = (ROOT / self.path.split("?", 1)[0].lstrip("/")).resolve()
        if not p.is_relative_to(ROOT):
            raise PermissionError(self.path)
        return p

    def reply(self, code: int, body: bytes = b"") -> None:
        self.send_response(code)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def body(self) -> bytes:
        if self.headers.get("Transfer-Encoding", "").lower() != "chunked":
            return self.rfile.read(int(self.headers.get("Content-Length", 0)))
        out = bytearray()
        while size := int(self.rfile.readline().split(b";")[0], 16):
            out += self.rfile.read(size)
            self.rfile.readline()  # 每块数据后的 CRLF
        while self.rfile.readline() not in (b"\r\n", b"\n", b""):
            pass  # 末尾可能跟着 trailer 头，读到空行为止
        return bytes(out)

    def do_GET(self) -> None:
        p = self.target()
        if p.is_file():
            self.reply(200, p.read_bytes())
        else:
            self.reply(404)

    do_HEAD = do_GET

    def do_PUT(self) -> None:
        p = self.target()
        data = self.body()
        p.parent.mkdir(parents=True, exist_ok=True)
        fd, tmp = tempfile.mkstemp(dir=p.parent)
        with os.fdopen(fd, "wb") as f:
            f.write(data)
        os.replace(tmp, p)  # 先写临时文件再改名：读者永远看不到写了一半的对象
        self.reply(201)

    def do_DELETE(self) -> None:
        p = self.target()
        existed = p.is_file()
        p.unlink(missing_ok=True)
        self.reply(204 if existed else 404)

    def log_message(self, fmt: str, *args) -> None:
        sys.stderr.write("[http] " + (fmt % args) + "\n")


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
tmp = PORT_FILE.with_suffix(".tmp")
tmp.write_text(str(server.server_address[1]))
tmp.replace(PORT_FILE)
server.serve_forever()
