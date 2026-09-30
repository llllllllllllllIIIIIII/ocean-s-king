"""环球航行 - 帆船气动模型原型 (纯 Python, 用于验证数学模型)

目的: 在写游戏代码前, 先确认"真风 -> 视风 -> 帆升力/阻力 -> 船体受力 ->
4自由度运动"这条链路能跑出真实帆船行为:
  1) 存在逆风死区 (no-go zone)
  2) 横风 (beam reach) 最快
  3) 顺风反而比横风慢
  4) 速度量级符合 16 世纪单桅小船

这个文件的公式会 1:1 翻译成游戏的 GDScript。
"""

import math

RHO_AIR = 1.225      # kg/m^3
G = 9.81
KNOT = 0.514444      # m/s per knot


# --------------------------------------------------------------------------
# 帆的升力/阻力系数表 (攻角 -> Cl, Cd), 线性插值
# 帆是薄翼: 18 度左右达到最大升力, 之后失速
# --------------------------------------------------------------------------
# 软帆(含桅杆干扰损失)的典型特性, 比刚性翼型低一些
CL_TABLE = [(0, 0.00), (5, 0.40), (10, 0.78), (15, 1.05),
            (18, 1.15), (25, 1.05), (35, 0.82), (50, 0.55),
            (70, 0.34), (90, 0.20)]
CD_TABLE = [(0, 0.02), (5, 0.04), (10, 0.09), (15, 0.16),
            (18, 0.24), (25, 0.45), (35, 0.75), (50, 1.00),
            (70, 1.15), (90, 1.20)]


def _interp(table, x):
    if x <= table[0][0]:
        return table[0][1]
    for i in range(1, len(table)):
        x0, y0 = table[i - 1]
        x1, y1 = table[i]
        if x <= x1:
            t = (x - x0) / (x1 - x0)
            return y0 + t * (y1 - y0)
    return table[-1][1]


def cl_cd(alpha_deg):
    """攻角(度) -> (Cl, Cd)。|a|>90 表示风流吹在帆的背面。"""
    a = abs(alpha_deg)
    if a > 90.0:
        a = 180.0 - a          # 背面受风退化为平板阻力
    return _interp(CL_TABLE, a), _interp(CD_TABLE, a)


# --------------------------------------------------------------------------
# 船
# --------------------------------------------------------------------------
class Boat:
    def __init__(self):
        self.mass = 25000.0     # kg  排水量 (25 吨)
        self.area_main = 38.0   # m^2 主帆
        self.area_jib = 17.0    # m^2 前帆
        self.gm = 0.85          # m   稳心高度 (决定横倾)
        self.h_ce = 7.0         # m   帆受力中心距水线高度
        self.k_lat = 12000.0    # N/(m/s) 龙骨侧向阻力 (越大越不打滑)
        self.c_lin = 120.0      # N/(m/s)  船体线性阻力 (摩擦)
        self.c_quad = 150.0     # N/(m/s)^2 船体兴波阻力
        self.leeway0 = 3.0      # 度  龙骨自身的固有阻力角(诱导阻力的下限)

    # 船体前进阻力
    def hull_drag(self, u):
        return self.c_lin * u + self.c_quad * u * u

    # 龙骨诱导阻力: 侧向力越大, 前进方向被拖累越重。
    # 这一项是"能不能顶风走"的决定性物理量 —— 没有它, 船会违反物理地贴风航行。
    def induced_drag(self, side_force, u, w):
        if u < 0.05:
            return float("inf")
        leeway = math.degrees(math.atan2(abs(w), u)) + self.leeway0
        return abs(side_force) * math.tan(math.radians(min(leeway, 80.0)))


BOAT = Boat()


def normalize180(a):
    while a > 180.0:
        a -= 360.0
    while a <= -180.0:
        a += 360.0
    return a


def sail_force(app_speed, app_dir_deg, chord_deg, area):
    """单面帆产生的力 (船体坐标系: +x 船首方向, +y 右舷)"""
    q = 0.5 * RHO_AIR * app_speed * app_speed
    alpha = normalize180(app_dir_deg - chord_deg)
    cl, cd = cl_cd(alpha)
    lift = q * area * cl
    drag = q * area * cd
    lift_dir = app_dir_deg + (90.0 if alpha > 0 else -90.0)
    fx = lift * math.cos(math.radians(lift_dir)) + drag * math.cos(math.radians(app_dir_deg))
    fy = lift * math.sin(math.radians(lift_dir)) + drag * math.sin(math.radians(app_dir_deg))
    return fx, fy


