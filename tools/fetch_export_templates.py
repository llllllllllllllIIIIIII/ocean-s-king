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
import concurrent.futures
import io
import os
import sys
import time
import urllib.error
import urllib.request
import zipfile
import zlib

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

# Where the per-chunk files live, so a rerun continues instead of restarting.
PARTS_DIR = os.path.join(os.environ.get("TEMP", "."), "godot_tpl", "parts")


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
        headers = self.get(0, 0, want_headers=True)
        cr = headers.get("Content-Range", "")
        if "/" not in cr:
            raise RuntimeError(f"server did not answer with Content-Range: {cr!r}")
        return int(cr.rsplit("/", 1)[1])

    def get(self, start: int, end: int, want_headers: bool = False,
            retries: int | None = None, backoff: float | None = None):
        req = urllib.request.Request(
            self.url,
            headers={"Range": f"bytes={start}-{end}", "User-Agent": "ocean-s-king-build"},
        )
        tries = retries if retries is not None else self.retries
        wait0 = backoff if backoff is not None else self.backoff
        last = None
        for attempt in range(1, tries + 1):
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
                if attempt < tries:
                    wait = wait0 * attempt
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
        data = self.get(self.pos, self.pos + want - 1)
        self._buf, self._buf_at = data, self.pos
        self.pos += n
        return data[:n]


def member_span(remote: HttpRangeFile, info: zipfile.ZipInfo) -> tuple[int, int]:
    """成员数据在文件里的绝对起点 + 压缩长度。

    本地文件头的 name/extra 长度**可以和中央目录里的不一样**（zip 规范允许），
    所以要按本地头的实际值算数据起点（这是解压出错最常见的坑）。
    """
    head = remote.get(info.header_offset, info.header_offset + 29)
    name_len = int.from_bytes(head[26:28], "little")
    extra_len = int.from_bytes(head[28:30], "little")
    return info.header_offset + 30 + name_len + extra_len, info.compress_size


def fetch_member_parallel(remote: HttpRangeFile, info: zipfile.ZipInfo,
                          threads: int, chunk: int, parts_dir: str) -> bytes:
    """把成员的压缩字节**分块并行**取回来，并且**每一块都落盘**。

    为什么要落盘：这条线随时会掉（WinError 10060/10054 见得多）。一块掉链子就丢掉整份
    36 MB 太亏 —— 每块写成 `parts/<成员>.<序号>.bin`，重跑时已经齐的块直接跳过，
    于是"重跑"是接着干，不是从头来。
    """
    start, size = member_span(remote, info)
    spans = [(o, min(o + chunk, size)) for o in range(0, size, chunk)]
    os.makedirs(parts_dir, exist_ok=True)
    stem = os.path.basename(info.filename)
    paths = [os.path.join(parts_dir, f"{stem}.{i:03d}.bin") for i in range(len(spans))]
    done = 0
    reused = 0
    t0 = time.time()

    def one(idx: int) -> None:
        nonlocal done, reused
        a, b = spans[idx]
        want = b - a
        path = paths[idx]
        if os.path.exists(path) and os.path.getsize(path) == want:
            reused += 1
            done += 1
            return
        attempt = 0
        while True:
            attempt += 1
            try:
                data = remote.get(start + a, start + b - 1, retries=1, backoff=1.0)
                if len(data) != want:
                    raise RuntimeError(f"短读：{len(data)} != {want}")
                with open(path, "wb") as fh:
                    fh.write(data)
                break
            except Exception as exc:                      # noqa: BLE001 - 这条线什么都可能抛
                wait = min(20.0, 2.0 * attempt)
                print(f"     [块 {idx + 1}/{len(spans)}] 第 {attempt} 次失败（{exc}），{wait:.0f}s 后再来",
                      flush=True)
                time.sleep(wait)
        done += 1
        if done % 4 == 0 or done == len(spans):
            got = sum(os.path.getsize(p) for p in paths if os.path.exists(p))
            rate = got / max(0.001, time.time() - t0) / 1024.0
            print(f"     {done}/{len(spans)} 块 · 盘上 {got / (1024 * 1024):.1f}/"
                  f"{size / (1024 * 1024):.1f} MB · {rate:.0f} KB/s（复用 {reused} 块）", flush=True)

    with concurrent.futures.ThreadPoolExecutor(max_workers=threads) as pool:
        list(pool.map(one, range(len(spans))))
    chunks = []
    for i, path in enumerate(paths):
        with open(path, "rb") as fh:
            chunks.append(fh.read())
    data = b"".join(chunks)
    if info.compress_type == zipfile.ZIP_STORED:
        return data
    if info.compress_type == zipfile.ZIP_DEFLATED:
        return zlib.decompressobj(-15).decompress(data)
    raise RuntimeError(f"不认识的压缩方式：{info.compress_type}")


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
    ap.add_argument("--threads", type=int, default=6, help="并行连接数（这条线单连接只有几十 KB/s）")
    ap.add_argument("--chunk-mb", type=int, default=2, help="每块多大（MB）")
    args = ap.parse_args()

    url = args.url or URL.format(ver=args.version)
    wanted = [w for w in WANTED if not (args.release_only and "debug" in w)]
    out = dest_dir(args.version)

    print("=== fetch_export_templates ===")
    print(f"url : {url}")
    print(f"dest: {out}")

    remote = HttpRangeFile(url)
    print(f"pack: {remote.size / (1024 * 1024):.1f} MB（我们只取其中 Windows 那几个成员）")

    small = 4 * 1024 * 1024          # 小于这个体积的成员就顺序取，不值得起线程
    threads = max(1, args.threads)
    chunk = max(1, args.chunk_mb) * 1024 * 1024
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
            info = zf.getinfo(name)
            print(f"  -> {short}（压缩后 {info.compress_size / (1024 * 1024):.1f} MB，"
                  f"解开 {info.file_size / (1024 * 1024):.1f} MB）", flush=True)
            ts = time.time()
            if info.compress_size >= small and threads > 1:
                blob = fetch_member_parallel(remote, info, threads, chunk, PARTS_DIR)
            else:
                blob = zf.read(name)
            with open(target, "wb") as dst:
                dst.write(blob)
            print(f"     {os.path.getsize(target) / (1024 * 1024):.1f} MB 已写入"
                  f"（{time.time() - ts:.0f} 秒）")

    dt = time.time() - t0
    print(
        f"完成：只取了 {remote.bytes_fetched / (1024 * 1024):.1f} MB"
        f"（{remote.requests} 次 range 请求），耗时 {dt / 60:.1f} 分钟"
    )
    print("下一步：powershell -ExecutionPolicy Bypass -File tools/package_win.ps1")
    return 0


if __name__ == "__main__":
    sys.exit(main())
