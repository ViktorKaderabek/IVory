#!/usr/bin/env python3
"""Vytvoří core/pokedata.json: staty všech druhů, typy, evoluční řady a násobitele úrovní (CPM).

Zdroje (veřejná data, stahuje se jen tady – aplikace pak nic nestahuje):
  - PvPoke gamemaster (druhy, formy, staty, evoluce)  https://github.com/pvpoke/pvpoke
  - PokeMiners game master (násobitele CP podle úrovně) https://github.com/PokeMiners/game_masters

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
        # stínové a mega formy mají stejné staty / jsou jen dočasné – pro výpočty stačí základní forma
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
    # evoluce, které vedou na vyřazené formy, vynechat
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
