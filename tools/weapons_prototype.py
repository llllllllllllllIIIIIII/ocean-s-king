#!/usr/bin/env python3
"""火器模型的离线标定（M6）。仿 tools/aero_prototype.py。

它做三件事：
    1. 读 data/defs/weapons.json（**数值的唯一真源**），按与 GDScript 完全相同的
       公式算一遍命中/伤害/哑火；
    2. 验四项硬指标（docs/13 第 6.2 节）—— 任何一条不过就退出码 1；
    3. 生成命中率查表 data/defs/weapons_table.json（给以后调参看趋势用）。

用法：
    python tools/weapons_prototype.py            # 验硬指标 + 打表
    python tools/weapons_prototype.py --mode metrics
    python tools/weapons_prototype.py --mode table
    python tools/weapons_prototype.py --mode scan --quality 1.35   # 扫"船员近战优势"这一个参数

⚠️ 公式是从 scripts/ballistics.gd 抄过来的。改那边必须改这里 ——
   两份不一致的时候，这个脚本就失去意义了（和气动那套一样的规矩）。
"""

import argparse
import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
DEFS = ROOT / "data" / "defs" / "weapons.json"
OUT_TABLE = ROOT / "data" / "defs" / "weapons_table.json"


def load():
    with DEFS.open(encoding="utf-8") as f:
        return json.load(f)


def weapon(d, wid):
    for w in d["weapons"]:
        if w["id"] == wid:
            return w
    for w in d.get("melee_weapons_local", []):
        if w["id"] == wid:
            return w
    return {}


def ammo(d, aid):
    for a in d["ammo_types"]:
        if a["id"] == aid:
            return a
    return {}


def weather(d, wid):
    for w in d["weather"]:
        if w["id"] == wid:
            return w
    return {}


def formation(d, fid):
    for f in d["formations"]:
        if f["id"] == fid:
            return f
    return {}


def reload_time(d, wid, skill):
    w = weapon(d, wid)
    return w["reload_s"] + (w["reload_skilled_s"] - w["reload_s"]) * max(0.0, min(1.0, skill))


def hit_chance(d, wid, skill, distance, formation_id="close", shooters=1, volley=False,
               target_size=None):
    w = weapon(d, wid)
    f = formation(d, formation_id)
    ts = f["target_size"] if target_size is None else target_size
    p = w["base_hit"] * (1.0 - w["skill_weight"] + w["skill_weight"] * max(0.0, min(1.0, skill)))
    eff = w["range_effective_m"]
    if distance > eff:
        over = (distance - eff) / max(1.0, w["half_range_m"])
        p *= 1.0 / (1.0 + over * over)
    p *= f["hit_mult"] * ts
    if volley and w["kind"] == "ranged":
        p *= 1.0 + f["volley_gain"] * max(0.0, min(1.0, (shooters - 1) / 9.0))
    return max(0.0, min(0.95, p))


def misfire_chance(d, wid, weather_id, wet=False):
    if wet:
        return 1.0
    w = weapon(d, wid)
    if w.get("kind") != "ranged":
        return 0.0
    return max(0.0, min(1.0, w["misfire_dry"] * weather(d, weather_id)["misfire_mult"]))


def damage_to_person(d, wid, aid, distance):
    w = weapon(d, wid)
    if w.get("kind") == "melee":
        return w["damage"]
    band = ammo(d, aid)["band_m"]
    if not (band[0] <= distance <= band[1]):
        return 0.0
    return w["damage"] * ammo(d, aid)["vs_person"]


def damage_to_structure(d, wid, aid):
    w = weapon(d, wid)
    if w.get("kind") == "melee":
        return 0.0
    return w["damage"] * ammo(d, aid)["vs_structure"]


def damage_to_rigging(d, wid, aid):
    """打帆索（M10 的链弹）。和砸结构、打人是三条独立的口径。"""
    w = weapon(d, wid)
    if w.get("kind") == "melee":
        return 0.0
    return w["damage"] * ammo(d, aid).get("vs_rigging", 0.0)


