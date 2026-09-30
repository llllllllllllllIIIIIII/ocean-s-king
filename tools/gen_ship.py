#!/usr/bin/env python3
"""根据船体参数生成 data/ships/caravel_60.json 与船壳轮廓 SVG。

为什么要有这个生成器（docs/05 第 8 节）：
    甲板格子的外形和 hull_outline.svg 必须来自同一个源。
    否则一边手摆格子、一边手画船壳，Day 2 一定会出现
    "甲板比船壳宽了两格"这种事后极难排查的错。

    所以：船体参数 -> 同时产出 甲板 tile map + 船壳 SVG 路径。

用法：
    python tools/gen_ship.py
"""

import json
import pathlib

# ---------------------------------------------------------------------------
# 船体参数（规格 B：约 60 吨 / 20 米 / 单桅拉丁帆）
# ---------------------------------------------------------------------------
NX = 20          # 船长方向格数（x=0 船首 -> x=19 船尾）
NY = 7           # 船宽方向格数（y=0 左舷 -> y=6 右舷，y=3 是中线）
M_PER_CELL = 1.0

# 每列的占用宽度（格）。WIDTHS[x] = 该列占几格。
# 艏部收窄 -> 中段最大 -> 艉部略收（平尾）
WIDTHS = [2, 3, 4, 5, 6, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 6, 6, 5, 5]

OUT_SHIP = 'data/ships/caravel_60.json'
OUT_SVG = 'assets/ship/parts/hull/hull_outline.svg'

ROOT = pathlib.Path(__file__).resolve().parent.parent


def row_span(x: int):
    """第 x 列占用的 y 区间 [y0, y1]"""
    w = WIDTHS[x]
    y0 = (NY - w) // 2
    return y0, y0 + w - 1


def blank():
    return [['.' for _ in range(NX)] for _ in range(NY)]   # grid[y][x]


def to_rows(grid):
    return [''.join(row) for row in grid]


# ---------------------------------------------------------------------------
# L2 主甲板
# ---------------------------------------------------------------------------
def build_deck():
    g = blank()
    for x in range(NX):
        y0, y1 = row_span(x)
        w = y1 - y0 + 1
        for y in range(y0, y1 + 1):
            if w <= 3:
                g[y][x] = '='          # 艏艉尖端，实心，不可走
            elif y == y0 or y == y1:
                g[y][x] = '='          # 舷墙
            else:
                g[y][x] = '#'          # 甲板

    # 开口与通道。注意：这些只是"地形"，桅杆/绞盘/舵是 props。
    g[3][12] = 'H'                     # 主舱口（下到 L1）
    g[3][4] = 'L'                      # 前梯（下到 L1）
    g[3][16] = 'L'                     # 尾梯（下到 L1）
    # 桅梯放在 (11,3)，紧邻桅杆 (10,3)。不能和桅杆同格——
    # 桅杆是 blocking prop，同格会让"爬上瞭望台"这条通道被堵死。
    g[3][11] = 'L'
    return g


# ---------------------------------------------------------------------------
# L1 下层甲板 / L0 货舱
# ---------------------------------------------------------------------------
def build_interior(features: dict):
    """features: {(x,y): char} 额外盖章（梯子/舱口）"""
    g = blank()
    for x in range(NX):
        y0, y1 = row_span(x)
        for y in range(y0, y1 + 1):
            if y == y0 or y == y1 or x == 0 or x == NX - 1:
                g[y][x] = '|'          # 船体内壁
            else:
                g[y][x] = '_'          # 舱内地板
    for (x, y), ch in features.items():
        g[y][x] = ch
    return g


def build_layer1():
    return build_interior({
        (12, 3): 'H',                  # 主舱口（从甲板下来）
        (4, 3): 'L', (16, 3): 'L',     # 甲板下来的梯子
        (7, 3): 'L', (14, 3): 'L',     # 下到货舱的梯子
    })


def build_layer0():
    return build_interior({
        (7, 3): 'L', (14, 3): 'L',     # 从下层甲板下来
    })


