"""Tag names: which IV tag an IV belongs in, whether a text OCR read is a given tag, and which tags a
Pokémon already wears (the chips on its detail screen)."""
import difflib

from . import config as cfg
from .vision import alnum, in_region


def same_tag(text, name):
    a, b = alnum(text), alnum(name)
    if not a or not b:
        return False
    if a == b or (a.endswith(b) and len(a) <= len(b) + 2):
        return True
    return len(b) >= 6 and difflib.SequenceMatcher(None, a, b).ratio() >= 0.88


# --- IV tags (part 2) ---
def iv_tag(iv):
    """Name of the IV tag for the IV percentage (sum / 45)."""
    total = sum(iv)
    for threshold, name in cfg.IV_TAGS:
        if total * 100 >= threshold * 45:
            return name
    return cfg.IV_TAGS[-1][1]


def detail_tags(tx):
    """All known tags (IV, TAG_NAME, PvP leagues, Battle tags, the tag renaming is limited to) that the Pokémon
    has on its detail screen."""
    region = (0.0, 0.44, 1.0, 0.68)
    known = [n for _, n in cfg.IV_TAGS] + [cfg.TAG_NAME] + [lg["name"] for lg in cfg.PVP.values()] + cfg.battle_tags() + \
        ([cfg.RENAME["only_tag"]] if cfg.RENAME["only_tag"] else []) + \
        ([cfg.WEAK["keep_tag"]] if cfg.WEAK["keep_tag"] else [])
    return [n for n in dict.fromkeys(known) if any(in_region(t, region) and same_tag(t["text"], n) for t in tx)]


def detail_chips(tx):
    """Tag chips under the name on the detail screen: (list of IV tags, whether it has TAG_NAME –
    "Removable" by default)."""
    region = (0.0, 0.44, 1.0, 0.68)
    have = []
    for _, name in cfg.IV_TAGS:
        if any(in_region(t, region) and same_tag(t["text"], name) for t in tx):
            have.append(name)
    removable = any(in_region(t, region) and same_tag(t["text"], cfg.TAG_NAME) for t in tx)
    return have, removable


