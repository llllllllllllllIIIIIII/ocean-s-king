#!/usr/bin/env python3
"""环球航行 - 帆船气动模型原型与标定工具（纯 Python + numpy）。

为什么要有这个文件（docs/01 第 8 节的风险清单第一条）：
    气动模型调不出正确的极坐标 = 致命风险。所以先在仓库外面（不依赖 Godot）
    把"真风 -> 视风 -> 帆的升力/阻力 -> 船体受力 + 龙骨诱导阻力 -> 稳态速度"
    这条链路跑对，再 1:1 翻译成 GDScript。工具里有两份实现（这里和
    scripts/ship_dynamics.gd），tests/test_aero_polar.gd 负责证明两者一致。

四项硬指标（docs/01 支柱 2 的验收，也是 Day 3 的验收）：
    1) 真风角 35-40 度以内无法推进（逆风死区）
    2) 横风最快
    3) 顺风明显慢于横风
    4) 最佳抢风角 40-45 度（迎风速度分量最大）

船体规格：规格 B —— 60 吨 / 24 米 / 单桅拉丁帆（主帆 + 前帆）。

用法（输出用 ASCII，Windows 终端才不乱码）：
    python tools/aero_prototype.py                           # 极坐标表 + 四项指标
    python tools/aero_prototype.py --mode criteria            # 只要四项指标
    python tools/aero_prototype.py --set leeway0=7 --mode criteria
    python tools/aero_prototype.py --mode tune --param leeway0 --lo 3 --hi 12
"""

import argparse
import json
import math
import pathlib

import numpy as np

RHO_AIR = 1.225      # kg/m^3
G = 9.81
KNOT = 0.514444      # m/s per knot
U_MIN = 0.3          # m/s  诱导阻力公式里的速度下限，防止除零

# ---------------------------------------------------------------------------
# 参数来源：data/defs/ship_physics.json（唯一真源，GDScript 读同一份）
# 读不到时退回下面这份内嵌副本，保证这个工具永远能跑。
# ---------------------------------------------------------------------------
PHYS_PATH = (pathlib.Path(__file__).resolve().parent.parent
             / "data" / "defs" / "ship_physics.json")


def _load_phys():
    try:
        return json.loads(PHYS_PATH.read_text(encoding="utf-8"))
    except Exception as exc:                       # noqa: BLE001 - 退回内嵌副本
        print("[warn] 读不到 %s（%s），使用内嵌默认参数" % (PHYS_PATH, exc))
        return {}


PHYS = _load_phys()
_HULL = PHYS.get("hull", {})
_KEEL = PHYS.get("keel", {})
_SAILS = PHYS.get("sails", {})
_POLAR = PHYS.get("sail_polar", {})

# ---------------------------------------------------------------------------
# 帆的升力/阻力系数表（攻角 -> Cl, Cd），线性插值
# 帆是薄翼：18 度左右达到最大升力，之后失速。软帆含桅杆干扰损失，
# 比刚性翼型低一些 —— 这也是"拉丁帆顶风能力天生有限"的来源。
# ---------------------------------------------------------------------------
ALPHA_DEG = np.array(_POLAR.get("alpha_deg",
                                [0, 5, 10, 15, 18, 25, 35, 50, 70, 90]), dtype=float)
CL_TABLE = np.array(_POLAR.get("cl",
                               [0.00, 0.40, 0.78, 1.05, 1.15, 1.05, 0.82, 0.55, 0.34, 0.20]))
CD_TABLE = np.array(_POLAR.get("cd",
                               [0.02, 0.04, 0.09, 0.16, 0.24, 0.45, 0.75, 1.00, 1.15, 1.20]))


def cl_cd(alpha_deg):
    """攻角（度）-> (Cl, Cd)。|a| > 90 表示风流吹在帆的背面，退化为平板阻力。"""
    a = np.abs(np.asarray(alpha_deg, dtype=float))
    a = np.where(a > 90.0, 180.0 - a, a)
    return np.interp(a, ALPHA_DEG, CL_TABLE), np.interp(a, ALPHA_DEG, CD_TABLE)