def build_layer3():
    """桅顶瞭望台：桅杆周围的一小块平台，其余是空气。"""
    g = blank()
    for x in range(9, 12):
        for y in range(2, 5):
            g[y][x] = 'p'
    g[3][11] = 'L'                     # 桅梯（下到 L2）
    return g


# ---------------------------------------------------------------------------
# 房间：格子上的语义标注（docs/05 第 3 节）
# ---------------------------------------------------------------------------
assert NX == 20 and NY == 7, 'ROOMS 是按 20x7 手写的，改了尺寸要一起改'

ROOMS = [
    # --- L1 下层甲板 ---
    {'id': 'galley', 'layer': 1, 'name': '厨房', 'purpose': 'cook',
     'cells': [(2, 2), (2, 3), (3, 2), (3, 3)]},
    {'id': 'berth_fwd', 'layer': 1, 'name': '前部铺位', 'purpose': 'sleep',
     'cells': [(5, 2), (5, 3), (5, 4), (6, 2), (6, 3), (6, 4)]},
    {'id': 'medicine', 'layer': 1, 'name': '医务角', 'purpose': 'heal',
     'cells': [(13, 3), (13, 4)]},
    {'id': 'captain_cabin', 'layer': 1, 'name': '船长室', 'purpose': 'captain',
     'cells': [(15, 2), (15, 3), (15, 4), (16, 2), (16, 3), (16, 4)]},
    # --- L0 货舱 ---
    {'id': 'ballast', 'layer': 0, 'name': '压舱石', 'purpose': 'ballast',
     'cells': [(2, 3), (3, 3), (4, 3)]},
    {'id': 'hold_water', 'layer': 0, 'name': '淡水舱', 'purpose': 'water',
     'cells': [(5, 3), (6, 3), (5, 4), (6, 4)]},
    {'id': 'hold_food', 'layer': 0, 'name': '食物舱', 'purpose': 'food',
     'cells': [(9, 3), (10, 3), (9, 4), (10, 4)]},
    {'id': 'stores', 'layer': 0, 'name': '备件舱', 'purpose': 'stores',
     'cells': [(15, 3), (16, 3), (15, 4), (16, 4)]},
]

# ---------------------------------------------------------------------------
# props：有状态的实体（docs/05 第 4 节）
# ---------------------------------------------------------------------------
PROPS = [
    {'type': 'mast', 'layer': 2, 'x': 10, 'y': 3, 'height_m': 14.0},
    {'type': 'capstan', 'layer': 2, 'x': 6, 'y': 3},
    {'type': 'windlass', 'layer': 2, 'x': 3, 'y': 3},
    {'type': 'helm', 'layer': 2, 'x': 17, 'y': 3},
    {'type': 'bunk', 'layer': 1, 'x': 5, 'y': 2},
    {'type': 'bunk', 'layer': 1, 'x': 5, 'y': 4},
    {'type': 'bunk', 'layer': 1, 'x': 6, 'y': 2},
    {'type': 'stove', 'layer': 1, 'x': 3, 'y': 2},
    {'type': 'chest', 'layer': 1, 'x': 15, 'y': 4},
    {'type': 'barrel', 'layer': 0, 'x': 5, 'y': 3, 'contents': 'water'},
    {'type': 'barrel', 'layer': 0, 'x': 6, 'y': 4, 'contents': 'water'},
    {'type': 'barrel', 'layer': 0, 'x': 9, 'y': 3, 'contents': 'food'},
    {'type': 'cargo', 'layer': 0, 'x': 15, 'y': 3},
]

LINKS = [
    {'type': 'hatch', 'x': 12, 'y': 3, 'from': 2, 'to': 1},
    {'type': 'ladder', 'x': 4, 'y': 3, 'from': 2, 'to': 1},
    {'type': 'ladder', 'x': 16, 'y': 3, 'from': 2, 'to': 1},
    {'type': 'ladder', 'x': 11, 'y': 3, 'from': 2, 'to': 3},
    {'type': 'ladder', 'x': 7, 'y': 3, 'from': 1, 'to': 0},
    {'type': 'ladder', 'x': 14, 'y': 3, 'from': 1, 'to': 0},
]


