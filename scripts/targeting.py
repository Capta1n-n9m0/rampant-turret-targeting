"""Build the Rampant target priority lists: the mod's targeting-data.lua, a report, and optionally a blueprint/book
with the lists stamped on its turrets plus a Lua console command for already-built turrets.

    python scripts/targeting.py [blueprint.base64.txt] [--tiers 1-5] [--max N]     (from the repository root)

Outputs:
  mod/rampant-turret-targeting/targeting-data.lua   the lists the mod uses
  out/targeting-report.md                 damage multiplier table + chosen priorities
  with a blueprint file:
  out/<input-name>-targeted.base64.txt   book/blueprint with priority-list on each turret
  out/apply_targeting.lua                 paste into the in-game console (/c ...) -- NOTE: disables achievements

Damage multipliers derived from RampantFixed 2.2.8 libs/Constants.lua + prototypes/SwarmUtils.lua
(tier 3 values of major=84%, minor=40%, extreme=99.99%, immunity=100%, majorWeak=-100%, minorWeak=-50%).
"""
import argparse, base64, json, os, re, sys, zlib

# ---- Rampant unit resistance data (units only; buildings/worms omitted) -------------
# damage multiplier vs physical / laser / fire   (1.0 = normal, 0 = immune, 2 = double)
UNITS = {
    # faction-unit          phys  laser fire   danger  note
    "nuclear-biter":       (1.0, 1.0, 0.16,  10, "nuke on death; kill before it reaches the wall"),
    "suicide-biter":       (1.0, 1.0, 0.16,   9, "explodes on wall; fast, low hp"),
    "energy-thief-biter":  (1.5, 0.16, 1.0,   7, "drains power; laser nearly useless"),
    "poison-biter":        (1.0, 2.0, 0.6,    7, "poison cloud on death"),
    "spawner-spitter":     (1.0, 1.0, 1.0,    7, "spawns swarm on death (30 long-range immunity)"),
    "inferno-spitter":     (1.0, 2.0, 0.0,    6, "fire pools, long range"),
    "laser-biter":         (1.5, 0.0, 0.6,    6, "laser immune"),
    "laser-spitter":       (1.5, 0.0, 0.6,    6, "laser immune, +2 range"),
    "fire-spitter":        (0.6, 2.0, 0.0,    6, "fire immune"),
    "fire-biter":          (0.6, 1.5, 0.0,    5, "fire immune, fire cloud on death"),
    "juggernaut-biter":    (0.0, 1.5, 0.0,    6, "tank; only laser works"),
    "troll-biter":         (0.6, 1.0, 2.0,    5, "huge hp+regen; burn it"),
    "physical-biter":      (0.16, 1.5, 0.6,   5, "armoured; bullets useless"),
    "electric-biter":      (1.0, 0.6, 1.0,    4, ""),
    "acid-biter":          (1.0, 1.0, 1.0,    3, ""),
    "acid-spitter":        (1.0, 1.0, 1.0,    3, ""),
    "fast-biter":          (1.0, 1.0, 0.5,    3, "not-flammable"),
    "fast-spitter":        (1.0, 1.0, 0.5,    3, "not-flammable"),
    "wasp-spitter":        (1.0, 1.0, 1.0,    3, "spawns wasps"),
    "neutral-biter":       (1.0, 1.0, 1.0,    2, ""),
    "neutral-spitter":     (1.0, 1.0, 1.0,    2, ""),
}
# ArmouredBiters "snappers" -- plain vanilla-style names, no Rampant tiers/factions.
# Resistances from ArmouredBiters 2.0.2 data.lua (percent + flat decrease, at 100% setting).
SNAPPERS = {
    # entity name                  phys  laser fire  danger note
    "leviathan-armoured-biter": (0.55, 0.35, 0.45, 8, "18k hp; bullets least resisted"),
    "behemoth-armoured-biter":  (0.65, 0.55, 0.60, 6, "6k hp"),
    "big-armoured-biter":       (0.75, 0.65, 0.75, 4, "800 hp"),
    "medium-armoured-biter":    (0.75, 0.85, 0.85, 3, "200 hp"),
    "small-armoured-biter":     (0.85, 0.85, 0.85, 2, "50 hp"),
}
MUST_FIRST = ("nuclear-biter", "suicide-biter")
DMG = {"gun-turret": 0, "laser-turret": 1, "flamethrower-turret": 2}   # column index

