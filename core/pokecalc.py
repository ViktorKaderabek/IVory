"""Výpočty nad statistikami druhů (core/pokedata.json, vytváří ho scripts/build_pokedata.py).

- druh a úroveň kusu z toho, co je vidět v detailu: jméno, typy, CP, HP a IV
  (i u přejmenovaných – sedět musí CP i HP zároveň)
- CP po evoluci, max CP na úrovni 50
- pořadí IV pro PvP ligy (1 = nejlepší ze 4096 kombinací, s nejlepší evolucí pod limit CP)
- hodnoty dílků pro šablonu jména

CP = (útok + IV) · √(obrana + IV) · √(výdrž + IV) · CPM² / 10, HP = (výdrž + IV) · CPM.
"""
import json
import re
import unicodedata
from functools import lru_cache
from pathlib import Path

import numpy as np

DATA = json.loads(Path(__file__).with_name("pokedata.json").read_text())
SPECIES = DATA["species"]
_CPM = DATA["cpm"]                       # celé úrovně 1, 2, 3 …
MAX_LEVEL = 50.0                         # strop pro PvP pořadí a max CP
LEAGUES = {"great": 1500, "ultra": 2500, "master": None}
LEAGUE_LETTER = {"great": "G", "ultra": "U", "master": "M"}


def _cpm_at(level):
    lo = _CPM[int(level) - 1]
    if level == int(level):
        return lo
    hi = _CPM[int(level)]
    return ((lo * lo + hi * hi) / 2) ** 0.5


LEVELS = np.arange(1.0, 51.01, 0.5)                  # úrovně 1 – 51 po půlkách
CPM = np.array([_cpm_at(level) for level in LEVELS])
PVP_LEVELS = LEVELS <= MAX_LEVEL
IV_GRID = np.array([(a, d, s) for a in range(16) for d in range(16) for s in range(16)])


def alnum(s):
    s = unicodedata.normalize("NFKD", s or "")
    return re.sub(r"[^a-z0-9]", "", "".join(c for c in s if not unicodedata.combining(c)).lower())


def base_name(name):
    """„Raichu (Alolan)“ → „Raichu“ (ve hře se forma ve jménu neukazuje)."""
    return re.sub(r"\s*\(.*\)$", "", name or "").strip()


NAME_INDEX = {}
for _sid, _sp in SPECIES.items():
    NAME_INDEX.setdefault(alnum(base_name(_sp["name"])), []).append(_sid)


def is_species_name(name):
    return alnum(name) in NAME_INDEX


def cp_of(stats, iv, cpm):
    a, d, s = (b + i for b, i in zip(stats, iv))
    return max(10, int(a * d ** 0.5 * s ** 0.5 * cpm * cpm / 10))


def _cps(stats, iv):
    a, d, s = (b + i for b, i in zip(stats, iv))
    return np.maximum(10, np.floor(a * d ** 0.5 * s ** 0.5 * CPM * CPM / 10)).astype(int)


def _hps(stats, iv):
    return np.maximum(10, np.floor((stats[2] + iv[2]) * CPM)).astype(int)


def descendants(sid):
    """Druh a všechny jeho další evoluce (všechny větve)."""
    out, todo = [], [sid]
    while todo:
        x = todo.pop(0)
        if x in SPECIES and x not in out:
            out.append(x)
            todo += SPECIES[x]["evolutions"]
    return out


def final_evolution(sid, iv=(15, 15, 15)):
    """Poslední evoluce; u větvení ta s nejvyšším max CP."""
    leaves = [x for x in descendants(sid) if not SPECIES[x]["evolutions"]] or [sid]
    return max(leaves, key=lambda x: cp_of(SPECIES[x]["stats"], iv, _cpm_at(MAX_LEVEL)))


def identify(name, types, cp, hp, iv, family_hint=None, dex_range=None):
    """Druh a úroveň kusu. Vrací (id druhu, úroveň) nebo (None, None), když to jednoznačně nejde.
    dex_range: rozmezí čísla v Pokédexu podle sousedů v boxu seřazeném podle čísla."""
    if not cp or not iv:
        return None, None
    cands = NAME_INDEX.get(alnum(name)) or list(SPECIES)
    if types:
        typed = [c for c in cands if sorted(SPECIES[c]["types"]) == sorted(types)]
        cands = typed or cands
    if family_hint:
        hint = alnum(family_hint)
        fam = [c for c in cands if hint and hint in alnum(SPECIES[c]["family"])]
        cands = fam or cands
    fits = []
    for c in cands:
        st = SPECIES[c]["stats"]
        ok = _cps(st, iv) == cp
        if hp:
            ok &= _hps(st, iv) == hp
        fits += [(c, float(LEVELS[k])) for k in np.flatnonzero(ok)]
    if dex_range:
        fits = [f for f in fits if dex_range[0] <= SPECIES[f[0]]["dex"] <= dex_range[1]]
    if not fits:
        return None, None
    kinds = {tuple(SPECIES[c]["stats"]) for c, _ in fits}
    if len(kinds) == 1:                 # jeden druh (nebo formy se stejnými staty)
        return fits[0]
    return None, None


