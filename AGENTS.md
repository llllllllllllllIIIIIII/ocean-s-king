# 环球航行（ocean-s-king）· 项目约定

16 世纪麦哲伦环球航行背景的远洋航行模拟 / 探索 / 管理游戏。
**2D 正交表现 + 3D 空间逻辑。** 7 天垂直切片开发中。

> 新窗口接手时：先读 `docs/07-交接.md`（当前进度快照），再读 `docs/01`（设计定稿）。
> 本文件只放**不随进度变**的约定。

---

## 环境

| 项 | 值 |
|---|---|
| 引擎 | Godot 4.7.2 便携版，固定路径 `D:\Godot\` |
| 仓库 | `C:\Users\杨一璇\Desktop\环球航行`（**独立仓库**） |
| ⚠️ | 桌面本身是**另一个** git 仓库且无提交，两者别混，别在桌面 `git add .` |
| 远端 | `origin` = https://github.com/llllllllllllllIIIIIII/ocean-s-king.git |

```powershell
$g = 'D:\Godot\Godot_v4.7.2-stable_win64_console.exe'
```

---

## 常用命令

```powershell
python tools/gen_ship.py                                               # 重新生成船体数据 + 船壳 SVG
& $g --headless --path . --script res://tests/validate_ship.gd         # 数据校验（退出码 0/1）
& $g --headless --path . --script res://tests/test_ship_debug_logic.gd # 无头驱动场景逻辑
& $g --path . res://scenes/ship_debug.tscn -- shots                    # 自动截图
& $g --path . res://scenes/ship_debug.tscn                             # 手动看
```

验证体系的完整说明在 `docs/06`。

---

## 项目铁律

1. **`ship.json` 只放结构，不放会变的值。** 速度、帆角、当前损伤、船员位置一律只在运行时内存里。
2. **船是数据，不是代码。** 改船 = 改生成器 + 重新生成；不要在 GDScript 里硬编码船体形状。
3. **`data/ships/*.json` 和 `assets/ship/parts/hull/hull_outline.svg` 是生成产物。**
   要改就改 `tools/gen_ship.py` 再重新生成，**不要手改这两个文件**。
4. **甲板外形与船壳轮廓必须同源**（都来自 `tools/gen_ship.py` 的 `WIDTHS`），
   否则必然出现"甲板比船壳宽两格"这种极难排查的错。
5. **任何系统都不允许直接改船的速度或位置**（包括剧情事件和调试工具）。
   数据流严格单向：玩家 → 船员 → 帆 → 船 → 表现。
6. **玩家不直接操船**：只选目标点 / 帆档，船员执行调帆，船在风力作用下运动。
7. **船内一律用船局部坐标**：+x 船首、+y 右舷、原点 = 桅杆底座。
8. **美术用 SVG 部件拼装**，运行时用 `Image.load_svg_from_string(svg, scale)`
   按当前缩放级别栅格化（这是矢量清晰度的关键，不要退回固定分辨率纹理导入）。
9. **四层共用 20×7 网格**，跨层连接 = 同一个 (x, y) 换一个 z。
10. **底层只有格子图**；房间是格子上的语义标签，不是独立的寻路结构。

---

## 已知的坑（全部踩过，别再踩）

| 坑 | 症状 | 对策 |
|---|---|---|
| Windows PowerShell 5.1 把无 BOM 的 `.ps1` 当 GBK 读 | 中文字符串把解析器搞崩 | `.ps1` 一律写**纯 ASCII** |
| Godot headless 不能截图 | `get_texture()` 返回 null | 画面验证走**窗口模式 + 自动截图** |
| `Camera2D.zoom` 是**越大越放大** | 滚轮方向写反 | 见 `docs/06` 第 4 节 |
| 截图时间线放在 `_draw()` 里 | 帧号推进不可控，54 帧跑了 22 秒 | 放 `_process()`；改完状态**隔一帧**再截 |
| 截图模式没禁用输入 | 一次误触滚轮污染整组图 | `_shot_mode` 时直接 return |
| JSON 数字解析成 float | 字典键 `2` 找不到 `2.0` | 存键时显式 `int(...)` |
| 无头 `add_child()` 后立刻断言 | `_ready()` 还没跑，内部状态是空的 | 等至少一帧 |
| 类型化数组不能直接赋值 | `Array[int] = dict.keys()` 报错 | 用 `.assign()` |
| Godot 默认字体没有中文字形 | 标签显示成方块 | 加载 `C:/Windows/Fonts/msyh.ttc` |
| 用真实按键输入测试 | 结果不可复现 | 构造 `InputEventMouseButton` 直接喂 `_unhandled_input()` |

---

## 每日固定动作

**开工前**
1. 跑一遍昨天的构建，确认没坏
2. 读 `docs/07-交接.md`，在 `docs/02` 写下今天的第一个动作

**收工前**
1. `python tools/gen_ship.py`（如果改了船体）+ 跑校验
2. 动了渲染就截一组图看一眼
3. `git commit` + `git tag dayN` + `git push --tags`
4. 更新 `docs/02` 当日记录 **和** `docs/07-交接.md`

> 每天结束**必须有一个能跑的版本**。宁可功能少，不可功能坏。
> 每天收工后换新窗口，不要一个窗口连干三天——摘要是**有损**的。

---

## 关于子 agent

当前配置要求**不主动派子 agent**，除非用户明确要求。

适合并行的：互相独立的产出（批量画 SVG 部件、写互不依赖的测试脚本、大范围核对文档）。
不适合的：强顺序依赖的链路（气动 → 指挥链路 → 船员），拆了更慢。

---

## 关于 skill

本项目**不需要**为它写 skill。项目约定放本文件、进度放 `docs/07` 就够了，
两者都在仓库里、都进版本管理。skill 只在"要把这套工作流复用到**别的**项目"时才有价值。