def ranked(turret, min_mult=0.35):
    """Order units for this turret: danger * effectiveness, drop units it can't hurt."""
    col = DMG[turret]
    rows = [(k, v) for k, v in {**UNITS, **SNAPPERS}.items() if v[col] >= min_mult]
    # bomb-type units come first whenever this turret does full damage to them
    rows.sort(key=lambda kv: (0 if (kv[0] in MUST_FIRST and kv[1][col] >= 1) else 1, -(kv[1][3] * kv[1][col])))
    return [k for k, _ in rows]

def expand(units, tiers):
    out = []
    for u in units:
        if u in SNAPPERS: out.append(u)                       # single prototype, no tiers
        else: out += [f"{u}-v1-t{t}-rampant" for t in reversed(tiers)]   # high tier first
    return out

# ---- blueprint plumbing ----------------------------------------------------------------
def decode(s): return json.loads(zlib.decompress(base64.b64decode(s.strip()[1:])))
def encode(o): return "0" + base64.b64encode(zlib.compress(json.dumps(o, separators=(",", ":")).encode(), 9)).decode()
HERO = re.compile(r"^hero-turret-\d+-for-(.+)$")
def base_name(n):
    m = HERO.match(n); return m.group(1) if m else n

def walk(node, fn):
    if "blueprint_book" in node:
        for c in node["blueprint_book"]["blueprints"]: walk(c, fn)
    elif "blueprint" in node:
        for e in node["blueprint"].get("entities", []): fn(e)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("file", nargs="?", help="blueprint string file to stamp (optional)")
    ap.add_argument("--tiers", default="1-10", help="tier range, e.g. 1-5 or 1-10")
    ap.add_argument("--max", type=int, default=0, help="cap entries per turret (0 = no cap)")
    a = ap.parse_args()
    lo, hi = map(int, a.tiers.split("-")); tiers = range(lo, hi + 1)

    lists = {}
    for t in DMG:
        names = expand(ranked(t), tiers)
        lists[t] = names[: a.max] if a.max else names

    os.makedirs("out", exist_ok=True)
    lua_tbl = "{" + ",".join(f'["{k}"]={{' + ",".join(f'"{x}"' for x in v) + "}" for k, v in lists.items()) + "}"
    if a.file:
        # 1) blueprint
        d = decode(open(a.file).read()); n = 0
        def stamp(e):
            nonlocal n
            b = base_name(e["name"])
            if b in lists:
                e["priority-list"] = [{"index": i + 1, "name": x} for i, x in enumerate(lists[b])]; n += 1
        walk(d, stamp)
        stem = os.path.splitext(os.path.splitext(os.path.basename(a.file))[0])[0]
        outp = f"out/{stem}-targeted.base64.txt"
        open(outp, "w").write(encode(d)); print(f"{outp}: {n} turrets stamped")

        # 2) Lua console command for already-built turrets
        lua = ["/c local L=" + lua_tbl,
               "local c=0 for _,s in pairs(game.surfaces) do for _,e in pairs(s.find_entities_filtered{type={'ammo-turret','electric-turret','fluid-turret'},force='player'}) do",
               " local b=e.name:match('^hero%-turret%-%d+%-for%-(.+)$') or e.name local l=L[b]",
               " if l then for i=1,250 do pcall(e.set_priority_target,e,i,l[i]) end c=c+1 end end end",
               "game.print('targeting applied to '..c..' turrets')"]
        open("out/apply_targeting.lua", "w").write(" ".join(lua) + "\n"); print("out/apply_targeting.lua written")

    # 2b) Lua data module for the mod (mod/rampant-turret-targeting/targeting-data.lua)
    mod_dir = "mod/rampant-turret-targeting"
    if os.path.isdir(mod_dir):
        hdr = "-- generated by scripts/targeting.py; do not edit"
        open(f"{mod_dir}/targeting-data.lua", "w").write(hdr + chr(10) + "return " + lua_tbl + chr(10))
        print(f"{mod_dir}/targeting-data.lua written")

    # 3) report
    r = ["# Rampant targeting report\n", "| unit | vs bullets | vs laser | vs fire | danger | note |", "|---|---|---|---|---|---|"]
    for k, v in sorted({**UNITS, **SNAPPERS}.items(), key=lambda kv: -kv[1][3]):
        r.append(f"| {k} | {v[0]:.2f}x | {v[1]:.2f}x | {v[2]:.2f}x | {v[3]} | {v[4]} |")
    for t in DMG:
        r += [f"\n## {t} priority order (tiers {a.tiers})", ""] + [f"{i+1}. {u}" for i, u in enumerate(ranked(t))]
    open("out/targeting-report.md", "w", encoding="utf8").write("\n".join(r) + "\n"); print("out/targeting-report.md written")

if __name__ == "__main__":
    main()
