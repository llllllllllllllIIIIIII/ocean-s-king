#!/usr/bin/env python3
"""生成游戏用的音频（M8）。**自产，不下载**。

为什么不用 CC0 素材库：铁律 13 要的是"来源与许可证逐条写清楚"。
自己合成出来的波形天然满足这一条 —— 没有第三方权利、没有出处不明的文件，
而且体积可控（全是 16-bit 单声道，几十 KB 一条）。

生成到 assets/audio/：
    amb_wind.wav     环境：风（随天气与风速调音量）
    amb_waves.wav    环境：浪（随航速与天气）
    sfx_anchor.wav   交互：抛锚（水花 + 链子）
    sfx_sail.wav     交互：调帆（帆布抖动）
    sfx_cannon.wav   交互：开炮（低频爆响 + 硝烟般的尾音）
    sfx_hammer.wav   交互：锤击（修船）
    theme.wav        主题：十六世纪远洋，低沉弦乐似的长音（约 24 秒，可循环）

用法：
    python tools/gen_audio.py

⚠️ 全部是**确定性**的（用 LCG 而不是 random），重新跑一次得到一模一样的文件。
"""

import math
import pathlib
import struct
import sys
import wave

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "assets" / "audio"
RATE = 22050


class Rng:
    """确定性伪随机（和游戏里"不用随机数"的纪律一致）。"""

    def __init__(self, seed=12345):
        self.s = seed & 0xFFFFFFFF

    def next(self):
        self.s = (1103515245 * self.s + 12345) & 0x7FFFFFFF
        return self.s / 0x7FFFFFFF * 2.0 - 1.0


def write_wav(name, samples):
    OUT.mkdir(parents=True, exist_ok=True)
    path = OUT / name
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        frames = bytearray()
        for s in samples:
            v = int(max(-1.0, min(1.0, s)) * 32000)
            frames += struct.pack("<h", v)
        w.writeframes(bytes(frames))
    print("  wrote %-18s %6.1f KB  %4.1f 秒" % (
        name, path.stat().st_size / 1024.0, len(samples) / RATE))


def lowpass(samples, a):
    """一阶低通：a 越小越闷。"""
    out = []
    y = 0.0
    for x in samples:
        y += a * (x - y)
        out.append(y)
    return out


def fade(samples, fade_in=0.0, fade_out=0.0):
    n = len(samples)
    fi = int(fade_in * RATE)
    fo = int(fade_out * RATE)
    out = list(samples)
    for i in range(min(fi, n)):
        out[i] *= i / max(1, fi)
    for i in range(min(fo, n)):
        out[n - 1 - i] *= i / max(1, fo)
    return out


def wind(seconds=8.0):
    """风：低通噪声 + 缓慢起伏。"""
    rng = Rng(7)
    raw = [rng.next() for _ in range(int(seconds * RATE))]
    base = lowpass(raw, 0.02)
    out = []
    for i, s in enumerate(base):
        t = i / RATE
        gust = 0.65 + 0.35 * math.sin(2 * math.pi * t / 5.0) * math.sin(2 * math.pi * t / 1.7)
        out.append(s * 2.6 * gust)
    return fade(out, 0.6, 0.6)


def waves(seconds=8.0):
    """浪：更低更慢的噪声，一波一波。"""
    rng = Rng(21)
    raw = [rng.next() for _ in range(int(seconds * RATE))]
    base = lowpass(raw, 0.006)
    out = []
    for i, s in enumerate(base):
        t = i / RATE
        swell = max(0.0, math.sin(2 * math.pi * t / 3.4)) ** 2
        out.append(s * 4.2 * swell)
    return fade(out, 0.8, 0.8)


def anchor(seconds=2.2):
    """抛锚：水花（噪声爆发）+ 链子（高频抖动）。"""
    rng = Rng(33)
    out = []
    for i in range(int(seconds * RATE)):
        t = i / RATE
        splash = rng.next() * math.exp(-t * 3.0) * 0.7
        chain = math.sin(2 * math.pi * 1400 * t) * math.exp(-t * 1.2) * 0.12 \
            * (1.0 if math.sin(2 * math.pi * 9 * t) > 0 else 0.25)
        out.append(splash + chain)
    return lowpass(out, 0.45)


def sail(seconds=1.4):
    """调帆：帆布抖两下。"""
    rng = Rng(41)
    out = []
    for i in range(int(seconds * RATE)):
        t = i / RATE
        flap = math.exp(-((t - 0.15) ** 2) / 0.002) + 0.7 * math.exp(-((t - 0.5) ** 2) / 0.004)
        out.append(rng.next() * flap * 0.5)
    return lowpass(out, 0.25)


def cannon(seconds=2.6):
    """开炮：低频爆响 + 长尾。"""
    rng = Rng(53)
    out = []
    for i in range(int(seconds * RATE)):
        t = i / RATE
        boom = math.sin(2 * math.pi * 60 * t * math.exp(-t * 1.5)) * math.exp(-t * 2.2)
        noise = rng.next() * math.exp(-t * 4.0)
        tail = rng.next() * math.exp(-t * 1.1) * 0.18
        out.append(boom * 0.9 + noise * 0.7 + tail)
    return lowpass(out, 0.30)


def hammer(seconds=0.9):
    """锤击：两声。"""
    rng = Rng(61)
    out = []
    for i in range(int(seconds * RATE)):
        t = i / RATE
        hit = math.exp(-((t - 0.05) ** 2) / 0.00004) + 0.8 * math.exp(-((t - 0.42) ** 2) / 0.00006)
        ring = math.sin(2 * math.pi * 900 * t) * math.exp(-t * 9.0) * 0.25
        out.append((rng.next() * 0.5 + ring) * hit)
    return lowpass(out, 0.5)


def theme(seconds=24.0):
    """主题：低沉的长音 + 五度，慢速起伏。像弦乐在远处。"""
    out = []
    chords = [
        (110.0, [1.0, 1.5, 2.0]),          # A
        (98.0, [1.0, 1.5, 2.0]),           # G
        (87.31, [1.0, 1.5, 2.0]),          # F
        (82.41, [1.0, 1.5, 2.0]),          # E
    ]
    bar = seconds / len(chords)
    for i in range(int(seconds * RATE)):
        t = i / RATE
        idx = min(len(chords) - 1, int(t / bar))
        base, ratios = chords[idx]
        local = (t - idx * bar) / bar
        env = min(1.0, local * 4.0) * min(1.0, (1.0 - local) * 4.0)
        v = 0.0
        for k, r in enumerate(ratios):
            f = base * r
            v += math.sin(2 * math.pi * f * t) / (2.0 + k)
            v += math.sin(2 * math.pi * f * 1.003 * t) / (3.0 + k)   # 轻微失谐，像两把琴
        v *= env * 0.22
        out.append(v)
    return fade(out, 0.8, 1.2)


def main() -> int:
    print("=== gen_audio ===")
    write_wav("amb_wind.wav", wind())
    write_wav("amb_waves.wav", waves())
    write_wav("sfx_anchor.wav", anchor())
    write_wav("sfx_sail.wav", sail())
    write_wav("sfx_cannon.wav", cannon())
    write_wav("sfx_hammer.wav", hammer())
    write_wav("theme.wav", theme())
    print("全部自产（LCG 合成），重新跑会得到同样的文件。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
