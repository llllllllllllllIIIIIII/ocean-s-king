#!/usr/bin/env python3
"""根据船体参数生成船体数据与几何类 SVG 部件。

为什么要有这个生成器（docs/05 第 8 节）：
    甲板格子的外形和船壳轮廓必须来自同一个源。否则一边手摆格子、
    一边手画船壳，Day 2 一定会出现"甲板比船壳宽了两格"这种事后极难排查的错。

所以这里用一个连续的半宽曲线 half_beam(x) 同时产出：
    * 逻辑层：甲板 tile map 的占用形状（量化成整格）
    * 视觉层：船壳轮廓 / 舷墙环 / 甲板铺板（连续曲线 + 手绘扰动）
    并由 assert_hull_contains_deck() 保证所有甲板格子都在船壳轮廓内。

用法：
    python tools/gen_ship.py

输出：
    data/ships/caravel_60.json
    assets/ship/parts/hull/hull_outline.svg
    assets/ship/parts/deck/deck_bulwark.svg
    assets/ship/parts/deck/deck_planks.svg
"""

import json
import pathlib

# ---------------------------------------------------------------------------
# 船体参数（规格 B：约 60 吨 / 24 米 / 单桅拉丁帆）
# ---------------------------------------------------------------------------
NX = 24          # 船长方向格数（x=0 船首 -> x=NX-1 船尾）
NY = 7           # 船宽方向格数（y=0 左舷 -> y=NY-1 右舷，中线在 y=3.5）
M_PER_CELL = 1.0
SVG = 100.0      # 1 格 = 100 SVG 单位（1 单位 = 1 厘米）

# 船壳比甲板略宽：甲板占 7 格（半宽 3.5），船壳半宽 3.85，
# 多出来的那一圈正是舷墙坐着的地方。等宽的话船看起来就像一片叶子。
HALF_BEAM_MAX = 3.85
BOW_TAPER = 0.36             # 艏部收窄占全长的比例
STERN_TAPER = 0.16           # 艉部收窄占全长的比例
BULWARK = 0.35               # 舷墙宽度（格）
JITTER = 0.035               # 手绘扰动幅度（格）

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT_SHIP = 'data/ships/caravel_60.json'
OUT_HULL = 'assets/ship/parts/hull/hull_outline.svg'
OUT_BULWARK = 'assets/ship/parts/deck/deck_bulwark.svg'
OUT_PLANKS = 'assets/ship/parts/deck/deck_planks.svg'
OUT_FLOOR = 'assets/ship/parts/cabin/interior_floor.svg'

PALETTE = {
    'hull_dark': '#241708',
    'hull': '#5a3f22',
    'hull_edge': '#1a1006',
    'bulwark': '#6b4f2a',
    'bulwark_edge': '#3a2913',
    'deck': '#c9a961',
    'deck_alt': '#c09f58',
    'deck_seam': '#8a6f3c',
    'floor': '#6b5230',
    'floor_alt': '#634b2c',
    'floor_seam': '#43321a',
}


# ---------------------------------------------------------------------------
# 连续船体曲线：唯一的形状真源
# ---------------------------------------------------------------------------
def half_beam(x: float) -> float:
    """连续的半宽曲线（单位：格）。x 是沿船长的连续位置，0..NX。"""
    t = x / NX
    if t < BOW_TAPER:
        # 指数 1.0（线性）配上较长的收窄段 -> 尖而长的艏部入水角
        return HALF_BEAM_MAX * (t / BOW_TAPER) ** 1.0
    if t > 1.0 - STERN_TAPER:
        s = (t - (1.0 - STERN_TAPER)) / STERN_TAPER
        # 线性收到平尾
        return HALF_BEAM_MAX - 1.55 * s
    return HALF_BEAM_MAX


def row_span(x: int):
    """第 x 列被甲板占用的 y 区间 [y0, y1]；艏尖这类放不下整格的列返回 None。"""
    h = half_beam(x + 0.5)
    # 判定用**格角**而不是格中心：格角戳出船壳，视觉上就是甲板露在船外。
    rows = [y for y in range(NY)
            if max(abs(y - NY / 2.0), abs(y + 1 - NY / 2.0)) <= h]
    if not rows:
        return None
    return rows[0], rows[-1]