# ---------------------------------------------------------------------------
# 船：规格 B（60 吨 / 24 米 / 单桅拉丁帆）
# 这些常数同时是 GDScript 版的默认值；改这里必须同步 data/defs/ship_physics.json
# ---------------------------------------------------------------------------
class Boat:
    def __init__(self, **kw):
        self.mass = kw.get("mass", _HULL.get("mass_kg", 60000.0))          # kg
        self.area_main = kw.get("area_main", _SAILS.get("main_area_m2", 62.0))
        self.area_jib = kw.get("area_jib", _SAILS.get("jib_area_m2", 28.0))
        self.jib_offset = kw.get("jib_offset", _SAILS.get("jib_attack_offset_deg", -8.0))
        self.gm = kw.get("gm", _HULL.get("gm_m", 0.55))                     # m
        self.h_ce = kw.get("h_ce", _HULL.get("h_ce_m", 10.5))               # m
        self.k_lat = kw.get("k_lat", _HULL.get("k_lat_n_per_ms", 20000.0))
        self.c_lin = kw.get("c_lin", _HULL.get("c_lin_n_per_ms", 137.0))
        self.c_quad = kw.get("c_quad", _HULL.get("c_quad_n_per_ms2", 172.0))
        # 兴波阻力的高次项：这才是真正的"船速上限"。没有它，顺风时帆的推力
        # 会随着视风一起长大（跑得越快视风越大），纸面上能算出 19 节的卡拉维尔。
        self.c_wave = kw.get("c_wave", _HULL.get("c_wave_n_per_ms4", 9.0))
        # ---- 龙骨失速模型（"能不能顶风走"的决定性物理量）------------------
        # 龙骨能提供的最大侧向力与水的动压成正比：F_max = k_stall * u^2。
        # 帆推出来的侧向力一旦超过 F_max，龙骨就失速：船开始横着滑，
        # 诱导阻力角按超载比例猛增（c_stall），于是死的逆风区出现了。
        # 未失速时诱导阻力很小 —— 这才让"刚出死区就能快起来"成为可能，
        # 极坐标在 45-90 度之间才会平（真实帆船就是这样）。
        self.k_stall = kw.get("k_stall", _KEEL.get("k_stall_n_per_ms2", 800.0))
        self.u_min = kw.get("u_min", _KEEL.get("u_min_ms", U_MIN))
        # 船体横流阻力（整条船横着被水推）：0.5 * rho_water * A_side * Cd
        # A_side ≈ 20 m 水线长 x 2.6 m 吃水 ≈ 52 m^2，Cd ≈ 1.0
        self.c_cross = kw.get("c_cross", _KEEL.get("c_cross_n_per_ms2", 12000.0))

    def hull_drag(self, u):
        return self.c_lin * u + self.c_quad * u * u + self.c_wave * u ** 4

    def stall_over(self, side_force, u, w=0.0):
        """龙骨超载比例：0 = 没失速，1 = 侧向力是失速上限的两倍。"""
        s2 = u * u + w * w + self.u_min * self.u_min
        fmax = self.k_stall * s2
        return np.maximum(np.abs(side_force) / np.maximum(fmax, 1e-6) - 1.0, 0.0)

    def side_slip(self, side_force, u, w):
        """横向力的去向：龙骨先顶（线性），顶不住就横着漂（船体横流阻力）。

        反解 w：龙骨能给的力封顶在 F_max = k_stall * s^2（动压越大越能顶），
        超出去的那部分由船体横流阻力 c_cross * w^2 承担。
        关键：反解出来的是**实际侧滑速度**，静止起步时 w=0 -> 诱导阻力=0，
        所以船能从静止起得来；等侧滑真的长起来，诱导阻力才把它按住。
        """
        a = np.abs(side_force)
        s2 = u * u + w * w + self.u_min * self.u_min
        fmax = self.k_stall * s2
        sgn = np.sign(side_force)
        keel_only = a / self.k_lat
        extra = np.sqrt(np.maximum(a - fmax, 0.0) / self.c_cross)
        return sgn * np.where(a <= fmax, keel_only, fmax / self.k_lat + extra)

    def induced_drag(self, side_force, u, w):
        """诱导（漂移）阻力：横向力沿水流方向的分量 = |F_lat| * sin(侧滑角)。

        未失速时侧滑很小 -> 阻力很小；失速以后侧滑变大 -> 阻力暴涨。
        这就是顶风死区的来源。没有这一项，船会违反物理地贴风航行。
        """
        s = np.sqrt(u * u + w * w) + 1e-9
        return np.abs(side_force) * np.abs(w) / s


