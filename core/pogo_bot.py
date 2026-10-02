#!/usr/bin/env python3
"""
PoGo Inventory Manager – jádro (bot), které ovládá iPhone přes Appium / WebDriverAgent.

1. část – duplicity:
  1) odkudkoliv ve hře dojde do boxu (Poké Ball -> POKÉMON), použije uložené
     hledání SAVED_SEARCH a seřadí podle čísla
  2) jede box shora dolů a skupiny stejných Pokémonů pozná PODLE OBRÁZKU
  3) u každého změří IV z appraisalu (útok/obrana/HP)
  4) nejlepšího nechá, ostatním dá tag TAG_NAME (multiselect -> TAG); když tag
     neexistuje, založí ho (Add New Tag)

2. část – celý box (bez filtru):
  každého Pokémona zařadí podle IV do jednoho z tagů IV_TAGS (detail -> ≡ -> TAG).
  Kdo už má tag TAG_NAME nebo právě jeden IV tag, toho přeskočí.

Když se cokoliv pokazí (jiná obrazovka, popup, spadlé spojení, zaseknutá hra),
zjistí, kde je, vrátí se do boxu a pokračuje tam, kde skončil. Na tlačítka
TRANSFER / EVOLVE / POWER UP nikdy neklepne (hlídá to každé klepnutí).

Nastavení se čte z ~/.pogo/config.json (upravuje ho aplikace); co tam chybí,
bere se z výchozích hodnot níže.

  python pogo_bot.py                  # obě části
  python pogo_bot.py --no-iv          # jen duplicity
  python pogo_bot.py --only-iv        # jen celý box do IV tagů
  python pogo_bot.py --fresh          # IV z paměti nepoužívat, změřit znovu

Normálně se spouští přes scripts/run.sh (připraví Appium i Python) nebo z aplikace.
"""
import argparse
import difflib
import io
import json
import os
import re
import socket
import sys
import threading
import time
import unicodedata
from collections import deque
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import cv2
import numpy as np
from PIL import Image

# ======================= KONFIGURACE ================================
APPIUM_URL = "http://127.0.0.1:4723"
UDID = ""                      # prázdné = první připojený iPhone
TEAM_ID = ""                   # prázdné = zjistí se z certifikátu „Apple Development“ v Klíčence
SIGNING_ID = "Apple Development"
BUNDLE_ID = "com.nianticlabs.pokemongo"
OUT_DIR = Path.home() / "Desktop" / "pogo_runs"
STATE_DIR = Path.home() / ".pogo"
CAL_FILE = STATE_DIR / "calibration.json"   # zapamatovaný text filtru
MEMORY_FILE = STATE_DIR / "pamet.json"      # změřené IV a komu už dal tag
CONFIG_FILE = STATE_DIR / "config.json"     # nastavení z aplikace (přepíše hodnoty níže)
MAX_GROUPS = 0                 # 0 = všechny várky duplicit

SAVED_SEARCH = "duplicit"      # uložené hledání v Search; číslo pod ním se ignoruje
TAG_NAME = "Removable"     # když ve hře neexistuje, skript ho založí
KEEP_N = 1                     # kolik nejlepších z každé várky nechat

# 2. část: po duplicitách projde CELÝ box (bez filtru) a každého zařadí podle IV do tagu.
SORT_ALL = True
IV_TAGS = [                    # (od kolika %, název tagu) – bere se první, který sedí
    (100, "100% Perfect"),
    (95, "95-99% Insane"),
    (90, "90-95% Amazing"),
    (85, "85-90% Great"),
    (80, "80-85% Good"),
    (70, "70-80% Mid"),
    (0, "70-0% Garbage"),
]
RECHECK_TAGGED = False         # False = kdo už má právě jeden z IV tagů, toho přeskočí (rychlejší)
IV_CACHE_HOURS = 6             # IV změřené za posledních X hodin se znovu neměří
TAGGED_DAYS = 30               # jak dlouho si pamatuje, komu už dal tag

# Texty v UI hry (pokud máš hru v jiném jazyce, přepiš)
L = {
    "attack": "Attack", "defense": "Defense", "hp": "HP",
    "appraise": "APPRAISE", "number": "NUMBER", "done": "DONE",
    "select_all": "SELECT ALL", "see_more": "See More",
    "add_new_tag": "Add New Tag", "enter_tag_name": "Enter tag name",
    "menu": ["POKEDEX", "POKEMON", "SHOP", "ITEMS", "BATTLE"],
    "sort_options": ["RECENT", "FAVORITE", "NUMBER", "HP", "NAME", "COMBAT POWER"],
    # bezpečná tlačítka pro zavření neznámých oken
    "safe_close": ["OK", "CLOSE", "DISMISS", "NOT NOW", "LATER", "NO THANKS", "CANCEL", "NO",
                   "I'M A PASSENGER", "RETRY", "TRY AGAIN"],
}
# Na tlačítka s tímhle textem (velkými písmeny) se nikdy neklepne, ani do jejich řádku.
DANGER_RE = re.compile(r"^(TRANSFER|YES|CONFIRM|TRADE|BUY|PURCHASE|RELEASE)\b")
# Řádky v detailu Pokémona: blokují celý řádek, jen plovoucí tlačítka X a ≡ (leží nad nimi) smí klepnout vedle textu.
DANGER_ROW_RE = re.compile(r"^(EVOLVE|POWER UP|PURIFY|MEGA EVOLVE)\b")
DANGER_BAND = 0.04             # ± výška pásu kolem nebezpečného tlačítka
APPRAISAL_WORDS = ["analyze", "analyse", "caught on", "categorized", "overall", "statistic", "available to"]

# Pevné body (podíl šířky/výšky obrazovky), změřené ze screenshotů
P_POKEBALL = [(0.50, 0.935), (0.50, 0.915), (0.50, 0.955)]   # Poké Ball na mapě
P_BOTTOM_X = (0.50, 0.94)      # X dole uprostřed (detail, box, seznam tagů)
P_CORNER = (0.87, 0.94)        # vpravo dole: ≡ v detailu, řazení v boxu, X otevřeného menu
P_MULTI_CLOSE = (0.107, 0.117) # X vlevo nahoře v multiselectu
P_SEARCH_BAR = (0.50, 0.178)   # pole Search v boxu
P_SEARCH_BACK = (0.105, 0.178) # šipka "<" u aktivního hledání (zruší ho)
P_SEARCH_CLEAR = (0.915, 0.176)
P_BOX_TAB = (0.50, 0.085)      # záložka POKÉMON nahoře v boxu
P_NEUTRAL = (0.50, 0.30)       # appraisal se posouvá/zavírá klepnutím kamkoliv
MENU_ICON_DY = 0.06            # ikona POKÉMON v menu je POD popiskem

# Mřížka boxu: kotvou buňky je text "CP1234", obrázek je pod ním, jméno ještě níž.
GRID_TOP, GRID_BOTTOM = 0.215, 0.785   # buňka je celá vidět, když je její CP v tomhle pásu
TOP_ROW_Y = 0.27                       # kam se při posunu dostane řádek
SPRITE_HALF_W = 0.11
SPRITE_TOP, SPRITE_BOTTOM = 0.025, 0.09   # bez CP i jména (přezdívky kazily podobnost)
NAME_DY = (0.07, 0.14)
SAME_SPECIES_THR = 0.85
CELL_TAP_DY = 0.05             # klepnutí do obrázku
SELECT_TAP_DY = 0.03           # v multiselectu těsně pod CP (dál od tlačítek dole)
SCROLL_FROM_Y = 0.80

# IV bary (oranžová = výplň, šedá = zbytek, růžovo-červená = 15)
BAR_MAX_W = 0.42               # jak daleko doprava od popisku bar hledat
BAR_LEFT_PAD = 0.03            # bar začíná kousek vlevo od popisku
BAR_GAP = 0.012                # max. mezera mezi dílky baru (podíl šířky)
BAR_MIN_W = 0.15               # kratší úsek není bar
FILL_MIN_R, FILL_MIN_RB = 170, 70
TRACK_MIN, TRACK_MAX = 180, 238
BAR_SETTLE = 0.7               # bary se plní animací: číst nejdřív X s po objevení
BAR_STABLE = 0.3               # ... a až když se hodnoty X s nemění

# Rychlost a odolnost
MJPEG_PORT = 9100              # Appium ho z telefonu přesměruje na localhost
MJPEG_QUALITY = 60
MJPEG_FPS = 15
MJPEG_SCALE = 75               # % rozlišení streamu (OCR to čte bez problému)
USE_STREAM = os.environ.get("POGO_NO_STREAM") != "1"
FRAME_LAG = 0.12               # snímky starší než klepnutí + X s se za výsledek neberou
LONG_PRESS_SEC = 0.9
NAV_TIMEOUT = 90               # s na cestu do boxu, pak restart hry
MAX_FAILS = 12                 # chyb po sobě bez pokroku, pak konec
TAG_SCROLL_MAX = 12
RING = 30                      # kolik posledních snímků uložit, když se něco pokazí
# ====================================================================

SAVER = ThreadPoolExecutor(max_workers=2)   # zápis obrázků neblokuje klikání
LOG_FILE = None
HOMOGLYPHS = str.maketrans("сСрРоОеЕаАхХ", "cCpPoOeEaAxX")   # OCR občas vrátí azbuku
TYPES = {"normal", "fire", "water", "grass", "electric", "ice", "fighting", "poison", "ground",
         "flying", "psychic", "bug", "rock", "ghost", "dragon", "dark", "steel", "fairy"}
CP_RE = re.compile(r"^cp(\d{2,5})$")
TAG_BTN_RE = re.compile(r"^tag\s*\(\s*([0-9il|]{1,3})\s*\)$")
PLAIN_NAME = re.compile(r"^[a-z][a-z'.\-]{2,}$")
BOX_STATES = ("box", "box_tags", "box_other", "search_page")
STATE_CZ = {
    "transfer_dialog": "dialog TRANSFER (zruším ho)", "confirm_dialog": "potvrzovací dialog (dám NO)",
    "tag_list": "seznam tagů",
    "multiselect": "multiselect", "appraisal": "appraisal", "detail_menu": "menu v detailu",
    "detail": "detail Pokémona", "sort_menu": "menu řazení", "box": "box",
    "box_tags": "box – záložka TAGS", "search_page": "hledání v boxu",
    "box_other": "box (bez mřížky)", "main_menu": "hlavní menu", "map": "mapa",
    "unknown": "neznámá obrazovka",
}


class StepError(Exception):
    """Krok se nepovedl – bot se vrátí do boxu a pokračuje."""


class Danger(StepError):
    """Klepnutí by mohlo trefit nebezpečné tlačítko – neprovedeno."""


class LostPosition(StepError):
    """Při posouvání se ztratilo místo v boxu – projede se znovu shora."""


class Fatal(Exception):
    """Nedá se pokračovat (chybí tag, uložené hledání, spojení...)."""


def log(msg=""):
    print(msg, flush=True)
    if LOG_FILE:
        try:
            with open(LOG_FILE, "a") as f:
                f.write(f"{time.strftime('%H:%M:%S')} {msg}\n")
        except OSError:
            pass


def short_err(e):
    lines = str(e).strip().splitlines()
    return (lines[0] if lines else repr(e))[:300]


def norm(s):
    s = unicodedata.normalize("NFKD", (s or "").translate(HOMOGLYPHS))
    return "".join(c for c in s if not unicodedata.combining(c)).lower().strip()


def alnum(s):
    return re.sub(r"[^a-z0-9]", "", norm(s))