def iv_fits(name, types, cp, hp, iv, family_hint=None, max_species=3):
    """Sedí IV přesně na CP a HP kusu pro nějakou úroveň? Druh podle jména, typů a cukru – jen když
    zbyde pár druhů (u neznámé přezdívky by mohla sednout náhoda). Bary appraisalu v půlce animace
    na CP i HP skoro nikdy nesednou."""
    if not (cp and hp and iv):
        return False
    cands = list(NAME_INDEX.get(alnum(name or "")) or [])
    if not cands and family_hint:
        hint = alnum(family_hint)
        cands = [c for c in SPECIES if hint and hint in alnum(SPECIES[c]["family"])]
    if types:
        cands = [c for c in cands if sorted(SPECIES[c]["types"]) == sorted(types)] or cands
    if not cands or len(cands) > max_species:
        return False
    return any(bool(((_cps(SPECIES[c]["stats"], iv) == cp) & (_hps(SPECIES[c]["stats"], iv) == hp)).any())
               for c in cands)


@lru_cache(maxsize=None)
def _league_products(sid, cap):
    """Součin statů pro všech 4096 IV na nejvyšší úrovni (≤ 50), kde CP nepřesáhne limit; -1 = nevejde se."""
    st = SPECIES[sid]["stats"]
    a = st[0] + IV_GRID[:, 0]
    d = st[1] + IV_GRID[:, 1]
    s = st[2] + IV_GRID[:, 2]
    cpm = CPM[PVP_LEVELS]
    cps = np.maximum(10, np.floor(a[:, None] * np.sqrt(d)[:, None] * np.sqrt(s)[:, None] * cpm ** 2 / 10))
    idx = (cps <= cap).sum(axis=1) - 1 if cap else np.full(len(a), len(cpm) - 1)
    m = cpm[np.clip(idx, 0, None)]
    prod = (a * m) * (d * m) * np.floor(s * m)
    return np.where(idx >= 0, prod, -1.0)


def league_rank(sid, iv, league):
    """Pořadí IV pro ligu (1 = nejlepší) s nejlepší evolucí pod limit CP: (pořadí, druh) nebo None."""
    cap = LEAGUES[league]
    k = iv[0] * 256 + iv[1] * 16 + iv[2]
    best = None
    for form in descendants(sid):
        prod = _league_products(form, cap)
        if prod[k] < 0:
            continue
        rank = 1 + int((prod > prod[k]).sum())
        if best is None or rank < best[0]:
            best = (rank, form)
    return best


def info(sid, iv, level, cp_now):
    """Všechno, co se o kusu dá spočítat (hodnoty pro šablonu jména i pro PvP tagy)."""
    sp = SPECIES[sid]
    fin = final_evolution(sid, iv)
    fname = base_name(SPECIES[fin]["name"])
    cp_evo = cp_now if fin == sid else cp_of(SPECIES[fin]["stats"], iv, _cpm_at(level))
    ranks = {lg: league_rank(sid, iv, lg) for lg in LEAGUES}
    return {
        "species": base_name(sp["name"]), "dex": sp["dex"], "level": level, "final": fname,
        "cp_evo": cp_evo, "max_cp": cp_of(SPECIES[fin]["stats"], iv, _cpm_at(MAX_LEVEL)),
        "ranks": {lg: (r[0] if r else None) for lg, r in ranks.items()},
    }


def iv_values(iv):
    """Dílky šablony, které stačí znát z IV (bez druhu)."""
    return {"iv": str(round(sum(iv) * 100 / 45)), "ivs": f"{iv[0]}/{iv[1]}/{iv[2]}"}


def chip_values(inf, iv):
    """Hodnoty dílků šablony jména (klíče jako v aplikaci: iv, ivs, lvl, species, short, evo,
    cpEvo, cpMax, great, ultra, master)."""
    def rank(lg):
        r = inf["ranks"].get(lg)
        return f"{LEAGUE_LETTER[lg]}{r}" if r else f"{LEAGUE_LETTER[lg]}-"
    return dict(iv_values(iv), lvl=f"L{inf['level']:g}", species=inf["species"], short=inf["species"][:6],
                evo=inf["final"][:3], cpEvo=str(inf["cp_evo"]), cpMax=str(inf["max_cp"]),
                great=rank("great"), ultra=rank("ultra"), master=rank("master"))


SEPARATORS = {"space": " ", "dash": "-", "pipe": "|"}
NAME_MAX = 12                                    # hra povolí max. 12 znaků
NEEDS_SPECIES = {"lvl", "species", "short", "evo", "cpEvo", "cpMax", "great", "ultra", "master"}


def render_name(template, values, cut=True):
    """Jméno podle šablony (dílky {"k": klíč, "v": vlastní text}); delší než 12 znaků se ořízne."""
    out = "".join(SEPARATORS[t["k"]] if t.get("k") in SEPARATORS else
                  str(t.get("v") or "") if t.get("k") == "text" else values.get(t.get("k"), "")
                  for t in template)
    return (out[:NAME_MAX] if cut else out).strip()


DEFAULT_TEMPLATE = [{"k": "iv"}, {"k": "space"}, {"k": "evo"}, {"k": "space"}, {"k": "master"}]
