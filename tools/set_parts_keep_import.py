#!/usr/bin/env python3
"""把 `assets/ship/parts/**/*.svg` 的导入方式设成 "Keep File (exported as is)"。

为什么必须这么做
----------------
`SvgBank` 的整个设计是**运行时读 .svg 源文本**再按缩放栅格化
（`Image.load_svg_from_string`），所以拉多远多近都锐利。
但 `.svg` 在 Godot 里是**导入资源**：`.import` 写着 `importer="texture"`，
导出时 `res://…svg` 会被**重映射**到 `.godot/imported/…ctex`。
于是导出包里的运行时读不到源文本，部件全部加载失败 —— 船退化成一个纯色方块。
（源码模式看起来完全正常，所以这个坑只在导出包里露出来；M8 收尾实测踩到。）

设成 "keep" 之后：Godot 不再导入它，源文件原样进包，`FileAccess` 读得到。

用法（加新部件之后跑一次即可）：
    python tools/set_parts_keep_import.py
"""

from __future__ import annotations

import glob
import os
import sys

TEMPLATE = """[remap]

importer="keep"

[deps]

source_file="res://{rel}"
dest_files=["res://{rel}"]
"""


def main() -> int:
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    pattern = os.path.join(root, "assets", "ship", "parts", "**", "*.svg.import")
    changed = 0
    seen = 0
    for path in sorted(glob.glob(pattern, recursive=True)):
        seen += 1
        rel = os.path.relpath(path[: -len(".import")], root).replace(os.sep, "/")
        wanted = TEMPLATE.format(rel=rel)
        with open(path, "r", encoding="utf-8") as fh:
            now = fh.read()
        if now == wanted:
            continue
        with open(path, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(wanted)
        changed += 1
    print(f"parts: {seen} 个 .import，改了 {changed} 个（其余本来就是 keep）")
    if seen == 0:
        print("!! 一个都没找到 —— 路径不对？")
        return 1
    print("下一步：& $g --headless --path . --import   （让引擎按 keep 重扫）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
