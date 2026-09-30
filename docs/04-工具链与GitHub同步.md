# 工具链与 GitHub 同步（待你确认）

> 这份文档是 Day 1 的施工单。里面有三件事**必须你来做**，我做不了，我标了 🔴。

---

## 1. Godot：现状与安装

### 现状（我已查过）

| 项目 | 状态 |
|---|---|
| `godot` 命令 | 没有 |
| Program Files / LOCALAPPDATA / 桌面 / 下载 / D 盘 / E 盘 | 全盘搜不到任何 `Godot*.exe` |
| 结论 | **Godot 完全没装，这是 Day 1 的硬前置** |

### 装什么

最新稳定版：**Godot 4.7.2**（2026-08-18 发布）。

下载页面的两个 Windows 包：

| 包 | 用途 | 选哪个 |
|---|---|---|
| `Godot_v4.7.2-stable_win64.exe.zip` | 标准版，GDScript | **选这个** |
| `Godot_v4.7.2-stable_mono_win64.zip` | 带 C# 支持，体积大一倍 | 不用，我们不用 C# |

直链：
`https://github.com/godotengine/godot/releases/download/4.7.2-stable/Godot_v4.7.2-stable_win64.exe.zip`

**它是绿色免安装的**——解压出一个 exe，放哪都行。建议放固定位置，例如 `D:\Godot\`。

### 🔴 需要你决定

- 你希望**我下载并解压到 `D:\Godot\`** 吗？还是你自己装（比如走 Steam 版）？
- 或者你希望装在别的路径？告诉我路径，我按你的来。

> 注：Steam 版 Godot 能用图形界面，但**命令行调用不方便**，会影响我自检。推荐用官方便携版。

---

## 2. 我怎么"与 Godot 互动"（你特别提到的那点）

这是"做好与 Godot 的互动"的具体含义。我需要的不是打开编辑器点点点，而是**能命令行驱动它**。

| 我要做的事 | 命令（Godot 4.7.2 便携版） | 用在哪 |
|---|---|---|
| 无头导入资源 | `Godot_..._console.exe --headless --path <工程> --import` | 每次新增 SVG / 数据文件后 |
| 无头跑逻辑测试 | `... --headless --path <工程> --script res://tests/polar_test.gd` | **Day 3 验证极坐标、Day 5 验证寻路** |
| 无头跑一小段再退出 | `... --headless --path <工程> --quit-after 300` | 自动化冒烟测试 |
| 窗口模式自动截图 | `... --path <工程> -- --autoshot 120 out.png` | **画面验证**（我写的截图脚本存 PNG 后退出） |
| 你手工用编辑器 | 双击 exe | 你看效果、调场景 |

### ⚠️ Day 1 必须实测确认的三个假设

我不想把没验证的东西写死，所以 Day 1 上午第一件事就是验证：

1. **`--headless --import` 能不能正常导入 SVG**（Godot 对 SVG 是"导入为纹理"，这一步会不会丢矢量精度）
2. **`--headless --script` 能不能跑我的测试脚本并打印结果**（这是我最主要的自检手段）
3. **headless 下能不能截图**——据我了解 Godot 4 的 headless 是 dummy 渲染，
   很可能截不到画面，那就走"窗口模式 + 自动截图脚本"的路子

> 如果第 1 条有问题（SVG 被栅格化），我们要改用**运行时直接解析 SVG 路径**的方案，
> 而不是让 Godot 导入成纹理。这会影响 Day 2 的做法，所以必须 Day 1 就确认。

---

## 3. 建议的项目目录结构

```
环球航行/
├─ docs/                      设计文档（已存在）
├─ tools/                     离线脚本（aero_prototype.py 已存在）
├─ data/                      ship.json / crew_key.json / events.json
├─ assets/ship/parts/         SVG 部件（见 03 号文档）
├─ scenes/                    Godot 场景
├─ scripts/                   GDScript
├─ tests/                     无头测试脚本
├─ .gitignore
└─ README.md
```

---

## 4. Git 仓库：现在有个坑

### 现状（我已查过）