# ---------------------------- kalibrace -----------------------------
def cal_load():
    try:
        return json.loads(CAL_FILE.read_text())
    except Exception:
        return {}


def cal_set(key, val):
    d = cal_load()
    d[key] = val
    CAL_FILE.parent.mkdir(parents=True, exist_ok=True)
    CAL_FILE.write_text(json.dumps(d, indent=1))


# ---------------------------- OCR (Apple Vision) --------------------
def ocr(data, fast=False):
    import Vision
    from Foundation import NSData

    ns = NSData.dataWithBytes_length_(data, len(data))
    handler = Vision.VNImageRequestHandler.alloc().initWithData_options_(ns, None)
    req = Vision.VNRecognizeTextRequest.alloc().init()
    req.setRecognitionLevel_(Vision.VNRequestTextRecognitionLevelFast if fast
                             else Vision.VNRequestTextRecognitionLevelAccurate)
    req.setUsesLanguageCorrection_(False)
    ok, err = handler.performRequests_error_([req], None)
    if not ok:
        raise RuntimeError(f"OCR selhalo: {err}")
    out = []
    for obs in req.results() or []:
        cands = obs.topCandidates_(1)
        if not cands:
            continue
        bb = obs.boundingBox()  # normalizované, počátek vlevo DOLE
        x, y = bb.origin.x, bb.origin.y
        w, h = bb.size.width, bb.size.height
        out.append({
            "text": str(cands[0].string()),
            "cx": x + w / 2, "cy": 1 - (y + h / 2),
            "x0": x, "x1": x + w, "y0": 1 - (y + h), "y1": 1 - y,
        })
    return out


class Frame:
    """Jeden snímek obrazovky; OCR se počítá až když je potřeba (a jen jednou)."""

    def __init__(self, img, raw, t):
        self.img, self.raw, self.t = img, raw, t
        self._tx = self._fast = None

    @property
    def texts(self):
        if self._tx is None:
            self._tx = ocr(self.raw)
        return self._tx

    @property
    def fast(self):
        if self._tx is not None:
            return self._tx
        if self._fast is None:
            self._fast = ocr(self.raw, fast=True)
        return self._fast


def in_region(t, region):
    return region is None or (region[0] <= t["cx"] <= region[2] and region[1] <= t["cy"] <= region[3])


def find_all(texts, patterns, exact=False, region=None):
    pats = [norm(p) for p in patterns]
    out = []
    for t in texts:
        if not in_region(t, region):
            continue
        n = norm(t["text"])
        if any((n == p) if exact else (p in n) for p in pats):
            out.append(t)
    return out


def find_text(texts, patterns, exact=False, region=None):
    r = find_all(texts, patterns, exact, region)
    return r[0] if r else None


def find_re(texts, rx, region=None):
    for t in texts:
        if in_region(t, region) and rx.search(norm(t["text"])):
            return t
    return None


def upper_text(s):
    letters = [c for c in s if c.isalpha()]
    return bool(letters) and sum(c.isupper() for c in letters) >= 0.8 * len(letters)


# ---------------------------- mřížka boxu ---------------------------
def cp_value(text):
    m = CP_RE.match(re.sub(r"\s", "", norm(text)))
    return int(m.group(1)) if m else None


def grid_cells(texts):
    """Buňky boxu podle textů 'CP1234' (i rozdělených na 'CP' + '1234'), po řádcích."""
    cells = []
    for t in texts:
        v = cp_value(t["text"])
        if v is not None:
            cells.append({"cx": t["cx"], "cy": t["cy"], "cp": v})
    nums = [t for t in texts if re.fullmatch(r"\d{2,5}", t["text"].strip())]
    for c in (t for t in texts if alnum(t["text"]) == "cp"):
        for n in nums:
            if abs(n["cy"] - c["cy"]) < 0.012 and -0.01 < n["x0"] - c["x1"] < 0.05:
                cells.append({"cx": (c["x0"] + n["x1"]) / 2, "cy": n["cy"], "cp": int(n["text"].strip())})
                break
    cells.sort(key=lambda c: c["cy"])
    rows, cur = [], []
    for c in cells:
        if cur and c["cy"] - cur[0]["cy"] > 0.03:
            rows.append(cur)
            cur = []
        cur.append(c)
    if cur:
        rows.append(cur)
    out = []
    for i, row in enumerate(rows):
        for c in sorted(row, key=lambda c: c["cx"]):
            c["row"] = i
            out.append(c)
    return out


def complete_cells(texts):
    return [c for c in grid_cells(texts) if GRID_TOP <= c["cy"] <= GRID_BOTTOM]


def crop_norm(img, x0, y0, x1, y1):
    H, W = img.shape[:2]
    return img[max(0, int(y0 * H)):min(H, int(y1 * H)),
               max(0, int(x0 * W)):min(W, int(x1 * W))]


def sprite_of(img, cell):
    return crop_norm(img, cell["cx"] - SPRITE_HALF_W, cell["cy"] + SPRITE_TOP,
                     cell["cx"] + SPRITE_HALF_W, cell["cy"] + SPRITE_BOTTOM)


def _sim1(a, b):
    return float(cv2.matchTemplate(b, a[6:58, 6:58], cv2.TM_CCOEFF_NORMED).max())


def sprite_sim(a, b):
    """Podobnost obrázků 0-1, snese posun o pár pixelů."""
    if a is None or b is None or a.size == 0 or b.size == 0:
        return 0.0
    a = cv2.resize(a, (64, 64), interpolation=cv2.INTER_AREA).astype(np.float32)
    b = cv2.resize(b, (64, 64), interpolation=cv2.INTER_AREA).astype(np.float32)
    if a.std() < 2 or b.std() < 2:
        return 0.0
    return max(_sim1(a, b), _sim1(b, a))


def name_of(texts, cell):
    best, bd = None, 9.0
    for t in texts:
        dy = t["cy"] - cell["cy"]
        if NAME_DY[0] < dy < NAME_DY[1] and abs(t["cx"] - cell["cx"]) < 0.13 and cp_value(t["text"]) is None:
            d = abs(t["cx"] - cell["cx"])
            if d < bd:
                best, bd = t["text"], d
    return re.sub(r"^[^A-Za-zÀ-ž0-9]+", "", best).strip() if best else ""


def with_details(cells, fr):
    for c in cells:
        c["name"] = name_of(fr.texts, c)
        c["sprite"] = sprite_of(fr.img, c)
        c["sig"] = f"{c['cp']}|{alnum(c['name'])}"
    return cells


def names_ok(a, b):
    """Jména se nevylučují (jedno chybí, nebo se liší jen značkou tagu na začátku)."""
    a, b = alnum(a), alnum(b)
    if not a or not b or a == b:
        return True
    return abs(len(a) - len(b)) <= 2 and (a.endswith(b) or b.endswith(a))


def same_species(a, b):
    na, nb = norm(a["name"]), norm(b["name"])
    if PLAIN_NAME.match(na) and PLAIN_NAME.match(nb) and \
            difflib.SequenceMatcher(None, na, nb).ratio() < 0.75:
        return False   # dvě různá jména druhů (ne přezdívky)
    return sprite_sim(a["sprite"], b["sprite"]) >= SAME_SPECIES_THR


def make_runs(cells):
    runs = []
    for c in cells:
        if runs and same_species(runs[-1][-1], c):
            runs[-1].append(c)
        else:
            runs.append([c])
    return runs


# ---------------------------- poznávání obrazovek -------------------
def transfer_dialog(tx):
    return bool(find_text(tx, ["do you want to transfer", "to the professor", "cannot undo"]))


def confirm_dialog(tx):
    """Jiný potvrzovací dialog (evolve, power up...) – vždy se odpoví NO/CANCEL."""
    return bool(find_text(tx, ["do you want to", "are you sure"]) and find_text(tx, ["no", "cancel"], exact=True))


def box_header(tx):
    top = (0.0, 0.0, 1.0, 0.18)
    return bool((find_text(tx, ["eggs"], exact=True, region=top) or find_text(tx, ["tags"], exact=True, region=top))
                and find_text(tx, ["pokemon"], region=top))


def main_menu_on(tx):
    r = (0.0, 0.4, 1.0, 1.0)
    return sum(1 for w in L["menu"] if find_text(tx, [w], exact=True, region=r)) >= 3


def detail_menu_on(tx):
    r = (0.4, 0.25, 1.0, 0.92)
    return bool(find_text(tx, [L["appraise"]], exact=True, region=r)
                and (find_text(tx, ["favorite"], exact=True, region=r) or find_text(tx, ["transfer"], exact=True, region=r)))


HP_RE = re.compile(r"^\d+\s*/\s*\d+\s*hp$")


def detail_on(tx):
    return bool(find_text(tx, ["stardust"], exact=True) or find_text(tx, ["power up"], exact=True)
                or find_re(tx, HP_RE))


def dialog_text(tx):
    """Text v bublině dole (appraisal) – dlouhé věty."""
    parts = [t for t in tx if t["cy"] > 0.84 and len(t["text"]) >= 22 and t["text"].count(" ") >= 3]
    return " ".join(norm(t["text"]) for t in sorted(parts, key=lambda t: t["cy"]))


def bar_labels(tx):
    """Popisky Attack/Defense/HP nad bary. Když OCR jeden mine, dopočítá ho z rozestupu."""
    keys = {"attack": (alnum(L["attack"]),), "defense": (alnum(L["defense"]), "defence"), "hp": (alnum(L["hp"]),)}
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
    """Appraisal = bary, nebo bublina s řečí profesora/leadera (ne jakýkoliv dlouhý text v detailu)."""
    if bar_labels(tx):
        return True
    d = dialog_text(tx)
    return bool(d) and detail_on(tx) and any(w in d for w in APPRAISAL_WORDS) and not bottom_x_visible(tx)


def sort_menu_on(tx):
    r = (0.4, 0.3, 1.0, 0.9)
    return sum(1 for o in L["sort_options"] if find_text(tx, [o], exact=True, region=r)) >= 3


def sort_active(img, t):
    """Aktivní řazení má vpravo od ikony šipku (světlé pixely); ostatní řádky tam nemají nic."""
    reg = crop_norm(img, 0.915, t["cy"] - 0.015, 0.975, t["cy"] + 0.015)
    return reg.size > 0 and (reg.min(axis=2) > 170).mean() > 0.02


def search_page_on(tx):
    return bool(find_text(tx, [L["see_more"], "recommended"])
                or find_text(tx, [SAVED_SEARCH], region=(0.0, 0.2, 1.0, 0.65)))


def is_map(img):
    """Mapa = dole uprostřed je červenobílý Poké Ball."""
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
    """Je vidět systémová klávesnice (klávesa 123, nebo hodně jednopísmenných kláves dole)."""
    if find_text(tx, ["123"], exact=True, region=(0.0, 0.75, 0.3, 0.98)):
        return True
    return sum(1 for t in tx if t["cy"] > 0.6 and len(t["text"].strip()) == 1 and t["text"].strip().isalpha()) >= 6


def classify(fr):
    tx = fr.texts
    if transfer_dialog(tx):
        return "transfer_dialog"
    if confirm_dialog(tx):
        return "confirm_dialog"
    if tag_list_on(tx):
        return "tag_list"
    if find_text(tx, [L["select_all"]], region=(0.3, 0.0, 1.0, 0.2)):
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
    return k[1:] if k.startswith("q") else k   # ikona lupy se čte jako "Q"


def keys_match(a, b):
    if not a or not b:
        return False
    if a == b or (min(len(a), len(b)) >= 6 and (a.startswith(b) or b.startswith(a))):
        return True
    return difflib.SequenceMatcher(None, a, b).ratio() >= 0.85


