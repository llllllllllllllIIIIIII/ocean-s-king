#!/usr/bin/env python3
"""Fetch just the Windows export templates out of Godot's 1.2 GB template pack.

Why this exists
---------------
`Godot_v<ver>_export_templates.tpz` carries every platform's templates and weighs
about 1.2 GB.  On a slow / flaky line that is hours of downloading, and 95% of it
(linux, macos, android, ios, web) is useless for a Windows build.

The pack is a plain zip, and HTTP range requests work against GitHub's release
CDN, so this script **reads the zip remotely**: it fetches the central directory,
then only the compressed bytes of the members we actually need, and writes them
straight into Godot's template folder:

    %APPDATA%\\Godot\\export_templates\\<dotted version>\\

That is where the editor looks (e.g. `4.7.2.stable`).  After this, run
`tools/package_win.ps1`.

Usage:
    python tools/fetch_export_templates.py                # release + debug + version.txt
    python tools/fetch_export_templates.py --release-only # skip the debug template
"""

from __future__ import annotations

import argparse
import io
import os
import sys
import time
import urllib.error
import urllib.request
import zipfile

ASSET = "Godot_v{ver}_export_templates.tpz"
URL = ("https://github.com/godotengine/godot/releases/download/{ver}/" + ASSET)

WANTED = [
    "templates/windows_release_x86_64.exe",
    "templates/windows_debug_x86_64.exe",
    "templates/version.txt",
]

# How much to pull per range request.  Bigger = fewer requests, but a stalled
# connection wastes more; 4 MB is a good middle ground on a slow line.
CHUNK = 4 * 1024 * 1024


class HttpRangeFile(io.RawIOBase):
    """A seekable, read-only file object backed by HTTP range requests.

    `zipfile` needs `seek`/`tell`/`read`; everything else (parsing the central
    directory, locating a member) is then handled by the stdlib.
    """

    def __init__(self, url: str, retries: int = 6, backoff: float = 8.0):
        self.url = url
        self.retries = retries
        self.backoff = backoff
        self.pos = 0
        self._buf = b""
        self._buf_at = 0
        self.bytes_fetched = 0
        self.requests = 0
        self.size = self._probe_size()

    # -- size -----------------------------------------------------------------
    def _probe_size(self) -> int:
        headers = self._get(0, 0, want_headers=True)
        cr = headers.get("Content-Range", "")
        if "/" not in cr:
            raise RuntimeError(f"server did not answer with Content-Range: {cr!r}")
        return int(cr.rsplit("/", 1)[1])

    def _get(self, start: int, end: int, want_headers: bool = False):
        req = urllib.request.Request(
            self.url,
            headers={"Range": f"bytes={start}-{end}", "User-Agent": "ocean-s-king-build"},
        )
        last = None
        for attempt in range(1, self.retries + 1):
            try:
                with urllib.request.urlopen(req, timeout=180) as resp:
                    data = resp.read()
                self.requests += 1
                self.bytes_fetched += len(data)
                if want_headers:
                    return resp.headers
                return data
            except (urllib.error.URLError, TimeoutError, ConnectionError) as exc:
                last = exc
                wait = self.backoff * attempt
                print(f"    [range] {start}-{end} 第 {attempt} 次失败（{exc}），{wait:.0f}s 后重试")
                time.sleep(wait)
        raise RuntimeError(f"range {start}-{end} 一直失败：{last}")

    # -- io.RawIOBase ---------------------------------------------------------
    def readable(self) -> bool:
        return True

    def seekable(self) -> bool:
        return True

    def tell(self) -> int:
        return self.pos

    def seek(self, offset: int, whence: int = os.SEEK_SET) -> int:
        if whence == os.SEEK_SET:
            self.pos = offset
        elif whence == os.SEEK_CUR:
            self.pos += offset
        elif whence == os.SEEK_END:
            self.pos = self.size + offset
        else:
            raise ValueError(f"bad whence {whence}")
        return self.pos

    def read(self, n: int = -1) -> bytes:
        if n is None or n < 0:
            n = min(self.size - self.pos, CHUNK)
        if n == 0 or self.pos >= self.size:
            return b""
        end = min(self.pos + n, self.size) - 1
        # reuse the cached window when the request is inside it
        if self._buf and self._buf_at <= self.pos and self.pos + n <= self._buf_at + len(self._buf):
            off = self.pos - self._buf_at
            self.pos += n
            return self._buf[off:off + n]
        want = min(max(n, CHUNK), self.size - self.pos)
        data = self._get(self.pos, self.pos + want - 1)
        self._buf, self._buf_at = data, self.pos
        self.pos += n
        return data[:n]


def dest_dir(version: str) -> str:
    appdata = os.environ.get("APPDATA")
    if not appdata:
        raise RuntimeError("找不到 %APPDATA% —— 这个脚本是给 Windows 上的 Godot 用的")
    return os.path.join(appdata, "Godot", "export_templates", version.replace("-", "."))


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--version", default="4.7.2-stable")
    ap.add_argument("--release-only", action="store_true")
    ap.add_argument("--url", default="")
    args = ap.parse_args()

    url = args.url or URL.format(ver=args.version)
    wanted = [w for w in WANTED if not (args.release_only and "debug" in w)]
    out = dest_dir(args.version)

    print("=== fetch_export_templates ===")
    print(f"url : {url}")
    print(f"dest: {out}")

    remote = HttpRangeFile(url)
    print(f"pack: {remote.size / (1024 * 1024):.1f} MB（我们只取其中 Windows 那几个成员）")

    t0 = time.time()
    os.makedirs(out, exist_ok=True)
    with zipfile.ZipFile(remote) as zf:
        names = set(zf.namelist())
        for name in wanted:
            if name not in names:
                print(f"  !! 压缩包里没有 {name}")
                return 2
            short = os.path.basename(name)
            target = os.path.join(out, short)
            print(f"  -> {short} …", flush=True)
            with zf.open(name) as src, open(target, "wb") as dst:
                while True:
                    chunk = src.read(1 << 20)
                    if not chunk:
                        break
                    dst.write(chunk)
            print(f"     {os.path.getsize(target) / (1024 * 1024):.1f} MB 已写入")

    dt = time.time() - t0
    print(
        f"完成：只取了 {remote.bytes_fetched / (1024 * 1024):.1f} MB"
        f"（{remote.requests} 次 range 请求），耗时 {dt / 60:.1f} 分钟"
    )
    print("下一步：powershell -ExecutionPolicy Bypass -File tools/package_win.ps1")
    return 0


if __name__ == "__main__":
    sys.exit(main())