DEFAULTS = Boat()

# 求前进速度时的搜索网格。诱导阻力在 u->0 时发散、船体阻力在 u->30 时发散，
# 于是"总阻力 - 推力"是一条 U 形曲线，可能有两个根；真正的稳态是**大的那个根**。
U_GRID = np.concatenate([np.geomspace(0.05, 1.0, 10), np.linspace(1.5, 30.0, 12)])


def normalize180(a):
    return (a + 180.0) % 360.0 - 180.0


# ---------------------------------------------------------------------------
# 核心：迭代求稳态 (u 前进速度, w 侧滑, phi 横倾)
#
# 帆的收放用"攻角"参数化：chord = 视风方向 - alpha。这正是船上舵手做的事
# —— 看着帆的吃风角收放，船一加速视风前移，就再收一点。所以每个迭代步都要
# 按当前视风重新算 chord。这样"最佳配平"就退化成对 alpha 的一维搜索。
# ---------------------------------------------------------------------------
def drag_total(boat, u, fy, w):
    """前进方向的总阻力 = 船体阻力 + 龙骨诱导阻力。"""
    return boat.hull_drag(u) + boat.induced_drag(fy, u, w)


def solve_surge(boat, fx, fy, w):
    """解 fx = 总阻力(u)。取满足条件的**最大** u（U 形曲线的右根 = 真稳态）。

    没有任何 u 满足 -> 船根本推不动 -> 返回 0。向量化：一次算一整批候选。
    """
    n = fx.shape[0]
    ug = np.broadcast_to(U_GRID.reshape(1, -1), (n, U_GRID.size))
    d = drag_total(boat, ug, fy.reshape(-1, 1), w.reshape(-1, 1))
    ok = d <= fx.reshape(-1, 1)
    idx = np.max(np.where(ok, np.arange(U_GRID.size).reshape(1, -1), -1), axis=1)

    stuck = idx < 0
    lo = np.where(stuck, U_GRID[0], U_GRID[np.maximum(idx, 0)])
    hi = np.where(idx >= U_GRID.size - 1, U_GRID[-1],
                  U_GRID[np.minimum(np.maximum(idx, 0) + 1, U_GRID.size - 1)])
    for _ in range(24):
        mid = 0.5 * (lo + hi)
        up = drag_total(boat, mid, fy, w) <= fx
        lo = np.where(up, mid, lo)
        hi = np.where(up, hi, mid)
    return np.where(stuck, 0.0, lo)