def widths():
    out = []
    for x in range(NX):
        sp = row_span(x)
        out.append(0 if sp is None else sp[1] - sp[0] + 1)
    return out


# ---------------------------------------------------------------------------
# 手绘扰动：同一个扰动序列被所有视觉部件复用，保证三层边缘严丝合缝
# ---------------------------------------------------------------------------
class Rng:
    def __init__(self, seed: int):
        self.s = seed & 0x7FFFFFFF

    def sym(self, amp: float) -> float:
        self.s = (1103515245 * self.s + 12345) & 0x7FFFFFFF
        return (self.s / 0x7FFFFFFF * 2.0 - 1.0) * amp


SAMPLES = 97                       # 沿船长采样点数（4 段/格）
_rng = Rng(20260930)
JITTER_X = [_rng.sym(JITTER) for _ in range(SAMPLES)]
JITTER_PORT = [_rng.sym(JITTER) for _ in range(SAMPLES)]
JITTER_STAR = [_rng.sym(JITTER) for _ in range(SAMPLES)]


def hull_points(inset: float = 0.0):
    """船壳轮廓的点列：左舷 艏->艉，再右舷 艉->艏。inset 是向内缩进的格数。"""
    port, star = [], []
    for i in range(SAMPLES):
        u = i / (SAMPLES - 1)
        x = u * NX + JITTER_X[i]
        h = max(half_beam(u * NX) - inset, 0.0)
        port.append((x * SVG, (NY / 2.0 - h) * SVG + JITTER_PORT[i] * SVG))
        star.append((x * SVG, (NY / 2.0 + h) * SVG + JITTER_STAR[i] * SVG))
    return port + list(reversed(star))


def path_of(points) -> str:
    d = 'M %.1f %.1f' % points[0]
    for p in points[1:]:
        d += ' L %.1f %.1f' % p
    return d + ' Z'


def x_range_for_y(y_cells: float, inset: float):
    """在缩进 inset 的船体形状上，找出 y 这一行被覆盖的 x 区间。"""
    need = abs(y_cells - NY / 2.0)
    hits = []
    steps = 600
    for i in range(steps + 1):
        x = i * NX / steps
        if max(half_beam(x) - inset, 0.0) >= need:
            hits.append(x)
    return (hits[0], hits[-1]) if hits else None


# ---------------------------------------------------------------------------
# 甲板上的开口与通道
# ---------------------------------------------------------------------------
MAST = (12, 3)
MAST_TOP_LADDER = (13, 3)
MAIN_HATCH = (14, 3)
FWD_LADDER = (5, 3)
AFT_LADDER = (19, 3)


def blank():
    return [['.' for _ in range(NX)] for _ in range(NY)]      # grid[y][x]


def to_rows(grid):
    return [''.join(row) for row in grid]


def build_deck():
    g = blank()
    for x in range(NX):
        sp = row_span(x)
        if sp is None:
            continue                              # 艏尖放不下整格
        y0, y1 = sp
        w = y1 - y0 + 1
        for y in range(y0, y1 + 1):
            if w <= 2:
                g[y][x] = '='                     # 艏艉尖端，实心
            elif y == y0 or y == y1:
                g[y][x] = '='                     # 舷墙
            else:
                g[y][x] = '#'                     # 甲板
    g[MAIN_HATCH[1]][MAIN_HATCH[0]] = 'H'
    g[FWD_LADDER[1]][FWD_LADDER[0]] = 'L'
    g[AFT_LADDER[1]][AFT_LADDER[0]] = 'L'
    g[MAST_TOP_LADDER[1]][MAST_TOP_LADDER[0]] = 'L'
    return g


def build_interior(features: dict):
    g = blank()
    for x in range(NX):
        sp = row_span(x)
        if sp is None:
            continue
        y0, y1 = sp
        for y in range(y0, y1 + 1):
            if y == y0 or y == y1 or x == 0 or x == NX - 1:
                g[y][x] = '|'                     # 船体内壁
            else:
                g[y][x] = '_'                     # 舱内地板
    for (x, y), ch in features.items():
        g[y][x] = ch
    return g


def build_layer1():
    return build_interior({
        MAIN_HATCH: 'H',
        FWD_LADDER: 'L', AFT_LADDER: 'L',
        (9, 3): 'L', (17, 3): 'L',                # 下到货舱
    })


