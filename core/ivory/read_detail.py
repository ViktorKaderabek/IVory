"""What the Pokémon detail screen and the appraisal say: CP, name, types, HP, candy and the IV bars."""
import re

from . import config as cfg
from .vision import alnum, cp_value, find_re, find_text, in_region, norm


TYPES = {"normal", "fire", "water", "grass", "electric", "ice", "fighting", "poison", "ground",
         "flying", "psychic", "bug", "rock", "ghost", "dragon", "dark", "steel", "fairy"}
HP_RE = re.compile(r"^\d+\s*/\s*\d+\s*hp$")


def detail_on(tx):
    return bool(find_text(tx, ["stardust"], exact=True) or find_text(tx, ["power up"], exact=True)
                or find_re(tx, HP_RE))


def detail_menu_on(tx):
    r = (0.4, 0.25, 1.0, 0.92)
    return bool(find_text(tx, [cfg.L["appraise"]], exact=True, region=r)
                and (find_text(tx, ["favorite"], exact=True, region=r) or find_text(tx, ["transfer"], exact=True, region=r)))


def detail_cp(tx):
    for t in tx:
        v = cp_value(t["text"])
        if v is not None and t["cy"] < 0.12 and 0.25 < t["cx"] < 0.75:
            return v
    return None


def detail_name(tx):
    for t in tx:
        if 0.38 <= t["cy"] <= 0.46 and 0.25 <= t["cx"] <= 0.75 and not HP_RE.match(norm(t["text"])):
            return t["text"]
    return ""


def detail_types(tx):
    found = set()
    for t in tx:
        if 0.53 <= t["cy"] <= 0.66 and 0.25 <= t["cx"] <= 0.75:   # lower when the Pokémon has tag chips
            found |= {w for w in re.split(r"[^a-z]+", norm(t["text"])) if w in TYPES}
    return sorted(found) or None


def detail_hp(tx):
    """Max HP from the "73 / 73 HP" line (for an injured Pokémon the first number is smaller)."""
    for t in tx:
        m = re.match(r"^(\d+)\s*/\s*(\d+)\s*hp$", norm(t["text"]))
        if m:
            return int(m.group(2))
    return None


def detail_candy(tx):
    """The candy name ("FUECOCO CANDY") = the evolution family; helps tell the species of a renamed Pokémon."""
    for t in tx:
        m = re.match(r"^([a-z][a-z .'-]{2,}) candy$", norm(t["text"]))
        if m:
            return m.group(1).strip()
    return None
def dialog_text(tx):
    """Text in the speech bubble at the bottom (appraisal): long sentences."""
    parts = [t for t in tx if t["cy"] > 0.84 and len(t["text"]) >= 22 and t["text"].count(" ") >= 3]
    return " ".join(norm(t["text"]) for t in sorted(parts, key=lambda t: t["cy"]))


def bar_labels(tx):
    """The Attack/Defense/HP labels above the bars. If OCR misses one, it is inferred from the spacing."""
    keys = {"attack": (alnum(cfg.L["attack"]),), "defense": (alnum(cfg.L["defense"]), "defence"), "hp": (alnum(cfg.L["hp"]),)}
    found = {}
    for t in tx:
        if not in_region(t, (0.0, 0.55, 0.6, 0.95)):
            continue
        a = alnum(t["text"])
        for k, prefixes in keys.items():
            if k not in found and any(a.startswith(p) and len(a) <= len(p) + 2 for p in prefixes):
                found[k] = t
    order = ["attack", "defense", "hp"]
    if len(found) == 2:
        (i, a), (j, b) = sorted((order.index(k), t) for k, t in found.items())
        pitch = (b["cy"] - a["cy"]) / (j - i)
        m = ({0, 1, 2} - {i, j}).pop()
        dy = pitch * (m - i)
        found[order[m]] = {"text": order[m], "x0": (a["x0"] + b["x0"]) / 2, "x1": a["x1"],
                           "cx": a["cx"], "cy": a["cy"] + dy, "y0": a["y0"] + dy, "y1": a["y1"] + dy}
    if len(found) != 3:
        return None
    labs = [found[k] for k in order]
    pitches = [labs[1]["cy"] - labs[0]["cy"], labs[2]["cy"] - labs[1]["cy"]]
    if not all(0.025 < p < 0.07 for p in pitches):
        return None
    return labs


def bottom_x_visible(tx):
    return bool(find_text(tx, ["x"], exact=True, region=(0.44, 0.9, 0.56, 0.98)))


def appraisal_on(tx):
    """Appraisal = the bars, or the professor's/leader's speech bubble
    (not just any long text on the detail screen)."""
    if bar_labels(tx):
        return True
    d = dialog_text(tx)
    return bool(d) and detail_on(tx) and any(w in d for w in cfg.APPRAISAL_WORDS) and not bottom_x_visible(tx)