def steady_state(boat, tws, twa_deg, alpha_main, alpha_jib=None, iters=42, u0=1.5):
    """给定帆的攻角（度），迭代求稳态。

    alpha_* 可以是标量或数组，一次算一整批配平候选。
    初值给 1.5 m/s 的一点余速：这正是现实里的语义 —— 船有了速度才谈得上
    "能不能走"，完全静止的船在死区里是永远起不来的。
    """
    alpha_main = np.atleast_1d(np.asarray(alpha_main, dtype=float))
    if alpha_jib is None:
        alpha_jib = np.clip(alpha_main + boat.jib_offset, 8.0, 90.0)
    alpha_jib = np.broadcast_to(np.atleast_1d(np.asarray(alpha_jib, dtype=float)),
                                alpha_main.shape)

    # 真风矢量（船体坐标系）。twa = 0 表示风从船首正前方来。
    wx = tws * math.cos(math.radians(twa_deg + 180.0))
    wy = tws * math.sin(math.radians(twa_deg + 180.0))

    u = np.full(alpha_main.shape, u0)
    w = np.zeros_like(u)
    phi = np.zeros_like(u)
    chord_main = np.full_like(u, -140.0)
    chord_jib = np.full_like(u, -140.0)

    for _ in range(iters):
        ax = wx - u
        ay = wy - w
        app_speed = np.maximum(np.hypot(ax, ay), 1e-6)
        app_dir = np.degrees(np.arctan2(ay, ax))
        q = 0.5 * RHO_AIR * app_speed * app_speed
        chord_main = app_dir - alpha_main
        chord_jib = app_dir - alpha_jib

        def one_sail(chord, area):
            alpha = normalize180(app_dir - chord)
            cl, cd = cl_cd(alpha)
            lift = q * area * cl
            drag = q * area * cd
            lift_dir = app_dir + np.where(alpha > 0.0, 90.0, -90.0)
            fx = lift * np.cos(np.radians(lift_dir)) + drag * np.cos(np.radians(app_dir))
            fy = lift * np.sin(np.radians(lift_dir)) + drag * np.sin(np.radians(app_dir))
            return fx, fy

        fxm, fym = one_sail(chord_main, boat.area_main)
        fxj, fyj = one_sail(chord_jib, boat.area_jib)
        fx, fy = fxm + fxj, fym + fyj

        # 横倾后桅杆倾斜，水平方向的有效推力 = cos(phi)
        cp = np.cos(np.radians(phi))
        fx, fy = fx * cp, fy * cp

        over = boat.stall_over(fy, u, w)
        # 侧滑由"龙骨 + 船体横流阻力"平衡反解；失速时侧滑明显变大，玩家看得见
        w_new = boat.side_slip(fy, u, w)
        u_new = solve_surge(boat, fx, fy, w_new)

        phi_new = np.degrees(np.arcsin(np.clip(
            fy * boat.h_ce / (boat.mass * G * boat.gm), -1.0, 1.0)))

        u += 0.35 * (u_new - u)
        w += 0.35 * (w_new - w)
        phi += 0.35 * (phi_new - phi)

    # 收敛校验：松弛迭代在"刚好推得动/刚好推不动"的刀尖上会进limit cycle，
    # 于是算出一个**根本不是稳态**的正速度（顺风时尤其明显）。
    # 真稳态下 u_new == u，所以只要最后一步还差得远，就判定为"这个配平站不住"。
    settled = np.abs(u_new - u) < 0.05
    u = np.where(settled, u, 0.0)
    return u, w, phi, chord_main, chord_jib


ALPHA_COARSE = np.arange(5.0, 91.0, 5.0)


def best_trim(boat, tws, twa_deg, alpha_step=5.0):
    """搜索最佳配平：一维扫主帆攻角（前帆跟着主帆减 8 度）。粗搜 + 局部细搜。"""
    alphas = np.arange(5.0, 91.0, alpha_step)
    u, w, phi, cm, cj = steady_state(boat, tws, twa_deg, alphas)
    idx = int(np.argmax(u))
    best = (float(u[idx]), float(cm[idx]), float(cj[idx]), float(w[idx]), float(phi[idx]))
    a0 = float(alphas[idx])

    fine = np.clip(a0 + np.arange(-alpha_step, alpha_step + 1e-9, 1.0), 5.0, 90.0)
    u2, w2, phi2, cm2, cj2 = steady_state(boat, tws, twa_deg, fine)
    j = int(np.argmax(u2))
    if u2[j] > best[0]:
        best = (float(u2[j]), float(cm2[j]), float(cj2[j]), float(w2[j]), float(phi2[j]))
    return best


def speed_kn(boat, tws, twa_deg):
    return best_trim(boat, tws, twa_deg)[0] / KNOT


# ---------------------------------------------------------------------------
# 四项硬指标
# ---------------------------------------------------------------------------
def no_go_boundary(boat, tws, threshold_kn=0.5):
    """从顶风往横风扫，第一个能"真的走起来"的真风角。"""
    for twa in range(5, 91):
        if speed_kn(boat, tws, float(twa)) >= threshold_kn:
            return twa
    return None


def best_vmg(boat, tws, lo=25, hi=80):
    """最佳抢风角：迎风速度分量 u*cos(twa) 最大的真风角。"""
    best = (0, -1e9)
    for twa in range(lo, hi + 1):
        u = speed_kn(boat, tws, float(twa))
        vmg = u * math.cos(math.radians(twa))
        if vmg > best[1]:
            best = (twa, vmg)
    return best