# ------------------------------------------------------------ 舷炮（M10）

def naval_hit_chance(d, wid, skill, distance, guns=6, broadside=False, closing=False):
    """舷炮命中：船炮的命中表 + 舷侧齐射增益 + 相对运动的罚。

    与 scripts/ballistics.gd 的 naval_hit_chance 同源 —— 两份不一致时这个脚本就没意义了。
    """
    n = d["naval"]
    p = hit_chance(d, wid, skill, distance, "ranked", 1, False, target_size=1.0)
    if broadside:
        p *= 1.0 + n["broadside_gain"] * max(0.0, min(1.0, (guns - 1) / 5.0))
    else:
        p *= n["independent_hit_mult"]
    if closing:
        p *= 1.0 - n["relative_motion_penalty"]
    return max(0.0, min(0.95, p))


def broadside_damage(d, skill, distance, aid, guns=6, broadside=True, closing=True):
    """一轮舷侧齐射的期望伤害（对结构）。"""
    p = naval_hit_chance(d, "culverin", skill, distance, guns, broadside, closing)
    return guns * p * damage_to_structure(d, "culverin", aid)


def ships_guns(d):
    """一艘船一侧的炮：从 naval.guns_per_side 推出来（不另写一份表）。"""
    out = []
    for wid, count in d["naval"]["guns_per_side"].items():
        out.append((wid, int(count)))
    return out


def boarding_rates(d, boarders, defenders, boarder_skill=0.6, defender_skill=0.45,
                   boarder_bonus=True):
    """接舷的期望值模型：跳帮那一下的一轮火器 + 之后甲板上的近战交换率。

    返回 (跳帮方每秒伤害, 防守方每秒伤害, 火器齐射的一次性伤害)。
    """
    b = d["naval"]["boarding"]
    q = d.get("crew_quality", {})
    dmg_mult = q.get("melee_damage_mult", 1.0) if boarder_bonus else 1.0
    hit_mult = q.get("melee_hit_mult", 1.0) if boarder_bonus else 1.0
    # 跳帮方：长矛（装填那一分钟里挡人的东西）
    pike = weapon(d, "pike")
    sword = weapon(d, "sword")

    def rate(weapon_def, skill, dmg, hit, cycle):
        p = weapon_def["base_hit"] * (1.0 - weapon_def["skill_weight"]
                                      + weapon_def["skill_weight"] * skill)
        return p * hit * weapon_def["damage"] * dmg / cycle

    board_rate = boarders * rate(pike, boarder_skill, dmg_mult, hit_mult, b["melee_cycle_s"])
    defend_rate = defenders * rate(sword, defender_skill, 1.0, b["defender_bonus"],
                                   b["melee_cycle_s"])
    volley = boarders * hit_chance(d, "arquebus", boarder_skill, 30.0, "close", 1, False) \
        * weapon(d, "arquebus")["damage"] * b["firearm_volley_mult"]
    return board_rate, defend_rate, volley


def expected_damage(d, shooters, wid, aid, skill, distance, formation_id, per_volley=1,
                    volley=False):
    p = hit_chance(d, wid, skill, distance, formation_id, per_volley, volley)
    return shooters * p * damage_to_person(d, wid, aid, distance)


# ------------------------------------------------------------ 四项硬指标