def build_layer0():
    return build_interior({(9, 3): 'L', (17, 3): 'L'})


def build_layer3():
    """桅顶瞭望台：桅杆周围的一小块平台，其余是空气。"""
    g = blank()
    for x in range(MAST[0] - 1, MAST[0] + 2):
        for y in range(MAST[1] - 1, MAST[1] + 2):
            g[y][x] = 'p'
    g[MAST_TOP_LADDER[1]][MAST_TOP_LADDER[0]] = 'L'
    return g


# ---------------------------------------------------------------------------
# 房间：格子上的语义标注（docs/05 第 3 节）
# ---------------------------------------------------------------------------
def rect(x0, y0, x1, y1):
    return [(x, y) for x in range(x0, x1 + 1) for y in range(y0, y1 + 1)]


ROOMS = [
    # --- L1 下层甲板 ---
    {'id': 'galley', 'layer': 1, 'name': '厨房', 'purpose': 'cook',
     'cells': rect(3, 3, 5, 3)},
    {'id': 'berth_fwd', 'layer': 1, 'name': '前部铺位', 'purpose': 'sleep',
     'cells': rect(6, 2, 7, 4)},
    {'id': 'berth_mid', 'layer': 1, 'name': '中部水手舱', 'purpose': 'sleep',
     'cells': rect(9, 1, 11, 2)},
    {'id': 'berth_aft', 'layer': 1, 'name': '后部铺位', 'purpose': 'sleep',
     'cells': rect(9, 4, 11, 5)},
    {'id': 'medicine', 'layer': 1, 'name': '医务角', 'purpose': 'heal',
     'cells': rect(14, 1, 15, 2)},
    {'id': 'captain_cabin', 'layer': 1, 'name': '船长室', 'purpose': 'captain',
     'cells': rect(18, 1, 20, 3)},
    # --- L0 货舱 ---
    {'id': 'ballast', 'layer': 0, 'name': '压舱石', 'purpose': 'ballast',
     'cells': rect(3, 3, 5, 3)},
    {'id': 'hold_water', 'layer': 0, 'name': '淡水舱', 'purpose': 'water',
     'cells': rect(6, 2, 7, 4)},
    {'id': 'hold_food', 'layer': 0, 'name': '食物舱', 'purpose': 'food',
     'cells': rect(10, 1, 12, 2)},
    {'id': 'stores', 'layer': 0, 'name': '备件舱', 'purpose': 'stores',
     'cells': rect(18, 4, 20, 5)},
]

# ---------------------------------------------------------------------------
# props：有状态的实体
# ---------------------------------------------------------------------------
PROPS = [
    {'type': 'mast', 'layer': 2, 'x': MAST[0], 'y': MAST[1], 'height_m': 16.0},
    {'type': 'capstan', 'layer': 2, 'x': 9, 'y': 3},
    {'type': 'windlass', 'layer': 2, 'x': 4, 'y': 3},
    {'type': 'helm', 'layer': 2, 'x': 21, 'y': 3},
    {'type': 'bunk', 'layer': 1, 'x': 6, 'y': 2},
    {'type': 'bunk', 'layer': 1, 'x': 7, 'y': 2},
    {'type': 'bunk', 'layer': 1, 'x': 6, 'y': 4},
    {'type': 'bunk', 'layer': 1, 'x': 7, 'y': 4},
    {'type': 'stove', 'layer': 1, 'x': 4, 'y': 3},
    {'type': 'chest', 'layer': 1, 'x': 19, 'y': 3},
    {'type': 'barrel', 'layer': 0, 'x': 6, 'y': 2, 'contents': 'water'},
    {'type': 'barrel', 'layer': 0, 'x': 6, 'y': 3, 'contents': 'water'},
    {'type': 'barrel', 'layer': 0, 'x': 7, 'y': 3, 'contents': 'water'},
    {'type': 'barrel', 'layer': 0, 'x': 10, 'y': 1, 'contents': 'food'},
    {'type': 'cargo', 'layer': 0, 'x': 18, 'y': 3},
    {'type': 'cargo', 'layer': 0, 'x': 19, 'y': 3},
]