def criteria(boat, tws=8.0, verbose=False):
    """返回 (结果字典, 是否全部通过)。tws = 8 m/s = 15.6 节（中等的风）。"""
    boundary = no_go_boundary(boat, tws)
    s45 = speed_kn(boat, tws, 45.0)
    s90 = speed_kn(boat, tws, 90.0)
    s150 = speed_kn(boat, tws, 150.0)
    s180 = speed_kn(boat, tws, 180.0)
    polar = {t: speed_kn(boat, tws, float(t)) for t in range(30, 181, 5)}
    fastest = max(polar, key=lambda t: polar[t])
    vmg_twa, vmg = best_vmg(boat, tws)

    res = {
        "no_go": boundary,
        "fastest_twa": fastest,
        "s45": s45, "s90": s90, "s150": s150, "s180": s180,
        "beam_over_downwind": s90 / max(s180, 1e-9),
        "vmg_twa": vmg_twa, "vmg_kn": vmg,
        "polar": polar,
    }
    checks = [
        ("1 no-go boundary in 35..40 deg", boundary is not None and 35 <= boundary <= 40,
         "got %s" % boundary),
        ("2 beam reach fastest", abs(fastest - 90) <= 15,
         "fastest at %d deg (%.2f kn)" % (fastest, polar[fastest])),
        ("3 downwind slower than beam", s180 < s90 * 0.9,
         "%.2f kn vs beam %.2f kn" % (s180, s90)),
        ("4 best VMG angle in 40..45 deg", 40 <= vmg_twa <= 45, "got %d deg" % vmg_twa),
    ]
    res["checks"] = checks
    res["ok"] = all(c[1] for c in checks)
    if verbose:
        for name, ok, note in checks:
            print("  [%s] %-40s %s" % ("PASS" if ok else "FAIL", name, note))
    return res, res["ok"]


RUMB = {0: "head 0", 30: "beat 30", 45: "beat 45", 60: "close 60",
        90: "beam 90", 120: "broad 120", 150: "run 150", 180: "dead run"}


def print_table(boat, tws_list=(6.0, 8.0, 10.0)):
    print("=" * 78)
    print("Steady-state polar - 60t / 24m caravel, main %.0f + jib %.0f = %.0f m2"
          % (boat.area_main, boat.area_jib, boat.area_main + boat.area_jib))
    print("=" * 78)
    for tws in tws_list:
        print("\nTWS %.1f m/s (%.1f kn)  --  best-trim u" % (tws, tws / KNOT))
        print("-" * 78)
        print("%-12s %10s %10s %10s %10s" % ("TWA", "speed(kn)", "main", "leeway", "heel"))
        for twa in (20, 30, 35, 40, 45, 60, 75, 90, 110, 120, 135, 150, 165, 180):
            u, cm, cj, w, phi = best_trim(boat, tws, float(twa))
            leeway = math.degrees(math.atan2(w, u)) if u > 0.05 else 0.0
            print("%-12s %10.2f %10.0f %10.1f %10.1f"
                  % (RUMB.get(twa, "%d deg" % twa), u / KNOT, abs(cm), leeway, abs(phi)))