def metrics(d, verbose=True):
    results = []

    def check(ok, text):
        results.append((ok, text))
        if verbose:
            print("  [%s] %s" % ("PASS" if ok else "FAIL", text))

    print("=== 四项硬指标 ===")
    # 1 射速
    aq = min(reload_time(d, "arquebus", s) for s in (0.0, 0.5, 0.7))
    fal = min(reload_time(d, "falconet", s) for s in (0.0, 0.5, 1.0))
    check(aq >= 30.0, "火绳枪装填 ≥30 秒（最熟练也有 %.0f 秒）" % aq)
    check(reload_time(d, "arquebus", 1.0) >= 20.0,
          "顶尖射手也要 20 秒以上（%.0f 秒）" % reload_time(d, "arquebus", 1.0))
    check(fal >= 120.0, "隼炮每发 ≥120 秒（%.0f 秒）" % fal)
    check(60.0 / aq <= 2.0, "射速 ≤2 发/分钟（%.2f 发/分钟）" % (60.0 / aq))

    # 2 齐射
    v = expected_damage(d, 10, "arquebus", "single_ball", 0.5, 100.0, "close", 10, True)
    s = expected_damage(d, 10, "arquebus", "single_ball", 0.5, 100.0, "loose", 1, False)
    check(v >= s * 1.8, "密集齐射是各自为战的 %.2f 倍（%.3f vs %.3f）" % (v / s, v, s))

    # 3 哑火
    dry = misfire_chance(d, "arquebus", "dry")
    rain = misfire_chance(d, "arquebus", "rain")
    check(dry <= 0.05, "干燥哑火率 ≤5%%（%.1f%%）" % (dry * 100))
    check(rain >= 0.30, "大雨哑火率 ≥30%%（%.1f%%）" % (rain * 100))
    check(misfire_chance(d, "arquebus", "dry", True) == 1.0, "火药受潮 → 打不着")

    # 4 弹种
    sc = damage_to_structure(d, "falconet", "scatter")
    ro = damage_to_structure(d, "falconet", "round_shot")
    check(sc <= ro * 0.1, "霰弹砸船只有实心弹的 %.0f%%" % (sc / ro * 100))
    check(damage_to_person(d, "falconet", "scatter", 40) == 0.0
          and damage_to_person(d, "falconet", "scatter", 300) == 0.0,
          "霰弹只对 80–200 米内的人有杀伤")
    check(damage_to_person(d, "falconet", "round_shot", 300) < 0.1,
          "实心弹打人几乎没用（%.2f）" % damage_to_person(d, "falconet", "round_shot", 300))

    # ---- 舷炮（M10）的四项 ----
    print("--- 舷炮（M10）---")
    # 1 装填
    shots = 0
    t = 0.0
    while t < 600.0:
        t += reload_time(d, "culverin", 0.7)
        shots += 1
    check(min(reload_time(d, "culverin", s) for s in (0.0, 0.5, 1.0)) >= 120.0,
          "寇非林长炮每发 ≥120 秒（最熟练也有 %.0f 秒）"
          % min(reload_time(d, "culverin", s) for s in (0.0, 0.5, 1.0)))
    check(shots <= 4, "十分钟一场，一门长炮打不出 %d 发以上（实际 %d 发）" % (shots, shots))
    # 2 齐射
    bs = broadside_damage(d, 0.6, 300.0, "round_shot", 6, True, True)
    ind = broadside_damage(d, 0.6, 300.0, "round_shot", 6, False, True)
    check(bs >= ind * 1.8, "六门舷侧齐射是各自为战的 %.2f 倍（%.3f vs %.3f）"
          % (bs / ind, bs, ind))
    # 3 接舷
    br, dr, volley = boarding_rates(d, 8, 8)
    check(br > dr, "人数相等 + 船员质量 → 跳帮方近战占优（%.3f vs %.3f）" % (br, dr))
    br2, dr2, volley2 = boarding_rates(d, 8, 16, boarder_bonus=True)
    check(dr2 > br2 + volley2 / 30.0,
          "人数劣势时，火器那一轮救不回来（跳帮 %.3f + 齐射 %.2f 对 守方 %.3f）"
          % (br2, volley2, dr2))
    # 4 弹种
    check(damage_to_person(d, "culverin", "scatter", 150) >
          damage_to_person(d, "culverin", "round_shot", 150) * 3.0,
          "霰弹打人远胜实心弹（%.2f vs %.2f）"
          % (damage_to_person(d, "culverin", "scatter", 150),
             damage_to_person(d, "culverin", "round_shot", 150)))
    check(damage_to_structure(d, "culverin", "scatter")
          <= damage_to_structure(d, "culverin", "round_shot") * 0.1,
          "霰弹砸结构只有实心弹的 %.0f%%"
          % (damage_to_structure(d, "culverin", "scatter")
             / damage_to_structure(d, "culverin", "round_shot") * 100))
    check(damage_to_rigging(d, "culverin", "chain_shot")
          >= damage_to_rigging(d, "culverin", "round_shot") * 3.0,
          "链弹撕帆索远胜实心弹（%.2f vs %.2f）"
          % (damage_to_rigging(d, "culverin", "chain_shot"),
             damage_to_rigging(d, "culverin", "round_shot")))
    check(damage_to_person(d, "culverin", "chain_shot", 150) < 0.25,
          "链弹打人不行（%.2f）" % damage_to_person(d, "culverin", "chain_shot", 150))

    ok = all(r[0] for r in results)
    print("%s：%d 项检查" % ("全部通过" if ok else "有不过的", len(results)))
    return ok


