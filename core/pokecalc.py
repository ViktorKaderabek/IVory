"""Calculations on species stats (~/.pogo/pokedata.json, downloaded by core/pokedata.py).

- species and level of a Pokémon from what the detail screen shows: name, types, CP, HP and IV
  (renamed ones too – CP and HP must both fit)
- CP after evolving, max CP at level 50
- IV rank for the PvP leagues (1 = best of the 4096 combinations, for the last evolution under the CP cap)
- chip values for the name template

CP = (attack + IV) · √(defense + IV) · √(stamina + IV) · CPM² / 10, HP = (stamina + IV) · CPM.
"""
import re
import unicodedata
from functools import lru_cache

import numpy as np

import pokedata

DATA = pokedata.load()
SPECIES = DATA["species"]
_CPM = DATA["cpm"]                       # whole levels 1, 2, 3 …
MAX_LEVEL = 50.0                         # cap for the PvP rank and max CP
LEAGUES = {"great": 1500, "ultra": 2500, "master": None}
LEAGUE_LETTER = {"great": "G", "ultra": "U", "master": "M"}


def _cpm_at(level):
    lo = _CPM[int(level) - 1]
    if level == int(level):
        return lo
    hi = _CPM[int(level)]
    return ((lo * lo + hi * hi) / 2) ** 0.5


LEVELS = np.arange(1.0, 51.01, 0.5)                  # levels 1 – 51 in half steps
CPM = np.array([_cpm_at(level) for level in LEVELS])
PVP_LEVELS = LEVELS <= MAX_LEVEL
IV_GRID = np.array([(a, d, s) for a in range(16) for d in range(16) for s in range(16)])


def alnum(s):
    s = unicodedata.normalize("NFKD", s or "")
    return re.sub(r"[^a-z0-9]", "", "".join(c for c in s if not unicodedata.combining(c)).lower())


def base_name(name):
    """Name without the form: "Raichu (Alolan)" → "Raichu" (the game doesn't show the form in the name)."""
    return re.sub(r"\s*\(.*\)$", "", name or "").strip()


NAME_INDEX = {}
for _sid, _sp in SPECIES.items():
    NAME_INDEX.setdefault(alnum(base_name(_sp["name"])), []).append(_sid)
    if alnum(_sp["name"]) == "mimejr":            # "Mime (Jr)" – "Mime Jr." in the game, not a form
        NAME_INDEX.setdefault("mimejr", []).append(_sid)


def family_key(sid):
    """Family of a species, for the candy hint. Species without evolutions (legendaries like Kyurem) have no
    family in the data – their candy is named after the species."""
    sp = SPECIES[sid]
    return alnum(sp["family"]) or "family" + alnum(base_name(sp["name"]))


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
    """The species and all of its further evolutions (every branch)."""
    out, todo = [], [sid]
    while todo:
        x = todo.pop(0)
        if x in SPECIES and x not in out:
            out.append(x)
            todo += SPECIES[x]["evolutions"]
    return out


def final_evolution(sid, iv=(15, 15, 15)):
    """The last evolution; when it branches, the one with the highest max CP."""
    leaves = [x for x in descendants(sid) if not SPECIES[x]["evolutions"]] or [sid]
    return max(leaves, key=lambda x: cp_of(SPECIES[x]["stats"], iv, _cpm_at(MAX_LEVEL)))


def types_fit(sid, types):
    """Do the read types fit the species? Often only one of two types is read from the detail screen
    (Kyurem: "dragon" without "ice"), so it's enough that the species has the types that were read."""
    return set(types) <= set(SPECIES[sid]["types"])


def identify(name, types, cp, hp, iv, family_hint=None, dex_range=None):
    """Species and level of a Pokémon. Returns (species id, level), or (None, None) when there is no
    unambiguous answer.
    dex_range: Pokédex number range, from the neighbors in the storage sorted by number."""
    if not cp or not iv:
        return None, None
    cands = NAME_INDEX.get(alnum(name)) or list(SPECIES)
    if types:
        typed = [c for c in cands if types_fit(c, types)]
        cands = typed or cands
    if family_hint:
        hint = alnum(family_hint)
        fam = [c for c in cands if hint and hint in family_key(c)]
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
    if len(kinds) > 1:
        # A name given by the bot ("MAX 3429 L35"): the species whose max CP (or level) is in the name wins
        nums = {int(x) for x in re.findall(r"\d+", name or "")}
        named = [f for f in fits if max_cp(f[0], iv) in nums] or \
                [f for f in fits if nums and f[1] == int(f[1]) and int(f[1]) in nums]
        fits = named or fits
        kinds = {tuple(SPECIES[c]["stats"]) for c, _ in fits}
    if len(kinds) == 1:                 # one species (or forms with the same stats)
        return fits[0]
    return None, None