| 项目 | 状态 |
|---|---|
| `C:\Users\杨一璇\Desktop` | **本身是一个 git 仓库**——仓库根在桌面，不是 `环球航行` |
| 提交历史 | **一个提交都没有** |
| 未跟踪文件 | 桌面上的所有东西：`.minecraft/`、`PCL/`、游戏安装包、简历、作业、截图…… 上百个条目 |
| `.gitignore` | 桌面没有 |

### 为什么不能直接用桌面这个仓库

如果直接在桌面仓库里 `git add .` 然后推到 GitHub，**你整个桌面都会被传上去**——
包括游戏安装器、个人文档、简历。这不行。

### 方案：在 `环球航行/` 里单独建一个仓库

```powershell
cd C:\Users\杨一璇\Desktop\环球航行
git init
git branch -M main
```

这样 `环球航行/` 就是一个独立仓库，和桌面的仓库互不干扰。

> **一个小注意**：桌面仓库会把 `环球航行/` 看作一个"嵌套仓库"。
> 因为桌面仓库没有任何提交，实际上不会有问题。但如果你想彻底干净，
> 可以在桌面加一个 `.gitignore` 写上 `环球航行/`，让桌面仓库彻底忽略它。
> 要不要我加，你说了算——这算动你桌面的配置，我不擅自做。

### `.gitignore`（Godot 专用）

```gitignore
# Godot 4
.godot/
*.translation
export/
export_presets.cfg

# 构建产物
*.exe
*.pck
*.zip

# 系统
Thumbs.db
Desktop.ini
.DS_Store

# 编辑器
.vscode/
.idea/

# 临时
*.tmp
*.log
_scratch/
```

> `*.import` **不要**忽略——Godot 4 需要它们。

---

## 5. GitHub 推送：需要你解决认证

### 现状（我已查过）

| 项目 | 状态 |
|---|---|
| git | 已装（2.45.1） |
| git 用户名 | 已配（杨 一璇） |
| git 邮箱 | 已配（assissin2023@163.com） |
| `gh` CLI | 没有 |
| SSH key | `~/.ssh` 目录不存在 |
| 现有 remote | 没有 |

**结论：我能在本地把仓库建好、提交好、打 tag，但推到 GitHub 需要先解决认证。**

### 三条路，你选一条

| 方案 | 你要做什么 | 我要做什么 | 难度 |
|---|---|---|---|
| **A（推荐）** 装 `gh` CLI | 浏览器里点一次授权 | 装 CLI、建仓库、推送，全自动 | 低 |
| B Personal Access Token | 去 GitHub 网页生成一个 token 贴给我 | 用 token 推送 | 中（token 要小心保管） |
| C SSH Key | 把公钥贴到 GitHub 的 SSH Keys 设置里 | 本地生成密钥、推送 | 中 |

### 我推荐的完整流程

**你需要做的（只做一次）**：

1. 决定装 `gh` 还是给我 token
2. 在 GitHub 上建一个**空的 private 仓库**，名字比如 `circumnavigation`
   （**不要**勾选"添加 README / .gitignore / license"，否则首次推送要处理冲突）

**我来做的**：

1. `git init` + `.gitignore` + `README.md`
2. 首次提交
3. 关联 remote
4. 推送 + 打 tag
5. 之后每天收工自动 commit + tag（`day1`…`day7`）

### 分支策略

```
main            始终是可运行的版本
codex/dayN      每天的开发分支，收工时合并回 main
```

按你的习惯，我用 `codex/` 前缀开分支。

> **建议仓库设为 private**：这是个未完成的项目，等切片做完了再决定要不要公开。

---

## 6. 关于大文件

7 天内的资产都是**文本**（SVG、JSON、GDScript、Godot 场景文件），**不需要 Git LFS**。

如果后面加音频或位图美术，再考虑 LFS。到时会提醒你。

---

## 7. 汇总：开工前需要你做的 3 件事

| # | 事情 | 为什么 |
|---|---|---|
| 🔴 1 | 让我装 Godot 4.7.2（告诉我放哪个盘），或你自己装并告诉我路径 | 没它 Day 1 开不了工 |
| 🔴 2 | 选 GitHub 认证方式（gh / token / SSH） | 没有远程我只在本地提交 |
| 🔴 3 | 在 GitHub 建一个空的 private 仓库，把地址给我 | 同上 |

剩下的（`git init`、`.gitignore`、目录结构、README、每日 commit + tag）我全包。