def table(d):
    print("=== 命中率查表 ===")
    rows = []
    dists = [20, 40, 60, 80, 100, 130, 160, 200, 250]
    skills = [0.2, 0.4, 0.6, 0.8]
    for wid in ("arquebus", "swivel", "falconet"):
        for fid in ("loose", "close", "ranked"):
            for sk in skills:
                row = {"weapon": wid, "formation": fid, "skill": sk, "hit": {}}
                for dist in dists:
                    row["hit"][str(dist)] = round(
                        hit_chance(d, wid, sk, dist, fid, 1, False), 4)
                rows.append(row)
    payload = {
        "_comment": "由 tools/weapons_prototype.py 生成，别手改。给调参看趋势用，运行时不算它。",
        "distances_m": dists,
        "volley_gain": {f["id"]: f["volley_gain"] for f in d["formations"]},
        "rows": rows,
    }
    OUT_TABLE.write_text(json.dumps(payload, ensure_ascii=False, indent=1), encoding="utf-8")
    print("  写到 %s（%d 行）" % (OUT_TABLE.relative_to(ROOT), len(rows)))
    # 人眼看一眼关键几格
    for dist in (40, 100, 200):
        p = hit_chance(d, "arquebus", 0.5, dist, "close", 1, False)
        pv = hit_chance(d, "arquebus", 0.5, dist, "close", 10, True)
        print("  火绳枪 %3d 米：单发 %.2f　十人齐射 %.2f" % (dist, p, pv))
    return True


def scan(d, material_key, values):
    """扫一个参数，看它怎么影响一场 10 对 10 的结果（用简化的期望值模型）。"""
    print("=== 扫参数 %s ===" % material_key)
    for v in values:
        d["crew_quality"] = {"melee_damage_mult": v, "melee_hit_mult": 1.15}
        # 极简版：三轮齐射之后见面的期望伤亡
        crew_dmg = expected_damage(d, 10, "arquebus", "single_ball", 0.5, 100.0, "close", 10, True)
        locals_down = min(10.0, crew_dmg * 3)
        survivors = 10.0 - locals_down
        crew_melee = 4 * 0.38 * 1.0 * v * 0.26 / 4.5
        local_melee = survivors * 0.34 * 0.9 * 0.19 / 4.0
        verdict = "船员顶得住" if crew_melee > local_melee else "船员被打崩"
        print("  quality=%.2f：三轮齐射打倒 %.1f 个当地人；剩下 %.1f 人冲上来，"
              "船员近战 %.3f vs 当地人 %.3f → %s" % (
                  v, locals_down, survivors, crew_melee, local_melee, verdict))
    return True


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--mode", default="all", choices=["all", "metrics", "table", "scan"])
    ap.add_argument("--quality", type=float, default=None)
    args = ap.parse_args()
    d = load()

    ok = True
    if args.mode in ("all", "metrics"):
        ok = metrics(d) and ok
    if args.mode in ("all", "table"):
        table(d)
    if args.mode in ("all", "scan"):
        scan(d, "crew_quality.melee_damage_mult", [1.0, 1.15, 1.35, 1.5])
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