LINKS = [
    {'type': 'hatch', 'x': MAIN_HATCH[0], 'y': MAIN_HATCH[1], 'from': 2, 'to': 1},
    {'type': 'ladder', 'x': FWD_LADDER[0], 'y': FWD_LADDER[1], 'from': 2, 'to': 1},
    {'type': 'ladder', 'x': AFT_LADDER[0], 'y': AFT_LADDER[1], 'from': 2, 'to': 1},
    {'type': 'ladder', 'x': MAST_TOP_LADDER[0], 'y': MAST_TOP_LADDER[1],
     'from': 2, 'to': 3},
    {'type': 'ladder', 'x': 9, 'y': 3, 'from': 1, 'to': 0},
    {'type': 'ladder', 'x': 17, 'y': 3, 'from': 1, 'to': 0},
]


def build_ship():
    return {
        'id': 'caravel_60',
        'name': '圣安东尼奥号',
        'version': 1,
        '_generated_by': 'tools/gen_ship.py —— 请改生成器，不要直接改这个文件',
        'units': {'meters_per_cell': M_PER_CELL, 'svg_units_per_cell': SVG},
        'hull': {
            'length_m': NX * M_PER_CELL,
            'beam_m': NY * M_PER_CELL,
            'displacement_t': 60,
            # 载重（M4 起）：能装多少货。60 吨的拉丁帆船 deadweight 约 24–30 吨，
            # 取 27 吨 —— 补给、火药、货物全都占这一份。船是数据，所以它在这里，
            # 不在 GDScript 里。
            'deadweight_t': 27,
            'cells_x': NX,
            'cells_y': NY,
            'origin_cell': [MAST[0], MAST[1]],
            'half_beam_max': HALF_BEAM_MAX,
            'bulwark_cells': BULWARK,
        },
        'layers': [
            {'id': 2, 'name': '主甲板', 'elevation_m': 0.0, 'kind': 'deck',
             'tiles': to_rows(build_deck())},
            {'id': 1, 'name': '下层甲板', 'elevation_m': -2.0, 'kind': 'interior',
             'tiles': to_rows(build_layer1())},
            {'id': 0, 'name': '货舱', 'elevation_m': -4.0, 'kind': 'interior',
             'tiles': to_rows(build_layer0())},
            {'id': 3, 'name': '桅顶瞭望台', 'elevation_m': 16.0, 'kind': 'platform',
             'tiles': to_rows(build_layer3())},
        ],
        'links': LINKS,
        'rooms': [dict(r, cells=[list(c) for c in r['cells']]) for r in ROOMS],
        'props': PROPS,
        'rig': {
            'masts': [{
                'id': 'main', 'pos': list(MAST), 'height_m': 16.0,
                'sails': [
                    {'id': 'main', 'type': 'lateen', 'area_m2': 38.0,
                     'boom_pivot': list(MAST), 'boom_length_m': 15.0},
                    {'id': 'jib', 'type': 'lateen', 'area_m2': 17.0,
                     'boom_pivot': list(MAST), 'boom_length_m': 9.0},
                ],
            }],
        },
        'vitals': {'hull': 1.0, 'mast': 1.0, 'rudder': 1.0},
    }


# ---------------------------------------------------------------------------
# 几何类 SVG 部件
# ---------------------------------------------------------------------------
def _svg(width, height, body: str, comment: str) -> str:
    return (
        '<svg xmlns="http://www.w3.org/2000/svg" width="%.0f" height="%.0f" '
        'viewBox="0 0 %.0f %.0f">\n'
        '  <!-- %s -->\n'
        '  <!-- 由 tools/gen_ship.py 生成，与甲板 tile map 同源。请勿手改。 -->\n'
        '%s\n</svg>\n' % (width, height, width, height, comment, body)
    )


def svg_hull_outline() -> str:
    outer = path_of(hull_points(0.0))
    # 伪立体：把船体主体往上左挪几个单位，露出右下方的暗色厚度。
    body = (
        '  <g transform="translate(-6 -8)">\n'
        '    <path d="%s" fill="%s"/>\n'
        '  </g>\n'
        '  <path d="%s" fill="%s" stroke="%s" stroke-width="7" '
        'stroke-linejoin="round"/>\n'
        % (outer, PALETTE['hull_dark'], outer, PALETTE['hull'], PALETTE['hull_edge'])
    )
    return _svg(NX * SVG, NY * SVG, body, '船壳轮廓（含伪立体厚度）')