def max_cp(sid, iv):
    """Max CP of the last evolution at level 50 (the cpMax template chip)."""
    return cp_of(SPECIES[final_evolution(sid, iv)]["stats"], iv, _cpm_at(MAX_LEVEL))


def iv_fits(name, types, cp, hp, iv, family_hint=None, max_species=3):
    """Do the IV fit the Pokémon's CP and HP exactly at some level? Species by name, types and candy – only
    when just a few species are left (with an unknown nickname a match could be chance). Appraisal bars
    caught mid-animation almost never fit both CP and HP."""
    if not (cp and hp and iv):
        return False
    cands = list(NAME_INDEX.get(alnum(name or "")) or [])
    if not cands and family_hint:
        hint = alnum(family_hint)
        cands = [c for c in SPECIES if hint and hint in family_key(c)]
    if types:
        cands = [c for c in cands if types_fit(c, types)] or cands
    if not cands or len(cands) > max_species:
        return False
    return any(bool(((_cps(SPECIES[c]["stats"], iv) == cp) & (_hps(SPECIES[c]["stats"], iv) == hp)).any())
               for c in cands)


@lru_cache(maxsize=None)
def _league_products(sid, cap):
    """Stat product for all 4096 IVs at the highest level (≤ 50) where CP stays within the cap; -1 = doesn't fit."""
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
    """League IV rank (1 = best) of the last evolution (the best one when it branches): (rank, species) or None.
    Lower stages are not ranked – Treecko with 15/15/15 doesn't reach 1500 CP even at level 50, so it would
    be "first" in every league, even though it is played there as Sceptile."""
    cap = LEAGUES[league]
    k = iv[0] * 256 + iv[1] * 16 + iv[2]
    best = None
    for form in [x for x in descendants(sid) if not SPECIES[x]["evolutions"]] or [sid]:
        prod = _league_products(form, cap)
        if prod[k] < 0:
            continue
        rank = 1 + int((prod > prod[k]).sum())
        if best is None or rank < best[0]:
            best = (rank, form)
    return best


def info(sid, iv, level, cp_now):
    """Everything that can be computed about a Pokémon (values for the name template and for PvP tags)."""
    sp = SPECIES[sid]
    fin = final_evolution(sid, iv)
    fname = base_name(SPECIES[fin]["name"])
    cp_evo = cp_now if fin == sid else cp_of(SPECIES[fin]["stats"], iv, _cpm_at(level))
    ranks = {lg: league_rank(sid, iv, lg) for lg in LEAGUES}
    return {
        "species": base_name(sp["name"]), "dex": sp["dex"], "level": level, "final": fname,
        "cp_evo": cp_evo, "max_cp": max_cp(sid, iv),
        "ranks": {lg: (r[0] if r else None) for lg, r in ranks.items()},
    }


def iv_values(iv):
    """Template chips that need only the IV (no species)."""
    return {"iv": str(round(sum(iv) * 100 / 45)), "ivs": f"{iv[0]}/{iv[1]}/{iv[2]}"}


def chip_values(inf, iv):
    """Name template chip values (keys as in the app: iv, ivs, lvl, species, short, evo,
    cpEvo, cpMax, great, ultra, master)."""
    def rank(lg):
        r = inf["ranks"].get(lg)
        return f"{LEAGUE_LETTER[lg]}{r}" if r else f"{LEAGUE_LETTER[lg]}-"
    return dict(iv_values(iv), lvl=f"L{inf['level']:g}", species=inf["species"], short=inf["species"][:6],
                evo=inf["final"][:3], cpEvo=str(inf["cp_evo"]), cpMax=str(inf["max_cp"]),
                great=rank("great"), ultra=rank("ultra"), master=rank("master"))


SEPARATORS = {"space": " ", "dash": "-", "pipe": "|"}
NAME_MAX = 12                                    # the game allows at most 12 characters
NEEDS_SPECIES = {"lvl", "species", "short", "evo", "cpEvo", "cpMax", "great", "ultra", "master"}


def render_name(template, values, cut=True):
    """Name from the template (chips {"k": key, "v": custom text}); anything over 12 characters is cut."""
    out = "".join(SEPARATORS[t["k"]] if t.get("k") in SEPARATORS else
                  str(t.get("v") or "") if t.get("k") == "text" else values.get(t.get("k"), "")
                  for t in template)
    return (out[:NAME_MAX] if cut else out).strip()


DEFAULT_TEMPLATE = [{"k": "iv"}, {"k": "space"}, {"k": "evo"}, {"k": "space"}, {"k": "master"}]