def tag_button(tx):
    for t in tx:
        if t["cy"] > 0.7 and TAG_BTN_RE.match(norm(t["text"])):
            return t
    return None


def tag_count(tx):
    t = tag_button(tx)
    if t is None:
        return None
    s = TAG_BTN_RE.match(norm(t["text"])).group(1).translate(str.maketrans("il|", "111"))
    return int(s) if s.isdigit() else None


def safe_button(tx):
    words = {alnum(w) for w in L["safe_close"]}
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
        if 0.53 <= t["cy"] <= 0.66 and 0.25 <= t["cx"] <= 0.75:   # níž, když má štítky tagů
            found |= {w for w in re.split(r"[^a-z]+", norm(t["text"])) if w in TYPES}
    return sorted(found) or None


def img_diff(a, b, region=(0.0, 0.2, 1.0, 0.8)):
    ca, cb = crop_norm(a, *region), crop_norm(b, *region)
    if ca.size == 0 or ca.shape != cb.shape:
        return 99.0
    ga = cv2.resize(cv2.cvtColor(ca, cv2.COLOR_RGB2GRAY), (64, 140), interpolation=cv2.INTER_AREA)
    gb = cv2.resize(cv2.cvtColor(cb, cv2.COLOR_RGB2GRAY), (64, 140), interpolation=cv2.INTER_AREA)
    return float(np.abs(ga.astype(int) - gb.astype(int)).mean())


def changed_frac(a, b):
    if a.size == 0 or a.shape != b.shape:
        return 1.0
    return float((np.abs(a.astype(int) - b.astype(int)).max(axis=2) > 40).mean())


# ---------------------------- IV bary --------------------------------
def _bar_run(bar_row, gap):
    """Souvislý úsek baru od jeho levého konce (mezery mezi dílky do `gap` px)."""
    xs = np.flatnonzero(bar_row)
    if xs.size == 0:
        return None
    breaks = np.flatnonzero(np.diff(xs) > gap)
    end = xs[breaks[0]] if breaks.size else xs[-1]
    return int(xs[0]), int(end)


def _measure_bar(img, label, y_end):
    """Najde bar pod popiskem (jen do y_end, ať nesáhne na další bar).
    Vrací (left, right, fill_end, row, pink) v pixelech, nebo None."""
    H, W = img.shape[:2]
    x0 = max(0, int((label["x0"] - BAR_LEFT_PAD) * W))
    x1 = min(W, int((label["x0"] + BAR_MAX_W) * W))
    y0 = max(0, int((label["y1"] - 0.002) * H))
    y1 = min(H, int(y_end * H))
    region = img[y0:y1, x0:x1].astype(int)
    if region.size == 0:
        return None
    r, g, b = region[..., 0], region[..., 1], region[..., 2]
    fill = (r > FILL_MIN_R) & ((r - b) > FILL_MIN_RB)
    track = (np.abs(r - g) < 15) & (np.abs(g - b) < 15) & (r >= TRACK_MIN) & (r <= TRACK_MAX)
    bar = fill | track
    gap = max(3, int(BAR_GAP * W))
    best = None
    for row in range(region.shape[0]):
        run = _bar_run(bar[row], gap)
        if run is None or run[0] > 0.25 * region.shape[1]:
            continue
        if best is None or run[1] - run[0] > best[1] - best[0]:
            best = (run[0], run[1], row)
    if best is None or best[1] - best[0] < BAR_MIN_W * W:
        return None
    left, right, row = best
    # konec výplně: medián přes pár řádků kolem nejlepšího (proti šumu JPEGu)
    ends, colors = [], []
    for rr in range(max(0, row - 2), min(region.shape[0], row + 3)):
        fx = np.flatnonzero(fill[rr, left:right + 1])
        if fx.size:
            ends.append(left + int(fx[-1]))
            colors.append(region[rr, left + fx].mean(axis=0))
    fill_end = int(np.median(ends)) if ends else None
    pink = False
    if colors:
        cr, cg, cb = np.mean(colors, axis=0)
        pink = cb > 105 and cg < 150      # růžovo-červená = 15, oranžová = méně
    return x0 + left, x0 + right, None if fill_end is None else x0 + fill_end, y0 + row, pink


def read_bars(img, labels):
    """Změří tři IV bary (útok, obrana, HP). Vrací (ivs nebo None, debug)."""
    gaps = [labels[i + 1]["y0"] - labels[i]["y0"] for i in range(2)]
    pitch = sum(gaps) / 2
    ends = [labels[1]["y0"] - 0.002, labels[2]["y0"] - 0.002, labels[2]["y1"] + pitch * 0.6]
    bars = [_measure_bar(img, lab, ye) for lab, ye in zip(labels, ends)]
    if any(b is None for b in bars):
        return None, bars
    length = max(b[1] - b[0] for b in bars)      # všechny bary jsou stejně dlouhé
    ivs = []
    for left, right, fill_end, row, pink in bars:
        if pink:
            iv = 15
        elif fill_end is None:
            iv = 0
        else:
            iv = min(14, round(15 * (fill_end - left + 1) / (length + 1)))
        ivs.append(int(max(0, iv)))
    return tuple(ivs), bars


def decide(recs, keep_n=None):
    """Nejlepší podle součtu IV (pak útok, obrana, HP) nechá, ostatní k odstranění.
    Nezměřené nikdy neoznačí."""
    keep_n = KEEP_N if keep_n is None else keep_n
    ok = sorted((r for r in recs if r.iv), key=lambda r: (sum(r.iv), *r.iv), reverse=True)
    for i, r in enumerate(ok):
        r.action = "keep" if i < keep_n else "remove"
    for r in recs:
        if not r.iv:
            r.action = None


def decide_group(group):
    """Když se ve skupině sešly různé typy (jiný druh / forma), rozhodne každou zvlášť."""
    kinds = {tuple(r.types) for r in group if r.types}
    if len(kinds) <= 1:
        decide(group)
        return False
    for k in kinds:
        decide([r for r in group if r.types and tuple(r.types) == k])
    for r in group:
        if not r.types:
            r.action = "keep" if r.iv else None   # bez typu radši nechat
    return True


# ---------------------------- obraz z telefonu ----------------------
class Stream:
    """Čte MJPEG stream WebDriverAgentu a drží si poslední snímek."""

    def __init__(self, port):
        self.port = port
        self.lock = threading.Lock()
        self.jpeg, self.t, self.n = None, 0.0, 0
        self.stop_ev = threading.Event()
        if USE_STREAM:
            threading.Thread(target=self._run, daemon=True).start()

    def latest(self):
        with self.lock:
            return self.jpeg, self.t, self.n

    def fresh(self, age=0.6):
        return self.jpeg is not None and time.time() - self.t < age

    def _run(self):
        while not self.stop_ev.is_set():
            try:
                with socket.create_connection(("127.0.0.1", self.port), timeout=3) as s:
                    s.settimeout(5)
                    s.sendall(b"GET / HTTP/1.1\r\nHost: localhost\r\n\r\n")
                    buf = bytearray()
                    while not self.stop_ev.is_set():
                        chunk = s.recv(1 << 18)
                        if not chunk:
                            break
                        buf += chunk
                        self._frames(buf)
            except OSError:
                pass
            self.stop_ev.wait(1.0)

    def _frames(self, buf):
        while True:
            i = buf.find(b"\xff\xd8")
            if i < 0:
                if len(buf) > 1 << 16:
                    del buf[:-1024]
                return
            m = re.search(rb"Content-Length:\s*(\d+)", bytes(buf[max(0, i - 256):i]), re.I)
            if m:
                end = i + int(m.group(1))
                if len(buf) < end:
                    return
            else:
                j = buf.find(b"\xff\xd9", i + 2)
                if j < 0:
                    return
                end = j + 2
            frame = bytes(buf[i:end])
            del buf[:end]
            with self.lock:
                self.jpeg, self.t, self.n = frame, time.time(), self.n + 1