def build_ship():
    return {
        'id': 'caravel_60',
        'name': '圣安东尼奥号',
        'version': 1,
        '_generated_by': 'tools/gen_ship.py —— 请改生成器，不要直接改这个文件',
        'units': {'meters_per_cell': M_PER_CELL},
        'hull': {
            'length_m': NX * M_PER_CELL,
            'beam_m': NY * M_PER_CELL,
            'displacement_t': 60,
            'cells_x': NX,
            'cells_y': NY,
            'origin_cell': [10, 3],
        },
        'layers': [
            {'id': 2, 'name': '主甲板', 'elevation_m': 0.0, 'kind': 'deck',
             'tiles': to_rows(build_deck())},
            {'id': 1, 'name': '下层甲板', 'elevation_m': -2.0, 'kind': 'interior',
             'tiles': to_rows(build_layer1())},
            {'id': 0, 'name': '货舱', 'elevation_m': -4.0, 'kind': 'interior',
             'tiles': to_rows(build_layer0())},
            {'id': 3, 'name': '桅顶瞭望台', 'elevation_m': 12.0, 'kind': 'platform',
             'tiles': to_rows(build_layer3())},
        ],
        'links': LINKS,
        'rooms': [dict(r, cells=[list(c) for c in r['cells']]) for r in ROOMS],
        'props': PROPS,
        'rig': {
            'masts': [{
                'id': 'main', 'pos': [10, 3], 'height_m': 14.0,
                'sails': [
                    {'id': 'main', 'type': 'lateen', 'area_m2': 38.0,
                     'boom_pivot': [10, 3], 'boom_length_m': 13.0},
                    {'id': 'jib', 'type': 'lateen', 'area_m2': 17.0,
                     'boom_pivot': [10, 3], 'boom_length_m': 8.0},
                ],
            }],
        },
        'vitals': {'hull': 1.0, 'mast': 1.0, 'rudder': 1.0},
    }


# ---------------------------------------------------------------------------
# 船壳轮廓 SVG：用同一条 WIDTHS 曲线生成，保证和甲板格子永远对得上
# ---------------------------------------------------------------------------
def build_hull_svg(scale=100.0):
    """把格子宽度曲线转成一条平滑的船壳轮廓路径。"""
    pts = []
    for x in range(NX):
        y0, y1 = row_span(x)
        # 左舷边（含半格修正，让轮廓落在格子中心之外）
        pts.append(((x + 0.5) * scale, (y0 - 0.5) * scale))
    for x in range(NX - 1, -1, -1):
        y0, y1 = row_span(x)
        pts.append(((x + 0.5) * scale, (y1 + 0.5) * scale))

    d = 'M %.1f %.1f ' % pts[0] + ' '.join('L %.1f %.1f' % p for p in pts[1:]) + ' Z'

    w = NX * scale
    h = NY * scale
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="{w:.0f}" height="{h:.0f}" viewBox="0 0 {w:.0f} {h:.0f}">
  <!-- 由 tools/gen_ship.py 生成，与甲板 tile map 同源。请勿手改。 -->
  <path d="{d}" fill="#3b2a1a" stroke="#1a120a" stroke-width="{scale * 0.12:.0f}"/>
</svg>
'''


def main():
    ship_path = ROOT / OUT_SHIP
    svg_path = ROOT / OUT_SVG
    ship_path.parent.mkdir(parents=True, exist_ok=True)
    svg_path.parent.mkdir(parents=True, exist_ok=True)

    ship = build_ship()
    ship_path.write_text(json.dumps(ship, ensure_ascii=False, indent=2) + '\n',
                         encoding='utf-8')
    svg_path.write_text(build_hull_svg(), encoding='utf-8')

    print('wrote %s' % ship_path.relative_to(ROOT))
    print('wrote %s' % svg_path.relative_to(ROOT))
    for layer in ship['layers']:
        print('\nL%d %s  (elevation %+.1f m)' % (
            layer['id'], layer['name'], layer['elevation_m']))
        for row in layer['tiles']:
            print('   ' + row)


if __name__ == '__main__':
    main()