def steady_state(tws, twa_deg, chord_main, chord_jib, iters=40):
    """给定真风与帆的收放角, 迭代求解稳态 (u 前进速度, w 侧滑, phi 横倾)"""
    # 真风矢量 (船体坐标系)。真风向 twa=0 表示风从船首正前方来。
    # 风"吹向"的方向 = twa + 180
    wx = tws * math.cos(math.radians(twa_deg + 180.0))
    wy = tws * math.sin(math.radians(twa_deg + 180.0))

    u = w = phi = 0.0
    for _ in range(iters):
        ax, ay = wx - u, wy - w                    # 视风 (相对船的风矢量)
        app_speed = math.hypot(ax, ay)
        if app_speed < 1e-4:
            return 0.0, 0.0, 0.0
        app_dir = math.degrees(math.atan2(ay, ax))

        fxm, fym = sail_force(app_speed, app_dir, chord_main, BOAT.area_main)
        fxj, fyj = sail_force(app_speed, app_dir, chord_jib, BOAT.area_jib)
        fx, fy = fxm + fxj, fym + fyj

        # 横倾后桅杆倾斜, 水平方向的有效推力 = cos(phi)
        cp = math.cos(math.radians(phi))
        fx, fy = fx * cp, fy * cp

        w_new = fy / BOAT.k_lat                    # 龙骨抵抗侧滑 -> 剩余侧滑速度

        # 前进方向: 推力 = 船体阻力 + 龙骨诱导阻力
        target = fx
        u_new = 0.0
        if target > 0:
            def residual(uu):
                return (BOAT.hull_drag(uu)
                        + BOAT.induced_drag(fy, uu, w_new)) - target
            if residual(0.06) < 0:                # 起步推不动 -> 停在原地
                u_new = 0.0
            else:
                lo, hi = 0.06, 25.0
                for _ in range(40):                # 二分求解 u, residual 单调递增
                    mid = 0.5 * (lo + hi)
                    if residual(mid) < 0:
                        lo = mid
                    else:
                        hi = mid
                u_new = lo

        phi_new = math.degrees(
            math.asin(max(-1.0, min(1.0, fy * BOAT.h_ce / (BOAT.mass * G * BOAT.gm)))))

        u += 0.35 * (u_new - u)
        w += 0.35 * (w_new - w)
        phi += 0.35 * (phi_new - phi)

    return u, w, phi


def best_trim(tws, twa_deg):
    """搜索主帆/前帆的最佳收放角 (最大化稳态前进速度)"""
    best = (0.0, -140.0, -140.0, 0.0, 0.0)
    for cm in range(-180, -9, 10):
        for cj in range(-180, -9, 10):
            u, w, phi = steady_state(tws, twa_deg, cm, cj)
            if u > best[0]:
                best = (u, float(cm), float(cj), w, phi)
    u0, cm0, cj0, _, _ = best
    for cm in [cm0 + d for d in range(-9, 10, 3)]:
        for cj in [cj0 + d for d in range(-9, 10, 3)]:
            if not (-180 <= cm <= -10 and -180 <= cj <= -10):
                continue
            u, w, phi = steady_state(tws, twa_deg, cm, cj)
            if u > best[0]:
                best = (u, cm, cj, w, phi)
    return best


RUMB = {0: "顶风 0°", 30: "抢风 30°", 45: "抢风 45°", 60: "近风 60°",
        90: "横风 90°", 120: "侧顺 120°", 150: "顺风 150°", 180: "正顺 180°"}


def main():
    print("=" * 74)
    print("单桅帆船稳态速度极坐标  (25t 排水量, 主帆38 + 前帆17 = 55 m^2)")
    print("=" * 74)

    for tws in (6.0, 10.0):
        print("\n真风速 %.0f m/s (%.1f 节)" % (tws, tws / KNOT))
        print("-" * 74)
        print("%-12s %10s %10s %10s %10s" % ("真风角", "船速(节)", "主帆角", "侧滑角", "横倾"))
        for twa in (20, 30, 40, 45, 60, 75, 90, 110, 120, 135, 150, 165, 180):
            u, cm, cj, w, phi = best_trim(tws, twa)
            leeway = math.degrees(math.atan2(w, u)) if u > 0.05 else 0.0
            print("%-12s %10.2f %10.0f %10.1f %10.1f"
                  % (RUMB.get(twa, "%d°" % twa), u / KNOT, abs(cm), leeway, abs(phi)))

    print("\n" + "=" * 74)
    print("关键结论检查")
    print("=" * 74)
    tws = 8.0
    no_go = None
    for twa in range(10, 91, 1):
        u, *_ = best_trim(tws, twa)
        if u / KNOT > 0.3 and no_go is None:
            no_go = twa
    speeds = {t: best_trim(tws, t)[0] / KNOT for t in (45, 90, 150, 180)}
    print("真风 8 m/s (15.6 节) 时:")
    print("  死区边界      : 真风角 %s° 以内无法向前推进" % no_go)
    print("  抢风 45° 船速 : %.2f 节" % speeds[45])
    print("  横风 90° 船速 : %.2f 节" % speeds[90])
    print("  顺风180° 船速 : %.2f 节" % speeds[180])
    print("  横风/顺风比   : %.2f  (>1 说明横风比顺风快, 符合真实帆船)"
          % (speeds[90] / max(speeds[180], 1e-6)))

    # 最佳抢风角 (最大迎风速度分量 VMG)
    best_vmg, best_twa = 0.0, 0
    for twa in range(25, 81, 1):
        u, *_ = best_trim(tws, twa)
        vmg = u * math.cos(math.radians(twa))
        if vmg > best_vmg:
            best_vmg, best_twa = vmg, twa
    print("  最佳抢风角    : %d° (迎风速度分量 %.2f 节) — 玩家实际会走之字形"
          % (best_twa, best_vmg / KNOT))


if __name__ == "__main__":
    main()
