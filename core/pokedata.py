#!/usr/bin/env python3
"""Game data for pokecalc: stats of all species, types, evolution lines and level multipliers (CPM),
and for the app's Battle screen (the "battle" part): moves, type chart, weather and the PvPoke league rankings.

The data isn't part of IVory. It is downloaded from the public sources below into ~/.pogo/pokedata.json:
scripts/run.sh refreshes it before every run once it is a week old (new Pokémon, changed stats), and
load() downloads it when it's missing (the bot or the tests started without run.sh).

Sources:
  - PvPoke gamemaster (species, forms, stats, evolutions, movesets)  https://github.com/pvpoke/pvpoke
  - PvPoke rankings (score, roles, moveset, matchups per league)     the same repository
  - PokeMiners game master (CP multipliers, raid moves, type chart,  https://github.com/PokeMiners/game_masters
    weather boosts, power-up costs)

  python3 core/pokedata.py      # download now
"""
import json
import re
import ssl
import urllib.request
from pathlib import Path

PVPOKE = "https://raw.githubusercontent.com/pvpoke/pvpoke/master/src/data/gamemaster.min.json"
MINERS = "https://raw.githubusercontent.com/PokeMiners/game_masters/master/latest/latest.json"
CACHE = Path.home() / ".pogo" / "pokedata.json"
RANKINGS = "https://raw.githubusercontent.com/pvpoke/pvpoke/master/src/data/rankings/all/overall/rankings-{}.json"
KEEP_TAGS = {"legendary", "mythical", "ultrabeast", "regional", "alolan", "galarian", "hisuian", "paldean"}
LEAGUES = {"great": 1500, "ultra": 2500, "master": 10000}
# order of the attackScalar lists in the game master
TYPES = ["normal", "fighting", "flying", "poison", "ground", "rock", "bug", "ghost", "steel", "fire", "water", "grass",
         "electric", "psychic", "ice", "dragon", "dark", "fairy"]
# game master weather → the names ScrapedDuck uses for the raid bosses' weather boost
WEATHER = {"CLEAR": "sunny", "RAINY": "rainy", "PARTLY_CLOUDY": "partly cloudy", "OVERCAST": "cloudy",
           "WINDY": "windy", "SNOW": "snow", "FOG": "fog"}
# PvPoke move id → game master move, where the names differ
MOVE_ALIASES = {"PYRO_BALL": "PYROBALL", "TECHNO_BLAST_DOUSE": "TECHNO_BLAST_WATER"}


def _ssl_context():
    # the downloaded Python may not see the system certificates; certifi comes with selenium
    try:
        import certifi
        return ssl.create_default_context(cafile=certifi.where())
    except ImportError:
        return ssl.create_default_context()


def fetch(url):
    with urllib.request.urlopen(url, timeout=120, context=_ssl_context()) as r:
        return json.load(r)


def build():
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
    rankings = {lg: fetch(RANKINGS.format(cp)) for lg, cp in LEAGUES.items()}
    return {"source": "PvPoke gamemaster + PokeMiners game master", "cpm": cpm, "species": species,
            "battle": battle(gm, miners, rankings)}


def battle(gm, miners, rankings):
    """What the Battle screen needs: every form (megas and shadows too, for raid bosses and PvP opponents) with
    its moves, the raid stats of those moves, the type chart, weather boosts and the league rankings."""
    pve = {}
    for x in miners:
        ms = x["data"].get("moveSettings")
        if ms and re.match(r"V\d+_MOVE_", x["templateId"]):
            pve[x["templateId"].split("_MOVE_", 1)[1]] = ms
            pve[str(ms.get("movementId"))] = ms
    names = {m["moveId"]: m["name"] for m in gm["moves"]}
    moves = {}

    def known(mid, fast):
        """Adds the move's raid stats to `moves`; False when the game master doesn't have it."""
        if mid in moves:
            return True
        key = MOVE_ALIASES.get(mid, mid)
        mtype = None
        if mid.startswith("HIDDEN_POWER_"):           # one move in the game, its type depends on the Pokémon
            key, mtype = "HIDDEN_POWER", mid.rsplit("_", 1)[1].lower()
        ms = pve.get(key + "_FAST") if fast else None
        ms = ms or pve.get(key)
        if not ms or not ms.get("durationMs"):
            return False
        moves[mid] = {"name": names.get(mid, mid.replace("_", " ").title()),
                      "type": mtype or ms["pokemonType"].replace("POKEMON_TYPE_", "").lower(),
                      "power": ms.get("power", 0), "duration": ms["durationMs"] / 1000,
                      "energy": abs(ms.get("energyDelta", 0))}
        return True

    pokemon = {}
    for p in gm["pokemon"]:
        if not p.get("released", True):
            continue
        entry = {"name": p["speciesName"], "dex": p["dex"],
                 "stats": [p["baseStats"]["atk"], p["baseStats"]["def"], p["baseStats"]["hp"]],
                 "types": [t for t in p["types"] if t and t != "none"],
                 "fast": [m for m in p.get("fastMoves") or [] if known(m, True)],
                 "charged": [m for m in p.get("chargedMoves") or [] if known(m, False)]}
        elite = [m for m in p.get("eliteMoves") or [] if m in entry["fast"] or m in entry["charged"]]
        if elite:
            entry["elite"] = elite
        pokemon[p["speciesId"]] = entry

    chart = {}
    for x in miners:
        te = x["data"].get("typeEffective")
        if te:
            chart[te["attackType"].replace("POKEMON_TYPE_", "").lower()] = te["attackScalar"]
    weather = {}
    for x in miners:
        wa = x["data"].get("weatherAffinities")
        if wa and wa["weatherCondition"] in WEATHER:
            weather[WEATHER[wa["weatherCondition"]]] = [t.replace("POKEMON_TYPE_", "").lower() for t in wa["pokemonType"]]
    up = next((x["data"]["pokemonUpgrades"] for x in miners if x["templateId"] == "POKEMON_UPGRADE_SETTINGS"), {})
    upgrades = {"stardust": up.get("stardustCost") or [], "candy": up.get("candyCost") or [], "xl": up.get("xlCandyCost") or []}
    leagues = {lg: {r["speciesId"]: {"score": r["score"], "roles": r.get("scores") or [], "moveset": r.get("moveset") or [],
                                     "beats": [m["opponent"] for m in r.get("matchups") or []],
                                     "loses": [m["opponent"] for m in r.get("counters") or []]}
                    for r in ranking}
               for lg, ranking in rankings.items()}
    return {"pokemon": pokemon, "moves": moves, "types": {"order": TYPES, "chart": chart}, "weather": weather,
            "leagues": leagues, "upgrades": upgrades}


def refresh():
    """Downloads the data into CACHE. The old file stays when the download fails."""
    data = build()
    CACHE.parent.mkdir(parents=True, exist_ok=True)
    tmp = CACHE.with_suffix(".tmp")
    tmp.write_text(json.dumps(data, ensure_ascii=False, separators=(",", ":")))
    tmp.replace(CACHE)
    return data


def load():
    if CACHE.exists():
        return json.loads(CACHE.read_text())
    return refresh()


if __name__ == "__main__":
    out = refresh()
    b = out["battle"]
    print(f"✔ {CACHE} – {len(out['species'])} species and forms, CPM for levels 1–{len(out['cpm'])}, "
          f"{len(b['moves'])} moves, rankings for {len(b['leagues'])} leagues")