def emit_trim_table(boat, path, tws_list=(3.0, 5.0, 8.0, 11.0, 14.0),
                    awa_list=tuple(range(0, 181, 5))):
    """生成船员的配平查表：给定真风速与**视风角**，该用多大攻角。

    为什么键是视风角而不是真风角（Day 3 现场踩坑后的结论）：
      水手看的是帆上吃到的风（视风），不是真风。按真风角查表，意味着
      "配平"建立在"船正以某个速度航行"这个前提上；船一旦停住，视风退化成真风，
      同一个攻角会把帆收到背风侧（船侧滑 84.7°、永远起不来）。
      改成按视风角查表后：停着的时候查到的是"让帆吃上力"的收放，
      跑起来视风前移，自动收敛到最佳配平 —— 这也是真实水手做的事。

    运行时（scripts/crew.gd）插值查这张表，比在游戏里现场搜索便宜三个数量级。
    Day 4 的指挥链路会在这上面加技能、疲劳与执行耗时。
    """
    out = {
        "_comment": "由 tools/aero_prototype.py --emit-trim-table 生成，不要手改。"
                    "下表 [i][j] 对应真风速 tws_ms[i]、**视风角** awa_deg[j]（0 = 风从船首来）。"
                    "alpha_deg = 该状态下主帆的最佳攻角（度）——船员按它收放帆："
                    "帆弦线 = 视风方向 − 攻角。speed_kn 只是同一状态下的稳态船速，供参考。",
        "version": 1,
        "ship_id": PHYS.get("ship_id", "caravel_60"),
        "tws_ms": list(tws_list),
        "awa_deg": list(awa_list),
        "alpha_deg": [],
        "speed_kn": [],
    }
    for tws in tws_list:
        # 1) 把"每个真风角下的稳态"算出来，记下它的视风角、最佳攻角、船速
        states = []
        for twa in range(0, 181):
            u, cm, cj, w, phi = best_trim(boat, tws, float(twa))
            app_dir = math.degrees(math.atan2(
                tws * math.sin(math.radians(twa + 180.0)) - w,
                tws * math.cos(math.radians(twa + 180.0)) - u))
            awa = abs(normalize180(app_dir + 180.0))
            a_deg = _alpha_of(app_dir, cm)
            states.append((awa, min(max(a_deg, 5.0), 90.0), u / KNOT))
        # 2) 重采样到规则的视风角网格：取视风角最接近的那个稳态
        alphas, speeds = [], []
        for awa in awa_list:
            best = min(states, key=lambda s: abs(s[0] - float(awa)))
            alphas.append(round(best[1], 1))
            speeds.append(round(best[2], 2))
        out["alpha_deg"].append(alphas)
        out["speed_kn"].append(speeds)
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(out, fh, ensure_ascii=False, indent=1)
    print("wrote %s（%d x %d）" % (path, len(tws_list), len(awa_list)))


def _alpha_of(app_dir_deg, chord_deg):
    """由"帆弦线角"反推攻角：alpha = 视风方向 - 弦线方向，归一到 0..90。"""
    a = normalize180(app_dir_deg - chord_deg)
    return abs(a) if abs(a) <= 90.0 else 180.0 - abs(a)


def main():
    ap = argparse.ArgumentParser(description="caravel aero prototype / calibration")
    ap.add_argument("--mode", default="all",
                    choices=["all", "table", "criteria", "tune", "trim-table"])
    ap.add_argument("--out", default="data/defs/trim_table.json",
                    help="--mode trim-table 的输出路径")
    ap.add_argument("--tws", type=float, default=8.0, help="true wind speed m/s")
    ap.add_argument("--set", action="append", default=[], metavar="K=V",
                    help="override boat param, e.g. --set leeway0=7")
    ap.add_argument("--param", default="leeway0", help="tune sweep parameter")
    ap.add_argument("--lo", type=float, default=3.0)
    ap.add_argument("--hi", type=float, default=12.0)
    ap.add_argument("--step", type=float, default=1.0)
    args = ap.parse_args()

    over = {}
    for kv in args.set:
        k, v = kv.split("=")
        over[k] = float(v)

    if args.mode == "trim-table":
        emit_trim_table(Boat(**over), args.out)
        return

    if args.mode == "tune":
        print("tune %s  (tws=%.1f m/s, fixed=%s)" % (args.param, args.tws, over))
        print("%-8s %8s %9s %9s %9s %9s %8s" %
              ("value", "no-go", "bestVMG", "s45", "s90", "s180", "verdict"))
        v = args.lo
        while v <= args.hi + 1e-9:
            b = Boat(**dict(over, **{args.param: v}))
            res, ok = criteria(b, args.tws)
            print("%-8.2f %8s %9s %9.2f %9.2f %9.2f %8s" % (
                v, res["no_go"], res["vmg_twa"], res["s45"], res["s90"], res["s180"],
                "OK" if ok else "-"))
            v += args.step
        return

    boat = Boat(**over)
    if args.mode in ("all", "table"):
        print_table(boat)
    if args.mode in ("all", "criteria"):
        print("\n" + "=" * 78)
        print("Hard criteria  (tws=%.1f m/s = %.1f kn)" % (args.tws, args.tws / KNOT))
        print("=" * 78)
        criteria(boat, args.tws, verbose=True)
        print("  params: %s" % {k: getattr(boat, k) for k in
                                ("mass", "area_main", "area_jib", "gm", "h_ce",
                                 "k_lat", "c_lin", "c_quad", "c_wave",
                                 "k_stall", "c_cross", "u_min")})


if __name__ == "__main__":
    main()
