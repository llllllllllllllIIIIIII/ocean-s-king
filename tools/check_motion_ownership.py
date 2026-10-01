#!/usr/bin/env python3
"""铁律检查：船的位置与速度只能由 scripts/ship_dynamics.gd 写。

AGENTS.md 第 5 条 / docs/01 的"唯一的数据流原则"：
    任何系统都不允许直接改船的速度或位置（包括剧情事件和调试工具）。
    数据流严格单向：玩家 → 船员 → 帆 → 船 → 表现。

Day 3 的验收标准就是这句话：**代码里搜不到任何"直接设置 velocity/position"的作弊行**。
动态测试证明不了这一点（作弊代码在测试时可能恰好不跑），所以这里做静态检查。

检查两类东西：
  1. 物理体速度的直接赋值（.velocity / .linear_velocity / .angular_velocity）
     —— 全项目禁止：船的运动是我们自己积分的，不用引擎物理。
  2. 船的运动状态字段（_pos_m / _heading_deg / _u / _w / _heel_deg ...）
     —— 只允许出现在 ship_dynamics.gd 里。

用法：
    python tools/check_motion_ownership.py
退出码 0 = 干净，1 = 找到越权写入。
"""

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SCRIPTS = ROOT / "scripts"
OWNER = "ship_dynamics.gd"          # 唯一允许写船的运动状态的文件

# 全项目禁止：直接给引擎物理体写速度/角速度
BANNED_ANYWHERE = [
    (re.compile(r"\.\s*(linear_velocity|angular_velocity|velocity)\s*="),
     "直接给物理体写速度（船的运动必须由 ship_dynamics 积分出来）"),
]

# 只有船的运动状态文件能写这些字段（读没关系）
OWNED_STATE = ["_pos_m", "_heading_deg", "_u", "_w", "_heel_deg", "_yaw_rate_dps"]
OWNED_RE = re.compile(r"(?<![A-Za-z0-9_])(" + "|".join(OWNED_STATE) + r")\s*"
                      r"(=|\+=|-=|\*=|/=)")

# 声明行不算写入（var _u := 0.0）
DECL_RE = re.compile(r"^\s*(@export\s+)?var\s+")


def scan(path: pathlib.Path):
    problems = []
    text = path.read_text(encoding="utf-8")
    for lineno, line in enumerate(text.splitlines(), start=1):
        code = line.split("#", 1)[0]
        for pattern, why in BANNED_ANYWHERE:
            if pattern.search(code):
                problems.append((lineno, code.strip(), why))
        if path.name != OWNER and not DECL_RE.match(code):
            m = OWNED_RE.search(code)
            if m:
                problems.append((
                    lineno, code.strip(),
                    "越权写船的运动状态 %s（只有 %s 能写）" % (m.group(1), OWNER)))
    return problems


def main() -> int:
    print("=== check_motion_ownership ===")
    files = sorted(SCRIPTS.rglob("*.gd"))
    if not files:
        print("找不到任何脚本：%s" % SCRIPTS)
        return 1
    total = 0
    for path in files:
        for lineno, code, why in scan(path):
            total += 1
            print("  [FAIL] %s:%d  %s\n         -> %s"
                  % (path.relative_to(ROOT), lineno, code, why))
    if total == 0:
        print("  [PASS] 检查 %d 个脚本：没有任何直接写船速/船位的代码" % len(files))
        print("=== OK ===")
        return 0
    print("=== 失败：%d 处越权写入 ===" % total)
    return 1


if __name__ == "__main__":
    sys.exit(main())