# ---------------------------- ovládání telefonu ---------------------
class Bot:
    def __init__(self, driver, run_dir):
        self.d = driver
        self.dir = run_dir
        self.stream = Stream(MJPEG_PORT)
        self.stream_misses = 0 if USE_STREAM else 99
        self.ring = deque(maxlen=RING)
        self._last = None
        self.need_sort = True
        self.fresh_list = False
        self.mode = "duplicit"            # "duplicit" = uložené hledání, "all" = celý box bez filtru
        self.filter_key = cal_load().get("filter_key")
        self.dumps = 0
        self.refresh()

    def refresh(self):
        size = self.d.get_window_size()
        self.W, self.H = size["width"], size["height"]

    def streaming(self):
        return self.stream_misses < 3 or self.stream.fresh()

    def wait_stream(self, sec=6):
        end = time.time() + sec
        while USE_STREAM and time.time() < end:
            if self.stream.fresh():
                log("Obraz: MJPEG stream (rychlý)")
                return True
            time.sleep(0.1)
        self.stream_misses = 99
        log("Obraz: stream nejede, beru screenshoty přes Appium (pomalejší)")
        return False

    # ---------- obraz ----------
    def frame(self, after=None, timeout=2.0):
        """Nejnovější snímek; s after= jen snímek přijatý až po tomto čase."""
        if self.streaming():
            end = time.time() + timeout
            while True:
                jpeg, t, n = self.stream.latest()
                now = time.time()
                if jpeg is not None and now - t < 0.6 and (after is None or t >= after):
                    self.stream_misses = 0
                    if self._last is not None and self._last[0] == n:
                        return self._last[1]
                    arr = cv2.imdecode(np.frombuffer(jpeg, np.uint8), cv2.IMREAD_COLOR)
                    if arr is not None:
                        fr = Frame(cv2.cvtColor(arr, cv2.COLOR_BGR2RGB), jpeg, t)
                        self._last = (n, fr)
                        return fr
                if now > end:
                    break
                time.sleep(0.01)
            self.stream_misses += 1
            if self.stream_misses == 3:
                log("   (stream neposílá snímky, přepínám na screenshoty)")
        png = self.d.get_screenshot_as_png()
        img = np.array(Image.open(io.BytesIO(png)).convert("RGB"))
        return Frame(img, png, time.time())

    def remember(self, kind, label, fr, pt=None):
        self.ring.append((kind, label, fr.raw if fr is not None else None,
                          fr._tx if fr is not None else None, pt))

    def dump(self, name):
        """Uloží posledních pár snímků (černá skříňka) – kvůli diagnostice."""
        items = list(self.ring)
        self.ring.clear()
        self.dumps += 1
        d = self.dir / f"{name}_{self.dumps:02d}"

        def work():
            d.mkdir(parents=True, exist_ok=True)
            for k, (kind, label, raw, tx, pt) in enumerate(items):
                if raw is None:
                    continue
                img = cv2.imdecode(np.frombuffer(raw, np.uint8), cv2.IMREAD_COLOR)
                if img is None:
                    continue
                if pt:
                    h, w = img.shape[:2]
                    cv2.circle(img, (int(pt[0] * w), int(pt[1] * h)), max(12, w // 30), (0, 0, 255), 6)
                base = d / f"{k:02d}_{kind}_{re.sub(r'[^A-Za-z0-9_]+', '_', label)[:40]}"
                cv2.imwrite(f"{base}.jpg", img, [cv2.IMWRITE_JPEG_QUALITY, 80])
                if tx:
                    Path(f"{base}.json").write_text(json.dumps(tx, ensure_ascii=False, indent=1))

        SAVER.submit(work)
        return d

    # ---------- dotyky ----------
    def guard(self, x, y, label, fr=None, overlay=False):
        """Pojistka před každým dotykem: žádný TRANSFER/EVOLVE/... v okolí.
        overlay=True: plovoucí tlačítko (X, ≡) leží nad řádky detailu, takže u EVOLVE/POWER UP
        stačí, že neklepne přímo na jejich text."""
        max_age = 0.3 if self.streaming() else 2.5
        if fr is None or time.time() - fr.t > max_age:
            fr = self.frame()
        tx = fr.fast
        if transfer_dialog(tx) and label != "CANCEL":
            raise Danger("je otevřený dialog TRANSFER – kromě CANCEL nic neklikám")
        for t in tx:
            s = t["text"].strip()
            if not upper_text(s):
                continue
            u = s.upper()
            if DANGER_RE.match(u) and abs(t["cy"] - y) < DANGER_BAND:
                hit = True
            elif DANGER_ROW_RE.match(u):
                hit = (t["x0"] - 0.04 <= x <= t["x1"] + 0.04 and abs(t["cy"] - y) < 0.025) if overlay \
                    else abs(t["cy"] - y) < DANGER_BAND
            else:
                hit = False
            if hit:
                raise Danger(f"'{label}' na ({x:.2f}, {y:.2f}) je moc blízko tlačítka '{s}' – NEKLIKÁM")
        return fr

    def tap(self, x, y, label, fr=None, overlay=False):
        fr = self.guard(x, y, label, fr, overlay)
        self.remember("tap", label, fr, (x, y))
        log(f"   klepnutí: {label} ({x:.2f}, {y:.2f})")
        self.d.execute_script("mobile: tap", {"x": int(x * self.W), "y": int(y * self.H)})
        return time.time()

    def long_press(self, x, y, label, fr=None, sec=LONG_PRESS_SEC):
        fr = self.guard(x, y, label, fr)
        self.remember("hold", label, fr, (x, y))
        log(f"   podržení {sec:.1f}s: {label} ({x:.2f}, {y:.2f})")
        self.d.execute_script("mobile: touchAndHold",
                              {"x": int(x * self.W), "y": int(y * self.H), "duration": sec})
        return time.time()

    def type_text(self, text):
        """Napíše text do pole, které má právě klávesnici (WebDriverAgent /wda/keys)."""
        log(f"   psaní: {text!r}")
        try:
            if self.d.command_executor.get_command("pogoKeys") is None:
                self.d.command_executor.add_command("pogoKeys", "POST", "/session/$sessionId/keys")
            self.d.execute("pogoKeys", {"value": list(text)})
        except Exception as e:
            log(f"   (psaní přes keys nešlo: {short_err(e)}, zkouším mobile: keys)")
            self.d.execute_script("mobile: keys", {"keys": [text]})

    def drag(self, a, b, label, ms=400, hold=0.3, fr=None):
        """Tažení prstem; s hold na konci podrží, aby seznam nedojel setrvačností."""
        from selenium.webdriver.common.actions import interaction
        from selenium.webdriver.common.actions.action_builder import ActionBuilder
        from selenium.webdriver.common.actions.pointer_input import PointerInput

        fr = self.guard(a[0], a[1], label, fr)
        self.remember("drag", label, fr, a)
        log(f"   tažení: {label}")
        finger = PointerInput(interaction.POINTER_TOUCH, "finger")
        ab = ActionBuilder(self.d, mouse=finger)
        finger.create_pointer_move(duration=0, x=int(a[0] * self.W), y=int(a[1] * self.H))
        finger.create_pointer_down(button=0)
        finger.create_pointer_move(duration=ms, x=int(b[0] * self.W), y=int(b[1] * self.H))
        if hold:
            finger.create_pause(hold)
        finger.create_pointer_up(button=0)
        ab.perform()
        return time.time()

    # ---------- čekání na výsledek ----------
    def wait_for(self, cond, timeout, after=None, label="kontrola"):
        """Čte nové snímky, dokud cond(frame) nevrátí pravdu (nebo nevyprší čas)."""
        end = time.time() + timeout
        while True:
            fr = self.frame(after=after)
            res = cond(fr)
            if res or time.time() > end:
                self.remember("check", label, fr)
                return res, fr
            after = fr.t + 0.005

    def act(self, pt, label, cond, timeout=2.0, fr=None, tries=2, alts=(), overlay=False):
        """Klepne a počká na očekávaný efekt; když nepřijde, zkusí to znovu (případně jinde)."""
        pts = [pt] + list(alts)
        for k in range(tries):
            p = pts[min(k, len(pts) - 1)]
            t0 = self.tap(p[0], p[1], label if k == 0 else f"{label} (znovu)", fr=fr, overlay=overlay)
            res, fr = self.wait_for(cond, timeout, after=t0 + FRAME_LAG, label=label)
            if res:
                return res, fr
        raise StepError(f"'{label}': klepnutí nemělo očekávaný efekt")

    def settle(self, fr, region=(0.0, 0.45, 1.0, 0.9), timeout=1.5, thr=1.5):
        """Počká, až obrazovka v dané oblasti přestane jezdit (konec animace)."""
        end = time.time() + timeout
        while time.time() < end:
            nxt = self.frame(after=fr.t + 0.005)
            if img_diff(fr.img, nxt.img, region) < thr:
                return nxt
            fr = nxt
        return fr

    def stable_text(self, patterns, exact=False, region=None, timeout=1.5):
        """Počká, až text stojí na místě (konec animace)."""
        end = time.time() + timeout
        prev = fr = None
        while True:
            fr = self.frame(after=fr.t + 0.005 if fr else None)
            t = find_text(fr.texts, patterns, exact, region)
            if t and prev and abs(t["cx"] - prev["cx"]) < 0.005 and abs(t["cy"] - prev["cy"]) < 0.005:
                return t, fr
            if time.time() > end:
                return t, fr
            prev = t


# ---------------------------- aplikace a spojení --------------------
def load_config():
    """Přepíše výchozí hodnoty podle ~/.pogo/config.json (zapisuje ho aplikace)."""
    global UDID, TEAM_ID, SIGNING_ID, SAVED_SEARCH, TAG_NAME, KEEP_N, IV_TAGS, RECHECK_TAGGED, \
        IV_CACHE_HOURS, MAX_GROUPS
    try:
        c = json.loads(CONFIG_FILE.read_text())
    except FileNotFoundError:
        return
    except Exception as e:
        log(f"Nastavení {CONFIG_FILE} nejde přečíst ({e}), beru výchozí hodnoty")
        return
    UDID = str(c.get("udid") or "").strip()
    TEAM_ID = str(c.get("team_id") or "").strip()
    SIGNING_ID = c.get("signing_id") or SIGNING_ID
    SAVED_SEARCH = c.get("saved_search") or SAVED_SEARCH
    TAG_NAME = c.get("remove_tag") or TAG_NAME
    KEEP_N = max(1, int(c.get("keep_best", KEEP_N)))
    tags = [(int(t["min"]), str(t["name"]).strip()) for t in c.get("iv_tags", []) if str(t.get("name", "")).strip()]
    if tags:
        IV_TAGS = sorted(tags, key=lambda t: -t[0])
    RECHECK_TAGGED = bool(c.get("recheck_tagged", RECHECK_TAGGED))
    IV_CACHE_HOURS = float(c.get("iv_cache_hours", IV_CACHE_HOURS))
    MAX_GROUPS = int(c.get("max_groups", MAX_GROUPS))


def _run(cmd):
    import subprocess
    try:
        return subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=20).stdout
    except Exception:
        return ""


def detect_udid():
    """UDID prvního připojeného iPhonu (ne simulátoru)."""
    out = _run("xcrun xctrace list devices 2>/dev/null")
    section = ""
    for line in out.splitlines():
        if line.startswith("=="):
            section = line
            continue
        m = re.match(r"^(.*) \(([\d.]+)\) \(([0-9A-Fa-f-]{20,})\)$", line.strip())
        if m and "Simulator" not in section and "Simulator" not in line:
            log(f"   iPhone: {m.group(1)} (iOS {m.group(2)})")
            return m.group(3)
    raise Fatal("Nevidím připojený iPhone. Připoj ho kabelem, odemkni a potvrď „Důvěřovat tomuto počítači“.")


def detect_team_id():
    """Apple Team ID z certifikátu „Apple Development“ v Klíčence (pole OU)."""
    out = _run("security find-certificate -c 'Apple Development' -p 2>/dev/null | openssl x509 -noout -subject 2>/dev/null")
    m = re.search(r"OU\s*=\s*([A-Z0-9]{10})", out)
    return m.group(1) if m else ""


def connect():
    from appium import webdriver
    from appium.options.ios import XCUITestOptions

    o = XCUITestOptions()
    o.platform_name = "iOS"
    o.udid = UDID or detect_udid()
    o.bundle_id = BUNDLE_ID
    o.automation_name = "XCUITest"
    o.no_reset = True
    o.new_command_timeout = 600
    team = TEAM_ID or detect_team_id()
    if team:
        o.xcode_org_id = team
        o.xcode_signing_id = SIGNING_ID
    else:
        log("   (Apple Team ID nevím – když se WebDriverAgent nepodepíše, doplň ho v nastavení)")
    o.set_capability("waitForQuiescence", False)
    o.set_capability("waitForIdleTimeout", 0)
    driver = webdriver.Remote(APPIUM_URL, options=o)
    settings = {"waitForIdleTimeout": 0, "animationCoolOffTimeout": 0,
                "mjpegServerScreenshotQuality": MJPEG_QUALITY, "mjpegServerFramerate": MJPEG_FPS,
                "mjpegScalingFactor": MJPEG_SCALE}
    for k, v in settings.items():
        try:
            driver.update_settings({k: v})
        except Exception as e:
            log(f"   (nastavení {k} se nepovedlo: {short_err(e)})")
    return driver


def session_alive(driver):
    try:
        driver.get_window_size()
        return True
    except Exception:
        return False


def reconnect(bot):
    log("   Spojení s telefonem spadlo, připojuji znovu...")
    try:
        bot.d.quit()
    except Exception:
        pass
    for _ in range(3):
        try:
            bot.d = connect()
            bot.refresh()
            return
        except Exception as e:
            log(f"   nepovedlo se ({short_err(e)}), zkusím znovu za 5 s")
            time.sleep(5)
    raise Fatal("Nepodařilo se znovu připojit k telefonu (je odemčený a připojený kabelem?)")


def ensure_app(bot):
    """Telefon odemčený a hra v popředí. Vrací True, když musel něco udělat."""
    acted = False
    try:
        if bot.d.is_locked():
            log("   Telefon je zamčený – zkouším odemknout (s kódem ho odemkni ručně, počkám)")
            try:
                bot.d.unlock()
            except Exception:
                pass
            end = time.time() + 600
            while bot.d.is_locked() and time.time() < end:
                time.sleep(2)
            acted = True
        if bot.d.query_app_state(BUNDLE_ID) != 4:   # 4 = běží v popředí
            log("   Pokémon GO není v popředí – přepínám do něj")
            bot.d.activate_app(BUNDLE_ID)
            time.sleep(2)
            acted = True
    except Exception as e:
        log(f"   (stav aplikace nezjištěn: {short_err(e)})")
    return acted


def restart_game(bot):
    log("   Restartuji Pokémon GO...")
    try:
        bot.d.terminate_app(BUNDLE_ID)
    except Exception:
        pass
    time.sleep(2)
    bot.d.activate_app(BUNDLE_ID)
    bot.need_sort = True
    end = time.time() + 75
    while time.time() < end:
        time.sleep(1.5)
        fr = bot.frame()
        st = classify(fr)
        if st in ("map", "main_menu") or st in BOX_STATES:
            log("   hra je načtená")
            return
        t = safe_button(fr.texts)
        if t:
            try:
                bot.tap(t["cx"], t["cy"], f"zavřít okno: {t['text']}", fr=fr)
            except StepError:
                pass
    log("   hra se po restartu nenačetla do mapy, zkusím pokračovat")


# ---------------------------- cesta do boxu -------------------------
def filter_state(bot, tx):
    k = filter_key(search_bar_text(tx))
    if k in ("", "search"):
        return "none"
    return "ok" if keys_match(k, bot.filter_key) else "other"


def apply_saved_search(bot, fr, attempt):
    t = find_text(fr.texts, [SAVED_SEARCH], region=(0.0, 0.2, 1.0, 0.75))
    if t is None:
        m = find_text(fr.texts, [L["see_more"]])
        if m and attempt >= 2:
            bot.act((m["cx"], m["cy"]), "See More",
                    lambda f: find_text(f.texts, [SAVED_SEARCH], region=(0.0, 0.15, 1.0, 0.95)), fr=fr, tries=1)
            return
        if attempt >= 4:
            raise Fatal(f"V hledání nevidím uložené hledání '{SAVED_SEARCH}'. Ulož ho ve hře, "
                        f"nebo přepiš SAVED_SEARCH v konfiguraci.")
        time.sleep(0.4)
        return
    _, f = bot.act((t["cx"], t["cy"]), f"hledání '{t['text']}'",
                   lambda f: classify(f) in ("box", "box_other") and filter_state(bot, f.texts) != "none",
                   timeout=3, fr=fr, alts=[(t["cx"], t["cy"] - 0.04)])
    key = filter_key(search_bar_text(f.texts))
    if key and key != bot.filter_key:
        bot.filter_key = key
        cal_set("filter_key", key)
    bot.fresh_list = True


def handle_unknown(bot, fr, attempt):
    if attempt == 1 and ensure_app(bot):
        return
    if attempt <= 2:
        time.sleep(0.6)   # třeba jen animace / načítání
        return
    t = safe_button(fr.texts)
    if t:
        bot.tap(t["cx"], t["cy"], f"zavřít okno: {t['text']}", fr=fr)
        time.sleep(0.6)
    elif attempt % 3 == 0:
        bot.tap(*P_BOTTOM_X, "zavřít (X dole)", fr=fr)
        time.sleep(0.8)
    else:
        time.sleep(0.6)


def nav_step(bot, st, fr, attempt):
    """Jeden krok směrem do boxu. Vrací snímek, když je box hotový (filtr + řazení)."""
    tx = fr.texts
    if keyboard_on(tx) and st not in ("search_page", "transfer_dialog", "confirm_dialog"):
        # otevřená klávesnice (třeba po nedokončeném zakládání tagu) – nejdřív ji schovat,
        # jinak by klepnutí dole trefila klávesy
        try:
            bot.d.execute_script("mobile: hideKeyboard", {})
        except Exception:
            bot.tap(0.5, 0.12, "schovat klávesnici", fr=fr)
        time.sleep(0.5)
        return None
    if st == "transfer_dialog":
        c = find_text(tx, ["cancel"], exact=True)
        if c is None:
            time.sleep(0.3)
            return None
        bot.act((c["cx"], c["cy"]), "CANCEL", lambda f: not transfer_dialog(f.texts), fr=fr, tries=1)
    elif st == "confirm_dialog":
        c = find_text(tx, ["no", "cancel"], exact=True)
        bot.act((c["cx"], c["cy"]), f"odmítnout dialog ({c['text']})", lambda f: not confirm_dialog(f.texts),
                fr=fr, tries=1)
    elif st == "tag_list":
        bot.act(P_BOTTOM_X, "zavřít seznam tagů (bez uložení)", lambda f: not tag_list_on(f.texts), fr=fr, tries=1)
    elif st == "multiselect":
        bot.act(P_MULTI_CLOSE, "zrušit multiselect", lambda f: classify(f) != "multiselect", fr=fr, tries=1)
    elif st == "appraisal":
        bot.act(P_NEUTRAL, "zavřít appraisal", lambda f: classify(f) != "appraisal", timeout=1.5, fr=fr, tries=1)
    elif st == "detail_menu":
        bot.act(P_CORNER, "zavřít menu", lambda f: classify(f) != "detail_menu", fr=fr, tries=1, overlay=True)
    elif st == "detail":
        bot.act(P_BOTTOM_X, "zavřít detail", lambda f: classify(f) != "detail", timeout=2.5, fr=fr, tries=1,
                overlay=True)
    elif st == "sort_menu":
        t, fr = bot.stable_text([L["number"]], exact=True, region=(0.4, 0.3, 1.0, 0.9))
        if bot.need_sort and t and not sort_active(fr.img, t):
            # klepnout jen když NUMBER ještě není aktivní – opakované klepnutí by obrátilo směr řazení
            bot.act((t["cx"], t["cy"]), "řadit podle NUMBER", lambda f: not sort_menu_on(f.texts), fr=fr, tries=1)
        else:
            if bot.need_sort and t:
                log("   řazení podle čísla už je nastavené")
            bot.act(P_CORNER, "zavřít řazení", lambda f: not sort_menu_on(f.texts), fr=fr, tries=1, overlay=True)
        if t:
            bot.need_sort = False
    elif st == "search_page":
        if bot.mode == "all":
            bot.act(P_SEARCH_BACK, "zavřít hledání", lambda f: classify(f) != "search_page", timeout=2.5, fr=fr,
                    tries=1)
        else:
            apply_saved_search(bot, fr, attempt)
    elif st == "box" and bot.mode == "all":
        if filter_state(bot, tx) != "none":
            p = P_SEARCH_CLEAR if attempt % 2 else P_SEARCH_BACK
            bot.act(p, "zrušit hledání (celý box)",
                    lambda f: classify(f) == "search_page" or filter_state(bot, f.texts) == "none",
                    timeout=2.5, fr=fr, tries=1)
        elif bot.need_sort:
            bot.act(P_CORNER, "řazení", lambda f: sort_menu_on(f.texts), fr=fr, tries=1, overlay=True)
        else:
            return fr
    elif st == "box":
        fs = filter_state(bot, tx)
        if fs == "none":
            bot.act(P_SEARCH_BAR, "Search", lambda f: classify(f) == "search_page", timeout=2.5, fr=fr, tries=1)
        elif fs == "other":
            p = P_SEARCH_BACK if attempt % 2 else P_SEARCH_CLEAR
            bot.act(p, "zrušit jiné hledání",
                    lambda f: classify(f) == "search_page" or filter_state(bot, f.texts) != "other",
                    timeout=2.5, fr=fr, tries=1)
        elif bot.need_sort:
            bot.act(P_CORNER, "řazení", lambda f: sort_menu_on(f.texts), fr=fr, tries=1, overlay=True)
        else:
            return fr
    elif st in ("box_tags", "box_other"):
        if st == "box_other" and bot.mode != "all" and filter_state(bot, tx) == "ok" and attempt >= 3:
            return fr   # náš filtr, ale nic nenašel
        if attempt == 1:
            time.sleep(0.5)   # box se možná teprve načítá
            return None
        t = find_text(tx, ["pokemon"], region=(0.3, 0.0, 0.7, 0.16))
        p = (t["cx"], t["cy"]) if t else P_BOX_TAB
        bot.act(p, "záložka POKÉMON", lambda f: classify(f) != st, timeout=2.5, fr=fr, tries=1)
    elif st == "main_menu":
        t, fr = bot.stable_text(["pokemon"], exact=True, region=(0.0, 0.5, 0.5, 1.0))
        cands = ([(t["cx"], t["cy"] + MENU_ICON_DY), (t["cx"], t["cy"] + 0.035), (t["cx"], t["cy"])]
                 if t else [(0.22, 0.835)])
        p = cands[(attempt - 1) % len(cands)]
        bot.act(p, "POKÉMON", lambda f: classify(f) in BOX_STATES, timeout=6, fr=fr, tries=1)
    elif st == "map":
        p = P_POKEBALL[(attempt - 1) % len(P_POKEBALL)]
        bot.act(p, "Poké Ball", lambda f: classify(f) == "main_menu", timeout=2.5, fr=fr, tries=1)
    else:
        handle_unknown(bot, fr, attempt)
    return None


def ensure_box(bot):
    """Odkudkoliv dojde do boxu s filtrem SAVED_SEARCH a řazením podle čísla."""
    start = time.time()
    restarted = False
    last, same = None, 0
    while True:
        stuck = same > (15 if last == "unknown" else 8)
        if time.time() - start > NAV_TIMEOUT or stuck:
            if restarted:
                raise Fatal("Do boxu se nedaří dostat ani po restartu hry. Mrkni do složky s chybou.")
            log("   nedaří se dostat do boxu" + (" (pořád stejná obrazovka)" if stuck else ""))
            restart_game(bot)
            restarted, start, last, same = True, time.time(), None, 0
            continue
        fr = bot.frame()
        st = classify(fr)
        same = same + 1 if st == last else 1
        if st != last:
            log(f"   obrazovka: {STATE_CZ.get(st, st)}")
        last = st
        bot.remember("stav", st, fr)
        try:
            done = nav_step(bot, st, fr, same)
        except Danger as e:
            log(f"   POZOR: {e}")
            time.sleep(0.3)
            continue
        except StepError as e:
            log(f"   ({e})")
            continue
        if done is not None:
            return done


# ---------------------------- čtení mřížky a posun ------------------
def read_grid(bot, timeout=4.0):
    """Počká, až mřížka stojí (žádná animace/scroll), a vrátí (buňky, snímek)."""
    end = time.time() + timeout
    prev = None
    while True:
        fr = bot.frame(after=prev.t + 0.005 if prev else None)
        cells = complete_cells(fr.texts)
        if cells and prev is not None:
            pc = complete_cells(prev.texts)
            same = len(pc) == len(cells) and all(
                a["cp"] == b["cp"] and abs(a["cy"] - b["cy"]) < 0.004 for a, b in zip(pc, cells))
            if same and img_diff(prev.img, fr.img) < 2.5:
                return with_details(cells, fr), fr
        if time.time() > end:
            if cells:
                return with_details(cells, fr), fr
            raise StepError("nevidím mřížku boxu")
        prev = fr


def cell_matches(ref, c):
    return ref["cp"] == c["cp"] and names_ok(ref["name"], c["name"]) and \
        sprite_sim(ref["sprite"], c["sprite"]) >= SAME_SPECIES_THR


def scroll_by(bot, cells, anchor):
    """Posune mřížku tak, aby řádek s anchor byl nahoře. Vrací False na konci seznamu."""
    dy = min(anchor["cy"] - TOP_ROW_Y, 0.55)
    before = [(c["cp"], round(c["cy"], 2)) for c in cells]
    moved = False
    for k in range(2):
        x = 0.5 if k == 0 else 0.3
        bot.drag((x, SCROLL_FROM_Y), (x, SCROLL_FROM_Y - dy), f"posun o {dy:.2f}",
                 ms=int(250 + 900 * dy), hold=0.3)
        cells2, fr = read_grid(bot)
        if classify(fr) == "multiselect":
            raise StepError("posun omylem spustil multiselect")
        if [(c["cp"], round(c["cy"], 2)) for c in cells2] != before:
            moved = True
            break
    if not moved:
        if any(c["cy"] > GRID_BOTTOM + 0.02 for c in grid_cells(fr.texts)):
            raise StepError("seznam se nedá posunout, i když pod ním ještě něco je")
        return False   # konec seznamu
    for _ in range(4):
        if any(cell_matches(anchor, c) for c in cells2):
            return True
        # přejeli jsme -> kousek zpátky
        bot.drag((0.5, 0.45), (0.5, 0.58), "kousek zpět", ms=350, hold=0.3)
        cells2, fr = read_grid(bot)
    raise LostPosition("při posunu jsem ztratil místo v boxu")


def bring_to_top(bot, cells, cell):
    if cell["cy"] - TOP_ROW_Y < 0.08:
        return False
    return scroll_by(bot, cells, cell)


def scroll_next(bot, cells):
    """Další obrazovka; poslední řádek zůstane nahoře jako překryv."""
    last_row = max(c["row"] for c in cells)
    anchor = next(c for c in cells if c["row"] == last_row)
    if anchor["cy"] - TOP_ROW_Y < 0.08:
        anchor = cells[-1]
    return scroll_by(bot, cells, anchor)


def scroll_to_top(bot):
    log("   na začátek seznamu")
    prev = None
    for _ in range(25):
        cells, fr = read_grid(bot)
        key = [c["cp"] for c in cells]
        if key == prev:
            return
        prev = key
        bot.drag((0.5, 0.32), (0.5, 0.85), "nahoru", ms=120, hold=0)


# ---------------------------- záznamy o Pokémonech ------------------
class Rec:
    def __init__(self, cell, gid):
        self.cp, self.name, self.sig, self.sprite = cell["cp"], cell["name"], cell["sig"], cell["sprite"]
        self.gid = gid
        self.iv = self.types = self.action = None
        self.status = "new"          # new | done | failed | single
        self.fails = self.tag_fails = 0
        self.tagged = self.ambiguous = self.cached = False
        self.note = ""


class Book:
    def __init__(self):
        self.recs, self.next_gid, self.progress = [], 1, 0

    def new_gid(self):
        self.next_gid += 1
        return self.next_gid - 1

    def assign(self, cells):
        """Buňkám přiřadí známé záznamy (stejné CP + jméno + obrázek), ve stejném pořadí."""
        used = set()
        for c in cells:
            c["rec"] = None
            for r in self.recs:
                if id(r) not in used and r.cp == c["cp"] and names_ok(r.name, c["name"]) \
                        and sprite_sim(r.sprite, c["sprite"]) >= SAME_SPECIES_THR:
                    c["rec"] = r
                    used.add(id(r))
                    break

    def group(self, gid):
        return [r for r in self.recs if r.gid == gid]

    def groups(self):
        gids = {}
        for r in self.recs:
            gids.setdefault(r.gid, []).append(r)
        return {g: rs for g, rs in gids.items() if len(rs) >= 2}

    def groups_done(self):
        return sum(1 for rs in self.groups().values() if all(r.status != "new" for r in rs))

    def outstanding(self):
        return [r for r in self.recs if r.action == "remove" and not r.tagged
                and not r.ambiguous and r.tag_fails < 2]


class Memory:
    """Trvalá paměť mezi běhy: změřené IV (pár hodin) a komu už dal tag."""

    def __init__(self, path):
        self.path = path
        try:
            self.data = json.loads(path.read_text())
        except Exception:
            self.data = {}
        now = time.time()
        self.data["iv"] = {k: v for k, v in self.data.get("iv", {}).items()
                           if now - v.get("t", 0) < IV_CACHE_HOURS * 3600}
        self.data["tagged"] = {k: v for k, v in self.data.get("tagged", {}).items()
                               if now - v < TAGGED_DAYS * 86400}

    def save(self):
        try:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            tmp = self.path.with_suffix(".tmp")
            tmp.write_text(json.dumps(self.data))
            tmp.replace(self.path)
        except OSError as e:
            log(f"   (paměť se nepodařilo uložit: {e})")

    def get_iv(self, sig):
        e = self.data["iv"].get(sig)
        if e and time.time() - e["t"] < IV_CACHE_HOURS * 3600:
            return tuple(e["iv"]), e.get("types")
        return None

    def set_iv(self, sig, iv, types):
        if sig.split("|", 1)[1]:          # bez jména si ho nepamatuju
            self.data["iv"][sig] = {"iv": list(iv), "types": types, "t": time.time()}
            self.save()

    def is_tagged(self, cp, name):
        prefix = alnum(TAG_NAME) + "|"
        for k in self.data["tagged"]:
            if not k.startswith(prefix):
                continue                     # záznam pro jiný tag
            c, n = k[len(prefix):].split("|", 1)
            if c == str(cp) and n and names_ok(n, name):
                return True
        return False

    def set_tagged(self, cp, name):
        self.data["tagged"][f"{alnum(TAG_NAME)}|{cp}|{alnum(name)}"] = time.time()
        self.save()


class Report:
    def __init__(self, run_dir, max_groups):
        self.dir, self.max = run_dir, max_groups
        self.t0 = time.time()
        self.shown = {}
        self.measured = 0

    def limit_reached(self, book):
        return bool(self.max) and book.groups_done() >= self.max

    def show(self, book, gid):
        group = book.group(gid)
        lines = []
        for r in group:
            ivs = "/".join(f"{v:>2}" for v in r.iv) if r.iv else " ?/ ?/ ?"
            pct = f"{sum(r.iv) / 45:4.0%}" if r.iv else "   ?"
            act = {"keep": "nechat", "remove": TAG_NAME}.get(r.action, "nezměřeno" if r.status == "failed" else "?")
            flags = (" ✔ otagováno" if r.tagged else "") + (" (z paměti)" if r.cached else "") \
                + (" (stejné CP i jméno – netaguju)" if r.ambiguous and r.action == "remove" else "")
            lines.append(f"   CP{r.cp:<5} {ivs}  {pct}  -> {act}{flags}")
        names = [r.name for r in group if PLAIN_NAME.match(norm(r.name))] or [r.name for r in group]
        title = max(set(names), key=names.count) if names else "?"
        text = f"\n── Várka: {title} ({len(group)} ks)\n" + "\n".join(lines)
        if self.shown.get(gid) != text:
            self.shown[gid] = text
            log(text)

    def show_iv(self, r):
        ivs = "/".join(f"{v:>2}" for v in r.iv) if r.iv else " ?/ ?/ ?"
        pct = f"{sum(r.iv) / 45:4.0%}" if r.iv else "   ?"
        log(f"   CP{r.cp:<5} {r.name[:16]:16s} {ivs} {pct}  -> {r.note}" + (" (IV z paměti)" if r.cached else ""))

    def save_iv(self, book2):
        if book2.recs:
            out = [{"cp": r.cp, "name": r.name, "iv": list(r.iv) if r.iv else None, "status": r.status,
                    "note": r.note} for r in book2.recs]
            (self.dir / "result_iv_tagy.json").write_text(json.dumps(out, ensure_ascii=False, indent=1))

    def summary_iv(self, book2):
        if not book2.recs:
            return
        log("\n------ 2. část: IV tagy ------")
        done = [r for r in book2.recs if r.status == "done"]
        for _, name in IV_TAGS:
            n = sum(1 for r in done if r.iv and iv_tag(r.iv) == name)
            if n:
                log(f"   {name:16s} {n} ks")
        log(f"Prošlo: {len(book2.recs)}, zařazeno teď: {len(done)}, "
            f"přeskočeno: {sum(r.status == 'skip' for r in book2.recs)}, "
            f"nepovedlo se: {sum(r.status == 'failed' for r in book2.recs)}")

    def save(self, book):
        out = [{"group": r.gid, "cp": r.cp, "name": r.name, "iv": list(r.iv) if r.iv else None,
                "types": r.types, "action": r.action, "tagged": r.tagged, "status": r.status,
                "from_memory": r.cached, "ambiguous": r.ambiguous}
               for r in book.recs if r.status != "single"]
        (self.dir / "result.json").write_text(json.dumps(out, ensure_ascii=False, indent=1))

    def summary(self, book):
        dt = time.time() - self.t0
        recs = [r for r in book.recs if r.status != "single"]
        rem = [r for r in recs if r.action == "remove"]
        log("\n================ SHRNUTÍ ================")
        log(f"Várek: {len(book.groups())}, Pokémonů ve várkách: {len(recs)}")
        log(f"Změřeno teď: {self.measured}, z paměti: {sum(r.cached for r in recs)}, "
            f"nezměřeno: {sum(r.status == 'failed' for r in recs)}")
        log(f"Označeno tagem {TAG_NAME}: {sum(r.tagged for r in rem)} z {len(rem)}")
        left = [r for r in rem if not r.tagged]
        if left:
            log("Neoznačené (zkontroluj ručně): " + ", ".join(f"CP{r.cp} {r.name}" for r in left))
        log(f"Čas: {dt / 60:.1f} min" + (f", {dt / self.measured:.1f} s na změřeného Pokémona" if self.measured else ""))


# ---------------------------- měření ---------------------------------
def check_detail(bot, fr, cell):
    """Ověří, že se otevřel správný Pokémon (CP, případně jméno)."""
    end = time.time() + 1.5
    cp, wrong = None, 0
    while True:
        cp, nm = detail_cp(fr.texts), detail_name(fr.texts)
        if cp == cell["cp"]:
            return fr
        if cp is None and nm and cell["name"] and alnum(nm) == alnum(cell["name"]) and time.time() > end - 0.75:
            return fr
        wrong += cp is not None
        if wrong >= 3 or time.time() > end:
            raise StepError(f"otevřel se jiný Pokémon (CP{cp} místo CP{cell['cp']})")
        fr = bot.frame(after=fr.t + 0.005)


def save_bars(bot, fr, labels, bars, vals, cp):
    """Výřez s bary a vyznačeným měřením (modře celý bar, zeleně výplň)."""
    dbg = fr.img.copy()
    for b in bars:
        if b:
            left, right, fill_end, row, _ = b
            cv2.line(dbg, (left, row - 8), (right, row - 8), (0, 0, 255), 2)
            if fill_end is not None:
                cv2.line(dbg, (left, row + 8), (fill_end, row + 8), (0, 160, 0), 2)
    y0 = max(0.0, labels[0]["y0"] - 0.03)
    y1 = min(1.0, labels[2]["y1"] + 0.06)
    crop = crop_norm(dbg, 0.0, y0, 0.6, y1)
    path = bot.dir / "iv" / f"CP{cp}_{'-'.join(map(str, vals))}.jpg"
    SAVER.submit(cv2.imwrite, str(path), cv2.cvtColor(crop, cv2.COLOR_RGB2BGR))


def read_appraisal(bot, cp):
    """Proklikne úvodní řeč a přečte bary, až dojedou animací. None = nepovedlo se."""
    end = time.time() + 9
    first = cur = cur_since = None
    d_prev, d_since = None, time.time()
    last_tap, taps = 0.0, 0
    after = None
    while time.time() < end:
        fr = bot.frame(after=after)
        after = fr.t + 0.005
        tx = fr.texts
        labels = bar_labels(tx)
        if labels:
            if first is None:
                first = fr.t
            vals, bars = read_bars(fr.img, labels)
            if vals != cur:
                cur, cur_since = vals, fr.t
            elif vals is not None and fr.t - cur_since >= BAR_STABLE and fr.t - first >= BAR_SETTLE:
                bot.remember("bary", f"CP{cp}", fr)
                save_bars(bot, fr, labels, bars, vals, cp)
                return vals
            continue
        if classify(fr) != "appraisal":
            if taps and time.time() - last_tap > 1.5:
                return None   # appraisal se zavřel dřív, než šly bary přečíst
            continue
        d = dialog_text(tx)
        if d != d_prev:
            d_prev, d_since = d, fr.t
        if d and fr.t - d_since >= 0.25 and time.time() - last_tap >= 0.6 and taps < 8:
            last_tap = bot.tap(*P_NEUTRAL, "appraisal dál", fr=fr)
            taps += 1
            after = last_tap + FRAME_LAG
    return None


def open_detail(bot, cell):
    """Klepne na buňku, počká, až detail dojede, a ověří, že je to správný Pokémon."""
    cp = cell["cp"]
    x, y = cell["cx"], cell["cy"] + CELL_TAP_DY
    _, fr = bot.act((x, y), f"otevřít CP{cp}", lambda f: classify(f) == "detail",
                    timeout=2.5, alts=[(x, y - 0.025)])
    fr = bot.settle(fr)                      # detail vyjíždí zespodu – počkat, až dojede
    return check_detail(bot, fr, cell)


def open_detail_menu(bot, fr):
    _, fr = bot.act(P_CORNER, "menu ≡", lambda f: classify(f) == "detail_menu", timeout=1.8, fr=fr, overlay=True)
    return fr


def appraise(bot, fr, cp):
    """Z otevřeného detailu: ≡ -> APPRAISE -> přečíst bary -> zavřít appraisal. Vrací (iv nebo None, snímek detailu)."""
    open_detail_menu(bot, fr)
    t, fr = bot.stable_text([L["appraise"]], exact=True, region=(0.4, 0.55, 1.0, 0.92))   # menu se rozsvěcuje
    if t is None:
        raise StepError("v menu chybí APPRAISE")
    bot.act((t["cx"], t["cy"]), "APPRAISE", lambda f: classify(f) == "appraisal", timeout=2.5, fr=fr, tries=1)
    iv = read_appraisal(bot, cp)
    for _ in range(4):
        if classify(bot.frame()) != "appraisal":
            break
        try:
            bot.act(P_NEUTRAL, "zavřít appraisal", lambda f: classify(f) != "appraisal", timeout=1.2, tries=1)
        except StepError:
            pass
    return iv, bot.settle(bot.frame())


def close_detail(bot, fr=None):
    fr = bot.settle(fr or bot.frame())
    bot.act(P_BOTTOM_X, "zavřít detail", lambda f: classify(f) == "box", timeout=2.5, fr=fr, overlay=True)


def measure(bot, cell):
    """Otevře detail, appraisal, přečte IV a vrátí se do boxu. Vrací (iv nebo None, typy)."""
    fr = open_detail(bot, cell)
    types = detail_types(fr.texts)
    iv, fr = appraise(bot, fr, cell["cp"])
    close_detail(bot, fr)
    return iv, types


# ---------------------------- tagování -------------------------------
LIST_REGION = (0.0, 0.12, 1.0, 0.9)


def same_tag(text, name):
    a, b = alnum(text), alnum(name)
    if not a or not b:
        return False
    if a == b or (a.endswith(b) and len(a) <= len(b) + 2):
        return True
    return len(b) >= 6 and difflib.SequenceMatcher(None, a, b).ratio() >= 0.88


def tag_row(tx, name=None):
    """Řádek s daným tagem v seznamu tagů."""
    name = name or TAG_NAME
    return next((x for x in tx if in_region(x, (0.0, 0.15, 1.0, 0.82)) and same_tag(x["text"], name)), None)


def scroll_tag_list(bot, fr, direction):
    """Posune seznam tagů. Vrací (nový snímek, jestli se něco pohnulo)."""
    a, b = ((0.5, 0.72), (0.5, 0.42)) if direction == "dolů" else ((0.5, 0.42), (0.5, 0.72))
    before = sorted(alnum(x["text"]) for x in fr.texts if in_region(x, LIST_REGION))
    t0 = bot.drag(a, b, f"seznam tagů {direction}", ms=350, hold=0.25, fr=fr)
    fr = bot.frame(after=t0 + 0.3)
    return fr, sorted(alnum(x["text"]) for x in fr.texts if in_region(x, LIST_REGION)) != before


def scan_tag_list(bot, fr, directions, name=None):
    """Projíždí seznam tagů, dokud nenajde tag. Vrací (řádek nebo None, snímek)."""
    for direction in directions:
        for _ in range(TAG_SCROLL_MAX):
            t = tag_row(fr.texts, name)
            if t:
                return t, fr
            fr, moved = scroll_tag_list(bot, fr, direction)
            if not moved:
                break
    return tag_row(fr.texts, name), fr


def find_add_new_tag(bot, fr):
    """Najde v seznamu 'Add New Tag' (bývá na konci seznamu)."""
    for direction in ("dolů", "nahoru"):
        for _ in range(TAG_SCROLL_MAX):
            a = find_text(fr.texts, [L["add_new_tag"]], region=LIST_REGION)
            if a:
                return a, fr
            fr, moved = scroll_tag_list(bot, fr, direction)
            if not moved:
                break
    return None, fr


def create_tag(bot, fr, name=None):
    """Add New Tag -> pole Enter tag name -> napsat název -> Done."""
    name = name or TAG_NAME
    log(f"   tag '{name}' v seznamu není – zakládám ho")
    a, fr = find_add_new_tag(bot, fr)
    if a is None:
        raise Fatal(f"Tag '{name}' v seznamu není a nevidím ani '{L['add_new_tag']}'. Založ ho ve hře ručně.")
    _, fr = bot.act((a["cx"], a["cy"]), L["add_new_tag"],
                    lambda f: find_text(f.texts, [L["enter_tag_name"]]) or keyboard_on(f.texts), timeout=3, fr=fr)
    if not keyboard_on(fr.texts):
        e = find_text(fr.texts, [L["enter_tag_name"]])
        if e is None:
            raise StepError(f"nevidím pole '{L['enter_tag_name']}'")
        _, fr = bot.act((e["cx"], e["cy"]), L["enter_tag_name"], lambda f: keyboard_on(f.texts), timeout=3, fr=fr)
    bot.type_text(name)
    ok, fr = bot.wait_for(lambda f: any(same_tag(x["text"], name) for x in f.texts), 3, label="název napsán")
    if not ok:
        raise StepError("název tagu se nepodařilo napsat")
    # Done: tlačítko nad klávesnicí, klávesa na klávesnici, nebo Enter
    kb_top = min((x["cy"] for x in fr.texts if x["cy"] > 0.55 and len(x["text"].strip()) == 1
                  and x["text"].strip().isalpha()), default=1.0)
    dones = find_all(fr.texts, ["done", "hotovo", "ok", "create", "save", "add"], exact=True)
    above = [d for d in dones if d["cy"] < kb_top - 0.02]
    d = (above or dones or [None])[0]
    if d is not None:
        t0 = bot.tap(d["cx"], d["cy"], f"Done ({d['text']})", fr=fr)
    else:
        t0 = time.time()
        bot.type_text("\n")
    ok, fr = bot.wait_for(lambda f: not keyboard_on(f.texts) and tag_list_on(f.texts), 3,
                          after=t0 + FRAME_LAG, label="tag založen")
    if not ok:
        raise StepError("po Done jsem se nevrátil do seznamu tagů")
    log(f"   ✔ tag '{name}' založen")
    return bot.settle(fr, region=LIST_REGION)


def tap_tag_row(bot, fr, t, label):
    """Klepne na řádek tagu (zaškrtne/odškrtne) a ověří, že se něco změnilo."""
    box = (0.03, t["cy"] - 0.025, 0.97, t["cy"] + 0.025)
    before_row, before_all = crop_norm(fr.img, *box).copy(), fr.img
    t0 = bot.tap(t["cx"], t["cy"], label, fr=fr)
    ok, _ = bot.wait_for(
        lambda f: changed_frac(before_row, crop_norm(f.img, *box)) > 0.004
        or changed_frac(before_all, f.img) > 0.002,
        1.5, after=t0 + FRAME_LAG, label=label)
    if not ok:
        raise StepError(f"klepnutí '{label}' se neprojevilo")
    return bot.frame(after=time.time() + 0.15)


def pick_tag(bot, fr, name=None):
    """V seznamu tagů najde tag a zaškrtne ho. Když tam není, založí ho a projede seznam znovu."""
    name = name or TAG_NAME
    t, fr = scan_tag_list(bot, fr, ["dolů"], name)
    if t is None:
        fr = create_tag(bot, fr, name)
        t, fr = scan_tag_list(bot, fr, ["dolů", "nahoru", "dolů"], name)
        if t is None:
            raise StepError(f"nově založený tag '{name}' v seznamu nevidím")
    return tap_tag_row(bot, fr, t, f"tag {name}")


# ---------------------------- 2. část: IV tagy ----------------------
def iv_tag(iv):
    """Název IV tagu podle procent (součet / 45)."""
    total = sum(iv)
    for threshold, name in IV_TAGS:
        if total * 100 >= threshold * 45:
            return name
    return IV_TAGS[-1][1]


def detail_chips(tx):
    """Štítky tagů pod jménem v detailu: (seznam IV tagů, má Removable)."""
    region = (0.0, 0.44, 1.0, 0.68)
    have = []
    for _, name in IV_TAGS:
        if any(in_region(t, region) and same_tag(t["text"], name) for t in tx):
            have.append(name)
    removable = any(in_region(t, region) and same_tag(t["text"], TAG_NAME) for t in tx)
    return have, removable


def set_iv_tag(bot, fr, target, wrong, add=True):
    """V detailu přes ≡ -> TAG odškrtne špatné IV tagy a (když add) zaškrtne target. Ověří to podle štítků.
    Na už zaškrtnutý tag se neklepe – klepnutí by ho odškrtlo."""
    open_detail_menu(bot, fr)
    t, fr = bot.stable_text(["tag"], exact=True, region=(0.4, 0.3, 1.0, 0.92))
    if t is None:
        raise StepError("v menu chybí TAG")
    _, fr = bot.act((t["cx"], t["cy"]), "TAG", lambda f: tag_list_on(f.texts), timeout=2.5, fr=fr, tries=1)
    fr = bot.settle(fr, region=LIST_REGION)
    for name in wrong:
        row, fr = scan_tag_list(bot, fr, ["dolů", "nahoru"], name)
        if row is not None:
            fr = tap_tag_row(bot, fr, row, f"odškrtnout {name}")
    if add:
        fr = pick_tag(bot, fr, target)
    d = find_text(fr.texts, [L["done"]], exact=True, region=(0.0, 0.7, 1.0, 0.95))
    if d is None:
        raise StepError("nevidím DONE")
    _, fr = bot.act((d["cx"], d["cy"]), "DONE", lambda f: classify(f) in ("detail", "detail_menu"),
                    timeout=3, fr=fr, tries=1)
    if classify(fr) == "detail_menu":
        _, fr = bot.act(P_CORNER, "zavřít menu", lambda f: classify(f) == "detail", fr=fr, tries=1, overlay=True)
    fr = bot.settle(fr)
    have, _ = detail_chips(fr.texts)
    if target not in have or any(w in have for w in wrong):
        raise StepError(f"tag se neuložil (štítky v detailu: {have})")
    return fr


def categorize(bot, mem, cell, rec, args):
    """Jeden Pokémon do správného IV tagu (přes detail)."""
    fr = open_detail(bot, cell)
    have, removable = detail_chips(fr.texts)
    if removable:
        rec.status, rec.note = "skip", f"má {TAG_NAME}, přeskakuji"
        close_detail(bot, fr)
        return
    if len(have) == 1 and not RECHECK_TAGGED:
        rec.status, rec.note = "skip", f"už má {have[0]}"
        close_detail(bot, fr)
        return
    cached = None if args.fresh else mem.get_iv(rec.sig)
    if cached:
        rec.iv, rec.cached = cached[0], True
    else:
        iv, fr = appraise(bot, fr, cell["cp"])
        if iv is None:
            close_detail(bot, fr)
            raise StepError(f"CP{cell['cp']}: IV se nepodařilo přečíst")
        rec.iv = iv
        mem.set_iv(rec.sig, iv, detail_types(fr.texts))
    target = iv_tag(rec.iv)
    wrong = [n for n in have if n != target]
    if target in have and not wrong:
        rec.status, rec.note = "done", f"{target} (už měl)"
    else:
        fr = set_iv_tag(bot, fr, target, wrong, add=target not in have)
        rec.status, rec.note = "done", target + (f" (odebráno: {', '.join(wrong)})" if wrong else "")
    close_detail(bot, fr)


def tag_selected(bot, mem, sel, fr):
    c0 = sel[0][0]
    t0 = bot.long_press(c0["cx"], c0["cy"] + CELL_TAP_DY, f"podržet CP{c0['cp']}", fr=fr)
    n, fr = bot.wait_for(lambda f: tag_count(f.texts), 2.5, after=t0 + FRAME_LAG, label="multiselect")
    if n != 1:
        raise StepError(f"multiselect se nespustil (TAG {n})")
    for c, _ in sel[1:]:
        want = n + 1
        for _ in range(2):
            t0 = bot.tap(c["cx"], c["cy"] + SELECT_TAP_DY, f"vybrat CP{c['cp']}", fr=fr)
            _, fr = bot.wait_for(lambda f: (tag_count(f.texts) or 0) >= want, 2.0,
                                 after=t0 + FRAME_LAG, label="výběr")
            cnt = tag_count(fr.texts)
            if cnt == want:
                break
            if cnt is None or cnt > want:
                raise StepError(f"výběr nesedí (TAG {cnt}, čekal jsem {want})")
        else:
            raise StepError(f"CP{c['cp']} se nepodařilo vybrat")
        n = want
    tb = tag_button(fr.texts)
    if tb is None:
        raise StepError("nevidím tlačítko TAG")
    _, fr = bot.act((tb["cx"], tb["cy"]), f"TAG ({n})", lambda f: tag_list_on(f.texts),
                    timeout=2.5, fr=fr, tries=1)
    fr = pick_tag(bot, fr)
    d = find_text(fr.texts, [L["done"]], exact=True, region=(0.0, 0.7, 1.0, 0.95))
    if d is None:
        raise StepError("nevidím DONE")
    bot.act((d["cx"], d["cy"]), "DONE", lambda f: classify(f) == "box", timeout=3, fr=fr, tries=1)
    for _, r in sel:
        r.tagged = True
        mem.set_tagged(r.cp, r.name)
    log(f"   ✔ {n} ks má tag '{TAG_NAME}'")


def tag_recs(bot, book, mem, recs):
    cells, fr = read_grid(bot)
    book.assign(cells)
    sel = []
    for r in recs:
        hits = [c for c in cells if c["rec"] is r]
        if len(hits) == 1:
            sel.append((hits[0], r))
        else:
            r.tag_fails += 1   # teď ho v mřížce nevidím jednoznačně
    if not sel:
        return
    log(f"   označuji {len(sel)} ks tagem {TAG_NAME}")
    try:
        tag_selected(bot, mem, sel, fr)
    except StepError:
        for _, r in sel:
            r.tag_fails += 1
        raise


# ---------------------------- hlavní smyčka ---------------------------
def needs_work(run):
    for c in run:
        r = c["rec"]
        if r is None or r.status == "new":
            return True
        if r.action == "remove" and not r.tagged and not r.ambiguous and r.tag_fails < 2:
            return True
    return False


def handle_run(bot, book, mem, args, run, report):
    gids = sorted({c["rec"].gid for c in run if c["rec"] is not None})
    gid = gids[0] if gids else book.new_gid()
    for g in gids[1:]:
        for r in book.group(g):
            r.gid = gid
    for c in run:
        if c["rec"] is None:
            c["rec"] = Rec(c, gid)
            book.recs.append(c["rec"])
        c["rec"].gid = gid
    group = book.group(gid)
    if len(group) < 2:
        for r in group:
            r.status = "single"
        return
    for r in group:   # stejné CP i jméno -> nejde spolehlivě rozlišit, netaguje se
        r.ambiguous = sum(1 for o in group if o.cp == r.cp and names_ok(o.name, r.name)) > 1
        if r.status == "single":
            r.status = "new"

    for c in run:
        r = c["rec"]
        if r.status != "new":
            continue
        cached = None if (r.ambiguous or args.fresh) else mem.get_iv(r.sig)
        if cached:
            r.iv, r.types = cached
            r.cached, r.status = True, "done"
            book.progress += 1
            continue
        log(f"\n   měřím CP{r.cp} {r.name}")
        try:
            iv, types = measure(bot, c)
        except StepError:
            r.fails += 1
            if r.fails >= 2:
                r.status = "failed"
                log(f"   CP{r.cp}: nejde změřit, přeskakuji ho")
            raise
        r.types = types or r.types
        if iv is None:
            r.fails += 1
            log(f"   CP{r.cp}: IV se nepodařilo přečíst" + (", přeskakuji" if r.fails >= 2 else ", zkusím znovu"))
            if r.fails >= 2:
                r.status = "failed"
            continue
        r.iv, r.status = iv, "done"
        book.progress += 1
        report.measured += 1
        log(f"   CP{r.cp}: IV {'/'.join(map(str, iv))}")
        if not r.ambiguous:
            mem.set_iv(r.sig, iv, r.types)

    if decide_group(group):
        log("   pozor: ve várce jsou různé typy (jiný druh/forma) – rozhoduji zvlášť")
    todo = []
    for c in run:
        r = c["rec"]
        if r.action == "remove" and not r.tagged and not r.ambiguous and r.tag_fails < 2:
            if mem.is_tagged(r.cp, r.name):
                r.tagged = True   # už má tag z dřívějška (znovu by se odznačil)
            else:
                todo.append(r)
    report.show(book, gid)
    if todo:
        tag_recs(bot, book, mem, todo)
        book.progress += 1
        report.show(book, gid)


def process(bot, book, mem, args, report):
    """Projde box od aktuálního místa dolů až na konec."""
    while True:
        cells, fr = read_grid(bot)
        if classify(fr) != "box":
            raise StepError("nejsem v boxu")
        book.assign(cells)
        runs = make_runs(cells)
        work = next((r for r in runs if needs_work(r)), None)
        if work is None:
            if report.limit_reached(book) or not scroll_next(bot, cells):
                return
            continue
        if work[-1] is cells[-1] and work[0] is not cells[0]:
            # skupina může pokračovat pod okrajem -> nejdřív ji posunout nahoru
            if bring_to_top(bot, cells, work[0]):
                continue
        if len(work) >= 2 and all(c["rec"] is None for c in work) and report.limit_reached(book):
            return
        handle_run(bot, book, mem, args, work, report)


def process_all(bot, book2, mem, args, report):
    """2. část: projde celý box (bez filtru) a každého zařadí do IV tagu."""
    while True:
        cells, fr = read_grid(bot)
        if classify(fr) != "box":
            raise StepError("nejsem v boxu")
        book2.assign(cells)
        cell = next((c for c in cells if c["rec"] is None or c["rec"].status == "new"), None)
        if cell is None:
            if not scroll_next(bot, cells):
                return
            continue
        if cell["rec"] is None:
            cell["rec"] = Rec(cell, 0)
            book2.recs.append(cell["rec"])
        r = cell["rec"]
        try:
            categorize(bot, mem, cell, r, args)
        except StepError:
            r.fails += 1
            if r.fails >= 2:
                r.status, r.note = "failed", "nepovedlo se, přeskakuji"
                report.show_iv(r)
            raise
        book2.progress += 1
        report.show_iv(r)


def run(bot, book, book2, mem, args, report):
    fails, last_progress = 0, -1
    need_top, cleanup = True, False
    phase = 2 if args.only_iv else 1
    while True:
        try:
            ensure_app(bot)
            bot.mode = "duplicit" if phase == 1 else "all"
            ensure_box(bot)
            if need_top:
                if not bot.fresh_list:
                    scroll_to_top(bot)
                need_top = False
            bot.fresh_list = False
            if phase == 1:
                process(bot, book, mem, args, report)
                if book.outstanding() and not cleanup:
                    cleanup, need_top = True, True
                    log("\nDoznačuji kusy, které mezitím odjely z obrazovky...")
                    continue
                if not SORT_ALL or args.no_iv or report.limit_reached(book):
                    return
                phase, need_top = 2, True
                log("\n========== 2. část: celý box podle IV do tagů ==========")
                continue
            process_all(bot, book2, mem, args, report)
            return
        except (Fatal, KeyboardInterrupt):
            raise
        except Exception as e:
            progress = book.progress + book2.progress
            if progress != last_progress:
                fails, last_progress = 0, progress
            fails += 1
            d = bot.dump("chyba")
            log(f"\n!! {short_err(e)}")
            log(f"   (posledních pár snímků: {d})")
            if fails > MAX_FAILS:
                raise Fatal(f"{MAX_FAILS}× po sobě chyba bez pokroku, končím")
            if not session_alive(bot.d):
                reconnect(bot)
            if isinstance(e, LostPosition):
                need_top = True
            log("   Vracím se do boxu a pokračuji...")


def main():
    global LOG_FILE
    ap = argparse.ArgumentParser()
    ap.add_argument("--max-groups", type=int, default=0, help="projít jen prvních N várek")
    ap.add_argument("--fresh", action="store_true", help="IV z paměti nepoužívat, změřit znovu")
    ap.add_argument("--only-iv", action="store_true", help="jen 2. část: celý box do IV tagů")
    ap.add_argument("--no-iv", action="store_true", help="jen duplicity, bez 2. části")
    args = ap.parse_args()
    load_config()
    if not args.max_groups:
        args.max_groups = MAX_GROUPS

    run_dir = OUT_DIR / time.strftime("%Y%m%d_%H%M%S")
    (run_dir / "iv").mkdir(parents=True, exist_ok=True)
    LOG_FILE = run_dir / "log.txt"
    log(f"Horší kusy dostanou tag '{TAG_NAME}'" + (f", max. {args.max_groups} várek" if args.max_groups else ", celý box"))
    log(f"Výsledky a screenshoty: {run_dir}")

    mem = Memory(MEMORY_FILE)
    book = Book()
    book2 = Book()
    report = Report(run_dir, args.max_groups)
    log("Připojuji se k telefonu...")
    try:
        driver = connect()
    except Exception as e:
        log(f"\nNepodařilo se připojit k telefonu: {short_err(e)}")
        return 1
    bot = Bot(driver, run_dir)
    bot.wait_stream()
    rc = 0
    try:
        run(bot, book, book2, mem, args, report)
    except Fatal as e:
        log(f"\nKONEC: {e}")
        rc = 1
    except KeyboardInterrupt:
        log("\nPřerušeno (Ctrl+C / Stop).")
        rc = 130
    finally:
        try:
            report.save(book)
            report.save_iv(book2)
            report.summary(book)
            report.summary_iv(book2)
        finally:
            bot.stream.stop_ev.set()
            try:
                bot.d.quit()
            except Exception:
                pass
            SAVER.shutdown(wait=True)
    return rc


if __name__ == "__main__":
    sys.exit(main())