def svg_deck_bulwark() -> str:
    outer = path_of(hull_points(0.0))
    inner = path_of(hull_points(BULWARK))
    # evenodd 让两条子路径之间形成环形，不会像 stroke 那样往船外溢出
    body = '  <path d="%s %s" fill="%s" fill-rule="evenodd" stroke="%s" stroke-width="5"/>\n' % (
        outer, inner, PALETTE['bulwark'], PALETTE['bulwark_edge'])
    return _svg(NX * SVG, NY * SVG, body, '舷墙（外轮廓与内轮廓之间的环）')


def svg_deck_planks() -> str:
    return _planks_svg(
        PALETTE['deck'], PALETTE['deck_alt'], PALETTE['deck_seam'], '甲板铺板')


def svg_interior_floor() -> str:
    return _planks_svg(
        PALETTE['floor'], PALETTE['floor_alt'], PALETTE['floor_seam'], '舱内地板')


def _planks_svg(base: str, alt: str, seam: str, comment: str) -> str:
    parts = ['  <path d="%s" fill="%s"/>' % (path_of(hull_points(BULWARK)), base)]
    # 铺板沿船长方向铺设 -> 分缝是等距的水平线，用曲线求交算出每条的跨度
    step = 0.4
    y = NY / 2.0 + step
    i = 0
    while y < NY:
        rng = x_range_for_y(y, BULWARK)
        if rng:
            color = seam if (i % 4 == 0) else alt
            width = 4 if (i % 4 == 0) else 2
            parts.append('  <line x1="%.1f" y1="%.1f" x2="%.1f" y2="%.1f" stroke="%s" stroke-width="%d"/>'
                         % (rng[0] * SVG, y * SVG, rng[1] * SVG, y * SVG, color, width))
        i += 1
        y += step
    y = NY / 2.0 - step
    i = 0
    while y > 0:
        rng = x_range_for_y(y, BULWARK)
        if rng:
            color = seam if (i % 4 == 0) else alt
            width = 4 if (i % 4 == 0) else 2
            parts.append('  <line x1="%.1f" y1="%.1f" x2="%.1f" y2="%.1f" stroke="%s" stroke-width="%d"/>'
                         % (rng[0] * SVG, y * SVG, rng[1] * SVG, y * SVG, color, width))
        i += 1
        y -= step
    return _svg(NX * SVG, NY * SVG, '\n'.join(parts), comment)


# ---------------------------------------------------------------------------
# 自检：甲板格子必须完全落在船壳轮廓内
# ---------------------------------------------------------------------------
def check_hull_contains_deck():
    """每个被占用的格子，四角都要在船壳轮廓内。

    这一条就是 docs/05 说的"外形同源"的实际保证——
    它让"甲板比船壳宽了"变成生成期的硬错误，而不是 Day 2 之后才发现的视觉 bug。
    """
    bad = []
    for x in range(NX):
        sp = row_span(x)
        if sp is None:
            continue
        y0, y1 = sp
        h_allowed = half_beam(x + 0.5)
        for corner_y in (y0, y1 + 1):
            if abs(corner_y - NY / 2.0) > h_allowed + 1e-6:
                bad.append((x, corner_y))
    if bad:
        raise SystemExit(
            '船体外形自检失败：这些格子的角超出了船壳轮廓 %s\n'
            '说明 half_beam() 与 row_span() 不一致。' % bad[:12])


def main():
    check_hull_contains_deck()

    ship = build_ship()
    outputs = {
        OUT_SHIP: json.dumps(ship, ensure_ascii=False, indent=2) + '\n',
        OUT_HULL: svg_hull_outline(),
        OUT_BULWARK: svg_deck_bulwark(),
        OUT_PLANKS: svg_deck_planks(),
        OUT_FLOOR: svg_interior_floor(),
    }
    for rel, text in outputs.items():
        p = ROOT / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text, encoding='utf-8')
        print('wrote %s' % rel)

    print('\n列宽 WIDTHS = %s' % widths())
    for layer in ship['layers']:
        print('\nL%d %s  (elevation %+.1f m)' % (
            layer['id'], layer['name'], layer['elevation_m']))
        for row in layer['tiles']:
            print('   ' + row)


if __name__ == '__main__':
    main()
