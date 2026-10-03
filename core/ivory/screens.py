"""Recognizing game screens and reading values from them."""
import difflib
import re

import cv2
import numpy as np

from . import config as cfg
from .vision import alnum, cp_value, crop_norm, find_re, find_text, in_region, norm, upper_text
from .grid import complete_cells


TYPES = {"normal", "fire", "water", "grass", "electric", "ice", "fighting", "poison", "ground",
         "flying", "psychic", "bug", "rock", "ghost", "dragon", "dark", "steel", "fairy"}
TAG_BTN_RE = re.compile(r"^tag\s*\(\s*([0-9ilo|]{1,3})\s*\)?$")    # OCR reads 0 as O too; ")" may be missing
TRANSFER_BTN_RE = re.compile(r"^transfer\s*\(\s*[0-9ilo|]{1,3}\s*\)$")
BOX_COUNT_RE = re.compile(r"^(\d{1,4})\s*/\s*\d{2,4}$")
SEARCH_COUNT_RE = re.compile(r"^\D{0,2}\(([0-9oil|]{1,4})\)$")   # "🔍(12)"; the magnifier icon is read as Q
BOX_STATES = ("box", "box_tags", "box_other", "search_page")


def transfer_dialog(tx):
    return bool(find_text(tx, ["do you want to transfer", "to the professor", "cannot undo"]))


def confirm_dialog(tx):
    """Some other confirmation dialog (evolve, power up...); always answered with NO/CANCEL."""
    return bool(find_text(tx, ["do you want to", "are you sure"]) and find_text(tx, ["no", "cancel"], exact=True))


def box_header(tx):
    top = (0.0, 0.0, 1.0, 0.18)
    return bool((find_text(tx, ["eggs"], exact=True, region=top) or find_text(tx, ["tags"], exact=True, region=top))
                and find_text(tx, ["pokemon"], region=top))


def main_menu_on(tx):
    r = (0.0, 0.4, 1.0, 1.0)
    return sum(1 for w in cfg.L["menu"] if find_text(tx, [w], exact=True, region=r)) >= 3


def detail_menu_on(tx):
    r = (0.4, 0.25, 1.0, 0.92)
    return bool(find_text(tx, [cfg.L["appraise"]], exact=True, region=r)
                and (find_text(tx, ["favorite"], exact=True, region=r) or find_text(tx, ["transfer"], exact=True, region=r)))


HP_RE = re.compile(r"^\d+\s*/\s*\d+\s*hp$")


def detail_on(tx):
    return bool(find_text(tx, ["stardust"], exact=True) or find_text(tx, ["power up"], exact=True)
                or find_re(tx, HP_RE))


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


def sort_menu_on(tx):
    r = (0.4, 0.3, 1.0, 0.9)
    return sum(1 for o in cfg.L["sort_options"] if find_text(tx, [o], exact=True, region=r)) >= 3


def sort_active(img, t):
    """The active sort option has an arrow to the right of its icon (light pixels); other rows have nothing there."""
    reg = crop_norm(img, 0.915, t["cy"] - 0.015, 0.975, t["cy"] + 0.015)
    return reg.size > 0 and (reg.min(axis=2) > 170).mean() > 0.02


def search_page_on(tx):
    """The storage search page: search suggestions below the Search field (for the keyboard see classify)."""
    return bool(find_text(tx, [cfg.L["see_more"], "recommended", "recent search", "saved search"]))


def is_map(img):
    """Map = a red and white Poké Ball at the bottom center."""
    top = crop_norm(img, 0.45, 0.905, 0.55, 0.93).astype(int)
    bot = crop_norm(img, 0.45, 0.94, 0.55, 0.965).astype(int)
    if top.size == 0 or bot.size == 0:
        return False
    red = ((top[..., 0] > 180) & (top[..., 1] < 90) & (top[..., 2] < 90)).mean()
    white = ((bot[..., 0] > 225) & (bot[..., 1] > 225) & (bot[..., 2] > 225)).mean()
    return red > 0.25 and white > 0.3


def tag_list_on(tx):
    return bool(find_re(tx, re.compile(r"^tag \d+ pokemon"), region=(0.0, 0.0, 1.0, 0.2)))


def keyboard_on(tx):
    """The system keyboard is visible (the 123 key, or many single-letter keys at the bottom)."""
    if find_text(tx, ["123"], exact=True, region=(0.0, 0.75, 0.3, 0.98)):
        return True
    return sum(1 for t in tx if t["cy"] > 0.6 and len(t["text"].strip()) == 1 and t["text"].strip().isalpha()) >= 6


def tag_dialog_on(fr):
    """The new-tag dialog: the "Enter tag name" field, or a row of color swatches."""
    return bool(find_text(fr.texts, [cfg.L["enter_tag_name"]]) or find_swatches(fr.img))


