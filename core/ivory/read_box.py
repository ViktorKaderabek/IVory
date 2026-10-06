"""What the Pokémon storage says: the header counts, the Search field, the sort menu and multi-select."""
import difflib
import re

from . import config as cfg
from .vision import alnum, find_re, find_text, norm, upper_text


TAG_BTN_RE = re.compile(r"^tag\s*\(\s*([0-9ilo|]{1,3})\s*\)?$")    # OCR reads 0 as O too; ")" may be missing
TRANSFER_BTN_RE = re.compile(r"^transfer\s*\(\s*[0-9ilo|]{1,3}\s*\)$")
BOX_COUNT_RE = re.compile(r"^(\d{1,4})\s*/\s*\d{2,4}$")
SEARCH_COUNT_RE = re.compile(r"^\D{0,2}\(([0-9oil|]{1,4})\)$")   # "🔍(12)"; the magnifier icon is read as Q
BOX_STATES = ("box", "box_tags", "box_other", "search_page")   # what classify() calls the storage
def box_header(tx):
    top = (0.0, 0.0, 1.0, 0.18)
    return bool((find_text(tx, ["eggs"], exact=True, region=top) or find_text(tx, ["tags"], exact=True, region=top))
                and find_text(tx, ["pokemon"], region=top))


def main_menu_on(tx):
    r = (0.0, 0.4, 1.0, 1.0)
    return sum(1 for w in cfg.L["menu"] if find_text(tx, [w], exact=True, region=r)) >= 3


def sort_menu_on(tx):
    r = (0.4, 0.3, 1.0, 0.9)
    return sum(1 for o in cfg.L["sort_options"] if find_text(tx, [o], exact=True, region=r)) >= 3


def search_page_on(tx):
    """The storage search page: search suggestions below the Search field (for the keyboard see classify)."""
    return bool(find_text(tx, [cfg.L["see_more"], "recommended", "recent search", "saved search"]))


def tag_list_on(tx):
    return bool(find_re(tx, re.compile(r"^tag \d+ pokemon"), region=(0.0, 0.0, 1.0, 0.2)))


def keyboard_on(tx):
    """The system keyboard is visible (the 123 key, or many single-letter keys at the bottom)."""
    if find_text(tx, ["123"], exact=True, region=(0.0, 0.75, 0.3, 0.98)):
        return True
    return sum(1 for t in tx if t["cy"] > 0.6 and len(t["text"].strip()) == 1 and t["text"].strip().isalpha()) >= 6


def search_bar_text(tx):
    parts = [t for t in tx if 0.15 <= t["cy"] <= 0.21 and 0.14 <= t["cx"] <= 0.9]
    return " ".join(t["text"] for t in sorted(parts, key=lambda t: t["x0"]))


def filter_key(s):
    k = alnum(s)
    return k[1:] if k.startswith("q") else k   # the magnifier icon is read as "Q"


def keys_match(a, b):
    if not a or not b:
        return False
    if a == b or (min(len(a), len(b)) >= 6 and (a.startswith(b) or b.startswith(a))):
        return True
    return difflib.SequenceMatcher(None, a, b).ratio() >= 0.85


def bar_matches(shown, want):
    """Does the Search field show the search the bot typed? The field truncates long text (on the left
    and on the right), so it is enough that a contiguous piece of the text matches the typed search."""
    if keys_match(shown, want):
        return True
    if not shown or not want or len(shown) < max(6, len(want) // 2):
        return False
    if shown in want:
        return True
    covered = sum(b.size for b in difflib.SequenceMatcher(None, shown, want, autojunk=False).get_matching_blocks())
    return covered >= 0.85 * len(shown)


def return_key(tx):
    """The Enter / Search key on the iPhone keyboard (bottom right)."""
    keys = {alnum(w) for w in cfg.L["return_keys"]}
    for t in tx:
        if t["cy"] > 0.8 and t["cx"] > 0.6 and alnum(t["text"]) in keys:
            return t
    return None


def tag_button(tx):
    for t in tx:
        if t["cy"] > 0.7 and TAG_BTN_RE.match(norm(t["text"])):
            return t
    return None


def multiselect_on(tx):
    """Multi-select: TAG (n) and TRANSFER (n) buttons at the bottom; older game versions have SELECT ALL at the top."""
    if find_text(tx, [cfg.L["select_all"]], region=(0.3, 0.0, 1.0, 0.2)):
        return True
    return tag_button(tx) is not None or find_re(tx, TRANSFER_BTN_RE, region=(0.0, 0.8, 1.0, 1.0)) is not None


def box_count(tx):
    """How many Pokémon the game shows in storage (the number below POKÉMON in the header, e.g. 433/725)."""
    lab = find_text(tx, ["pokemon"], region=(0.0, 0.0, 1.0, 0.16))
    if lab is None:
        return None
    for t in tx:
        m = BOX_COUNT_RE.match(re.sub(r"\s", "", t["text"]))
        if m and abs(t["cx"] - lab["cx"]) < 0.12 and 0 < t["cy"] - lab["cy"] < 0.06:
            return int(m.group(1))
    return None


def search_count(tx):
    """How many Pokémon the search found: during a search the header shows a magnifier and "(12)"
    below POKÉMON instead of 433/725."""
    lab = find_text(tx, ["pokemon"], region=(0.0, 0.0, 1.0, 0.16))
    if lab is None:
        return None
    for t in tx:
        m = SEARCH_COUNT_RE.match(re.sub(r"\s", "", norm(t["text"])))
        if m and abs(t["cx"] - lab["cx"]) < 0.12 and 0 < t["cy"] - lab["cy"] < 0.06:
            return int(m.group(1).translate(str.maketrans("oil|", "0111")))
    return None


def tag_count(tx):
    t = tag_button(tx)
    if t is None:
        return None
    s = TAG_BTN_RE.match(norm(t["text"])).group(1).translate(str.maketrans("il|o", "1110"))
    return int(s) if s.isdigit() else None


def safe_button(tx):
    words = {alnum(w) for w in cfg.L["safe_close"]}
    for t in tx:
        if alnum(t["text"]) in words and upper_text(t["text"]):
            return t
    return None
