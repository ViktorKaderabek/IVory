#!/usr/bin/env python3
"""Builds core/pokedata.json: stats of all species, types, evolution lines and level multipliers (CPM).

Sources (public data, downloaded only here; the app itself never downloads game data):
  - PvPoke gamemaster (species, forms, stats, evolutions)  https://github.com/pvpoke/pvpoke
  - PokeMiners game master (CP multipliers by level)       https://github.com/PokeMiners/game_masters

  python3 scripts/build_pokedata.py
"""
import json
import sys
import urllib.request
from pathlib import Path

PVPOKE = "https://raw.githubusercontent.com/pvpoke/pvpoke/master/src/data/gamemaster.min.json"
MINERS = "https://raw.githubusercontent.com/PokeMiners/game_masters/master/latest/latest.json"
OUT = Path(__file__).resolve().parents[1] / "core" / "pokedata.json"
KEEP_TAGS = {"legendary", "mythical", "ultrabeast", "alolan", "galarian", "hisuian", "paldean"}


def fetch(url):
    with urllib.request.urlopen(url, timeout=120) as r:
        return json.load(r)


def main():
    gm = fetch(PVPOKE)
    species = {}
    for p in gm["pokemon"]:
        sid = p["speciesId"]
        tags = set(p.get("tags") or [])
        # shadow forms have the same stats, mega forms are only temporary: the base form is enough for the math
        if "shadow" in tags or "mega" in tags or sid.endswith("_shadow") or not p.get("released", True):
            continue
        fam = p.get("family") or {}
        species[sid] = {
            "name": p["speciesName"],
            "dex": p["dex"],
            "stats": [p["baseStats"]["atk"], p["baseStats"]["def"], p["baseStats"]["hp"]],
            "types": [t for t in p["types"] if t and t != "none"],
            "family": fam.get("id", ""),
            "parent": fam.get("parent"),
            "evolutions": fam.get("evolutions") or [],
            "tags": sorted(tags & KEEP_TAGS),
        }
    # drop evolutions that lead to excluded forms
    for sp in species.values():
        sp["evolutions"] = [e for e in sp["evolutions"] if e in species]
        if sp["parent"] not in species:
            sp["parent"] = None

    miners = fetch(MINERS)
    cpm = next(x["data"]["playerLevel"]["cpMultiplier"] for x in miners
               if x.get("templateId") == "PLAYER_LEVEL_SETTINGS")[:55]

    OUT.write_text(json.dumps({"source": "PvPoke gamemaster + PokeMiners game master",
                               "cpm": cpm, "species": species}, ensure_ascii=False, separators=(",", ":")))
    print(f"✔ {OUT} – {len(species)} druhů a forem, CPM pro úrovně 1–{len(cpm)}")


if __name__ == "__main__":
    sys.exit(main())