def classify(fr):
    tx = fr.texts
    if transfer_dialog(tx):
        return "transfer_dialog"
    if confirm_dialog(tx):
        return "confirm_dialog"
    if find_text(tx, [cfg.L["enter_tag_name"]]):
        return "tag_dialog"
    if tag_list_on(tx):
        return "tag_dialog" if find_swatches(fr.img) else "tag_list"
    if multiselect_on(tx) or multiselect_look(fr.img):
        return "multiselect"
    if appraisal_on(tx):
        return "appraisal"
    if detail_menu_on(tx):
        return "detail_menu"
    if detail_on(tx):
        return "detail"
    if sort_menu_on(tx):
        return "sort_menu"
    if box_header(tx):
        if keyboard_on(tx):
            return "search_page"   # the keyboard is open for the Search field
        if complete_cells(tx):
            return "box"
        if find_text(tx, ["have this tag"]):
            return "box_tags"
        if search_page_on(tx):
            return "search_page"
        return "box_other"
    if main_menu_on(tx):
        return "main_menu"
    if is_map(fr.img):
        return "map"
    return "unknown"


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


def teal_top(img):
    """Dark teal bar at the top (multi-select)."""
    top = crop_norm(img, 0.25, 0.06, 0.95, 0.12).astype(int)
    return top.size > 0 and float(((top.sum(axis=2) < 420) & (top[..., 2] >= top[..., 0]) &
                                   (top[..., 1] >= top[..., 0])).mean()) > 0.9


def multiselect_look(img):
    """Multi-select by colors, for when OCR can't read the button texts: the teal bar at the top
    and the green TAG button at the bottom (100% and 98% on real screenshots, at most 47% and 31% elsewhere)."""
    btn = crop_norm(img, 0.2, 0.845, 0.8, 0.875).astype(int)
    return btn.size > 0 and teal_top(img) and \
        float(((btn[..., 1] > btn[..., 0] + 40) & (btn[..., 1] > btn[..., 2] + 5)).mean()) > 0.8


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


def find_swatches(img, region=(0.02, 0.10, 0.98, 0.92)):
    """Color swatches in the new-tag dialog: at least 5 equally sized filled circles side by side
    (in one or more rows). Returns [{cx, cy, r, rgb}] row by row from the left (cx, cy, r as a fraction
    of the screen width/height), or []."""
    H, W = img.shape[:2]
    X0, Y0 = int(region[0] * W), int(region[1] * H)
    crop = img[Y0:int(region[3] * H), X0:int(region[2] * W)]
    if crop.size == 0:
        return []
    hsv = cv2.cvtColor(crop, cv2.COLOR_RGB2HSV)
    sat, val = hsv[..., 1].astype(np.int16), hsv[..., 2].astype(np.int16)
    # "anything that is not the light background": colored, dark, or mid gray (the gray swatch)
    mask = (((sat > 60) & (val > 50)) | (val < 120) | ((sat < 45) & (val >= 90) & (val <= 205))).astype(np.uint8)
    k = max(3, W // 200) | 1
    mask = cv2.morphologyEx(mask, cv2.MORPH_OPEN, np.ones((k, k), np.uint8))
    contours, _ = cv2.findContours(mask, cv2.RETR_LIST, cv2.CHAIN_APPROX_NONE)
    dmin, dmax = 0.035 * W, 0.17 * W
    cands = []
    for c in contours:
        area = cv2.contourArea(c)
        if area < np.pi * (dmin / 2) ** 2 * 0.6:
            continue
        (x, y), r = cv2.minEnclosingCircle(c)
        per = cv2.arcLength(c, True)
        if not dmin <= 2 * r <= dmax or per <= 0:
            continue
        if 4 * np.pi * area / per ** 2 < 0.78 or area / (np.pi * r * r) < 0.75:
            continue
        y0p, x0p = max(0, int(y - r)), max(0, int(x - r))
        pm = mask[y0p:int(y + r) + 1, x0p:int(x + r) + 1]
        pc = crop[y0p:int(y + r) + 1, x0p:int(x + r) + 1]
        yy, xx = np.ogrid[y0p:y0p + pm.shape[0], x0p:x0p + pm.shape[1]]
        d2 = (yy - y) ** 2 + (xx - x) ** 2
        if pm[d2 <= (0.6 * r) ** 2].mean() < 0.45:
            continue                       # hollow circle (the letter O, a ring): not a color swatch
        px = pc[d2 <= (0.75 * r) ** 2]
        px = px[px.min(axis=1) < 215]      # skip the white check mark / selection mark
        if len(px) < 10:
            continue
        cands.append({"x": x + X0, "y": y + Y0, "r": r, "rgb": tuple(int(v) for v in np.median(px, axis=0))})
    if len(cands) < 5:
        return []
    best = []
    for c in cands:                        # largest group of equally sized swatches
        grp = [d for d in cands if abs(d["r"] - c["r"]) <= 0.18 * c["r"]]
        if len(grp) > len(best):
            best = grp
    out = []
    for c in sorted(best, key=lambda c: c["r"]):   # concentric outlines of one swatch count once
        if all(np.hypot(c["x"] - o["x"], c["y"] - o["y"]) > o["r"] for o in out):
            out.append(c)
    if len(out) < 5:
        return []
    rmed = float(np.median([c["r"] for c in out]))
    rows = []
    for c in sorted(out, key=lambda c: c["y"]):
        if rows and abs(c["y"] - rows[-1][0]["y"]) < rmed:
            rows[-1].append(c)
        else:
            rows.append([c])
    flat = [c for row in rows if len(row) >= 2 for c in sorted(row, key=lambda c: c["x"])]
    if len(flat) < 5:
        return []
    return [{"cx": c["x"] / W, "cy": c["y"] / H, "r": c["r"] / W, "rgb": c["rgb"]} for c in flat]


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
