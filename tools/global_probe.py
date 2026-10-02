#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""全球地理的离线探针（M9 的辅助工具，不是运行时的一部分）。

它把 `data/world/global/*.json` 按**和 GDScript 一样的规则**读进来：
投影（经纬度 → 米、x 轴卷起来）、两个地形原语（圆 / 折线加半宽的带子）、
干地的口径（到轮廓的距离 < -beach_width）。用来做两件事：

    python tools/global_probe.py ports             # 每个港是不是在水里、离最近的岸多远
    python tools/global_probe.py route             # 每段航线上有没有干地（每 250 米）
    python tools/global_probe.py at 127.4 0.7      # 一个经纬度点在水里还是干地上
    python tools/global_probe.py map 40            # 打一张 ASCII 小地图（看点摆得对不对）

**权威判定仍然是 `tests/test_globalmap.gd`** —— 这个脚本只是让"改坐标"这件事
不用每次都开一次引擎。
"""

import json
import math
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WORLD = os.path.join(ROOT, "data", "world", "global")


def load_world():
    master = json.load(open(os.path.join(WORLD, "geography.json"), encoding="utf-8"))
    feats = list(master.get("features", []))
    for rel in master.get("include", []):
        sub = json.load(open(os.path.join(WORLD, rel), encoding="utf-8"))
        feats.extend(sub.get("features", []))
    master["features"] = feats
    return master


def project(w, lon, lat):
    p = w["projection"]
    x = (lon - p.get("lon0", -180.0)) * p["m_per_deg"]
    y = (p.get("lat0", 90.0) - lat) * p["m_per_deg"]
    if w.get("wrap_x"):
        x %= w["world_m"][0]
    return (x, y)


def shape_of(raw, w):
    if "points_lonlat" in raw:
        pts = [project(w, *q) for q in raw["points_lonlat"]]
    elif "points" in raw:
        pts = [(float(q[0]), float(q[1])) for q in raw["points"]]
    else:
        pts = []
    hw = float(raw.get("half_width_m", float(raw.get("width_m", 0.0)) * 0.5))
    if len(pts) >= 2:
        return ("band", pts, hw)
    if "center_lonlat" in raw and raw.get("kind") != "current":
        c = project(w, *raw["center_lonlat"])
    elif "pos_lonlat" in raw:
        c = project(w, *raw["pos_lonlat"])
    elif "center" in raw:
        c = (float(raw["center"][0]), float(raw["center"][1]))
    else:
        c = (0.0, 0.0)
    return ("circle", c, float(raw.get("radius_m", 0.0)))


def seg_dist(p, a, b):
    ax, ay = a
    bx, by = b
    dx, dy = bx - ax, by - ay
    l2 = dx * dx + dy * dy
    if l2 <= 1e-9:
        return math.hypot(p[0] - ax, p[1] - ay)
    t = max(0.0, min(1.0, ((p[0] - ax) * dx + (p[1] - ay) * dy) / l2))
    return math.hypot(p[0] - (ax + t * dx), p[1] - (ay + t * dy))


def surf_dist(shape, p):
    kind = shape[0]
    if kind == "circle":
        return math.hypot(p[0] - shape[1][0], p[1] - shape[1][1]) - shape[2]
    pts, hw = shape[1], shape[2]
    d = min(seg_dist(p, pts[i], pts[i + 1]) for i in range(len(pts) - 1))
    return d - hw


def lands(w):
    out = []
    for f in w["features"]:
        if f.get("kind") == "land":
            out.append((f, shape_of(f, w)))
    return out


def surface_of_land(w, p, f):
    """只算"这块陆地"到点的距离（圆/带同口径），用来判断干地。"""
    return surf_dist(shape_of(f, w), p)


def is_dry_land(w, p):
    best = None
    for f, _ in lands(w):
        d = surface_of_land(w, p, f)
        if d < 0.0 and (best is None or d < best):
            best = d
    if best is None:
        return False
    # 找到这块地自己的 beach_width
    for f, _ in lands(w):
        d = surface_of_land(w, p, f)
        if d == best:
            return d < -float(f.get("beach_width_m", 0.0))
    return False


def nearest_land(w, p):
    best = (1e18, "?")
    for f, _ in lands(w):
        d = surface_of_land(w, p, f)
        if d < best[0]:
            best = (d, f.get("id", "?"))
    return best


def ports(w):
    return [f for f in w["features"] if f.get("kind") == "port"]


def port_pos(w, pid):
    for f in ports(w):
        if f.get("id") == pid:
            shape = shape_of(f, w)
            return shape[1]
    return None


def cmd_ports(w):
    print("港 \t\t 干地? \t 离岸(米) \t 最近的地")
    bad = 0
    for f in ports(w):
        p = shape_of(f, w)[1]
        d = is_dry_land(w, p)
        nd, nid = nearest_land(w, p)
        print("%-14s %-6s %9.0f \t %s" % (f.get("id"), "干地!" if d else "水", nd, nid))
        if d:
            bad += 1
    print("--- 干地上的港：%d / %d" % (bad, len(ports(w))))
    return 1 if bad else 0


def route_points(w, r):
    pts = [port_pos(w, r["from"])]
    for q in r.get("via_lonlat", []):
        pts.append(project(w, *q))
    pts.append(port_pos(w, r["to"]))
    return [p for p in pts if p]


def wrap_delta(w, a, b):
    dx = b[0] - a[0]
    if w.get("wrap_x"):
        width = w["world_m"][0]
        dx = (dx + width * 0.5) % width - width * 0.5
    return (dx, b[1] - a[1])


def cmd_route(w):
    routes = json.load(open(os.path.join(WORLD, "routes.json"), encoding="utf-8"))["routes"]
    total = 0
    for r in routes:
        pts = route_points(w, r)
        hits = []
        n = 0
        for i in range(len(pts) - 1):
            dx, dy = wrap_delta(w, pts[i], pts[i + 1])
            dist = math.hypot(dx, dy)
            steps = max(1, int(math.ceil(dist / 250.0)))
            for k in range(steps + 1):
                t = k / float(steps)
                p = (pts[i][0] + dx * t, pts[i][1] + dy * t)
                if w.get("wrap_x"):
                    p = (p[0] % w["world_m"][0], p[1])
                n += 1
                if is_dry_land(w, p):
                    hits.append(p)
        total += len(hits)
        flag = "OK " if not hits else "BAD"
        extra = ""
        if hits:
            nd, nid = nearest_land(w, hits[0])
            extra = "  首处 (%.0f,%.0f) 最近地=%s %.0fm" % (hits[0][0], hits[0][1], nid, nd)
        print("%s %-16s 采样 %5d  踩干地 %4d%s" % (flag, r["id"], n, len(hits), extra))
    print("--- 全部航段踩干地合计：%d" % total)
    return 1 if total else 0


def _port_pos_any(w, pid):
    return port_pos(w, pid)


def cmd_at(w, lon, lat):
    p = project(w, lon, lat)
    nd, nid = nearest_land(w, p)
    print("(%.2f, %.2f) -> (%.0f, %.0f)  %s；最近的地 %s，距离 %.0f 米"
          % (lon, lat, p[0], p[1], "干地" if is_dry_land(w, p) else "水", nid, nd))


def cmd_map(w, cols=80):
    rows = max(12, int(cols / 2))
    width, height = w["world_m"][0], w["world_m"][1]
    print("ASCII 地图：%d×%d，列=%d（每格约 %.1f km）" % (int(width / 1000), int(height / 1000), cols, width / cols / 1000.0))
    out = []
    for r in range(rows):
        line = []
        for c in range(cols):
            p = ((c + 0.5) * width / cols, (r + 0.5) * height / rows)
            ch = "."
            for f, _ in lands(w):
                if is_dry_land(w, p) and surface_of_land(w, p, f) <= 0.0:
                    ch = "#"
                    break
            for f in ports(w):
                if math.hypot(p[0] - shape_of(f, w)[1][0], p[1] - shape_of(f, w)[1][1]) < width / cols:
                    ch = "P"
            line.append(ch)
        out.append("".join(line))
    print("\n".join(out))


def skin_dist(w, p):
    """到最近陆地轮廓的距离（正数 = 在水里，离岸多远）。"""
    return min(surface_of_land(w, p, f) for f, _ in lands(w))


def push_out(w, p, margin=500.0, iters=60):
    """把一个落在干地上的点推到水面上（沿着"离最近那块地最远"的方向）。

    返回 (新的米坐标, 经纬度)。推的方向取"背离最近那块地的骨架"。
    """
    cur = p
    for _ in range(iters):
        if skin_dist(w, cur) > 200.0:
            break
        best = None
        for f, shape in lands(w):
            d = surf_dist(shape, cur)
            if best is None or d < best[0]:
                best = (d, f, shape)
        _, _, shape = best
        if shape[0] == "circle":
            q = shape[1]
        else:
            pts = shape[1]
            q = min(((seg_nearest(cur, pts[i], pts[i + 1])) for i in range(len(pts) - 1)),
                    key=lambda z: math.hypot(cur[0] - z[0], cur[1] - z[1]))
        vx, vy = cur[0] - q[0], cur[1] - q[1]
        n = math.hypot(vx, vy)
        if n < 1e-6:
            vx, vy, n = 0.0, 1.0, 1.0
        step = (margin + abs(best[0])) * 1.15
        cur = (cur[0] + vx / n * step, cur[1] + vy / n * step)
    return cur


def seg_nearest(p, a, b):
    ax, ay = a
    bx, by = b
    dx, dy = bx - ax, by - ay
    l2 = dx * dx + dy * dy
    if l2 <= 1e-9:
        return a
    t = max(0.0, min(1.0, ((p[0] - ax) * dx + (p[1] - ay) * dy) / l2))
    return (ax + t * dx, ay + t * dy)


def unproject(w, p):
    pr = w["projection"]
    lon = pr.get("lon0", -180.0) + p[0] / pr["m_per_deg"]
    lat = pr.get("lat0", 90.0) - p[1] / pr["m_per_deg"]
    if lon > 180.0:
        lon -= 360.0
    return (round(lon, 2), round(lat, 2))


def cmd_fix(w):
    """把落在干地上的港与航点推到水面上，打印可以粘回 JSON 的经纬度。"""
    print("=== 港口 ===")
    for f in ports(w):
        p = shape_of(f, w)[1]
        if not is_dry_land(w, p):
            print("%-14s 已经在水里（离岸 %.0f 米）" % (f.get("id"), skin_dist(w, p)))
            continue
        q = push_out(w, p)
        lon, lat = unproject(w, q)
        print("%-14s 原 (%.2f, %.2f)  →  新 (%.2f, %.2f)   离岸 %.0f 米"
              % (f.get("id"), f["pos_lonlat"][0], f["pos_lonlat"][1], lon, lat, skin_dist(w, q)))
    print("=== 航点（只列需要挪的）===")
    routes = json.load(open(os.path.join(WORLD, "routes.json"), encoding="utf-8"))["routes"]
    for r in routes:
        fixes = []
        for i, q in enumerate(r.get("via_lonlat", [])):
            p = project(w, *q)
            if is_dry_land(w, p):
                nq = push_out(w, p)
                lon, lat = unproject(w, nq)
                fixes.append("  %s via[%d] (%.2f, %.2f) → (%.2f, %.2f) 离岸 %.0f"
                             % (r["id"], i, q[0], q[1], lon, lat, skin_dist(w, nq)))
        if fixes:
            print("\n".join(fixes))
    return 0


def cmd_scale():
    """把海岸带的半宽压到 1/3、沙滩压到 1/2（一次性整理，改完请跑 route/ports 复核）。

    为什么：1:125 的比例下，半宽 2400 米的岸带 = 300 真实公里宽。它只需要**拦住船**
    （船在数据里是一个点），不需要把大陆填满 —— 太厚会让港口和航点被迫离岸几百公里。
    """
    import glob
    import re
    for f in sorted(glob.glob(os.path.join(WORLD, "*.json"))):
        s = open(f, encoding="utf-8").read()
        s2 = re.sub(r'"half_width_m":\s*(\d+)',
                    lambda m: '"half_width_m": %d' % max(400, round(int(m.group(1)) / 3)), s)
        s2 = re.sub(r'"beach_width_m":\s*(\d+)',
                    lambda m: '"beach_width_m": %d' % max(120, round(int(m.group(1)) / 2)), s2)
        if s2 != s:
            open(f, "w", encoding="utf-8", newline="\n").write(s2)
            print("scaled", os.path.basename(f))
    return 0


def cmd_beach(width):
    """把所有陆地的沙滩宽度设成同一个值（一次性整理）。

    沙滩是"可以靠上去的水"，干地才是船撞不进去的墙。岸带半宽 400、
    沙滩 300 时，干地只有 100 米厚 —— 仍然是一道墙，但航段可以贴着岸走。
    """
    import glob
    import re
    for f in sorted(glob.glob(os.path.join(WORLD, "*.json"))):
        s = open(f, encoding="utf-8").read()
        s2 = re.sub(r'"beach_width_m":\s*\d+', '"beach_width_m": %d' % width, s)
        if s2 != s:
            open(f, "w", encoding="utf-8", newline="\n").write(s2)
            print("beach=%d" % width, os.path.basename(f))
    return 0


def cmd_routefix(w):
    """给踩到干地的那几段航段**补绕行点**：每一段连续踩干地的地方，取最深处往外推，
    打印「插在第几个 via 之后」+ 可以粘回去的经纬度。
    """
    routes = json.load(open(os.path.join(WORLD, "routes.json"), encoding="utf-8"))["routes"]
    for r in routes:
        pts = route_points(w, r)
        vias = r.get("via_lonlat", [])
        insertions = []
        for i in range(len(pts) - 1):
            dx, dy = wrap_delta(w, pts[i], pts[i + 1])
            dist = math.hypot(dx, dy)
            steps = max(1, int(math.ceil(dist / 250.0)))
            run = []
            for k in range(steps + 1):
                t = k / float(steps)
                p = (pts[i][0] + dx * t, pts[i][1] + dy * t)
                if w.get("wrap_x"):
                    p = (p[0] % w["world_m"][0], p[1])
                d = skin_dist(w, p)
                if d < -120.0 or is_dry_land(w, p):
                    run.append((d, p))
                elif run:
                    insertions.append((i, min(run, key=lambda z: z[0])))
                    run = []
            if run:
                insertions.append((i, min(run, key=lambda z: z[0])))
        if not insertions:
            continue
        print("--- %s（%d 处需要绕行点）" % (r["id"], len(insertions)))
        for seg, (depth, p) in insertions:
            q = push_out(w, p, margin=350.0)
            lon, lat = unproject(w, q)
            # 段号 seg：0 = 起点港→via[0]，k = via[k-1]→via[k]，最后 = via[last]→终点港
            where = "起点后" if seg == 0 else ("via[%d] 后" % (seg - 1))
            print("    插在 %-10s (%.2f, %.2f)   原处深 %.0f 米" % (where, lon, lat, depth))
    return 0


def leg_hits(w, r):
    """一段航线上踩到干地的采样点（含所在段号），用于自动绕行。"""
    pts = route_points(w, r)
    hits = []
    for i in range(len(pts) - 1):
        dx, dy = wrap_delta(w, pts[i], pts[i + 1])
        dist = math.hypot(dx, dy)
        steps = max(1, int(math.ceil(dist / 250.0)))
        run = []
        for k in range(steps + 1):
            t = k / float(steps)
            p = (pts[i][0] + dx * t, pts[i][1] + dy * t)
            if w.get("wrap_x"):
                p = (p[0] % w["world_m"][0], p[1])
            if is_dry_land(w, p):
                run.append(p)
            elif run:
                hits.append((i, run[len(run) // 2]))
                run = []
        if run:
            hits.append((i, run[len(run) // 2]))
    return hits


def cmd_autofix(w, rounds=8, margin=1100.0):
    """自动给航线补绕行点，直到整条环球航线不踩干地（或到轮次上限）。

    每一轮：找出每段连续踩干地的中间点 → 往外推 → 插进 via_lonlat 的正确位置。
    改完直接写回 `routes.json`（这是**一次性的数据整理**，权威判定仍是
    `tests/test_globalmap.gd`）。
    """
    path = os.path.join(WORLD, "routes.json")
    doc = json.load(open(path, encoding="utf-8"))
    # 第 0 步：先把**每一个航点**都推到离岸 900 米以外。
    # 港与航点当初是按更厚的岸带摆的，岸带变薄之后它们会贴在骨架上 ——
    # 只修"踩到的那一点"会来回震荡（推出去、两边的段又压回来）。
    for r in doc["routes"]:
        vias = list(r.get("via_lonlat", []))
        out = []
        for q in vias:
            p = project(w, q[0], q[1])
            if skin_dist(w, p) < 900.0:
                p = push_out(w, p, margin=900.0)
                lon, lat = unproject(w, p)
                out.append([lon, lat])
            else:
                out.append(q)
        r["via_lonlat"] = out
    json.dump(doc, open(path, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
    open(path, "a", encoding="utf-8").write("\n")
    w = load_world()
    for rd in range(1, rounds + 1):
        total = 0
        changed = False
        for r in doc["routes"]:
            hits = leg_hits(w, r)
            total += len(hits)
            if not hits:
                continue
            vias = list(r.get("via_lonlat", []))
            # 从后往前插，前面的下标才不会被挪动
            for seg, p in sorted(hits, key=lambda z: -z[0]):
                q = push_out(w, p, margin=margin)
                lon, lat = unproject(w, q)
                vias.insert(seg, [lon, lat])
                changed = True
            r["via_lonlat"] = vias
        print("第 %d 轮：踩干地 %d 处" % (rd, total))
        if total == 0:
            break
        if not changed:
            break
        # 重新加载（位置变了，投影/几何都要重算）
        json.dump(doc, open(path, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
        open(path, "a", encoding="utf-8").write("\n")
        w = load_world()
    json.dump(doc, open(path, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
    open(path, "a", encoding="utf-8").write("\n")
    w = load_world()
    left = sum(len(leg_hits(w, r)) for r in doc["routes"])
    print("--- 结束后仍踩干地：%d 处" % left)
    return 1 if left else 0


def main():
    w = load_world()
    if len(sys.argv) < 2:
        print(__doc__)
        return 0
    cmd = sys.argv[1]
    if cmd == "ports":
        return cmd_ports(w)
    if cmd == "route":
        return cmd_route(w)
    if cmd == "at":
        cmd_at(w, float(sys.argv[2]), float(sys.argv[3]))
        return 0
    if cmd == "map":
        cmd_map(w, int(sys.argv[2]) if len(sys.argv) > 2 else 80)
        return 0
    if cmd == "fix":
        return cmd_fix(w)
    if cmd == "scale":
        return cmd_scale()
    if cmd == "beach":
        return cmd_beach(int(sys.argv[2]) if len(sys.argv) > 2 else 300)
    if cmd == "routefix":
        return cmd_routefix(w)
    if cmd == "autofix":
        return cmd_autofix(w)
    print(__doc__)
    return 0


if __name__ == "__main__":
    sys.exit(main())
