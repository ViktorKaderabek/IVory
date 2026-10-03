#!/usr/bin/env python3
"""
PoGo Inventory Manager – jádro (bot), které ovládá iPhone přes Appium / WebDriverAgent.

Příprava (jednou za běh):
  otevře seznam tagů ve hře a ověří, že existují všechny tagy z nastavení. Chybějící
  založí (Add New Tag -> název -> barva -> potvrdit).

1. část – duplicity:
  1) odkudkoliv ve hře dojde do boxu (Poké Ball -> POKÉMON), do pole Search napíše
     SEARCH_QUERY a seřadí podle čísla
  2) jede box shora dolů a skupiny stejných Pokémonů pozná PODLE OBRÁZKU
  3) u každého změří IV z appraisalu (útok/obrana/HP)
  4) nejlepšího nechá, ostatním dá tag TAG_NAME (multiselect -> TAG)

2. část – celý box (bez hledání):
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
S POGO_EVENTS=1 posílá aplikaci i strojově čitelné události (řádky „@@{json}“),
s POGO_LIVE=1 ukládá poslední snímek obrazovky do ~/.pogo/live.jpg (náhled v aplikaci).
"""
import argparse
import difflib
import io
import json
import os
import re
import signal
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

import pokecalc

# ======================= KONFIGURACE ================================
APPIUM_URL = "http://127.0.0.1:4723"
UDID = ""                      # prázdné = první připojený iPhone
TEAM_ID = ""                   # prázdné = zjistí se z certifikátu „Apple Development“ v Klíčence
SIGNING_ID = "Apple Development"
BUNDLE_ID = "com.nianticlabs.pokemongo"
OUT_DIR = Path.home() / "Desktop" / "pogo_runs"
STATE_DIR = Path.home() / ".pogo"
CAL_FILE = STATE_DIR / "calibration.json"   # jak hra zobrazuje napsané hledání
MEMORY_FILE = STATE_DIR / "pamet.json"      # změřené IV a komu už dal tag
CONFIG_FILE = STATE_DIR / "config.json"     # nastavení z aplikace (přepíše hodnoty níže)
LIVE_FILE = STATE_DIR / "live.jpg"          # poslední snímek obrazovky pro náhled v aplikaci
BOX_FILE = STATE_DIR / "last_box.json"      # přečtený box pro aplikaci (rozsah IV, ukázky jmen)
MAX_GROUPS = 0                 # 0 = všechny skupiny duplicit

SEARCH_QUERY = "count & !legendary & !ultra beasts"   # co bot napíše do pole Search v boxu
TAG_NAME = "Removable"         # tag pro horší duplicity; když ve hře chybí, bot ho založí
KEEP_N = 1                     # kolik nejlepších z každé skupiny stejných Pokémonů nechat

# 2. část: po duplicitách projde CELÝ box (bez hledání) a každého zařadí podle IV do tagu.
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
FAST = True                    # rychlý režim: IV přečíst šipkou ▶ v appraisalu, tagovat hromadně
SEARCH_BATCH = 30              # kolik Pokémonů nejvýš v jednom hledání podle CP (délka hledání)
TAGGED_DAYS = 30               # jak dlouho si pamatuje, komu už dal tag

# Barvy tagů ve hře (pořadí jako v nabídce hry). RGB jsou jen přibližné: bot v dialogu
# najde kolečka s barvami a klepne na to, které je požadované barvě nejblíž.
TAG_PALETTE = {
    "blue": (60, 130, 230), "green": (70, 180, 100), "purple": (150, 95, 215), "yellow": (240, 200, 50),
    "red": (225, 70, 70), "orange": (240, 140, 50), "gray": (145, 150, 155), "black": (40, 40, 45),
}
COLOR_CZ = {"blue": "modrá", "green": "zelená", "purple": "fialová", "yellow": "žlutá", "red": "červená",
            "orange": "oranžová", "gray": "šedá", "black": "černá"}
TAG_COLOR = "red"              # barva tagu TAG_NAME, když ho bot zakládá
DEFAULT_IV_COLORS = ["yellow", "orange", "purple", "blue", "green", "gray", "black"]   # od nejlepšího
TAG_COLORS = {name: DEFAULT_IV_COLORS[i % len(DEFAULT_IV_COLORS)] for i, (_, name) in enumerate(IV_TAGS)}

# Kroky běhu (pořadí je vždy tohle): duplicity, IV tagy, PvP tagy, přejmenování
STEPS = ["duplicates", "iv", "pvp", "rename"]

# PvP tagy: kus s pořadím IV pro ligu do max_rank dostane tag ligy (1 = nejlepší ze 4096)
PVP = {
    "great": {"name": "Great League", "enabled": True, "max_rank": 100, "color": "blue"},
    "ultra": {"name": "Ultra League", "enabled": True, "max_rank": 100, "color": "yellow"},
    "master": {"name": "Master League", "enabled": True, "max_rank": 50, "color": "purple"},
}

# Přejmenování: kusy s IV v rozsahu dostanou jméno podle šablony (max. 12 znaků)
RENAME = {"min": 85, "max": 100, "template": None, "overwrite_custom": False, "skip_removable": True,
          "only_tag": ""}

# Texty v UI hry (pokud máš hru v jiném jazyce, přepiš)
L = {
    "attack": "Attack", "defense": "Defense", "hp": "HP",
    "appraise": "APPRAISE", "number": "NUMBER", "done": "DONE",
    "select_all": "SELECT ALL", "see_more": "See More", "mixed": "Mixed",
    "add_new_tag": "Add New Tag", "enter_tag_name": "Enter tag name",
    "menu": ["POKEDEX", "POKEMON", "SHOP", "ITEMS", "BATTLE"],
    "sort_options": ["RECENT", "FAVORITE", "NUMBER", "HP", "NAME", "COMBAT POWER"],
    # bezpečná tlačítka pro zavření neznámých oken
    "safe_close": ["OK", "CLOSE", "DISMISS", "NOT NOW", "LATER", "NO THANKS", "CANCEL", "NO",
                   "I'M A PASSENGER", "RETRY", "TRY AGAIN"],
    # potvrzení dialogu pro nový tag (hra / systém v češtině)
    "confirm": ["CREATE", "SAVE", "ADD", "OK", "DONE", "HOTOVO", "ULOŽIT", "VYTVOŘIT", "PŘIDAT"],
    # klávesa Enter na klávesnici iPhonu (podle jazyka a pole)
    "return_keys": ["search", "done", "go", "return", "enter", "hledat", "hotovo", "přejít", "zadat"],
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
BAR_QUICK = 0.1                # stačí, když bary stojí X s a IV přesně sedí na CP a HP kusu

# Rychlost a odolnost
MJPEG_PORT = 9100              # Appium ho z telefonu přesměruje na localhost
MJPEG_QUALITY = 60
MJPEG_FPS = 30                 # víc snímků = bot dřív pozná, že je tu další Pokémon
MJPEG_SCALE = 75               # % rozlišení streamu (OCR to čte bez problému)
USE_STREAM = os.environ.get("POGO_NO_STREAM") != "1"
EVENTS = os.environ.get("POGO_EVENTS") == "1"   # události pro aplikaci (řádky „@@{json}“)
LIVE = os.environ.get("POGO_LIVE") == "1"       # náhled obrazovky pro aplikaci (LIVE_FILE)
FRAME_LAG = 0.12               # snímky starší než klepnutí + X s se za výsledek neberou
LONG_PRESS_SEC = 0.9
NAV_TIMEOUT = 90               # s na cestu do boxu, pak restart hry
MAX_FAILS = 12                 # chyb po sobě bez pokroku, pak konec
TAG_SCROLL_MAX = 12
RING = 30                      # kolik posledních snímků uložit, když se něco pokazí
# ====================================================================

SAVER = ThreadPoolExecutor(max_workers=2)   # zápis obrázků neblokuje klikání
READER = ThreadPoolExecutor(max_workers=1)  # přesné OCR přečteného kusu běží, zatímco jde šipka ▶ dál
LOG_FILE = None
HOMOGLYPHS = str.maketrans("сСрРоОеЕаАхХ", "cCpPoOeEaAxX")   # OCR občas vrátí azbuku
TYPES = {"normal", "fire", "water", "grass", "electric", "ice", "fighting", "poison", "ground",
         "flying", "psychic", "bug", "rock", "ghost", "dragon", "dark", "steel", "fairy"}
CP_RE = re.compile(r"^cp?(\d{2,5})$")              # OCR občas ztratí P („c1272“)
TAG_BTN_RE = re.compile(r"^tag\s*\(\s*([0-9ilo|]{1,3})\s*\)?$")    # OCR čte 0 i jako O, závorka chybí
TRANSFER_BTN_RE = re.compile(r"^transfer\s*\(\s*[0-9ilo|]{1,3}\s*\)$")
BOX_COUNT_RE = re.compile(r"^(\d{1,4})\s*/\s*\d{2,4}$")
SEARCH_COUNT_RE = re.compile(r"^\D{0,2}\(([0-9oil|]{1,4})\)$")   # „🔍(12)“ – lupa se čte jako Q
PLAIN_NAME = re.compile(r"^[a-z][a-z'.\-]{2,}$")
BOX_STATES = ("box", "box_tags", "box_other", "search_page")
STATE_NAMES = {   # obrazovka: (česky, anglicky)
    "transfer_dialog": ("dialog Transfer (bot ho zruší)", "Transfer dialog (the bot cancels it)"),
    "confirm_dialog": ("potvrzovací dialog (bot dá Ne)", "confirmation dialog (the bot says No)"),
    "tag_list": ("výběr tagů", "tag picker"), "tag_dialog": ("zakládání tagu", "new tag dialog"),
    "multiselect": ("výběr více Pokémonů", "multi-select"), "appraisal": ("hodnocení IV (appraisal)", "IV appraisal"),
    "detail_menu": ("menu Pokémona", "Pokémon menu"), "detail": ("detail Pokémona", "Pokémon detail"),
    "sort_menu": ("řazení", "sort menu"), "box": ("inventář", "storage"),
    "box_tags": ("inventář – záložka Tagy", "storage – Tags tab"), "search_page": ("hledání v inventáři", "storage search"),
    "box_other": ("inventář (žádní Pokémoni)", "storage (no Pokémon)"), "main_menu": ("hlavní menu", "main menu"),
    "map": ("mapa", "map"), "unknown": ("neznámá obrazovka", "unknown screen"),
}


def state_name(st):
    cs, en = STATE_NAMES.get(st, (st, st))
    return T(cs, en)


class StepError(Exception):
    """Krok se nepovedl – bot se vrátí do boxu a pokračuje."""


class Danger(StepError):
    """Klepnutí by mohlo trefit nebezpečné tlačítko – neprovedeno."""


class LostPosition(StepError):
    """Při posouvání se ztratilo místo v boxu – projede se znovu shora."""


class TagCreated(StepError):
    """Tag se právě založil – výběr tagů se zavře bez uložení a otevře znovu (není to chyba)."""


class NeedTop(StepError):
    """Další krok potřebuje seznam od začátku – inventář se zavře a otevře znovu (není to chyba)."""


class NotInSearch(StepError):
    """Pokémon ve výsledcích hledání podle CP není (CP se nejspíš přečetlo špatně)."""


class NoNavigation(StepError):
    """V appraisalu nejde přejít na dalšího Pokémona – rychlý režim nejde, použije se pomalý."""


class Fatal(Exception):
    """Nedá se pokračovat (tag nejde založit, hledání nejde zadat, spojení...)."""


class NotAuthorized(Exception):
    """iPhone nepovolil ovládání (vypnutá UI Automation, nebo zaseklý WebDriverAgent)."""


LANG = "en"                    # jazyk výpisu: "en" / "cs" (config.json „language“, nastavuje aplikace)


def T(cs, en):
    """Text v jazyce výpisu: T("česky", "English")."""
    return cs if LANG == "cs" else en


def log(msg=""):
    print(msg, flush=True)
    if LOG_FILE:
        try:
            with open(LOG_FILE, "a") as f:
                f.write(f"{time.strftime('%H:%M:%S')} {msg}\n")
        except OSError:
            pass


def emit(kind, **data):
    """Událost pro aplikaci – z ní kreslí přehledný průběh. Do log.txt nejde."""
    if EVENTS:
        print("@@" + json.dumps({"e": kind, **data}, ensure_ascii=False), flush=True)


def step(text):
    """Co bot právě dělá (velký nápis v aplikaci)."""
    emit("step", text=text)


def pokemon_count(n):
    if LANG != "cs":
        return f"{n} Pokémon"
    return f"{n} Pokémon" if n == 1 else f"{n} Pokémoni" if 2 <= n <= 4 else f"{n} Pokémonů"


def pct_text(n):
    """Procenta ve výpisu: česky „87 %“, anglicky „87%“."""
    return T(f"{n} %", f"{n}%")


def color_word(c):
    """Název barvy tagu ve výpisu."""
    return T(COLOR_CZ.get(c, c), c)


def color_name(value, default):
    v = str(value or "").strip().lower()
    v = {"grey": "gray", "violet": "purple"}.get(v, v)
    return v if v in TAG_PALETTE else default


def tag_color(name):
    """Barva, kterou má tag dostat, když ho bot zakládá."""
    if name == TAG_NAME:
        return TAG_COLOR
    for lg in PVP.values():
        if lg["name"] == name:
            return lg["color"]
    return TAG_COLORS.get(name)


def league_tags():
    """Názvy tagů zapnutých PvP lig."""
    return [lg["name"] for lg in PVP.values() if lg["enabled"]]


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
    if PLAIN_NAME.match(na) and PLAIN_NAME.match(nb) and pokecalc.is_species_name(na) and \
            pokecalc.is_species_name(nb) and difflib.SequenceMatcher(None, na, nb).ratio() < 0.75:
        return False   # dvě různá jména druhů (přezdívka jako „Kytka“ tu nerozhoduje)
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
    """Stránka hledání v boxu: návrhy hledání pod polem Search (klávesnice viz classify)."""
    return bool(find_text(tx, [L["see_more"], "recommended", "recent search", "saved search"]))


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


def tag_dialog_on(fr):
    """Dialog pro založení tagu: pole „Enter tag name“, nebo řada koleček s barvami."""
    return bool(find_text(fr.texts, [L["enter_tag_name"]]) or find_swatches(fr.img))


def classify(fr):
    tx = fr.texts
    if transfer_dialog(tx):
        return "transfer_dialog"
    if confirm_dialog(tx):
        return "confirm_dialog"
    if find_text(tx, [L["enter_tag_name"]]):
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
            return "search_page"   # pole Search má klávesnici
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


def bar_matches(shown, want):
    """Je v poli Search to hledání, které bot napsal? Dlouhý text pole zkrátí (zleva i zprava),
    takže stačí, když souvislý kus textu sedí s napsaným hledáním."""
    if keys_match(shown, want):
        return True
    if not shown or not want or len(shown) < max(6, len(want) // 2):
        return False
    if shown in want:
        return True
    covered = sum(b.size for b in difflib.SequenceMatcher(None, shown, want, autojunk=False).get_matching_blocks())
    return covered >= 0.85 * len(shown)


def return_key(tx):
    """Klávesa Enter / Hledat na klávesnici iPhonu (vpravo dole)."""
    keys = {alnum(w) for w in L["return_keys"]}
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
    """Nahoře tmavě tyrkysová lišta (výběr více Pokémonů)."""
    top = crop_norm(img, 0.25, 0.06, 0.95, 0.12).astype(int)
    return top.size > 0 and float(((top.sum(axis=2) < 420) & (top[..., 2] >= top[..., 0]) &
                                   (top[..., 1] >= top[..., 0])).mean()) > 0.9


def multiselect_look(img):
    """Výběr více Pokémonů podle barev, když OCR nepřečte texty tlačítek: tyrkysová lišta nahoře
    a zelené tlačítko TAG dole (na skutečných snímcích 100 % a 98 %, jinde nejvýš 47 % a 31 %)."""
    btn = crop_norm(img, 0.2, 0.845, 0.8, 0.875).astype(int)
    return btn.size > 0 and teal_top(img) and \
        float(((btn[..., 1] > btn[..., 0] + 40) & (btn[..., 1] > btn[..., 2] + 5)).mean()) > 0.8


def multiselect_on(tx):
    """Výběr více Pokémonů: dole tlačítka TAG (n) a TRANSFER (n); starší verze hry má nahoře SELECT ALL."""
    if find_text(tx, [L["select_all"]], region=(0.3, 0.0, 1.0, 0.2)):
        return True
    return tag_button(tx) is not None or find_re(tx, TRANSFER_BTN_RE, region=(0.0, 0.8, 1.0, 1.0)) is not None


def box_count(tx):
    """Kolik Pokémonů hra v boxu ukazuje (číslo pod POKÉMON v hlavičce, např. 433/725)."""
    lab = find_text(tx, ["pokemon"], region=(0.0, 0.0, 1.0, 0.16))
    if lab is None:
        return None
    for t in tx:
        m = BOX_COUNT_RE.match(re.sub(r"\s", "", t["text"]))
        if m and abs(t["cx"] - lab["cx"]) < 0.12 and 0 < t["cy"] - lab["cy"] < 0.06:
            return int(m.group(1))
    return None


def search_count(tx):
    """Kolik Pokémonů hledání našlo: při hledání je pod POKÉMON v hlavičce lupa a „(12)“ místo 433/725."""
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
        self.mode = "duplicit"            # "duplicit" = napsané hledání, "all" = celý box bez hledání,
        #                                   "cp" = hledání podle CP (bot.query) pro hromadné tagování
        self.query = None                 # hledání v režimu „cp“ (cp2260,cp2268,…)
        self.typed_query = None           # co bot naposledy napsal do pole Search
        self.bars_frame = None            # snímek, ze kterého read_appraisal přečetl bary
        self.bars_rec = None              # kus z toho snímku, když ho rychlé potvrzení už přečetlo
        self.select_all_ok = True         # SELECT ALL ve výsledcích hledání (vypne se, když počet nesedí)
        cal = cal_load().get("search") or {}
        # jak hra ukazuje napsané hledání v poli Search (zjistí se při prvním hledání)
        self.filter_key = cal.get("key") if cal.get("query") == SEARCH_QUERY else filter_key(SEARCH_QUERY)
        self.dumps = 0
        self.tags_checked = False         # příprava: tagy z nastavení ve hře existují
        self.tag_checks = 0
        self.tag_attempts = {}            # kolikrát se zkoušel založit který tag
        self.broken_tags = set()          # tagy, které se nepodařilo založit
        self.created_tags = []
        self.fast = FAST                  # rychlý režim (šipka ▶ v appraisalu, hromadné tagování)
        self.tag_counts = {}              # panel „Tagy v inventáři“: tag -> počet kusů
        self.box_total = 0
        self.progress = 0                 # přečtení / otagovaní Pokémoni (kvůli počítání chyb bez pokroku)
        # o kolik hra posune seznam na jednotku tahu prstem (iPhone asi 1,6×) – měří se při každém posunu;
        # výchozí odhad je spíš vyšší: menší posun nevadí, přejetí stojí opravu
        self.scroll_gain = min(3.0, max(0.6, float(cal_load().get("scroll_gain", 1.5))))
        self.last_shift = None            # o kolik se seznam posunul při posledním scroll_by
        self.shown_count = None           # kolik Pokémonů ukazuje hra v hlavičce boxu
        self.live_raw = None              # poslední snímek ze screenshotu (když nejede stream)
        self.refresh()
        if LIVE:
            threading.Thread(target=self._live_loop, daemon=True).start()

    def refresh(self):
        size = self.d.get_window_size()
        self.W, self.H = size["width"], size["height"]

    def _live_loop(self):
        """Pro aplikaci: každou půlsekundu uloží nejnovější snímek obrazovky do LIVE_FILE."""
        last = None
        while not self.stream.stop_ev.is_set():
            jpeg, t, _ = self.stream.latest()
            if jpeg is None or time.time() - t > 2.0:
                jpeg, t = self.live_raw or (None, None)
            if jpeg is not None and t != last:
                try:
                    tmp = LIVE_FILE.with_name(LIVE_FILE.name + ".tmp")
                    tmp.write_bytes(jpeg)
                    tmp.replace(LIVE_FILE)
                    last = t
                except OSError:
                    pass
            self.stream.stop_ev.wait(0.5)

    def streaming(self):
        return self.stream_misses < 3 or self.stream.fresh()

    def wait_stream(self, sec=6):
        end = time.time() + sec
        while USE_STREAM and time.time() < end:
            if self.stream.fresh():
                log(T("Obraz z iPhonu: video stream (rychlé)", "iPhone screen: video stream (fast)"))
                return True
            time.sleep(0.1)
        self.stream_misses = 99
        log(T("Obraz z iPhonu: video stream nejede, beru screenshoty (pomalejší, ale funguje)",
              "iPhone screen: the video stream isn't working, using screenshots (slower, but it works)"))
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
                log(T("   (video stream neposílá snímky, přepínám na screenshoty)",
                      "   (the video stream sends no frames, switching to screenshots)"))
        png = self.d.get_screenshot_as_png()
        img = np.array(Image.open(io.BytesIO(png)).convert("RGB"))
        fr = Frame(img, png, time.time())
        self.live_raw = (png, fr.t)
        return fr

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
            raise Danger(T("je otevřený dialog TRANSFER – kromě CANCEL nic neklikám",
                           "the TRANSFER dialog is open – tapping nothing but CANCEL"))
        if y > 0.89 and multiselect_look(fr.img):
            raise Danger(T(f"'{label}' na ({x:.2f}, {y:.2f}): ve výběru více Pokémonů je dole TRANSFER – NEKLIKÁM",
                           f"'{label}' at ({x:.2f}, {y:.2f}): multi-select has TRANSFER at the bottom – NOT TAPPING"))
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
                raise Danger(T(f"'{label}' na ({x:.2f}, {y:.2f}) je moc blízko tlačítka '{s}' – NEKLIKÁM",
                               f"'{label}' at ({x:.2f}, {y:.2f}) is too close to the '{s}' button – NOT TAPPING"))
        return fr

    def tap(self, x, y, label, fr=None, overlay=False):
        fr = self.guard(x, y, label, fr, overlay)
        self.remember("tap", label, fr, (x, y))
        log(T(f"   klepnutí: {label} ({x:.2f}, {y:.2f})", f"   tap: {label} ({x:.2f}, {y:.2f})"))
        self.d.execute_script("mobile: tap", {"x": int(x * self.W), "y": int(y * self.H)})
        return time.time()

    def long_press(self, x, y, label, fr=None, sec=LONG_PRESS_SEC):
        fr = self.guard(x, y, label, fr)
        self.remember("hold", label, fr, (x, y))
        log(T(f"   podržení {sec:.1f}s: {label} ({x:.2f}, {y:.2f})", f"   hold {sec:.1f}s: {label} ({x:.2f}, {y:.2f})"))
        self.d.execute_script("mobile: touchAndHold",
                              {"x": int(x * self.W), "y": int(y * self.H), "duration": sec})
        return time.time()

    def type_text(self, text):
        """Napíše text do pole, které má právě klávesnici (WebDriverAgent /wda/keys)."""
        log(T(f"   psaní: {text!r}", f"   typing: {text!r}"))
        try:
            if self.d.command_executor.get_command("pogoKeys") is None:
                self.d.command_executor.add_command("pogoKeys", "POST", "/session/$sessionId/keys")
            self.d.execute("pogoKeys", {"value": list(text)})
        except Exception as e:
            log(T(f"   (psaní přes keys nešlo: {short_err(e)}, zkouším mobile: keys)",
                  f"   (typing via keys failed: {short_err(e)}, trying mobile: keys)"))
            self.d.execute_script("mobile: keys", {"keys": [text]})

    def drag(self, a, b, label, ms=400, hold=0.3, fr=None):
        """Tažení prstem; s hold na konci podrží, aby seznam nedojel setrvačností."""
        from selenium.webdriver.common.actions import interaction
        from selenium.webdriver.common.actions.action_builder import ActionBuilder
        from selenium.webdriver.common.actions.pointer_input import PointerInput

        fr = self.guard(a[0], a[1], label, fr)
        self.remember("drag", label, fr, a)
        log(T(f"   tažení: {label}", f"   drag: {label}"))
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
        raise StepError(T(f"'{label}': klepnutí nemělo očekávaný efekt", f"'{label}': the tap had no effect"))

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
    global UDID, TEAM_ID, SIGNING_ID, SEARCH_QUERY, TAG_NAME, TAG_COLOR, TAG_COLORS, KEEP_N, IV_TAGS, \
        RECHECK_TAGGED, MAX_GROUPS, FAST, LANG
    try:
        c = json.loads(CONFIG_FILE.read_text())
    except FileNotFoundError:
        return
    except Exception as e:
        log(T(f"Nastavení {CONFIG_FILE} nejde přečíst ({e}), beru výchozí hodnoty",
              f"Can't read the settings in {CONFIG_FILE} ({e}), using the defaults"))
        return
    LANG = "cs" if str(c.get("language") or "").strip().lower() == "cs" else "en"
    UDID = str(c.get("udid") or "").strip()
    TEAM_ID = str(c.get("team_id") or "").strip()
    SIGNING_ID = c.get("signing_id") or SIGNING_ID
    SEARCH_QUERY = " ".join(str(c.get("search_query") or "").split()) or SEARCH_QUERY
    TAG_NAME = str(c.get("remove_tag") or "").strip() or TAG_NAME
    TAG_COLOR = color_name(c.get("remove_tag_color"), TAG_COLOR)
    KEEP_N = max(1, int(c.get("keep_best", KEEP_N)))
    tags, seen = [], set()
    for t in c.get("iv_tags") or []:
        name = str(t.get("name", "")).strip()
        if not name or alnum(name) in seen:
            continue                      # bez názvu nebo dvakrát – nepoužije se
        seen.add(alnum(name))
        tags.append((min(100, max(0, int(t.get("min", 0)))), name, t.get("color")))
    if tags:
        tags.sort(key=lambda t: -t[0])
        IV_TAGS = [(m, n) for m, n, _ in tags]
        TAG_COLORS = {n: color_name(col, DEFAULT_IV_COLORS[min(i, len(DEFAULT_IV_COLORS) - 1)])
                      for i, (_, n, col) in enumerate(tags)}
    RECHECK_TAGGED = bool(c.get("recheck_tagged", RECHECK_TAGGED))
    FAST = bool(c.get("fast_mode", FAST))
    for key, lg in (c.get("pvp") or {}).items():
        if key in PVP and isinstance(lg, dict):
            PVP[key]["enabled"] = bool(lg.get("enabled", PVP[key]["enabled"]))
            PVP[key]["max_rank"] = max(1, min(4096, int(lg.get("max_rank", PVP[key]["max_rank"]))))
            PVP[key]["color"] = color_name(lg.get("color"), PVP[key]["color"])
            PVP[key]["name"] = str(lg.get("name") or PVP[key]["name"]).strip() or PVP[key]["name"]
    rn = c.get("rename") or {}
    RENAME["min"] = max(0, min(100, int(rn.get("min", RENAME["min"]))))
    RENAME["max"] = max(RENAME["min"], min(100, int(rn.get("max", RENAME["max"]))))
    if isinstance(rn.get("template"), list) and rn["template"]:
        RENAME["template"] = [t for t in rn["template"] if isinstance(t, dict) and t.get("k")]
    for k in ("overwrite_custom", "skip_removable"):
        if k in rn:
            RENAME[k] = bool(rn[k])
    RENAME["only_tag"] = str(rn.get("only_tag") or "").strip()
    MAX_GROUPS = int(c.get("max_groups", MAX_GROUPS))


def _run(cmd):
    import subprocess
    try:
        return subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=20).stdout
    except Exception:
        return ""


def list_devices():
    """Připojené iPhony (ne simulátory): [(jméno, iOS, UDID)]."""
    out = _run("xcrun xctrace list devices 2>/dev/null")
    section, found = "", []
    for line in out.splitlines():
        if line.startswith("=="):
            section = line
            continue
        m = re.match(r"^(.*) \(([\d.]+)\) \(([0-9A-Fa-f-]{20,})\)$", line.strip())
        if m and "Simulator" not in section and "Simulator" not in line:
            found.append((m.group(1), m.group(2), m.group(3)))
    return found


def detect_udid():
    """UDID prvního připojeného iPhonu."""
    devs = list_devices()
    if not devs:
        raise Fatal(T("Nevidím připojený iPhone. Připoj ho kabelem, odemkni a potvrď „Důvěřovat tomuto počítači“.",
                      "No iPhone connected. Connect it with a cable, unlock it and tap “Trust This Computer”."))
    return devs[0][2]


def detect_team_id():
    """Apple Team ID z certifikátu „Apple Development“ v Klíčence (pole OU)."""
    out = _run("security find-certificate -c 'Apple Development' -p 2>/dev/null | openssl x509 -noout -subject 2>/dev/null")
    m = re.search(r"OU\s*=\s*([A-Z0-9]{10})", out)
    return m.group(1) if m else ""


def connect(udid, fresh_wda=False):
    from appium import webdriver
    from appium.options.ios import XCUITestOptions

    o = XCUITestOptions()
    o.platform_name = "iOS"
    o.udid = udid
    o.bundle_id = BUNDLE_ID
    o.automation_name = "XCUITest"
    o.no_reset = True
    o.new_command_timeout = 600
    team = TEAM_ID or detect_team_id()
    if team:
        o.xcode_org_id = team
        o.xcode_signing_id = SIGNING_ID
    else:
        log(T("   (Apple Team ID nevím – když se WebDriverAgent nepodepíše, doplň ho v nastavení)",
              "   (Apple Team ID unknown – if WebDriverAgent fails to sign, fill it in the settings)"))
    o.set_capability("waitForIdleTimeout", 0)
    o.set_capability("wdaLaunchTimeout", 240000)   # první sestavení WebDriverAgentu trvá i pár minut
    if fresh_wda:
        o.set_capability("useNewWDA", True)        # starý WebDriverAgent z iPhonu smazat a spustit nový
    driver = webdriver.Remote(APPIUM_URL, options=o)
    settings = {"waitForIdleTimeout": 0, "animationCoolOffTimeout": 0,
                "mjpegServerScreenshotQuality": MJPEG_QUALITY, "mjpegServerFramerate": MJPEG_FPS,
                "mjpegScalingFactor": MJPEG_SCALE}
    for k, v in settings.items():
        try:
            driver.update_settings({k: v})
        except Exception as e:
            log(T(f"   (nastavení {k} se nepovedlo: {short_err(e)})", f"   (setting {k} failed: {short_err(e)})"))
    try:
        driver.get_window_size()       # smí bot iPhone opravdu ovládat?
    except Exception as e:
        if "not authorized" in str(e).lower():
            try:
                driver.quit()
            except Exception:
                pass
            raise NotAuthorized(short_err(e))
        raise
    return driver


def open_session(udid):
    """Spojení s iPhonem. Když iPhone ovládání odmítne (typicky WebDriverAgent zůstal viset
    z minulého běhu), spustí WebDriverAgent načisto a zkusí to znovu."""
    try:
        return connect(udid)
    except NotAuthorized:
        log(T("   iPhone ovládání odmítl („Not authorized for performing UI testing actions“).",
              "   The iPhone refused control (“Not authorized for performing UI testing actions”)."))
        log(T("   Nejčastěji na něm zůstal viset WebDriverAgent z minula – spouštím ho načisto (chvíli to trvá)...",
              "   Usually a WebDriverAgent from last time is stuck on it – starting it fresh (takes a while)..."))
        step(T("Spouštím WebDriverAgent na iPhonu načisto (může to trvat i 2 minuty)",
               "Starting WebDriverAgent on the iPhone fresh (can take up to 2 minutes)"))
        try:
            return connect(udid, fresh_wda=True)
        except NotAuthorized:
            raise Fatal(T("iPhone nepovolil ovládání. Odemkni ho a na iPhonu zapni Nastavení → Vývojář → "
                          "„Enable UI Automation“ (automatizace UI). Pak spusť znovu.",
                          "The iPhone doesn't allow control. Unlock it and turn on Settings → Developer → "
                          "“Enable UI Automation”. Then run again."))


def explain_connect_error(e):
    """Srozumitelná věta k chybě při připojování."""
    low = str(e).lower()
    if any(w in low for w in ("connection refused", "max retries exceeded", "failed to establish", "newconnectionerror")):
        return T("Appium server neběží, nedá se k němu připojit. Spusť to znovu; podrobnosti jsou v ~/.pogo/appium.log.",
                 "The Appium server isn't running. Run again; details are in ~/.pogo/appium.log.")
    if "developer mode" in low:
        return T("Na iPhonu zapni Režim pro vývojáře (Nastavení → Soukromí a zabezpečení → Režim pro vývojáře).",
                 "Turn on Developer Mode on the iPhone (Settings → Privacy & Security → Developer Mode).")
    if any(w in low for w in ("xcodebuild failed", "code 65", "signing", "provisioning", "certificate")):
        return T("Nepodařilo se sestavit nebo podepsat WebDriverAgent (pomocnou aplikaci, přes kterou bot ovládá iPhone). "
                 "Zkontroluj Apple Team ID v nastavení a účet v Xcode (Settings → Accounts). Na iPhonu potvrď důvěru "
                 "vývojáři: Nastavení → Obecné → Správa VPN a zařízení.",
                 "Couldn't build or sign WebDriverAgent (the helper app the bot controls the iPhone with). "
                 "Check the Apple Team ID in the settings and your account in Xcode (Settings → Accounts). On the iPhone, "
                 "trust the developer: Settings → General → VPN & Device Management.")
    if "unknown device" in low or ("udid" in low and "not" in low) or "could not find a device" in low:
        return T("iPhone se nenašel. Připoj ho kabelem, odemkni, potvrď „Důvěřovat“ a zkontroluj iPhone v nastavení aplikace.",
                 "iPhone not found. Connect it with a cable, unlock it, tap “Trust” and check the iPhone in the app settings.")
    if "locked" in low or "passcode" in low:
        return T("iPhone je zamčený. Odemkni ho a spusť znovu.", "The iPhone is locked. Unlock it and run again.")
    return T(f"Nepodařilo se připojit k iPhonu: {short_err(e)}", f"Couldn't connect to the iPhone: {short_err(e)}")


def session_alive(driver):
    try:
        driver.get_window_size()
        return True
    except Exception:
        return False


def reconnect(bot):
    log(T("   Spojení s telefonem spadlo, připojuji znovu...", "   Lost the connection to the phone, reconnecting..."))
    step(T("Spojení s iPhonem spadlo – připojuji znovu", "Lost the connection to the iPhone – reconnecting"))
    try:
        bot.d.quit()
    except Exception:
        pass
    for _ in range(3):
        try:
            bot.d = open_session(bot.udid)
            bot.refresh()
            return
        except Fatal:
            raise
        except Exception as e:
            log(T(f"   nepovedlo se ({short_err(e)}), zkusím znovu za 5 s", f"   failed ({short_err(e)}), retrying in 5 s"))
            time.sleep(5)
    raise Fatal(T("Nepodařilo se znovu připojit k iPhonu. Je odemčený a připojený kabelem?",
                  "Couldn't reconnect to the iPhone. Is it unlocked and connected with a cable?"))


def ensure_app(bot):
    """Telefon odemčený a hra v popředí. Vrací True, když musel něco udělat."""
    acted = False
    try:
        if bot.d.is_locked():
            log(T("   Telefon je zamčený – zkouším odemknout (s kódem ho odemkni ručně, počkám)",
                  "   The phone is locked – trying to unlock it (with a passcode, unlock it yourself, I'll wait)"))
            emit("problem", text=T("iPhone je zamčený – odemkni ho, bot počká a pak pokračuje.",
                                   "The iPhone is locked – unlock it, the bot waits and then continues."))
            try:
                bot.d.unlock()
            except Exception:
                pass
            end = time.time() + 600
            while bot.d.is_locked() and time.time() < end:
                time.sleep(2)
            acted = True
        if bot.d.query_app_state(BUNDLE_ID) != 4:   # 4 = běží v popředí
            log(T("   Pokémon GO není v popředí – přepínám do něj", "   Pokémon GO isn't in front – switching to it"))
            bot.d.activate_app(BUNDLE_ID)
            time.sleep(2)
            acted = True
    except Exception as e:
        log(T(f"   (stav aplikace nezjištěn: {short_err(e)})", f"   (app state unknown: {short_err(e)})"))
    return acted


def restart_game(bot):
    log(T("   Restartuji Pokémon GO...", "   Restarting Pokémon GO..."))
    step(T("Restartuji Pokémon GO", "Restarting Pokémon GO"))
    emit("problem", text=T("Hra se zasekla – restartuji ji a pokračuji.", "The game got stuck – restarting it and continuing."))
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
            log(T("   hra je načtená", "   the game is loaded"))
            return
        t = safe_button(fr.texts)
        if t:
            try:
                bot.tap(t["cx"], t["cy"], T(f"zavřít okno: {t['text']}", f"close window: {t['text']}"), fr=fr)
            except StepError:
                pass
    log(T("   hra se po restartu nenačetla do mapy, zkusím pokračovat",
          "   the game didn't load to the map after the restart, trying to continue"))


# ---------------------------- cesta do boxu -------------------------
def cp_filter_ok(tx, query):
    """Je v boxu hledání podle CP query? Pole Search dlouhý seznam CP zkrátí a OCR ho čte s chybami
    („ср3а0“), proto stačí, když většina čísel v poli je ze seznamu, nebo když všechny buňky
    v mřížce mají CP ze seznamu."""
    cps = {int(x) for x in re.findall(r"cp(\d+)", query)}
    nums = [int(n) for n in re.findall(r"\d{2,5}", norm(search_bar_text(tx)))]
    if len(nums) >= 2 and sum(n in cps for n in nums) >= 0.6 * len(nums):
        return True
    cells = complete_cells(tx)
    return bool(cells) and all(c["cp"] in cps for c in cells)


def filter_state(bot, tx):
    """none = v poli Search nic není, ok = je tam hledání, které má být, other = jiné hledání.
    Hledání podle CP si jsou podobná (pole dlouhý text zkrátí), proto platí jen to, které bot
    právě napsal."""
    k = filter_key(search_bar_text(tx))
    if k in ("", "search"):
        return "none"
    if bot.mode == "cp":
        ok = bot.typed_query == bot.query and (bar_matches(k, filter_key(bot.query)) or cp_filter_ok(tx, bot.query))
        return "ok" if ok else "other"
    if bot.typed_query not in (None, SEARCH_QUERY):
        return "other"                     # v poli je ještě hledání podle CP z tagování
    return "ok" if bar_matches(k, bot.filter_key) or bar_matches(k, filter_key(SEARCH_QUERY)) else "other"


def stale_search(bot, tx):
    """Je zadané hledání, které teď není potřeba? V hlavičce je počet výsledků „(n)“, nebo v poli
    Search je hledání, které bot napsal dřív."""
    if search_count(tx) is not None:
        return True
    k = filter_key(search_bar_text(tx))
    return k not in ("", "search") and (bool(re.match(r"cp\d", k)) or any(
        q and bar_matches(k, filter_key(q)) for q in (bot.typed_query, SEARCH_QUERY)))


def clear_search_field(bot, fr):
    """Smaže text, který už v poli Search je: křížek vpravo v poli, jinak klávesa Delete."""
    empty = lambda f: filter_key(search_bar_text(f.texts)) in ("", "search")
    try:
        _, fr = bot.act(P_SEARCH_CLEAR, T("smazat pole Search", "clear the Search field"), empty, timeout=1.5, fr=fr, tries=1)
        return fr
    except StepError:
        pass
    bot.type_text("\b" * (len(search_bar_text(bot.frame().texts)) + 5))
    ok, fr = bot.wait_for(empty, 2.0, label="pole Search smazané")
    if not ok:
        raise StepError(T("v poli Search zůstal starý text a nejde smazat", "the Search field keeps old text that can't be cleared"))
    return fr


def apply_search(bot, fr, attempt):
    """Stránka hledání je otevřená: napíše hledání (SEARCH_QUERY, v režimu „cp“ bot.query) do pole
    Search a potvrdí ho Enterem."""
    q = bot.query if bot.mode == "cp" else SEARCH_QUERY
    shown_q = q if len(q) <= 60 else q[:57] + "…"
    if attempt > 6:
        raise Fatal(T(f"Hledání „{shown_q}“ se nedaří zadat. Zkus ho napsat ve hře ručně; když tam funguje, "
                      f"pošli složku s chybou z výsledků.",
                      f"Can't enter the search “{shown_q}”. Try typing it in the game yourself; if it works there, "
                      f"send the error folder from the results."))
    want = filter_key(q)
    step(T(f"Píšu do hledání: {shown_q}", f"Typing the search: {shown_q}"))
    if not keyboard_on(fr.texts):
        _, fr = bot.act(P_SEARCH_BAR, T("pole Search", "Search field"), lambda f: keyboard_on(f.texts), timeout=2.5, fr=fr)
    shown = filter_key(search_bar_text(fr.texts))
    if shown not in ("", "search") and not bar_matches(shown, want):
        log(T("   v poli Search je jiný text – mažu ho", "   the Search field has other text – clearing it"))
        fr = clear_search_field(bot, fr)
        shown = ""
    if not bar_matches(shown, want):
        bot.type_text(q)
        ok, fr = bot.wait_for(lambda f: bar_matches(filter_key(search_bar_text(f.texts)), want), 3,
                              label="hledání napsané")
        if not ok:
            log(T("   (napsané hledání v poli nevidím – zkusím ho i tak potvrdit)",
                  "   (can't see the typed search in the field – confirming it anyway)"))
    bot.typed_query = q
    done = lambda f: (not keyboard_on(f.texts) and classify(f) in ("box", "box_other")
                      and filter_state(bot, f.texts) == "ok")
    t0 = time.time()
    bot.type_text("\n")
    ok, fr = bot.wait_for(done, 4, after=t0 + FRAME_LAG, label="hledání potvrzené")
    if not ok and keyboard_on(fr.texts):
        k = return_key(fr.texts)
        if k is not None:
            t0 = bot.tap(k["cx"], k["cy"], T(f"klávesa {k['text']}", f"key {k['text']}"), fr=fr)
            ok, fr = bot.wait_for(done, 3, after=t0 + FRAME_LAG, label="hledání potvrzené")
    if not ok:
        raise StepError(T("hledání se nepodařilo potvrdit", "couldn't confirm the search"))
    if bot.mode != "cp":
        key = filter_key(search_bar_text(fr.texts))
        if key and key != bot.filter_key:
            bot.filter_key = key
            cal_set("search", {"query": SEARCH_QUERY, "key": key})
        emit("search", query=SEARCH_QUERY)
    log(T(f"   ✔ hledání „{shown_q}“ je zadané", f"   ✔ search “{shown_q}” entered"))
    bot.fresh_list = True


def handle_unknown(bot, fr, attempt):
    if attempt == 1 and ensure_app(bot):
        return
    if attempt <= 2:
        time.sleep(0.6)   # třeba jen animace / načítání
        return
    t = safe_button(fr.texts)
    if t:
        bot.tap(t["cx"], t["cy"], T(f"zavřít okno: {t['text']}", f"close window: {t['text']}"), fr=fr)
        time.sleep(0.6)
    elif multiselect_on(fr.texts) or multiselect_look(fr.img) or \
            find_text(fr.texts, ["transfer"], region=(0.0, 0.8, 1.0, 1.0)):
        # výběr více Pokémonů: dole uprostřed je TRANSFER, zavírá se křížkem vlevo nahoře
        bot.tap(*P_MULTI_CLOSE, T("zrušit výběr (X vlevo nahoře)", "cancel selection (X top left)"), fr=fr)
        time.sleep(0.8)
    elif attempt % 3 == 0:
        bot.tap(*P_BOTTOM_X, T("zavřít (X dole)", "close (X at the bottom)"), fr=fr)
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
            bot.tap(0.5, 0.12, T("schovat klávesnici", "hide the keyboard"), fr=fr)
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
        bot.act((c["cx"], c["cy"]), T(f"odmítnout dialog ({c['text']})", f"decline dialog ({c['text']})"), lambda f: not confirm_dialog(f.texts),
                fr=fr, tries=1)
    elif st == "tag_dialog":
        # rozdělaný dialog pro nový tag (třeba po chybě) – zavřít bez uložení
        c = find_text(tx, ["cancel", "close", "zrušit", "zavřít"], exact=True) or safe_button(tx)
        p = (c["cx"], c["cy"]) if c else P_BOTTOM_X
        bot.act(p, T("zavřít dialog pro nový tag", "close the new tag dialog"), lambda f: classify(f) != "tag_dialog", fr=fr, tries=1)
    elif st == "tag_list":
        bot.act(P_BOTTOM_X, T("zavřít výběr tagů (bez uložení)", "close the tag picker (without saving)"), lambda f: not tag_list_on(f.texts), fr=fr, tries=1)
    elif st == "multiselect":
        bot.act(P_MULTI_CLOSE, T("zrušit multiselect", "cancel multi-select"), lambda f: classify(f) != "multiselect", fr=fr, tries=1)
    elif st == "appraisal":
        bot.act(P_NEUTRAL, T("zavřít appraisal", "close appraisal"), lambda f: classify(f) != "appraisal", timeout=1.5, fr=fr, tries=1)
    elif st == "detail_menu":
        bot.act(P_CORNER, T("zavřít menu", "close menu"), lambda f: classify(f) != "detail_menu", fr=fr, tries=1, overlay=True)
    elif st == "detail":
        bot.act(P_BOTTOM_X, T("zavřít detail", "close detail"), lambda f: classify(f) != "detail", timeout=2.5, fr=fr, tries=1,
                overlay=True)
    elif st == "sort_menu":
        t, fr = bot.stable_text([L["number"]], exact=True, region=(0.4, 0.3, 1.0, 0.9))
        if bot.need_sort and t and not sort_active(fr.img, t):
            # klepnout jen když NUMBER ještě není aktivní – opakované klepnutí by obrátilo směr řazení
            bot.act((t["cx"], t["cy"]), T("řadit podle NUMBER", "sort by NUMBER"), lambda f: not sort_menu_on(f.texts), fr=fr, tries=1)
        else:
            if bot.need_sort and t:
                log(T("   řazení podle čísla už je nastavené", "   sorting by number is already set"))
            bot.act(P_CORNER, T("zavřít řazení", "close the sort menu"), lambda f: not sort_menu_on(f.texts), fr=fr, tries=1, overlay=True)
        if t:
            bot.need_sort = False
    elif st == "search_page":
        if bot.mode == "all":
            bot.act(P_SEARCH_BACK, T("zavřít hledání", "close search"), lambda f: classify(f) != "search_page", timeout=2.5, fr=fr,
                    tries=1)
        else:
            apply_search(bot, fr, attempt)
    elif st == "box" and bot.mode == "all":
        if filter_state(bot, tx) != "none":
            p = P_SEARCH_CLEAR if attempt % 2 else P_SEARCH_BACK
            bot.act(p, T("zrušit hledání (celý inventář)", "cancel search (whole storage)"),
                    lambda f: classify(f) == "search_page" or filter_state(bot, f.texts) == "none",
                    timeout=2.5, fr=fr, tries=1)
            bot.fresh_list = True
        elif bot.need_sort:
            bot.act(P_CORNER, T("řazení", "sort"), lambda f: sort_menu_on(f.texts), fr=fr, tries=1, overlay=True)
        else:
            return fr
    elif st == "box":
        fs = filter_state(bot, tx)
        if fs == "none":
            bot.act(P_SEARCH_BAR, T("pole Search", "Search field"), lambda f: classify(f) == "search_page", timeout=2.5, fr=fr, tries=1)
        elif fs == "other":
            p = P_SEARCH_BACK if attempt % 2 else P_SEARCH_CLEAR
            bot.act(p, T("zrušit jiné hledání", "cancel the other search"),
                    lambda f: classify(f) == "search_page" or filter_state(bot, f.texts) != "other",
                    timeout=2.5, fr=fr, tries=1)
        elif bot.need_sort:
            bot.act(P_CORNER, T("řazení", "sort"), lambda f: sort_menu_on(f.texts), fr=fr, tries=1, overlay=True)
        else:
            return fr
    elif st in ("box_tags", "box_other"):
        ours = st == "box_other" and bot.mode != "all" and filter_state(bot, tx) == "ok"
        if ours and (attempt >= 3 or search_count(tx) == 0):
            return fr   # naše hledání, jen nic nenašlo – co dál, rozhodne volající
        if attempt == 1 or ours:
            time.sleep(0.5)   # box (nebo výsledky hledání) se možná teprve načítá
            return None
        if st == "box_other" and stale_search(bot, tx):
            # dřívější hledání bez výsledků (třeba CP, které ve hře není): záložka POKÉMON tu nepomůže,
            # hledání se musí zrušit
            p = P_SEARCH_BACK if attempt % 2 == 0 else P_SEARCH_CLEAR
            bot.act(p, T("zrušit hledání bez výsledků", "cancel the search without results"),
                    lambda f: classify(f) != "box_other" or filter_state(bot, f.texts) == "none",
                    timeout=2.5, fr=fr, tries=1)
            if bot.mode == "all":
                bot.fresh_list = True
            return None
        t = find_text(tx, ["pokemon"], region=(0.3, 0.0, 0.7, 0.16))
        p = (t["cx"], t["cy"]) if t else P_BOX_TAB
        bot.act(p, T("záložka POKÉMON", "POKÉMON tab"), lambda f: classify(f) != st, timeout=2.5, fr=fr, tries=1)
    elif st == "main_menu":
        t, fr = bot.stable_text(["pokemon"], exact=True, region=(0.0, 0.5, 0.5, 1.0))
        cands = ([(t["cx"], t["cy"] + MENU_ICON_DY), (t["cx"], t["cy"] + 0.035), (t["cx"], t["cy"])]
                 if t else [(0.22, 0.835)])
        p = cands[(attempt - 1) % len(cands)]
        bot.act(p, "POKÉMON", lambda f: classify(f) in BOX_STATES, timeout=6, fr=fr, tries=1)
        bot.fresh_list = True      # nově otevřený inventář začíná nahoře
    elif st == "map":
        p = P_POKEBALL[(attempt - 1) % len(P_POKEBALL)]
        bot.act(p, "Poké Ball", lambda f: classify(f) == "main_menu", timeout=2.5, fr=fr, tries=1)
    else:
        handle_unknown(bot, fr, attempt)
    return None


def ensure_box(bot):
    """Odkudkoliv dojde do boxu: s napsaným hledáním SEARCH_QUERY (nebo bez hledání v režimu „all“)
    a s řazením podle čísla. Vrací snímek boxu."""
    start = time.time()
    restarted = False
    last, same = None, 0
    while True:
        stuck = same > (15 if last == "unknown" else 8)
        if time.time() - start > NAV_TIMEOUT or stuck:
            if restarted:
                raise Fatal(T("Do inventáře se nedaří dostat ani po restartu hry. "
                              "Snímky obrazovky jsou ve složce s výsledky (chyba_XX).",
                              "Can't get to the Pokémon storage even after restarting the game. "
                              "Screenshots are in the results folder (chyba_XX)."))
            log(T("   nedaří se dostat do inventáře", "   can't get to the storage") +
                (T(" (pořád stejná obrazovka)", " (stuck on the same screen)") if stuck else ""))
            restart_game(bot)
            restarted, start, last, same = True, time.time(), None, 0
            continue
        fr = bot.frame()
        st = classify(fr)
        same = same + 1 if st == last else 1
        if st != last:
            log(T("   obrazovka: ", "   screen: ") + state_name(st))
            emit("screen", state=st, text=state_name(st))
            if last is None and st not in ("box", "search_page"):
                step(T("Jdu do inventáře", "Going to the Pokémon storage"))
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
            raise StepError(T("nevidím mřížku inventáře", "can't see the storage grid"))
        prev = fr


def cell_matches(ref, c, multi=False):
    """Stejná buňka (po posunu)? CP + obrázek, a jméno, když je celé vidět – u spodního řádku
    obrazovky bývá jméno napůl schované za tlačítky a přečte se špatně. Ve výběru více Pokémonů má
    vybraná buňka zelené pozadí, tam stačí CP, sloupec a jméno."""
    low = max(ref.get("cy", 0), c.get("cy", 0)) > 0.70
    if ref["cp"] != c["cp"] or not (low or names_ok(ref["name"], c["name"])):
        return False
    if multi:
        return abs(ref["cx"] - c["cx"]) < 0.08
    return sprite_sim(ref["sprite"], c["sprite"]) >= SAME_SPECIES_THR


def grid_shift(old, new):
    """O kolik se seznam posunul nahoru: stejné CP ve stejném sloupci na obou snímcích (medián)."""
    d = sorted(o["cy"] - n["cy"] for o in old for n in new
               if o["cp"] == n["cp"] and abs(o["cx"] - n["cx"]) < 0.06 and -0.3 < o["cy"] - n["cy"] < 1.2)
    return d[len(d) // 2] if d else None


def learn_gain(bot, shift, finger):
    """Poměr posunu seznamu k tahu prstem (klouzavý průměr, uloží se pro další běh)."""
    if shift is None or finger < 0.06 or shift <= 0.02:
        return
    g = min(3.0, max(0.6, shift / finger))
    old = bot.scroll_gain
    bot.scroll_gain = round(0.5 * old + 0.5 * g, 3)
    if abs(bot.scroll_gain - old) > 0.05:
        try:
            cal_set("scroll_gain", bot.scroll_gain)
        except OSError:
            pass


def scroll_by(bot, cells, anchor, multi=False):
    """Posune mřížku tak, aby řádek s anchor byl nahoře. Vrací False na konci seznamu.
    Hra posune seznam víc, než kolik ujede prst (iPhone asi 1,6×): poměr se měří při každém posunu
    (bot.scroll_gain), takže posun sedí napoprvé. Když přece přejede, vrátí se přesně o kolik přejel.
    bot.last_shift = o kolik se seznam posunul (pro skládání seznamu bez zdvojených řádků).
    multi=True: posouvá se uvnitř výběru více Pokémonů (multiselect)."""
    bot.last_shift = None
    want = anchor["cy"] - (TOP_ROW_Y + 0.02)
    old = grid_cells(bot.frame().texts)            # i napůl schované řádky – podle nich se měří posun
    before = [(c["cp"], round(c["cy"], 2)) for c in cells]
    moved = False
    for k in range(2):
        x = 0.5 if k == 0 else 0.3
        dy = min(0.55, max(0.08, want / bot.scroll_gain))
        bot.drag((x, SCROLL_FROM_Y), (x, SCROLL_FROM_Y - dy), f"posun o {dy:.2f}",
                 ms=int(250 + 900 * dy), hold=0.3)
        cells2, fr = read_grid(bot)
        if not multi and classify(fr) == "multiselect":
            raise StepError("posun omylem spustil multiselect")
        if [(c["cp"], round(c["cy"], 2)) for c in cells2] != before:
            moved = True
            shift = grid_shift(old, grid_cells(fr.texts))
            if shift is None:          # z předchozí obrazovky není vidět nic – přejelo to hodně
                bot.scroll_gain = min(3.0, round(bot.scroll_gain * 1.4, 3))
            else:
                learn_gain(bot, shift, dy)
            break
    if not moved:
        if any(c["cy"] > GRID_BOTTOM + 0.02 for c in grid_cells(fr.texts)):
            raise StepError(T("seznam se nedá posunout, i když pod ním ještě něco je",
                              "the list won't scroll although there's more below"))
        return False   # konec seznamu
    for _ in range(4):
        hit = next((c for c in cells2 if cell_matches(anchor, c, multi)), None)
        if hit is not None:
            bot.last_shift = anchor["cy"] - hit["cy"]
            return True
        # přejeli jsme: kotva je nad horním okrajem – vrátit seznam přesně o tolik, kolik chybí
        shift = grid_shift(old, grid_cells(fr.texts))
        lost = (TOP_ROW_Y + 0.04) - (anchor["cy"] - shift) if shift is not None else 0.17
        back = min(0.30, max(0.05, lost / bot.scroll_gain))
        bot.drag((0.5, 0.42), (0.5, 0.42 + back), T("kousek zpět", "a bit back"), ms=int(250 + 700 * back), hold=0.3)
        cells2, fr = read_grid(bot)
    raise LostPosition(T("při posunu jsem ztratil místo v inventáři", "lost my place in the storage while scrolling"))


def bring_to_top(bot, cells, cell):
    if cell["cy"] - TOP_ROW_Y < 0.08:
        return False
    return scroll_by(bot, cells, cell)


def scroll_next(bot, cells, multi=False):
    """Další obrazovka; poslední řádek zůstane nahoře jako překryv."""
    last_row = max(c["row"] for c in cells)
    anchor = next(c for c in cells if c["row"] == last_row)
    if anchor["cy"] - TOP_ROW_Y < 0.08:
        anchor = cells[-1]
    return scroll_by(bot, cells, anchor, multi)


def reopen_box(bot):
    """Na začátek seznamu: inventář zavře (X dole) a ensure_box ho otevře znovu – nově otevřený
    inventář začíná vždycky nahoře. Rychlý tah prstem dolů na začátku seznamu hra bere jako
    zavření inventáře, proto se na začátek neroluje."""
    log(T("   na začátek seznamu: zavírám inventář, znovu se otevře nahoře",
          "   back to the top of the list: closing the storage, it reopens at the top"))
    fr = bot.frame()
    if classify(fr) not in BOX_STATES:
        return
    try:
        bot.act(P_BOTTOM_X, T("zavřít inventář", "close the storage"), lambda f: classify(f) not in BOX_STATES, timeout=3, fr=fr, tries=2)
        return
    except StepError:
        pass
    # křížek nezabral: na začátek pomalými tahy (pomalé tažení s podržením hra za zavření nebere;
    # a kdyby se inventář přece zavřel, nevadí – otevře se znovu nahoře)
    prev = None
    for _ in range(40):
        bot.drag((0.5, 0.40), (0.5, 0.75), T("nahoru (pomalu)", "up (slowly)"), ms=500, hold=0.3)
        if classify(bot.frame()) not in BOX_STATES:
            return
        cells, fr = read_grid(bot)
        key = [c["cp"] for c in cells]
        if key == prev:
            bot.fresh_list = True
            return
        prev = key
    raise StepError(T("seznam se nedaří dostat na začátek", "can't get the list back to the top"))


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
        self.target, self.removed, self.had = None, [], False   # 2. část: IV tag, odebrané tagy, už ho měl


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
    """Trvalá paměť mezi běhy: co bot ví o každém kusu v inventáři (IV, typy, tagy, jméno) a komu dal
    tag. Podle času se nemaže – po každém běhu se srovná s tím, co je ve hře (viz remember_box)."""

    def __init__(self, path):
        self.path = path
        try:
            self.data = json.loads(path.read_text())
        except Exception:
            self.data = {}
        now = time.time()
        self.data["iv"] = {k: v for k, v in self.data.get("iv", {}).items() if isinstance(v, dict) and v.get("iv")}
        self.data["tagged"] = {k: v for k, v in self.data.get("tagged", {}).items()
                               if now - v < TAGGED_DAYS * 86400}
        self.data["box"] = [it for it in self.data.get("box", []) if isinstance(it, dict) and it.get("iv")]
        self.box_start = list(self.data["box"])    # jak byla paměť na začátku běhu (srovnává se s ní)

    def save(self):
        try:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            tmp = self.path.with_suffix(".tmp")
            tmp.write_text(json.dumps(self.data, default=lambda o: o.item() if hasattr(o, "item") else str(o)))
            tmp.replace(self.path)
        except OSError as e:
            log(T(f"   (paměť se nepodařilo uložit: {e})", f"   (couldn't save the memory: {e})"))

    def get_iv(self, sig):
        e = self.data["iv"].get(sig)
        return (tuple(e["iv"]), e.get("types")) if e else None

    def set_iv(self, sig, iv, types, save=True):
        if sig.split("|", 1)[1]:          # bez jména si ho nepamatuju
            self.data["iv"][sig] = {"iv": list(iv), "types": types, "t": time.time()}
            if save:
                self.save()

    def box_items(self):
        """Kusy přečtené v minulých bězích: IV, typy, HP, tagy a jméno, jak byly naposledy ve hře."""
        return self.data["box"]

    def set_box(self, items):
        """Nový obsah paměti; IV podle podpisu (pomalý režim) jen pro kusy, které v ní jsou."""
        self.data["box"] = items
        self.data["iv"] = {f"{it['gcp']}|{alnum(it.get('gname') or '')}": {"iv": it["iv"], "types": it.get("types"),
                                                                           "t": it.get("t")}
                           for it in items if alnum(it.get("gname") or "")}
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

    def renamed(self, cp, name):
        """Dal tomuhle kusu jméno bot? (pak to není vlastní přezdívka). CP se od přejmenování mohlo
        změnit (vylepšení), proto stačí stejné jméno."""
        n, done = alnum(name), self.data.setdefault("renamed", {})
        return bool(n) and (f"{cp}|{n}" in done or any(k.split("|", 1)[-1] == n for k in done))

    def set_renamed(self, cp, name):
        self.data.setdefault("renamed", {})[f"{cp}|{alnum(name)}"] = time.time()
        self.save()


def iv_pct(iv):
    return round(sum(iv) * 100 / 45) if iv else None


def species_title(group):
    names = [r.name for r in group if PLAIN_NAME.match(norm(r.name))] or [r.name for r in group]
    return max(set(names), key=names.count) if names else "?"


class Report:
    def __init__(self, run_dir, max_groups):
        self.dir, self.max = run_dir, max_groups
        self.t0 = time.time()
        self.shown, self.sent = {}, {}
        self.measured = 0
        self.pvp_tagged = 0
        self.renamed = 0

    def limit_reached(self, book):
        return bool(self.max) and book.groups_done() >= self.max

    def show(self, book, gid, quiet=False):
        """Skupina stejných Pokémonů: IV každého a co s ním bot udělá. quiet = jen událost pro aplikaci."""
        group = book.group(gid)
        lines = []
        for r in group:
            ivs = "/".join(f"{v:>2}" for v in r.iv) if r.iv else " ?/ ?/ ?"
            pct = f"{sum(r.iv) / 45:4.0%}" if r.iv else "   ?"
            act = {"keep": T("nechat", "keep"), "remove": f"tag {TAG_NAME}"}.get(
                r.action, T("nezměřeno", "not measured") if r.status == "failed" else "?")
            flags = (T(" ✔ označeno", " ✔ tagged") if r.tagged else "") + \
                (T(" (IV z paměti)", " (IV from memory)") if r.cached else "") + \
                (T(" (stejné CP i jméno – nejde rozlišit, neoznačuji)", " (same CP and name – can't tell apart, not tagging)")
                 if r.ambiguous and r.action == "remove" else "")
            lines.append(f"   CP{r.cp:<5} {ivs}  {pct}  -> {act}{flags}")
        title = species_title(group)
        text = T(f"\n── Skupina: {title} ({len(group)}×)\n", f"\n── Group: {title} ({len(group)}×)\n") + "\n".join(lines)
        if not quiet and self.shown.get(gid) != text:
            self.shown[gid] = text
            log(text)
        payload = {"id": gid, "title": title, "tag": TAG_NAME, "color": TAG_COLOR, "items": [{
            "cp": r.cp, "name": r.name, "iv": list(r.iv) if r.iv else None, "pct": iv_pct(r.iv),
            "action": r.action, "tagged": r.tagged, "cached": r.cached, "failed": r.status == "failed",
            "ambiguous": r.ambiguous} for r in group]}
        key = json.dumps(payload, sort_keys=True)
        if self.sent.get(gid) != key:
            self.sent[gid] = key
            emit("group", **payload)

    def show_iv(self, r):
        """2. část: jeden Pokémon a jeho IV tag."""
        ivs = "/".join(f"{v:>2}" for v in r.iv) if r.iv else " ?/ ?/ ?"
        pct = f"{sum(r.iv) / 45:4.0%}" if r.iv else "   ?"
        log(f"   CP{r.cp:<5} {r.name[:16]:16s} {ivs} {pct}  -> {r.note}" + (T(" (IV z paměti)", " (IV from memory)") if r.cached else ""))
        emit("iv", cp=r.cp, name=r.name, iv=list(r.iv) if r.iv else None, pct=iv_pct(r.iv), status=r.status,
             tag=r.target, color=tag_color(r.target) if r.target else None, had=r.had, removed=r.removed,
             note=r.note, cached=r.cached)

    def save_iv(self, book2):
        if book2.recs:
            out = [{"cp": r.cp, "name": r.name, "iv": list(r.iv) if r.iv else None, "status": r.status,
                    "tag": r.target, "note": r.note} for r in book2.recs]
            (self.dir / "result_iv_tagy.json").write_text(json.dumps(out, ensure_ascii=False, indent=1))

    def summary_iv(self, book2):
        if not book2.recs:
            return {}
        log(T("\n------ 2. část: IV tagy ------", "\n------ Part 2: IV tags ------"))
        done = [r for r in book2.recs if r.status == "done"]
        per_tag = []
        for _, name in IV_TAGS:
            n = sum(1 for r in done if r.target == name)
            if n:
                log(f"   {name:16s} {n}×")
                per_tag.append({"name": name, "color": tag_color(name), "count": n})
        out = {"seen": len(book2.recs), "tagged": sum(1 for r in done if not r.had),
               "had": sum(1 for r in done if r.had), "skipped": sum(r.status == "skip" for r in book2.recs),
               "failed": sum(r.status in ("failed", "pending") for r in book2.recs), "per_tag": per_tag}
        log(T(f"Prošlo: {out['seen']}, nově otagováno: {out['tagged']}, tag už měli: {out['had']}, "
              f"přeskočeno: {out['skipped']}, nepovedlo se: {out['failed']}",
              f"Checked: {out['seen']}, newly tagged: {out['tagged']}, already tagged: {out['had']}, "
              f"skipped: {out['skipped']}, failed: {out['failed']}"))
        return out

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
        left = [r for r in rem if not r.tagged]
        out = {"minutes": round(dt / 60, 1), "groups": len(book.groups()), "pokemon": len(recs),
               "measured": self.measured, "cached": sum(r.cached for r in recs),
               "failed": sum(r.status == "failed" for r in recs), "removable": sum(r.tagged for r in rem),
               "removable_total": len(rem), "left": [f"{r.name} CP{r.cp}" for r in left]}
        log(T("\n================ SHRNUTÍ ================", "\n================ SUMMARY ================"))
        if recs:
            log(T(f"Skupin stejných Pokémonů: {out['groups']}, Pokémonů v nich: {out['pokemon']}",
                  f"Groups of the same Pokémon: {out['groups']}, Pokémon in them: {out['pokemon']}"))
            log(T(f"Změřeno teď: {out['measured']}, z paměti: {out['cached']}, nepodařilo se změřit: {out['failed']}",
                  f"Measured now: {out['measured']}, from memory: {out['cached']}, couldn't measure: {out['failed']}"))
            log(T(f"Tag {TAG_NAME} dostalo: {out['removable']} z {out['removable_total']}",
                  f"Got the {TAG_NAME} tag: {out['removable']} of {out['removable_total']}"))
            if left:
                log(T("Bez tagu zůstali (zkontroluj ručně): ", "Left without the tag (check them yourself): ") +
                    ", ".join(out["left"]))
        log(T(f"Čas: {dt / 60:.1f} min", f"Time: {dt / 60:.1f} min") +
            (T(f", {dt / self.measured:.1f} s na změřeného Pokémona", f", {dt / self.measured:.1f} s per measured Pokémon")
             if self.measured else ""))
        return out


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
            raise StepError(T(f"otevřel se jiný Pokémon (CP{cp} místo CP{cell['cp']})",
                              f"a different Pokémon opened (CP{cp} instead of CP{cell['cp']})"))
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


def read_appraisal(bot, cp, prev=None, quick=None):
    """Proklikne úvodní řeč a přečte bary, až dojedou animací. None = nepovedlo se.
    Popisky barů hledá rychlým OCR (na skutečných snímcích stejné IV jako přesné, 5× rychlejší).
    Hodnoty musí BAR_STABLE s stát; dokud vypadají jako u předchozího kusu prev (bary se po přechodu
    šipkou ▶ možná teprve překreslují), čeká se aspoň BAR_SETTLE. quick(snímek, IV) vrátí přečtený kus,
    když IV z barů přesně sedí na jeho CP a HP – pak stačí, že bary stojí BAR_QUICK s. Snímek s bary je
    v bot.bars_frame, kus z rychlého potvrzení v bot.bars_rec."""
    end = time.time() + 9
    first = cur = cur_since = None
    d_prev, d_since = None, time.time()
    last_tap, taps = 0.0, 0
    after = None
    bot.bars_frame = bot.bars_rec = None
    tried = None
    while time.time() < end:
        fr = bot.frame(after=after)
        after = fr.t + 0.005
        labels = bar_labels(fr.fast)
        if labels:
            if first is None:
                first = fr.t
            vals, bars = read_bars(fr.img, labels)
            if vals != cur:
                cur, cur_since = vals, fr.t
                continue
            if vals is None:
                continue
            new = prev is not None and tuple(vals) != tuple(prev)
            if quick and new and any(vals) and fr.t - cur_since >= BAR_QUICK and tried != vals:
                tried = vals
                bot.bars_rec = quick(fr, vals)
            if bot.bars_rec is not None or (fr.t - cur_since >= BAR_STABLE and (fr.t - first >= BAR_SETTLE or new)):
                bot.remember("bary", f"CP{cp}", fr)
                save_bars(bot, fr, labels, bars, vals, cp)
                bot.bars_frame = fr
                return vals
            continue
        tx = fr.texts
        if classify(fr) != "appraisal":
            if taps and time.time() - last_tap > 1.5:
                return None   # appraisal se zavřel dřív, než šly bary přečíst
            continue
        d = dialog_text(tx)
        if d != d_prev:
            d_prev, d_since = d, fr.t
        if d and fr.t - d_since >= 0.25 and time.time() - last_tap >= 0.6 and taps < 8:
            last_tap = bot.tap(*P_NEUTRAL, T("appraisal dál", "appraisal next"), fr=fr)
            taps += 1
            after = last_tap + FRAME_LAG
    return None


def open_detail(bot, cell):
    """Klepne na buňku, počká, až detail dojede, a ověří, že je to správný Pokémon."""
    cp = cell["cp"]
    x, y = cell["cx"], cell["cy"] + CELL_TAP_DY
    _, fr = bot.act((x, y), T(f"otevřít CP{cp}", f"open CP{cp}"), lambda f: classify(f) == "detail",
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
        raise StepError(T("v menu chybí APPRAISE", "APPRAISE is missing in the menu"))
    bot.act((t["cx"], t["cy"]), "APPRAISE", lambda f: classify(f) == "appraisal", timeout=2.5, fr=fr, tries=1)
    iv = read_appraisal(bot, cp)
    for _ in range(4):
        if classify(bot.frame()) != "appraisal":
            break
        try:
            bot.act(P_NEUTRAL, T("zavřít appraisal", "close appraisal"), lambda f: classify(f) != "appraisal", timeout=1.2, tries=1)
        except StepError:
            pass
    return iv, bot.settle(bot.frame())


def close_detail(bot, fr=None):
    fr = bot.settle(fr or bot.frame())
    bot.act(P_BOTTOM_X, T("zavřít detail", "close detail"), lambda f: classify(f) == "box", timeout=2.5, fr=fr, overlay=True)


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
    """Posune seznam tagů. Vrací (nový snímek, jestli se seznam opravdu posunul).
    Pohyb se pozná podle obrazu až po dojetí: na začátku/konci seznamu se řádky jen odrazí
    a vrátí na místo (text přečtený uprostřed odrazu by mylně hlásil posun)."""
    a, b = ((0.5, 0.72), (0.5, 0.42)) if direction == "dolů" else ((0.5, 0.42), (0.5, 0.72))
    before = fr.img
    t0 = bot.drag(a, b, T(f"seznam tagů {direction}", f"tag list {'down' if direction == 'dolů' else 'up'}"), ms=350, hold=0.25, fr=fr)
    fr = bot.settle(bot.frame(after=t0 + 0.3), region=LIST_REGION, timeout=1.2)
    return fr, img_diff(before, fr.img, LIST_REGION) > 3.0


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


def keyboard_top(tx):
    """Horní okraj klávesnice (podíl výšky), když je vidět; jinak 1.0."""
    keys = [x["y0"] for x in tx if x["cy"] > 0.55 and len(x["text"].strip()) == 1 and x["text"].strip().isalpha()]
    return min(keys) - 0.02 if len(keys) >= 6 else 1.0


def find_swatches(img, region=(0.02, 0.10, 0.98, 0.92)):
    """Kolečka s barvami v dialogu pro nový tag: aspoň 5 stejně velkých plných kruhů vedle sebe
    (v jedné nebo více řadách). Vrací [{cx, cy, r, rgb}] po řadách zleva (cx, cy, r jako podíl
    šířky/výšky obrazovky), nebo []."""
    H, W = img.shape[:2]
    X0, Y0 = int(region[0] * W), int(region[1] * H)
    crop = img[Y0:int(region[3] * H), X0:int(region[2] * W)]
    if crop.size == 0:
        return []
    hsv = cv2.cvtColor(crop, cv2.COLOR_RGB2HSV)
    sat, val = hsv[..., 1].astype(np.int16), hsv[..., 2].astype(np.int16)
    # „něco, co není světlé pozadí“: barevné, tmavé, nebo středně šedé (šedé kolečko)
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
            continue                       # dutý kruh (písmeno O, prstýnek) – není to kolečko s barvou
        px = pc[d2 <= (0.75 * r) ** 2]
        px = px[px.min(axis=1) < 215]      # bez bílé fajfky / označení
        if len(px) < 10:
            continue
        cands.append({"x": x + X0, "y": y + Y0, "r": r, "rgb": tuple(int(v) for v in np.median(px, axis=0))})
    if len(cands) < 5:
        return []
    best = []
    for c in cands:                        # největší skupina stejně velkých koleček
        grp = [d for d in cands if abs(d["r"] - c["r"]) <= 0.18 * c["r"]]
        if len(grp) > len(best):
            best = grp
    out = []
    for c in sorted(best, key=lambda c: c["r"]):   # soustředné obrysy jednoho kolečka jen jednou
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


def _lab(rgb):
    return cv2.cvtColor(np.uint8([[rgb]]), cv2.COLOR_RGB2LAB)[0, 0].astype(float)


def nearest_swatch(swatches, color):
    """Kolečko pro barvu: kolečka a barvy se spárují (každá barva jen jednou), aby se třeba
    oranžová nespletla se žlutou, když jsou obě vidět."""
    ref = {n: _lab(rgb) for n, rgb in TAG_PALETTE.items()}
    labs = [_lab(sw["rgb"]) for sw in swatches]
    pairs = sorted((float(np.linalg.norm(a - ref[n])), i, n) for i, a in enumerate(labs) for n in ref)
    used_i, used_n, assign = set(), set(), {}
    for _, i, n in pairs:
        if i not in used_i and n not in used_n:
            assign[n] = i
            used_i.add(i)
            used_n.add(n)
    if color in assign:
        return swatches[assign[color]]
    return min(swatches, key=lambda sw: float(np.linalg.norm(_lab(sw["rgb"]) - ref[color])))


def pick_swatch(bot, fr, swatches, color):
    """Klepne na kolečko s barvou a počká, až se výběr ukáže."""
    sw = nearest_swatch(swatches, color)
    H, W = fr.img.shape[:2]
    rx, ry = 2 * sw["r"], 2 * sw["r"] * W / H
    box = (sw["cx"] - rx, sw["cy"] - ry, sw["cx"] + rx, sw["cy"] + ry)
    before = crop_norm(fr.img, *box).copy()
    t0 = bot.tap(sw["cx"], sw["cy"], T(f"barva {COLOR_CZ.get(color, color)}", f"color {color}"), fr=fr)
    ok, fr = bot.wait_for(lambda f: changed_frac(before, crop_norm(f.img, *box)) > 0.01, 1.2,
                          after=t0 + FRAME_LAG, label="barva vybraná")
    log(T("   barva tagu: ", "   tag color: ") + color_word(color) +
        ("" if ok else T(" (vypadá, že už byla vybraná)", " (looks like it was already selected)")))
    return fr


def confirm_button(tx):
    """Tlačítko, které potvrdí dialog pro nový tag (CREATE / SAVE / DONE / OK …). Když je jich vidět víc
    (pod dialogem bývá DONE výběru tagů), bere to nejvýš – to patří dialogu."""
    words = {alnum(w) for w in L["confirm"]}
    hits = [t for t in tx if alnum(t["text"]) in words and len(t["text"].strip()) <= 12]
    return min(hits, key=lambda t: t["cy"]) if hits else None


def create_tag(bot, fr, name, color=None):
    """Ve výběru tagů založí tag: Add New Tag -> název -> barva -> potvrdit. Vrací snímek výběru tagů.
    Postup se řídí tím, co je zrovna vidět (pole pro název, klávesnice, kolečka s barvami), takže
    nevadí, jestli hra otevře klávesnici sama, ani jestli jsou barvy nad polem, nebo pod ním."""
    color = color or tag_color(name)
    bot.tag_attempts[name] = bot.tag_attempts.get(name, 0) + 1
    cz = f" ({color_word(color)})" if color else ""
    log(T(f"   zakládám tag „{name}“{cz}", f"   creating tag “{name}”{cz}"))
    step(T(f"Zakládám tag „{name}“{cz}", f"Creating tag “{name}”{cz}"))
    a, fr = find_add_new_tag(bot, fr)
    if a is None:
        raise Fatal(T(f"Tag „{name}“ ve hře chybí a ve výběru tagů nevidím „{L['add_new_tag']}“ "
                      f"(nemáš už 100 tagů?). Založ ho ve hře ručně a spusť znovu.",
                      f"Tag “{name}” is missing in the game and the tag picker has no “{L['add_new_tag']}” "
                      f"(do you have 100 tags already?). Create it in the game yourself and run again."))
    _, fr = bot.act((a["cx"], a["cy"]), L["add_new_tag"],
                    lambda f: keyboard_on(f.texts) or tag_dialog_on(f), timeout=3, fr=fr)
    colored, typed = color is None, False
    for _ in range(12):
        tx = fr.texts
        kb = keyboard_on(tx)
        if not colored:
            sw = find_swatches(fr.img, (0.02, 0.10, 0.98, min(0.92, keyboard_top(tx)) if kb else 0.92))
            if sw:
                fr = pick_swatch(bot, fr, sw, color)
                colored = True
                continue
        if not typed:
            if not kb:
                e = find_text(tx, [L["enter_tag_name"]])
                if e is None:
                    raise StepError(T("v dialogu pro nový tag nevidím pole pro název", "the new tag dialog has no name field"))
                _, fr = bot.act((e["cx"], e["cy"]), T("pole pro název tagu", "tag name field"), lambda f: keyboard_on(f.texts),
                                timeout=2.5, fr=fr)
                continue
            bot.type_text(name)
            ok, fr = bot.wait_for(lambda f: any(same_tag(x["text"], name) for x in f.texts), 3, label="název napsaný")
            if not ok:
                raise StepError(T("název tagu se nepodařilo napsat", "couldn't type the tag name"))
            typed = True
            continue
        if kb:
            # schovat klávesnici (Enter), ať jsou vidět barvy i tlačítko pro potvrzení
            t0 = time.time()
            bot.type_text("\n")
            _, fr = bot.wait_for(lambda f: not keyboard_on(f.texts), 2.5, after=t0 + FRAME_LAG, label="bez klávesnice")
            if keyboard_on(fr.texts):
                d = confirm_button(fr.texts)
                if d is None:
                    raise StepError(T("klávesnice v dialogu pro nový tag nejde zavřít", "can't close the keyboard in the new tag dialog"))
                t0 = bot.tap(d["cx"], d["cy"], T(f"klávesnice: {d['text']}", f"keyboard: {d['text']}"), fr=fr)
                fr = bot.frame(after=t0 + 0.4)
            continue
        if tag_list_on(tx) and not tag_dialog_on(fr):
            break                          # dialog se zavřel sám (Enter ho potvrdil)
        if not colored:
            log(T("   (kolečka s barvami nevidím – tag dostane výchozí barvu hry)",
                  "   (can't see the color circles – the tag gets the game's default color)"))
            colored = None
        d = confirm_button(tx)
        if d is None:
            raise StepError(T("v dialogu pro nový tag nevidím tlačítko pro potvrzení", "the new tag dialog has no confirm button"))
        t0 = bot.tap(d["cx"], d["cy"], T(f"potvrdit nový tag ({d['text']})", f"confirm the new tag ({d['text']})"), fr=fr)
        ok, fr = bot.wait_for(lambda f: tag_list_on(f.texts) and not keyboard_on(f.texts) and not tag_dialog_on(f),
                              3, after=t0 + FRAME_LAG, label="tag založený")
        if ok:
            break
    else:
        raise StepError(T("dialog pro nový tag se nepodařilo dokončit", "couldn't finish the new tag dialog"))
    color_ok = bool(colored) and color is not None
    log(T(f"   ✔ tag „{name}“ založený", f"   ✔ tag “{name}” created") +
        (T(", barva ", ", color ") + color_word(color) if color_ok else
         T(" (barvu se nepodařilo vybrat – změň ji ve hře)", " (couldn't pick the color – change it in the game)")
         if color else ""))
    emit("tag_created", name=name, color=color, color_ok=color_ok)
    bot.created_tags.append(name)
    return bot.settle(fr, region=LIST_REGION)


def wait_checked(bot, fr, name, timeout=0.8):
    """Je řádek tagu name ve výběru tagů zaškrtnutý? Hra může fajfku dokreslit až chvilku po otevření
    výběru, proto na ni chvilku počká. Vrací (zaškrtnutý, snímek)."""
    def on(f):
        t = tag_row(f.texts, name)
        return t is not None and row_checked(f.img, t)
    if on(fr):
        return True, fr
    return bot.wait_for(on, timeout, label=f"fajfka {name}")


def row_state(f, name):
    """Řádek tagu name ve výběru tagů: "on" (zelená fajfka), "mixed" (výběr více Pokémonů, tag má jen
    část z nich – vpravo šedé „Mixed“), "off", nebo None (řádek není vidět)."""
    t = tag_row(f.texts, name)
    if t is None:
        return None
    if row_checked(f.img, t):
        return "on"
    if find_text(f.texts, [L["mixed"]], exact=True, region=(0.55, t["cy"] - 0.03, 1.0, t["cy"] + 0.03)):
        return "mixed"
    return "off"


def set_row(bot, fr, name, checked):
    """Ve výběru tagů zaškrtne řádek tagu name (checked=True), nebo ho odškrtne, a ověří to na dalších
    snímcích. Na řádek, který už ve správném stavu je, neklepe – klepnutí by ho přepnulo (přidávaný
    tag by tím Pokémonům odebralo). „Mixed“ (tag má jen část vybraných) se klepnutím přepne na nic,
    teprve další klepnutí ho dá všem – proto se klepe, dokud řádek neukáže, co má. Když se stav
    nastavit nedaří, vyhodí StepError: DONE se pak nestiskne a výběr se zavře bez uložení."""
    want = "on" if checked else "off"
    what = "tag" if checked else T("odebrat", "remove")
    taps, waited, noted = 0, False, False
    for _ in range(9):                       # nanejvýš 2 posuny a 3 klepnutí, pak poslední kontrola
        fr = bot.settle(fr, region=LIST_REGION, timeout=0.8)
        t = tag_row(fr.texts, name)
        if t is None:
            raise StepError(T(f"ve výběru tagů nevidím {name}", f"can't see {name} in the tag picker"))
        s = row_state(fr, name)
        if s == want:
            if taps == 0 and checked:
                log(T(f"   tag {name} už je zaškrtnutý – neklepu na něj (odebral by se)",
                      f"   tag {name} is already checked – not tapping it (that would remove it)"))
            if taps >= 2:
                bot.dump("tagy")                # pro kontrolu, jak hra přepíná „Mixed“
            return fr
        if taps == 3:
            break
        if s == "mixed" and not noted:
            noted = True
            log(T(f"   tag {name}: má ho jen část vybraných (Mixed) – " + ("dám ho všem" if checked else "odeberu ho všem"),
                  f"   tag {name}: only some of the selected have it (Mixed) – " +
                  ("giving it to all" if checked else "removing it from all")))
        if checked and s == "off" and not waited:
            # fajfka se může ukázat až chvilku po otevření výběru – klepnutí by tag odebralo
            waited = True
            on, fr = wait_checked(bot, fr, name)
            if on:
                log(T(f"   tag {name} už je zaškrtnutý – neklepu na něj (odebral by se)",
                      f"   tag {name} is already checked – not tapping it (that would remove it)"))
                return fr
            continue
        if t["cy"] > 0.77:
            # řádek je dole v přechodu nad DONE, kde klepnutí hra nebere – posunout seznam výš
            fr, moved = scroll_tag_list(bot, fr, "dolů")
            if moved:
                continue
        t0 = bot.tap(t["cx"], t["cy"], f"{what} {name}" + (T(" (znovu)", " (again)") if taps else ""), fr=fr)
        taps += 1
        # počkat na změnu (z „Mixed“ se klepnutím stane nic, ne fajfka) – o dalším klepnutí rozhodne smyčka
        _, fr = bot.wait_for(lambda f: row_state(f, name) not in (s, None), 1.5, after=t0 + FRAME_LAG,
                             label=f"{what} {name}")
    raise StepError(T(f"tag {name} se ve výběru nedaří {'zaškrtnout' if checked else 'odškrtnout'} – nic neukládám",
                      f"can't {'check' if checked else 'uncheck'} tag {name} in the picker – saving nothing"))


def pick_tag(bot, fr, name=None):
    """Ve výběru tagů najde tag a zaškrtne ho. Projede seznam oběma směry – výběr nemusí být nahoře.
    Když tag ve hře chybí, založí ho a vyhodí TagCreated: výběr se pak zavře bez uložení a otevře
    znovu, takže se nový tag zaškrtne stejně jako každý jiný."""
    name = name or TAG_NAME
    t, fr = scan_tag_list(bot, fr, ["dolů", "nahoru"], name)
    if t is None:
        if name in bot.broken_tags or bot.tag_attempts.get(name, 0) >= 2:
            bot.broken_tags.add(name)
            if name == TAG_NAME:
                raise Fatal(T(f"Tag „{name}“ se nedaří založit. Založ ho ve hře ručně (inventář → Tagy → +) a spusť znovu.",
                              f"Can't create tag “{name}”. Create it in the game yourself (storage → Tags → +) and run again."))
            raise StepError(T(f"tag „{name}“ ve hře chybí a nedaří se ho založit",
                              f"tag “{name}” is missing in the game and can't be created"))
        create_tag(bot, fr, name)
        raise TagCreated(T(f"tag „{name}“ je založený, vybírám ho znovu", f"tag “{name}” is created, picking it again"))
    return set_row(bot, fr, name, True)    # už zaškrtnutý nechá být – klepnutí by ho odškrtlo


def open_tag_list(bot, fr):
    """Z detailu Pokémona: ≡ -> TAG -> výběr tagů."""
    open_detail_menu(bot, fr)
    t, fr = bot.stable_text(["tag"], exact=True, region=(0.4, 0.3, 1.0, 0.92))
    if t is None:
        raise StepError(T("v menu chybí TAG", "TAG is missing in the menu"))
    _, fr = bot.act((t["cx"], t["cy"]), "TAG", lambda f: tag_list_on(f.texts), timeout=2.5, fr=fr, tries=1)
    return bot.settle(fr, region=LIST_REGION)


def leave_tag_list(bot, fr):
    """Zavře výběr tagů bez uložení (X) a z detailu se vrátí do boxu."""
    _, fr = bot.act(P_BOTTOM_X, T("zavřít výběr tagů (bez uložení)", "close the tag picker (without saving)"), lambda f: not tag_list_on(f.texts),
                    fr=fr, tries=1)
    fr = bot.settle(fr)
    if classify(fr) == "detail_menu":
        _, fr = bot.act(P_CORNER, T("zavřít menu", "close menu"), lambda f: classify(f) == "detail", fr=fr, tries=1, overlay=True)
    close_detail(bot, fr)


def collect_tag_names(bot, fr):
    """Projede celý výběr tagů shora dolů a vrátí texty všech řádků."""
    for _ in range(TAG_SCROLL_MAX):
        fr, moved = scroll_tag_list(bot, fr, "nahoru")
        if not moved:
            break
    seen = []
    for _ in range(TAG_SCROLL_MAX + 1):
        seen += [x["text"] for x in fr.texts if in_region(x, LIST_REGION)]
        fr, moved = scroll_tag_list(bot, fr, "dolů")
        if not moved:
            break
    seen += [x["text"] for x in fr.texts if in_region(x, LIST_REGION)]
    return seen, fr


def wanted_tags(args):
    """Tagy z nastavení, které tenhle běh potřebuje."""
    names = ([TAG_NAME] if "duplicates" in args.steps else []) + \
        ([n for _, n in IV_TAGS] if "iv" in args.steps else []) + (league_tags() if "pvp" in args.steps else [])
    out = []
    for n in names:
        if all(alnum(n) != alnum(o) for o in out):
            out.append(n)
    return out


def check_tags(bot, args):
    """Příprava: ve výběru tagů ve hře ověří, že existují všechny tagy z nastavení, a chybějící založí
    (v barvě z nastavení). Otevře k tomu prvního Pokémona v boxu; jeho tagy nemění (zavírá se bez uložení)."""
    bot.tag_checks += 1
    wanted = [n for n in wanted_tags(args) if n not in bot.broken_tags]
    if not wanted:
        bot.tags_checked = True
        return
    cells, fr = read_grid(bot)
    step(T("Kontroluji tagy ve hře", "Checking the tags in the game"))
    log(T("\nKontroluji, že ve hře jsou všechny tagy z nastavení...", "\nChecking that every tag from the settings exists in the game..."))
    fr = open_detail(bot, cells[0])
    fr = open_tag_list(bot, fr)
    seen, fr = collect_tag_names(bot, fr)
    missing = [n for n in wanted if not any(same_tag(x, n) for x in seen)]
    for n in wanted:
        log(f"   {'✚' if n in missing else '✔'} {n}" + (T(" – ve hře chybí", " – missing in the game") if n in missing else ""))
    emit("tags", items=[{"name": n, "color": tag_color(n), "ok": n not in missing} for n in wanted])
    for n in missing:
        if bot.tag_attempts.get(n, 0) >= 2:
            bot.broken_tags.add(n)
            log(T(f"   ✖ tag „{n}“ se nepodařilo založit", f"   ✖ couldn't create tag “{n}”"))
            emit("problem", text=T(f"Tag „{n}“ se nepodařilo založit. Založ ho ve hře ručně (inventář → Tagy → +).",
                                   f"Couldn't create tag “{n}”. Create it in the game yourself (storage → Tags → +)."))
            if n == TAG_NAME:
                raise Fatal(T(f"Tag „{n}“ se nedaří založit. Založ ho ve hře ručně (inventář → Tagy → +) a spusť znovu.",
                              f"Can't create tag “{n}”. Create it in the game yourself (storage → Tags → +) and run again."))
            continue
        fr = create_tag(bot, fr, n)
    leave_tag_list(bot, fr)
    bot.tags_checked = True
    if not missing:
        log(T("   všechny tagy ve hře jsou", "   all tags exist in the game"))


# ---------------------------- 2. část: IV tagy ----------------------
def iv_tag(iv):
    """Název IV tagu podle procent (součet / 45)."""
    total = sum(iv)
    for threshold, name in IV_TAGS:
        if total * 100 >= threshold * 45:
            return name
    return IV_TAGS[-1][1]


def detail_tags(tx):
    """Všechny známé tagy (IV, TAG_NAME, PvP ligy, vybraný tag pro přejmenování), které má kus v detailu."""
    region = (0.0, 0.44, 1.0, 0.68)
    known = [n for _, n in IV_TAGS] + [TAG_NAME] + [lg["name"] for lg in PVP.values()] + \
        ([RENAME["only_tag"]] if RENAME["only_tag"] else [])
    return [n for n in dict.fromkeys(known) if any(in_region(t, region) and same_tag(t["text"], n) for t in tx)]


def detail_hp(tx):
    """Maximální HP z řádku „73 / 73 HP“ (u zraněného kusu je první číslo menší)."""
    for t in tx:
        m = re.match(r"^(\d+)\s*/\s*(\d+)\s*hp$", norm(t["text"]))
        if m:
            return int(m.group(2))
    return None


def detail_candy(tx):
    """Název cukru („FUECOCO CANDY“) = evoluční řada; u přejmenovaného kusu pomůže poznat druh."""
    for t in tx:
        m = re.match(r"^([a-z][a-z .'-]{2,}) candy$", norm(t["text"]))
        if m:
            return m.group(1).strip()
    return None


def detail_chips(tx):
    """Štítky tagů pod jménem v detailu: (seznam IV tagů, má Removable)."""
    region = (0.0, 0.44, 1.0, 0.68)
    have = []
    for _, name in IV_TAGS:
        if any(in_region(t, region) and same_tag(t["text"], name) for t in tx):
            have.append(name)
    removable = any(in_region(t, region) and same_tag(t["text"], TAG_NAME) for t in tx)
    return have, removable


def row_checked(img, t):
    """Je řádek ve výběru tagů zaškrtnutý? Hra kreslí vpravo v řádku zelenou fajfku."""
    reg = crop_norm(img, 0.80, t["cy"] - 0.018, 0.98, t["cy"] + 0.018).astype(int)
    if reg.size == 0:
        return False
    r, g = reg[..., 0], reg[..., 1]
    return float(((g - r > 40) & (g > 120)).mean()) > 0.008


def set_iv_tag(bot, fr, target, wrong=()):
    """V detailu přes ≡ -> TAG nastaví IV tagy: target zaškrtnutý, všechny ostatní IV tagy odškrtnuté.
    Co je zaškrtnuté, pozná ve výběru podle zelené fajfky, takže odebere i nesedící IV tag, který
    v detailu nebyl vidět. Na už zaškrtnutý target neklepe – klepnutí by ho odškrtlo.
    Vrací (snímek detailu, seznam odebraných tagů)."""
    fr = open_tag_list(bot, fr)
    ivnames = [n for _, n in IV_TAGS]
    removed, has_target = [], False
    pending = {w for w in wrong if w != target}       # nesedící tagy, které ukázal detail
    for _ in range(TAG_SCROLL_MAX + 1):
        for t in [x for x in fr.texts if in_region(x, (0.0, 0.15, 1.0, 0.82))]:
            name = next((n for n in ivnames if same_tag(t["text"], n)), None)
            if name is None or name in removed or (name == target and has_target):
                continue
            if name == target:
                fr = set_row(bot, fr, name, True)
                has_target = True
            else:
                on = row_checked(fr.img, t)
                if not on and name in pending:       # detail ten tag ukázal – fajfka může přijít až za chvilku
                    on, fr = wait_checked(bot, fr, name)
                if on:
                    fr = set_row(bot, fr, name, False)
                    removed.append(name)
            pending.discard(name)
        if has_target and not pending:
            break                                    # dál už není co měnit
        fr, moved = scroll_tag_list(bot, fr, "dolů")
        if not moved:
            break
    if not has_target:
        fr = pick_tag(bot, fr, target)      # tag nebyl vidět: najde ho (i nahoře), nebo ho založí
    d = find_text(fr.texts, [L["done"]], exact=True, region=(0.0, 0.7, 1.0, 0.95))
    if d is None:
        raise StepError(T("nevidím DONE", "can't see DONE"))
    _, fr = bot.act((d["cx"], d["cy"]), "DONE", lambda f: classify(f) in ("detail", "detail_menu"),
                    timeout=3, fr=fr, tries=1)
    if classify(fr) == "detail_menu":
        _, fr = bot.act(P_CORNER, T("zavřít menu", "close menu"), lambda f: classify(f) == "detail", fr=fr, tries=1, overlay=True)
    def saved(f):
        h = detail_chips(f.texts)[0]
        return target in h and not any(n in h for n in ivnames if n != target)
    ok, fr = bot.wait_for(saved, 3.0, label="štítky v detailu")   # štítek se ukáže až chvilku po DONE
    if not ok:
        raise StepError(T(f"tag se neuložil (štítky v detailu: {detail_chips(fr.texts)[0]})",
                          f"the tag didn't save (chips in the detail: {detail_chips(fr.texts)[0]})"))
    return fr, sorted(set(removed) | {w for w in wrong if w != target})


def categorize(bot, mem, cell, rec, args):
    """Jeden Pokémon do správného IV tagu (přes detail). IV tagy, které k jeho IV nesedí, odebere."""
    step(T(f"Třídím do IV tagů: {cell['name'] or 'Pokémon'} (CP {cell['cp']})",
           f"Sorting into IV tags: {cell['name'] or 'Pokémon'} (CP {cell['cp']})"))
    fr = open_detail(bot, cell)
    have, removable = detail_chips(fr.texts)
    if removable:
        rec.status, rec.note = "skip", T(f"má tag {TAG_NAME} – přeskakuji", f"has the {TAG_NAME} tag – skipping")
        close_detail(bot, fr)
        return
    cached = None if args.fresh else mem.get_iv(rec.sig)
    if len(have) == 1 and not RECHECK_TAGGED and not (cached and iv_tag(cached[0]) != have[0]):
        # už otagovaný a nastaveno „přeskočit otagované“ (když IV z paměti říkají, že tag nesedí, opraví se)
        rec.status, rec.note, rec.target, rec.had = "skip", T(f"už má {have[0]}", f"already has {have[0]}"), have[0], True
        close_detail(bot, fr)
        return
    if cached:
        rec.iv, rec.cached = cached[0], True
    else:
        iv, fr = appraise(bot, fr, cell["cp"])
        if iv is None:
            close_detail(bot, fr)
            raise StepError(T(f"CP{cell['cp']}: IV se nepodařilo přečíst", f"CP{cell['cp']}: couldn't read the IV"))
        rec.iv = iv
        mem.set_iv(rec.sig, iv, detail_types(fr.texts))
    target = iv_tag(rec.iv)
    rec.target = target
    wrong = [n for n in have if n != target]
    if target in have and not wrong:
        rec.status, rec.note, rec.had = "done", T(f"{target} (už měl)", f"{target} (already had it)"), True
    else:
        fr, removed = set_iv_tag(bot, fr, target, wrong)
        rec.status, rec.had, rec.removed = "done", target in have, removed
        rec.note = target + (T(f" (odebráno: {', '.join(removed)})", f" (removed: {', '.join(removed)})") if removed else "")
    close_detail(bot, fr)


def tag_selected(bot, mem, sel, fr):
    c0 = sel[0][0]
    t0 = bot.long_press(c0["cx"], c0["cy"] + CELL_TAP_DY, T(f"podržet CP{c0['cp']}", f"hold CP{c0['cp']}"), fr=fr)
    n, fr = bot.wait_for(lambda f: tag_count(f.texts), 2.5, after=t0 + FRAME_LAG, label="multiselect")
    if n != 1:
        raise StepError(T(f"multiselect se nespustil (TAG {n})", f"multi-select didn't start (TAG {n})"))
    for c, _ in sel[1:]:
        want = n + 1
        for _ in range(2):
            t0 = bot.tap(c["cx"], c["cy"] + SELECT_TAP_DY, T(f"vybrat CP{c['cp']}", f"select CP{c['cp']}"), fr=fr)
            _, fr = bot.wait_for(lambda f: (tag_count(f.texts) or 0) >= want, 2.0,
                                 after=t0 + FRAME_LAG, label="výběr")
            cnt = tag_count(fr.texts)
            if cnt == want:
                break
            if cnt is None or cnt > want:
                raise StepError(T(f"výběr nesedí (TAG {cnt}, čekal jsem {want})", f"the selection is off (TAG {cnt}, expected {want})"))
        else:
            raise StepError(T(f"CP{c['cp']} se nepodařilo vybrat", f"couldn't select CP{c['cp']}"))
        n = want
    tb = tag_button(fr.texts)
    if tb is None:
        raise StepError(T("nevidím tlačítko TAG", "can't see the TAG button"))
    _, fr = bot.act((tb["cx"], tb["cy"]), f"TAG ({n})", lambda f: tag_list_on(f.texts),
                    timeout=2.5, fr=fr, tries=1)
    fr = pick_tag(bot, fr)
    d = find_text(fr.texts, [L["done"]], exact=True, region=(0.0, 0.7, 1.0, 0.95))
    if d is None:
        raise StepError(T("nevidím DONE", "can't see DONE"))
    bot.act((d["cx"], d["cy"]), "DONE", lambda f: classify(f) == "box", timeout=3, fr=fr, tries=1)
    for _, r in sel:
        r.tagged = True
        mem.set_tagged(r.cp, r.name)
    log(T(f"   ✔ tag {TAG_NAME} přidán: {pokemon_count(n)}", f"   ✔ tag {TAG_NAME} added: {pokemon_count(n)}"))
    emit("tagged", tag=TAG_NAME, color=TAG_COLOR, items=[{"cp": r.cp, "name": r.name} for _, r in sel])


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
    log(T(f"   označuji tagem {TAG_NAME}: ", f"   tagging with {TAG_NAME}: ") + ", ".join(f"CP{r.cp}" for _, r in sel))
    step(T(f"Označuji tagem {TAG_NAME}: {pokemon_count(len(sel))}", f"Tagging with {TAG_NAME}: {pokemon_count(len(sel))}"))
    try:
        tag_selected(bot, mem, sel, fr)
    except TagCreated:
        raise                          # tag se právě založil – zkusí se znovu, není to chyba
    except StepError:
        for _, r in sel:
            r.tag_fails += 1
        raise


# ---------------------------- rychlý režim ----------------------------
# 1) seznam se jednou projede jen posouváním (pořadí, CP, jméno, obrázek)
# 2) otevře se první Pokémon, appraisal, a šipkou ▶ (nebo swipem) se jde na dalšího – IV
#    a tagy každého se přečtou bez zavírání detailu
# 3) rozhodne se v paměti (horší duplicity, správný IV tag)
# 4) tagy se nastaví hromadně: v seznamu se vyberou všichni, kdo mají dostat (nebo ztratit)
#    stejný tag, a nastaví se najednou
class FastState:
    """Rozpracovaný rychlý průchod jednoho seznamu – přežije chybu a návrat do boxu."""

    def __init__(self):
        self.seq = None          # buňky seznamu v pořadí
        self.recs = {}           # index -> přečtený Pokémon z detailu
        self.scanned = False
        self.planned = False     # duplicity rozhodnuté
        self.iv_planned = False
        self.pvp_planned = False
        self.rename_planned = False
        self.identified = False
        self.passes = []         # [(tag, odebrat?, indexy)] – zbývající hromadná tagování
        self.pass_fails = 0      # neúspěšné pokusy o aktuální dávku
        self.group_of = {}       # index -> číslo skupiny (duplicity)
        self.upto = None         # kam až číst (limit skupin duplicit)
        self.index_rec = {}      # index -> Rec (výsledky pro přehled)
        self.phantom = set()     # buňky seznamu, které ve hře nejsou (zdvojené při posouvání)
        self.extra = []          # přečtení Pokémoni, kteří v seznamu chybí
        self.scan_fail = {}      # index -> kolikrát se od něj nepodařilo číst
        self.cache_hits = 0      # kolik kusů se vzalo z paměti (minulý běh) místo čtení


def emit_counts(bot, changed=None, delta=0):
    """Panel „Tagy v inventáři“: kolik kusů má který tag (průběžně)."""
    emit("tagcounts", counts=bot.tag_counts, total=bot.box_total, changed=changed, delta=delta)


def count_tags(bot, st):
    """Po přečtení celého boxu: počty kusů v každém známém tagu podle toho, co je teď ve hře."""
    known = [TAG_NAME] + [n for _, n in IV_TAGS] + [lg["name"] for lg in PVP.values()]
    bot.tag_counts = {n: 0 for n in known}
    for rec in st.recs.values():
        for n in rec.get("tags") or []:
            if n in bot.tag_counts:
                bot.tag_counts[n] += 1
    bot.box_total = len(st.seq)
    emit_counts(bot)


def require_top(bot):
    """Krok potřebuje seznam od začátku: když není, inventář se zavře a otevře znovu."""
    if not bot.fresh_list:
        reopen_box(bot)
        raise NeedTop(T("seznam potřebuju od začátku", "I need the list from the top"))
    bot.fresh_list = False


def same_cell(a, b):
    low = max(a.get("cy", 0), b.get("cy", 0)) > 0.70     # spodní jména bývají napůl schovaná
    return a["cp"] == b["cp"] and (low or names_ok(a["name"], b["name"]))


def merge_screen(seq, cells):
    """Přidá do seq buňky nové obrazovky; překryv s předchozí obrazovkou vynechá. Snese jednu
    špatně přečtenou buňku v překryvu (jinak by se celý řádek zapsal dvakrát)."""
    best = 0
    for k in range(min(len(cells), len(seq)), 0, -1):
        hits = sum(1 for i in range(k) if same_cell(seq[len(seq) - k + i], cells[i]))
        if hits == k or (k >= 3 and hits >= k - 1):
            best = k
            break
    seq.extend(cells[best:])


def merge_by_shift(seq, prev, cells, shift):
    """Nové buňky po posunu o shift: všechno, co leží pod posledním řádkem předchozí obrazovky prev.
    Buňku posledního řádku, kterou předchozí obrazovka nepřečetla, doplní na její místo."""
    bottom = max(c["cy"] for c in prev)
    last = [c for c in prev if c["cy"] > bottom - 0.03]
    for c in sorted((c for c in cells if abs(c["cy"] + shift - bottom) < 0.06), key=lambda c: c["cx"]):
        if not any(o["cp"] == c["cp"] and abs(o["cx"] - c["cx"]) < 0.06 for o in last):
            k = len(seq) - len(last) + sum(1 for o in last if o["cx"] < c["cx"])
            seq.insert(k, c)
            last.append(c)
    seq.extend(c for c in cells if c["cy"] + shift > bottom + 0.06)


def locate(seq, cells, hint=0):
    """Index v seq, kde začíná obrazovka cells (podle pořadí CP a jmen), nebo None.
    Hledá nejdřív kolem nápovědy, pak v celém seznamu."""
    near = _locate(seq, cells, range(max(0, hint - 8), min(len(seq), hint + 40)))
    return near if near is not None else _locate(seq, cells, range(len(seq)))


def _locate(seq, cells, offsets):
    best = None
    need = max(min(2, len(cells)), int(0.7 * len(cells)))   # výsledek hledání může mít jen 1 buňku
    for o in offsets:
        n = sum(1 for i, c in enumerate(cells) if o + i < len(seq) and same_cell(seq[o + i], c))
        if n >= need and (best is None or n > best[1]):
            best = (o, n)
    return best[0] if best else None


def grid_scan(bot):
    """Projede seznam shora dolů (jen posouvání) a vrátí všechny buňky v pořadí."""
    require_top(bot)
    step(T("Procházím seznam Pokémonů", "Going through the Pokémon list"))
    seq = []
    cells, fr = read_grid(bot)
    bot.shown_count = box_count(fr.texts) if bot.mode == "all" else None
    merge_screen(seq, cells)
    while True:
        emit("scan", what="seznam", n=len(seq))
        prev = cells
        if not scroll_next(bot, cells):
            break
        cells, fr = read_grid(bot)
        if bot.last_shift is not None:
            merge_by_shift(seq, prev, cells, bot.last_shift)
        else:
            merge_screen(seq, cells)
    shown = bot.shown_count
    log(T(f"   v seznamu je {pokemon_count(len(seq))}", f"   the list has {pokemon_count(len(seq))}") +
        (T(f" (hra ukazuje {shown} – rozdíl srovná čtení IV)", f" (the game shows {shown} – reading the IV evens it out)")
         if shown and shown != len(seq) else ""))
    return seq


def open_cell(bot, seq, idx, skip=()):
    """Najde v seznamu Pokémona seq[idx] a otevře jeho detail (hledá od aktuální polohy dolů).
    skip = buňky, které ve hře nejsou (zdvojené při posouvání) – při hledání se vynechají."""
    view = [k for k in range(len(seq)) if k not in skip or k == idx]
    vseq, vidx = [seq[k] for k in view], view.index(idx)
    hint = 0
    while True:
        cells, fr = read_grid(bot)
        off = locate(vseq, cells, hint)
        if off is not None and off <= vidx < off + len(cells):
            return open_detail(bot, cells[vidx - off])
        if off is not None and off > vidx:
            raise LostPosition(T("Pokémon, u kterého se má pokračovat, je výš v seznamu",
                                 "the Pokémon to continue from is higher up in the list"))
        if not scroll_next(bot, cells):
            raise StepError(T(f"Pokémona č. {idx + 1} v seznamu nenacházím", f"can't find Pokémon no. {idx + 1} in the list"))
        hint = (off if off is not None else hint) + max(1, len(cells) - 3)


def detail_fp(fr):
    """Otisk Pokémona v detailu – změní se, když se přejde na dalšího."""
    tx = fr.texts
    hp = next((alnum(t["text"]) for t in tx if HP_RE.match(norm(t["text"]))), "")
    labels = bar_labels(tx)
    return detail_cp(tx), alnum(detail_name(tx)), hp, read_bars(fr.img, labels)[0] if labels else None


def quick_fp(fr):
    """Otisk Pokémona z rychlého OCR (16 ms místo 86): CP, jméno, HP a hodnoty barů (bary z pixelů)."""
    tx = fr.fast
    hp = next((alnum(t["text"]) for t in tx if HP_RE.match(norm(t["text"]))), "")
    labels = bar_labels(tx)
    return detail_cp(tx), alnum(detail_name(tx)), hp, (read_bars(fr.img, labels)[0] if labels else None)


def fp_change(a, b):
    """2 = určitě jiný Pokémon (jiné jméno nebo jiné bary), 1 = možná (liší se jen CP nebo HP – rychlé
    OCR se mohlo splést), 0 = stejný. Co rychlé OCR nepřečetlo, nerozhoduje."""
    if not (b[0] or b[1]):
        return 0
    if a[1] and b[1] and difflib.SequenceMatcher(None, a[1], b[1]).ratio() < 0.8:
        return 2
    if a[3] and b[3] and tuple(a[3]) != tuple(b[3]):
        return 2
    if (a[0] and b[0] and a[0] != b[0]) or (a[2] and b[2] and a[2] != b[2]):
        return 1
    return 0


def next_pokemon(bot, fr=None):
    """V appraisalu přejde na dalšího Pokémona: šipka ▶ vpravo u barů, jinak swipe doleva přes
    obrázek Pokémona. Vrací snímek s novým Pokémonem, nebo None (konec seznamu / nejde to).
    fr = snímek aktuálního Pokémona. Přechod se pozná rychlým OCR; když se liší jen CP nebo HP,
    ověří se přesným."""
    fr = fr or bot.frame()
    labels = bar_labels(fr.fast)
    before = quick_fp(fr)

    def changed(f):
        c = fp_change(before, quick_fp(f))
        if c == 1:
            a, b = detail_fp(fr), detail_fp(f)
            return a[:3] != b[:3] and bool(b[0] or b[1])
        return c == 2
    # šipka jen když jsou vidět bary appraisalu – v obyčejném detailu je na jejím místě řádek EVOLVE
    for how in (("arrow", "swipe") if labels else ("swipe",)):
        if how == "arrow":
            t0 = bot.tap(0.975, labels[1]["cy"] + 0.01, T("další Pokémon (▶)", "next Pokémon (▶)"), fr=fr)
        else:
            t0 = bot.drag((0.80, 0.22), (0.20, 0.22), T("další Pokémon (swipe)", "next Pokémon (swipe)"), ms=260, hold=0, fr=fr)
        ok, f = bot.wait_for(changed, 2.5, after=t0 + FRAME_LAG, label="další Pokémon")
        if ok:
            return f
        fr = f
    return None


def read_here(bot, fr, iv):
    """Co je vidět v detailu / appraisalu: CP, jméno, typy, HP, cukr, IV a tagy."""
    tx = fr.texts
    have, removable = detail_chips(tx)
    return {"cp": detail_cp(tx), "name": detail_name(tx), "types": detail_types(tx), "hp": detail_hp(tx),
            "candy": detail_candy(tx), "iv": tuple(iv) if iv else None, "have": have, "removable": removable,
            "tags": detail_tags(tx)}


class Done:
    """Hotový výsledek se stejným rozhraním jako Future z ThreadPoolExecutoru."""

    def __init__(self, value):
        self.value = value

    def result(self):
        return self.value


def cp_match(cell_cp, rec_cp):
    """CP z mřížky vs. z detailu: 2 = stejné, 1 = OCR v appraisalu přečetlo jen začátek nebo číslici navíc
    (2134 / 21, 3277 / 32772), 0 = ne. Shoda 1 platí jen se stejným jménem (match_score)."""
    if cell_cp is None or rec_cp is None:
        return 0
    if cell_cp == rec_cp:
        return 2
    a, b = str(cell_cp), str(rec_cp)
    return 1 if min(len(a), len(b)) >= 2 and (a.startswith(b) or b.startswith(a)) else 0


def match_score(cell, rec):
    """Jak dobře přečtený Pokémon (z detailu) sedí na buňku seznamu; 0 = vůbec."""
    rn = alnum(rec.get("name") or "")
    names = names_ok(cell["name"], rec.get("name") or "") or (len(rn) >= 4 and rn[:5] == alnum(cell["name"])[:5])
    c = cp_match(cell["cp"], rec.get("cp"))
    if c == 2:
        return 3 if names else 2
    if c == 1 and names:
        return 1.5
    if rec.get("cp") is None and rn and names:
        return 1
    return 0


def align(st, expect, rec):
    """Index v seznamu pro přečteného Pokémona. Čeká se expect; seznam z posouvání může mít buňku
    zdvojenou (přeskočí se) nebo mu buňka může chybět (vrátí se). None = poblíž nesedí nic."""
    best, best_key = None, None
    for j in range(max(0, expect - 3), min(len(st.seq), expect + 10)):
        if j < expect and j in st.recs:
            continue                          # zpátky jen na nepřečtenou buňku (jinak by přepsal jiný kus)
        sc = match_score(st.seq[j], rec)
        if sc <= 0:
            continue
        key = (sc, -abs(j - expect) - (0.5 if j < expect else 0))
        if best_key is None or key > best_key:
            best, best_key = j, key
    return best


def unread(st, total):
    return [k for k in range(total) if k not in st.recs and k not in st.phantom]


def drop_phantoms(st, total):
    """Po přečtení všech kusů srovná seznam s tím, co ukázala šipka ▶: buňky, které ve hře nejsou
    (zdvojené při posouvání), vyhodí a kusy, které při posouvání chyběly, vloží na jejich místo
    (pak jdou otagovat přes hledání podle CP jako ostatní). Vrací počet vyhozených buněk."""
    gone = {k for k in st.phantom if k < total and k not in st.recs}
    st.phantom = set()
    st.scan_fail = {}
    extra, st.extra = st.extra, []
    if not gone and not extra:
        return 0
    after = {}
    for rec in extra:
        after.setdefault(rec.pop("after", -1), []).append(rec)
    seq, recs, new = [], {}, {}

    def add_extra(k):
        for rec in after.get(k, []):
            recs[len(seq)] = rec
            seq.append({"cp": rec["cp"], "name": rec["name"] or "", "sprite": None, "cx": 0.0, "cy": 0.0,
                        "row": 0, "sig": f"{rec['cp']}|{alnum(rec['name'] or '')}"})

    add_extra(-1)
    for k in range(len(st.seq)):
        if k not in gone:
            new[k] = len(seq)
            seq.append(st.seq[k])
            if k in st.recs:
                recs[new[k]] = st.recs[k]
        add_extra(k)
    if st.upto is not None:
        st.upto = new.get(st.upto, len(seq)) if st.upto < len(st.seq) else len(seq)
    st.seq, st.recs = seq, recs
    st.group_of = {new[k]: g for k, g in st.group_of.items() if k in new}
    st.added = sum(len(v) for v in after.values())
    return len(gone)


def at_end(bot, st, last, total):
    """Šipka ▶ ani swipe nikam nevedou: je to poslední Pokémon v boxu? Když je známý počet z hlavičky
    boxu, musí být přečtení všichni; jinak smí zbýt nejvýš pár buněk (zdvojené na konci seznamu)."""
    left = [k for k in unread(st, total) if k > last]
    if not left:
        return True
    if bot.shown_count and total == len(st.seq):
        return len(st.recs) + len(st.extra) >= bot.shown_count
    return len(left) <= 3


def scan_details(bot, st, upto=None):
    """IV a tagy všech Pokémonů v st.seq: detail + appraisal, pak šipkou ▶ na další. Každý přečtený
    kus se podle CP a jména srovná se seznamem z posouvání (ten může mít buňku zdvojenou, nebo mu
    může chybět). Po chybě pokračuje od prvního nepřečteného; přečtené kusy znovu nečte."""
    total = len(st.seq) if upto is None else upto
    expected = bot.shown_count if upto is None and bot.shown_count else total
    first_segment = True
    while True:
        todo = unread(st, total)
        if not todo:
            break
        start = todo[0]
        if st.scan_fail.get(start, 0) >= 2:      # odsud se číst opakovaně nedaří – kus vynechat
            log(T(f"   kus č. {start + 1} (CP{st.seq[start]['cp']}) se nedaří otevřít, vynechávám ho",
                  f"   can't open no. {start + 1} (CP{st.seq[start]['cp']}), skipping it"))
            st.phantom.add(start)
            continue
        st.scan_fail[start] = st.scan_fail.get(start, 0) + 1
        if first_segment:
            require_top(bot)
            first_segment = False
        step(T("Čtu IV: ", "Reading IV: ") + f"{len(st.recs) + 1}/{expected}")
        fr = open_cell(bot, st.seq, start, st.phantom)
        open_detail_menu(bot, fr)
        t, fr = bot.stable_text([L["appraise"]], exact=True, region=(0.4, 0.55, 1.0, 0.92))
        if t is None:
            raise StepError(T("v menu chybí APPRAISE", "APPRAISE is missing in the menu"))
        bot.act((t["cx"], t["cy"]), "APPRAISE", lambda f: classify(f) == "appraisal", timeout=2.5, fr=fr, tries=1)
        expect, last, seen_cp, first = start, start - 1, None, True

        def quick(f, vals):                    # IV z barů přesně sedí na CP a HP kusu → bary jsou dojeté
            r = read_here(bot, f, vals)
            return r if pokecalc.iv_fits(r["name"], r["types"], r["cp"], r["hp"], vals, r["candy"]) else None

        iv = read_appraisal(bot, st.seq[start]["cp"], quick=quick)
        while True:
            here = bot.bars_frame if iv else bot.frame()
            st.quick_n = getattr(st, "quick_n", 0) + (bot.bars_rec is not None)
            # přesné OCR tohohle kusu běží na pozadí, zatímco šipka ▶ jde na dalšího
            job = Done(bot.bars_rec) if bot.bars_rec is not None else READER.submit(read_here, bot, here, iv)
            ahead = next((k for k in unread(st, total) if k > expect), None)
            go_on = ahead is not None and ahead - expect <= 12
            fr = next_pokemon(bot, here) if go_on else None
            rec = job.result()
            if rec["cp"] is None:
                rec["cp"] = seen_cp                # CP z přechodu na tohoto Pokémona
            j = align(st, expect, rec)
            ivs = "/".join(map(str, rec["iv"])) if rec["iv"] else "?"
            if j is None:
                key = (rec["cp"], alnum(rec["name"] or ""), rec["iv"])
                if all((x["cp"], alnum(x["name"] or ""), x["iv"]) != key for x in st.extra):
                    rec["after"] = last            # v seznamu patří hned za tenhle index
                    rec["t"] = time.time()
                    st.extra.append(rec)
                    bot.progress += 1
                n = len(st.recs) + len(st.extra)
                log(f"   {n}/{expected} CP{rec['cp']} {rec['name']}: IV {ivs} " +
                    T("(v seznamu z posouvání chyběl – doplním)", "(missing from the scrolled list – adding it)"))
                emit("scan", what="iv", n=min(n, expected), total=expected, cp=rec["cp"], name=rec["name"],
                     iv=list(rec["iv"]) if rec["iv"] else None)
            else:
                for k in range(expect, j):
                    if k not in st.recs:
                        st.phantom.add(k)         # buňka, která ve hře není (zdvojená)
                st.phantom.discard(j)
                if rec["cp"] is None:
                    rec["cp"] = st.seq[j]["cp"]   # v appraisalu nebylo CP čitelné – mřížka ho má
                rec["t"] = time.time()
                st.recs[j] = rec
                st.scan_fail.pop(j, None)
                last, expect = j, j + 1
                bot.progress += 1
                n = len(st.recs) + len(st.extra)
                st.scan_t = getattr(st, "scan_t", None) or [time.time(), n - 1]
                log(f"   {n}/{expected} CP{rec['cp']} {rec['name']}: IV {ivs}" +
                    (f" · {', '.join(rec['have'])}" if rec["have"] else ""))
                emit("scan", what="iv", n=min(n, expected), total=expected, cp=rec["cp"], name=rec["name"],
                     iv=list(rec["iv"]) if rec["iv"] else None)
                step(T("Čtu IV: ", "Reading IV: ") + f"{min(n, expected)}/{expected}")
            nxt = next((k for k in unread(st, total) if k > last), None)
            if not go_on or nxt is None or nxt - last > 12:
                break                          # hotovo, nebo je další nepřečtený daleko – otevře se znovu
            if fr is None:
                if first and not st.recs.keys() - {start}:
                    raise NoNavigation(T("v appraisalu nejde přejít na dalšího Pokémona", "the appraisal can't move to the next Pokémon"))
                if at_end(bot, st, last, total):
                    for k in unread(st, total):
                        if k > last:
                            st.phantom.add(k)
                    break
                raise StepError(T("na dalšího Pokémona se nepodařilo přejít", "couldn't move to the next Pokémon"))
            first = False
            seen_cp = detail_cp(fr.fast)
            if not bar_labels(fr.fast) and classify(fr) == "detail":   # appraisal se zavřel – otevřít znovu
                open_detail_menu(bot, fr)
                t, fr = bot.stable_text([L["appraise"]], exact=True, region=(0.4, 0.55, 1.0, 0.92))
                if t is None:
                    raise StepError(T("v menu chybí APPRAISE", "APPRAISE is missing in the menu"))
                bot.act((t["cx"], t["cy"]), "APPRAISE", lambda f: classify(f) == "appraisal", timeout=2.5, fr=fr,
                        tries=1)
            iv = read_appraisal(bot, seen_cp or st.seq[min(expect, len(st.seq) - 1)]["cp"], prev=rec["iv"],
                                quick=quick)
        for _ in range(4):                     # zavřít appraisal a detail
            if classify(bot.frame()) != "appraisal":
                break
            try:
                bot.act(P_NEUTRAL, T("zavřít appraisal", "close appraisal"), lambda f: classify(f) != "appraisal", timeout=1.2, tries=1)
            except StepError:
                pass
        close_detail(bot)
    t0n = getattr(st, "scan_t", None)
    if t0n and len(st.recs) + len(st.extra) - t0n[1] >= 10:
        dt, n = time.time() - t0n[0], len(st.recs) + len(st.extra) - t0n[1]
        quick = round(100 * st.quick_n / max(1, n))
        log(T(f"   ⏱ čtení IV: {pokemon_count(n)} za {int(dt // 60)}:{int(dt % 60):02d} "
              f"({dt / n:.2f} s na kus, bary rychle potvrzené u {quick} %)",
              f"   ⏱ IV reading: {pokemon_count(n)} in {int(dt // 60)}:{int(dt % 60):02d} "
              f"({dt / n:.2f} s each, bars quick-confirmed for {quick}%)"))
        emit("speed", per=round(dt / n, 2), n=n)
    gone = drop_phantoms(st, total)
    added = getattr(st, "added", 0)
    if gone or added:
        log(T(f"   seznam srovnán podle detailů: {pokemon_count(len(st.recs))}",
              f"   list matched to the details: {pokemon_count(len(st.recs))}") +
            (T(f", {gone} zdvojených buněk vyhozeno", f", {gone} doubled cells dropped") if gone else "") +
            (T(f", {added} chybějících doplněno", f", {added} missing ones added") if added else ""))


def cp_query(cps, base=None):
    """Hledání, které ukáže jen Pokémony s daným CP (cp2260,cp2268,…); base = další podmínka (&…)."""
    q = ",".join(f"cp{c}" for c in sorted(cps))
    return f"{q}&{base}" if base else q


def search_view(seq, idxs, base=None):
    """Pro hromadnou práci přes hledání: (hledání, pohled) – pohled = indexy seq, které hra po
    napsání hledání ukáže, ve stejném pořadí (seznam je pořád řazený podle čísla)."""
    cps = {seq[i]["cp"] for i in idxs}
    # kusy, které hledání podle CP už dvakrát nenašlo (ve hře s tím CP nejsou), ve výsledcích nebudou
    return cp_query(cps, base), [k for k in range(len(seq)) if seq[k]["cp"] in cps and seq[k].get("miss", 0) < 2]


def show_search(bot, query):
    """Box jen s výsledky hledání query, od začátku seznamu."""
    bot.mode, bot.query = "cp", query
    ensure_box(bot)
    require_top(bot)


def match_view(vseq, cells, lo=0):
    """Obrazovka výsledků hledání -> {index buňky: index ve vseq} (páruje se od vseq[lo]). Pořadí sedí
    (výsledky jsou seřazené jako celý seznam), ale kus může ve hře chybět (špatně přečtené CP) nebo
    přebývat – páruje se proto nejdelší společnou posloupností podle CP a jména, ne pevným posunem.
    Ze stejně dlouhých párování vyhraje souvislejší (mezera mezi páry stojí bod)."""
    lo = max(0, lo)
    cand = list(range(lo, len(vseq)))
    n, m = len(cells), len(cand)
    hit = [[same_cell(vseq[j], c) for j in cand] for c in cells]
    inner = [[0] * (m + 1) for _ in range(n + 1)]   # už je něco spárované – mezera stojí bod
    lead = [[0] * (m + 1) for _ in range(n + 1)]    # ještě nic – vynechání na začátku je zdarma
    for a in range(n - 1, -1, -1):
        for b in range(m - 1, -1, -1):
            take = 100 + inner[a + 1][b + 1] if hit[a][b] else 0
            inner[a][b] = max(0, take, inner[a][b + 1] - 1, inner[a + 1][b] - 1)
            lead[a][b] = max(0, take, lead[a][b + 1], lead[a + 1][b])
    out, a, b, started = {}, 0, 0, False
    while a < n and b < m:
        table, cost = (inner, 1) if started else (lead, 0)
        cur = table[a][b]
        if cur <= 0:
            break
        if hit[a][b] and cur == 100 + inner[a + 1][b + 1]:
            out[a] = cand[b]
            a, b, started = a + 1, b + 1, True
        elif cur == table[a][b + 1] - cost:
            b += 1                 # kus vseq[cand[b]] na obrazovce není
        else:
            a += 1                 # buňka, která ve vseq není
    return out


def next_lo(cells, pairs, lo):
    """Odkud párovat další obrazovku: po posunu zůstane nahoře poslední řádek (rezerva o řádek)."""
    if not pairs:
        return lo
    last = max(c["row"] for c in cells)
    row = [pairs[k] for k, c in enumerate(cells) if c["row"] == last and k in pairs]
    return max(lo, (min(row) if row else max(pairs.values())) - 3)


def search_empty(bot):
    """Hledání nic nenašlo? V hlavičce je „(0)“, nebo se ani po chvilce neukáže žádná buňka."""
    done = lambda f: complete_cells(f.texts) or search_count(f.texts) == 0
    fr = bot.frame()
    if not done(fr):
        _, fr = bot.wait_for(done, 1.5, label="výsledky hledání")
    return not complete_cells(fr.texts) and classify(fr) == "box_other"


def mark_missing(seq, idxs, sure):
    """Kusy seq[i], které hledání podle CP nenašlo. Napoprvé se zkusí ještě jednou (buňka se mohla jen
    špatně přečíst); když je jisté, že ve hře nejsou, nebo je hledání nenašlo podruhé, vynechají se
    i v dalších krocích. Vrací ty, které se vynechávají."""
    out = []
    for i in idxs:
        seq[i]["miss"] = seq[i].get("miss", 0) + (2 if sure else 1)
        if seq[i]["miss"] >= 2:
            out.append(i)
    return out


def empty_search(bot, seq, idxs, query):
    """Když hledání nic nenašlo, označí kusy seq[i] jako chybějící a vrátí ty, které se vynechávají
    (jinak None). Jisté je to, když v poli Search je přesně napsané hledání; jinak se mohlo napsat
    špatně – příště se smaže a napíše znovu."""
    if not search_empty(bot):
        return None
    exact = filter_key(search_bar_text(bot.frame().texts)) == filter_key(query)
    if not exact:
        bot.typed_query = None             # příště hledání smazat a napsat znovu
    log(T("   hledání nic nenašlo – ", "   the search found nothing – ") +
        (T("Pokémon s tímhle CP ve hře není (CP se nejspíš přečetlo špatně), přeskakuji",
           "there's no Pokémon with this CP in the game (the CP was probably misread), skipping") if exact
         else T("zkusím ho napsat znovu", "typing it again")))
    return mark_missing(seq, idxs, sure=exact)


def tag_batch(bot, seq, idxs, tag, remove=False, base=None):
    """Hromadně přidá tag Pokémonům seq[i] (i v idxs, nejvýš SEARCH_BATCH najednou), nebo ho odebere.
    Do hledání napíše jejich CP (cp2260,cp2268,…), takže hra ukáže jen je (a pár dalších se stejným
    CP) na jedné až dvou obrazovkách – celý seznam se neprojíždí. base = hledání, ze kterého seq je
    (duplicity), přidá se za CP. Vrací (indexy seq, kterým se tag nastavil, indexy seq, které ve hře
    nejsou – hledání podle CP je nenašlo, nejspíš mají špatně přečtené CP; ty se vynechají a zbytek
    dávky se otaguje normálně)."""
    gone = [i for i in idxs if seq[i].get("miss", 0) >= 2]
    need = sorted(i for i in idxs if seq[i].get("miss", 0) < 2)[:SEARCH_BATCH]
    if not need:
        return [], gone
    query, view = search_view(seq, need, base)
    vseq = [seq[k] for k in view]
    vpos = {k: n for n, k in enumerate(view)}
    want = {vpos[i] for i in need}
    show_search(bot, query)
    what = T(f"{'Odebírám' if remove else 'Přidávám'} tag {tag}: {pokemon_count(len(need))}",
             f"{'Removing' if remove else 'Adding'} tag {tag}: {pokemon_count(len(need))}")
    log(f"\n   {what}")
    step(what)
    lost = empty_search(bot, seq, need, query)
    if lost is not None:
        return [], gone + lost
    fr = bot.frame()
    found = search_count(fr.texts)             # kolik kusů hledání našlo („(12)“ v hlavičce)
    exact = filter_key(search_bar_text(fr.texts)) == filter_key(query)   # hledání v poli celé a správně
    others = set(range(len(vseq))) - want      # ve výsledcích hledání, ale tag nedostanou
    chosen, state = set(), {"lo": 0, "fr": None, "scrolled": False}

    def toggle(c, v, fr, on):
        """Klepne na buňku (vybrat / odebrat z výběru) a počká, až se změní počet v TAG (n)."""
        n_want = len(chosen) + (1 if on else -1)
        if not chosen:
            t0 = bot.long_press(c["cx"], c["cy"] + CELL_TAP_DY, T(f"podržet CP{c['cp']}", f"hold CP{c['cp']}"), fr=fr)
            n, fr = bot.wait_for(lambda f: tag_count(f.texts), 2.5, after=t0 + FRAME_LAG, label="multiselect")
            if n != 1:
                raise StepError(T(f"multiselect se nespustil (TAG {n})", f"multi-select didn't start (TAG {n})"))
        else:
            t0 = bot.tap(c["cx"], c["cy"] + SELECT_TAP_DY, T(f"{'vybrat' if on else 'odebrat z výběru'} CP{c['cp']}", f"{'select' if on else 'deselect'} CP{c['cp']}"),
                         fr=fr)
            _, fr = bot.wait_for(lambda f: tag_count(f.texts) == n_want, 2.0, after=t0 + FRAME_LAG, label="výběr")
            if tag_count(fr.texts) != n_want:
                raise StepError(T(f"výběr nesedí (TAG {tag_count(fr.texts)}, čekal jsem {n_want})",
                                  f"the selection is off (TAG {tag_count(fr.texts)}, expected {n_want})"))
        (chosen.add if on else chosen.discard)(v)
        return fr

    def visit(todo, on, first_only=False):
        """Projde výsledky hledání od aktuální polohy dolů a klepne na buňky todo (indexy vseq) –
        jen na ty, které se spárují s CP i jménem. Vrací ty, které ve výsledcích nenašel."""
        left = set(todo)
        while left:
            cells, fr = read_grid(bot)
            pairs = match_view(vseq, cells, state["lo"])
            if not pairs:
                raise StepError(T("ve výsledcích hledání se nedá zorientovat", "can't find my way in the search results"))
            for k, c in enumerate(cells):
                v = pairs.get(k)
                if v in left and c["cp"] == vseq[v]["cp"]:
                    fr = toggle(c, v, fr, on)
                    left.discard(v)
                    if first_only:
                        state["fr"] = fr
                        return left
            state["fr"] = fr
            if not left or max(left) < max(pairs.values()):
                break                          # zbylé měly být výš – ve výsledcích nejsou
            n_before = len(chosen)
            if not scroll_next(bot, cells, multi=bool(chosen)):
                break                          # konec výsledků
            state["scrolled"] = True
            if chosen and tag_count(bot.frame().texts) != n_before:
                raise StepError(T("posun změnil výběr", "scrolling changed the selection"))
            state["lo"] = next_lo(cells, pairs, state["lo"])
        return left

    def missed(left):
        """Kusy, které ve výsledcích nejsou. Jistě chybí, když je hledání v poli celé a hra našla
        o tolik kusů méně, než čeká seznam; jinak se zkusí ještě v další dávce."""
        sure = exact and found is not None and len(left) <= len(vseq) - found
        return mark_missing(seq, [view[v] for v in left], sure)

    visit(want, True, first_only=True)            # výběr se spustí podržením prvního cíle
    if not chosen:
        log(T("   nikoho z nich ve výsledcích hledání nevidím, přeskakuji", "   none of them are in the search results, skipping"))
        return [], gone + missed(want)
    fr = state["fr"]
    sa = None
    if bot.select_all_ok and not state["scrolled"] and len(want) >= 3 and len(others) <= len(want) // 3 \
            and len(vseq) <= 100 and found in (None, len(vseq)):
        sa = find_text(fr.texts, [L["select_all"]], region=(0.3, 0.0, 1.0, 0.2))
    left = set()
    if sa is not None:
        # SELECT ALL vybere všechny výsledky hledání; kusy navíc (stejné CP) se pak odklepnou
        t0 = bot.tap(sa["cx"], sa["cy"], T("vybrat všechny výsledky (SELECT ALL)", "select all results (SELECT ALL)"), fr=fr)
        _, fr = bot.wait_for(lambda f: (tag_count(f.texts) or 0) >= len(vseq), 2.5, after=t0 + FRAME_LAG,
                             label="vybrat vše")
        cnt = tag_count(fr.texts)
        if cnt == len(vseq):
            chosen.update(range(len(vseq)))
            state["fr"] = fr
            if others and visit(others, False):
                raise StepError(T("kusy navíc se nepodařilo odebrat z výběru", "couldn't deselect the extra ones"))
        else:
            # výsledků je jinak, než čeká seznam (kus chybí nebo přebývá): výběr zrušit a vybrat po jednom
            if cnt is None or cnt > len(vseq) + 3:
                bot.select_all_ok = False      # SELECT ALL nejspíš nebere ohled na hledání – dál po jednom
            log(T(f"   SELECT ALL vybral {cnt}, ve výsledcích čekám {len(vseq)} – vybírám po jednom",
                  f"   SELECT ALL picked {cnt}, the results should have {len(vseq)} – selecting one by one"))
            bot.act(P_MULTI_CLOSE, T("zrušit výběr", "cancel selection"), lambda f: classify(f) != "multiselect", fr=fr, tries=1)
            chosen.clear()
            left = visit(want, True)
            if not chosen:
                return [], gone + missed(want)
    else:
        left = visit(want - chosen, True)
    fr = state["fr"]
    selected = sorted(chosen)
    if not selected or tag_count(fr.texts) != len(selected) or set(selected) - want:
        raise StepError(T(f"výběr nesedí (TAG {tag_count(fr.texts)}, vybráno {len(selected)})",
                          f"the selection is off (TAG {tag_count(fr.texts)}, selected {len(selected)})"))
    if left:
        log(T("   ve výsledcích hledání nevidím: ", "   not in the search results: ") + ", ".join(f"CP{vseq[v]['cp']}" for v in sorted(left)))
    tb = tag_button(fr.texts)
    if tb is None:
        raise StepError(T("nevidím tlačítko TAG", "can't see the TAG button"))
    _, fr = bot.act((tb["cx"], tb["cy"]), f"TAG ({len(selected)})", lambda f: tag_list_on(f.texts),
                    timeout=2.5, fr=fr, tries=1)
    fr = bot.settle(fr, region=LIST_REGION)
    if remove:
        row, fr = scan_tag_list(bot, fr, ["dolů", "nahoru"], tag)
        if row is not None:
            on, fr = wait_checked(bot, fr, tag)      # fajfka se může ukázat až chvilku po otevření výběru
            if on or row_state(fr, tag) == "mixed":  # „Mixed“: má ho jen část vybraných – i těm ho odebrat
                fr = set_row(bot, fr, tag, False)
    else:
        fr = pick_tag(bot, fr, tag)
    d = find_text(fr.texts, [L["done"]], exact=True, region=(0.0, 0.7, 1.0, 0.95))
    if d is None:
        raise StepError(T("nevidím DONE", "can't see DONE"))
    bot.act((d["cx"], d["cy"]), "DONE", lambda f: classify(f) in ("box", "box_other"), timeout=3, fr=fr, tries=1)
    log(T(f"   ✔ tag {tag} {'odebrán' if remove else 'přidán'}: {pokemon_count(len(selected))}",
          f"   ✔ tag {tag} {'removed' if remove else 'added'}: {pokemon_count(len(selected))}"))
    return [view[v] for v in selected], gone + (missed(left) if left else [])


def note_tag(rec, tag, remove):
    """Po hromadném tagování: záznam kusu odpovídá tomu, co je teď ve hře (paměť pro další běh)."""
    if rec is None:
        return
    rec["tags"] = [t for t in (rec.get("tags") or []) if t != tag] + ([] if remove else [tag])
    if tag in {n for _, n in IV_TAGS}:
        rec["have"] = [t for t in (rec.get("have") or []) if t != tag] + ([] if remove else [tag])
    if tag == TAG_NAME:
        rec["removable"] = not remove


def run_passes(bot, st, on_done):
    """Provede zbývající hromadná tagování (st.passes); po každé dávce zavolá on_done(tag, remove, indexy).
    Taguje se v st.seq (s hledáním st.tag_base), nebo – když duplicity převzaly data z přečteného celého
    boxu – v st.tag_full.seq přes převod indexů st.tag_map. Kusy, které hra podle CP nenajde, se
    vynechají a běh pokračuje."""
    full, fwd = getattr(st, "tag_full", None), getattr(st, "tag_map", None)
    back = {j: i for i, j in fwd.items()} if full is not None else None
    cell = (lambda i: full.seq[fwd[i]]) if full is not None else (lambda i: st.seq[i])
    while st.passes:
        tag, remove, idxs = st.passes[0]
        if full is not None:
            idxs = [i for i in idxs if i in fwd]
        if not idxs:
            st.passes.pop(0)
            continue
        try:
            if full is not None:
                done, gone = tag_batch(bot, full.seq, [fwd[i] for i in idxs], tag, remove)
                done, gone = [back[j] for j in done], [back[j] for j in gone]
            else:
                done, gone = tag_batch(bot, st.seq, idxs, tag, remove, getattr(st, "tag_base", None))
        except (Fatal, TagCreated, NeedTop):
            raise
        except StepError:
            st.pass_fails += 1
            if st.pass_fails >= 3:      # tyhle Pokémony se nedaří vybrat – vynechat, ať běh nestojí
                log(T(f"   ✖ tag {tag} se u {pokemon_count(len(idxs))} nepodařilo nastavit, vynechávám je",
                      f"   ✖ couldn't set tag {tag} for {pokemon_count(len(idxs))}, skipping them"))
                emit("problem", text=T(f"Tag {tag} se u {pokemon_count(len(idxs))} nepodařilo nastavit – "
                                       f"zkontroluj je ručně.",
                                       f"Couldn't set tag {tag} for {pokemon_count(len(idxs))} – check them yourself."))
                st.passes.pop(0)
                st.pass_fails = 0
                continue
            raise
        st.pass_fails = 0
        bot.progress += len(done)
        if tag in bot.tag_counts or not remove:
            bot.tag_counts[tag] = max(0, bot.tag_counts.get(tag, 0) + (-len(done) if remove else len(done)))
            emit_counts(bot, tag, -len(done) if remove else len(done))
        on_done(tag, remove, done)
        for i in done:
            note_tag(full.recs.get(fwd[i]) if full is not None else st.recs.get(i), tag, remove)
        if gone:
            cps = ", ".join(f"CP{cell(i)['cp']}" for i in gone)
            log(T(f"   ✖ tag {tag} vynechávám u {cps} – hledání podle CP je ve hře nenašlo (CP se nejspíš přečetlo špatně)",
                  f"   ✖ skipping tag {tag} for {cps} – the CP search didn't find them in the game (probably a misread CP)"))
            new = [i for i in gone if not cell(i).get("miss_noted")]
            for i in new:
                cell(i)["miss_noted"] = True
            if new:
                emit("problem", text=T(f"{pokemon_count(len(new))} se ve hře nepodařilo najít podle CP (nejspíš "
                                       f"špatně přečtené CP) – zkontroluj je ručně.",
                                       f"Couldn't find {pokemon_count(len(new))} in the game by CP (probably a misread "
                                       f"CP) – check them yourself."))
        skip = set(done) | set(gone)
        st.passes[0] = (tag, remove, [i for i in idxs if i not in skip])


def regroup(st, args):
    """Skupiny stejných Pokémonů (duplicity) v st.seq[:st.upto]."""
    st.group_of = {}
    gid, upto = 0, len(st.seq) if st.upto is None else st.upto
    k = 0
    for run_ in make_runs(st.seq[:upto]):
        if len(run_) >= 2:
            gid += 1
            if args.max_groups and gid > args.max_groups:
                break
            for i in range(k, k + len(run_)):
                st.group_of[i] = gid
        k += len(run_)


def map_from_full(st, full):
    """Duplicity bez druhého čtení IV: buňky seznamu z hledání (výběr z celého boxu ve stejném pořadí)
    se spárují s už přečtenými kusy celého boxu podle CP, jména a obrázku."""
    st.tag_map, j0, miss = {}, 0, 0
    for i, c in enumerate(st.seq):
        j = next((j for j in range(j0, len(full.seq)) if full.seq[j]["cp"] == c["cp"]
                  and names_ok(full.seq[j]["name"], c["name"])
                  and sprite_sim(full.seq[j]["sprite"], c["sprite"]) >= SAME_SPECIES_THR), None)
        if j is None:
            miss += 1
            continue
        st.tag_map[i] = j
        if j in full.recs:
            st.recs[i] = full.recs[j]      # stejný záznam – Removable se propíše i do dalších kroků
        j0 = j + 1
    log(T(f"   IV beru z přečteného inventáře: {pokemon_count(len(st.recs))}",
          f"   taking IVs from the read storage: {pokemon_count(len(st.recs))}") +
        (T(f", {miss} se nepodařilo spárovat", f", {miss} couldn't be matched") if miss else ""))


def fast_duplicates(bot, book, mem, args, report, st, full=None):
    """1. část rychle: seznam z hledání → IV všech (šipkou ▶, nebo převzaté z přečteného celého boxu
    full) → horší duplicity → hromadně tag TAG_NAME (přes hledání podle CP)."""
    if st.seq is None:
        st.seq = grid_scan(bot)
        pos = {id(c): k for k, c in enumerate(st.seq)}
        gid, upto = 0, len(st.seq)
        for run_ in make_runs(st.seq):
            if len(run_) < 2:
                continue
            gid += 1
            if args.max_groups and gid > args.max_groups:
                upto = pos[id(run_[0])]
                break
            for c in run_:
                st.group_of[pos[id(c)]] = gid
        st.upto = upto
        log(T("   skupin stejných Pokémonů: ", "   groups of the same Pokémon: ") + str(len(set(st.group_of.values()))))
        if full is None and not getattr(bot, "no_cache", False):
            st.cache_hits = from_memory(st, mem)
            if st.cache_hits:
                log(T(f"   z paměti: {pokemon_count(st.cache_hits)} (minule přečtení, stejné CP i jméno)",
                      f"   from memory: {pokemon_count(st.cache_hits)} (read last time, same CP and name)"))
    if not st.scanned:
        if full is not None:
            map_from_full(st, full)
        else:
            scan_details(bot, st, st.upto)
            remember_box(st, mem, whole=False)
        st.scanned = True
        regroup(st, args)        # seznam se mohl při čtení opravit (zdvojené buňky pryč)
        if full is not None:
            st.tag_full = full   # tagovat v celém boxu (hledání podle CP), indexy přes st.tag_map
        else:
            st.tag_base = SEARCH_QUERY
    if not st.planned:
        targets = []
        groups = {}
        for i, gid in sorted(st.group_of.items()):
            r = Rec(st.seq[i], gid)
            rec = st.recs.get(i) or {}
            r.iv, r.types = rec.get("iv"), rec.get("types")
            r.status = "done" if r.iv else "failed"
            r.tagged = bool(rec.get("removable")) or mem.is_tagged(r.cp, r.name)
            if r.iv:
                if rec.get("cached"):
                    r.cached = True        # IV z minulého běhu (nečetlo se znovu)
                else:
                    report.measured += 1
                mem.set_iv(r.sig, r.iv, r.types, save=False)
            book.recs.append(r)
            groups.setdefault(gid, []).append((i, r))
        for gid, items in groups.items():
            group = [r for _, r in items]
            for r in group:      # stejné CP i jméno ve skupině – nejde spolehlivě rozlišit
                r.ambiguous = sum(1 for o in group if o.cp == r.cp and names_ok(o.name, r.name)) > 1
            if decide_group(group):
                log(T("   pozor: ve skupině jsou různé formy (jiné typy) – každou posuzuji zvlášť",
                  "   note: the group has different forms (other types) – judging each one separately"))
            targets += [i for i, r in items if r.action == "remove" and not r.tagged and not r.ambiguous]
            report.show(book, gid)
        st.index_rec = {i: r for items in groups.values() for i, r in items}
        st.passes = [(TAG_NAME, False, targets)] if targets else []
        st.planned = True
        mem.save()

    def done(tag, remove, idxs):
        for i in idxs:
            r = st.index_rec[i]
            r.tagged = True
            mem.set_tagged(r.cp, r.name)
            rec = st.recs.get(i)
            if rec is not None:            # další kroky (IV, PvP, přejmenování) ho vynechají
                rec["removable"] = True
                rec["tags"] = list(dict.fromkeys((rec.get("tags") or []) + [TAG_NAME]))
        emit("tagged", tag=TAG_NAME, color=TAG_COLOR,
             items=[{"cp": st.index_rec[i].cp, "name": st.index_rec[i].name} for i in idxs])
        book.progress += 1
        for gid in sorted({st.index_rec[i].gid for i in idxs}):
            report.show(book, gid)
    run_passes(bot, st, done)


def fast_iv(bot, book2, mem, args, report, st):
    """2. část rychle: celý box → IV a tagy všech přes šipku ▶ → hromadně přidat správné IV tagy
    (od nejlepšího) a odebrat nesedící."""
    ensure_scanned(bot, st, mem)
    if not st.iv_planned:
        add = {n: [] for _, n in IV_TAGS}
        drop = {n: [] for _, n in IV_TAGS}
        st.index_rec = {}
        for i, cell in enumerate(st.seq):
            rec = st.recs.get(i) or {}
            r = Rec(cell, 0)
            st.index_rec[i] = r
            book2.recs.append(r)
            r.iv, r.types = rec.get("iv"), rec.get("types")
            r.cached = bool(rec.get("cached"))
            if rec.get("removable"):
                r.status, r.note = "skip", T(f"má tag {TAG_NAME} – přeskakuji", f"has the {TAG_NAME} tag – skipping")
                continue
            if not r.iv:
                r.status, r.note = "failed", T("IV se nepodařilo přečíst", "couldn't read the IV")
                continue
            mem.set_iv(r.sig, r.iv, r.types, save=False)
            have = [h for h in (rec.get("have") or []) if h in drop]   # jen IV tagy z teď platného nastavení
            r.target = iv_tag(r.iv)
            r.had = r.target in have
            r.removed = [h for h in have if h != r.target]
            # „done“ až po skutečném nastavení tagu (hromadná dávka se může nepovést)
            r.status = "done" if r.had and not r.removed else "pending"
            r.note = r.target + (T(" (už měl)", " (already had it)") if r.had and not r.removed else "") + \
                (T(f" (odebrat: {', '.join(r.removed)})", f" (remove: {', '.join(r.removed)})") if r.removed else "")
            if not r.had:
                add[r.target].append(i)
            for h in r.removed:
                drop[h].append(i)
        st.passes = [(n, False, add[n]) for _, n in IV_TAGS if add[n]] + \
                    [(n, True, drop[n]) for _, n in IV_TAGS if drop[n]]
        st.pending = {}
        for _, _, ix in st.passes:
            for i in ix:
                st.pending[i] = st.pending.get(i, 0) + 1
        st.iv_planned = True
        mem.save()
        if st.passes:
            log(T("\n   Plán hromadného tagování: ", "\n   Bulk tagging plan: ") + ", ".join(
                f"{'−' if rm else '+'}{n} ({len(ix)})" for n, rm, ix in st.passes))

    def done(tag, remove, idxs):
        book2.progress += 1
        for i in idxs:
            st.pending[i] -= 1
            if st.pending[i] == 0:          # všechny změny u tohohle Pokémona hotové
                st.index_rec[i].status = "done"
                report.show_iv(st.index_rec[i])
    run_passes(bot, st, done)
    for i, r in st.index_rec.items():
        if r.status == "pending":            # dávka s jeho tagem se nepovedla ani na třetí pokus
            r.status, r.note = "failed", f"{r.note} – " + (
                T("ve hře nenalezen (CP se asi přečetlo špatně)", "not found in the game (probably a misread CP)")
                if st.seq[i].get("miss", 0) >= 2 else T("tag se nepodařilo nastavit", "couldn't set the tag"))
    for r in st.index_rec.values():          # kdo nic nepotřeboval (už měl / přeskočen / chyba)
        if r.status != "done" or (r.had and not r.removed):
            report.show_iv(r)


def scan_details_slow(bot, st):
    """Záloha, když v appraisalu nejde přejít na dalšího: každého kusu otevře zvlášť."""
    total = len(st.seq)
    started = False
    for i in range(total):
        if i in st.recs:
            continue
        if not started:                    # kusy se otevírají shora dolů – začít od začátku seznamu
            require_top(bot)
            started = True
        step(T("Čtu IV: ", "Reading IV: ") + f"{i + 1}/{total}")
        fr = open_cell(bot, st.seq, i)
        fr = bot.settle(fr)
        rec = read_here(bot, fr, None)
        iv, fr = appraise(bot, fr, st.seq[i]["cp"])
        rec["iv"] = tuple(iv) if iv else None
        rec["t"] = time.time()
        st.recs[i] = rec
        bot.progress += 1
        ivs = "/".join(map(str, iv)) if iv else "?"
        log(f"   {i + 1}/{total} CP{rec['cp']} {rec['name']}: IV {ivs}")
        emit("scan", what="iv", n=i + 1, total=total, cp=rec["cp"], name=rec["name"], iv=list(iv) if iv else None)
        close_detail(bot, fr)


CACHE_KEYS = ("cp", "name", "types", "hp", "candy", "iv", "have", "removable", "tags", "sid", "level", "t")


def same_name(a, b):
    """Jméno z mřížky ve dvou bězích: OCR se může lišit v písmenku, ne v druhu (Pidgey ≠ Pidgeot)."""
    a, b = alnum(a), alnum(b)
    if not a or not b:
        return False
    if a == b or names_ok(a, b):
        return True
    return min(len(a), len(b)) >= 6 and difflib.SequenceMatcher(None, a, b).ratio() >= 0.85


def from_memory(st, mem):
    """Opakovaný běh: kusy, které bot zná z minula (v seznamu stejné CP a jméno a v paměti právě jeden
    takový), nečte znovu – IV, typy, HP a tagy vezme z paměti. Vrací počet takových kusů."""
    by_cp = {}
    for it in mem.box_items():
        if it.get("iv"):
            by_cp.setdefault(it.get("gcp"), []).append(it)
    hits = {}
    for i, c in enumerate(st.seq):
        cands = [it for it in by_cp.get(c["cp"], []) if same_name(c["name"], it.get("gname") or "")]
        if len(cands) == 1:
            hits[i] = cands[0]
    uses = {}
    for it in hits.values():
        uses[id(it)] = uses.get(id(it), 0) + 1
    n = 0
    for i, it in hits.items():
        if uses[id(it)] > 1 or i in st.recs:
            continue                   # dvě buňky na jeden záznam (stejné CP i jméno) – radši přečíst
        rec = {k: it.get(k) for k in CACHE_KEYS}
        rec["iv"] = tuple(rec["iv"])
        rec["tags"] = list(rec.get("tags") or [])
        # co z toho jsou IV tagy a jestli má tag TAG_NAME, podle teď platného nastavení (názvy tagů se
        # mohly od minula změnit)
        ivnames = {n for _, n in IV_TAGS}
        rec["have"] = [t for t in rec["tags"] if t in ivnames]
        rec["removable"] = TAG_NAME in rec["tags"]
        rec["cached"] = True
        if not rec.get("sid"):
            rec.pop("sid", None)       # druh se zkusí poznat znovu (pomůžou sousedé v seznamu)
            rec.pop("level", None)
        st.recs[i] = rec
        n += 1
    return n


def remember_box(st, mem, whole, complete=False):
    """Paměť pro další běh: co je o každém kusu známo teď (IV, typy, tagy po tagování, jméno po
    přejmenování). Podle času se nic nemaže – paměť se srovná s inventářem:
    - whole = st je celý inventář. complete = navíc se celý přečetl šipkou ▶ (bez paměti), takže co
      v něm není, ve hře není – smaže se.
    - celý inventář z paměti: kus, který v seznamu nebyl, se smaže, když měl tag TAG_NAME (nejspíš
      převedený), nebo když chyběl už podruhé po sobě (OCR mřížky občas buňku přehlédne).
    - jen část inventáře (seznam z hledání): ostatních záznamů se to netýká.
    Srovnává se s pamětí ze začátku běhu, takže opakované uložení během jednoho běhu nic nezdvojí."""
    if mem is None or not st.seq:
        return
    now = time.time()
    items = []
    for i in sorted(st.recs):
        rec = st.recs[i]
        cell = st.seq[i] if i < len(st.seq) else None
        if cell is None or not rec.get("iv") or cell.get("cp") is None:
            continue
        it = {k: rec.get(k) for k in CACHE_KEYS}
        it["iv"] = list(rec["iv"])
        it["t"] = rec.get("t") or now
        it["gcp"], it["gname"] = cell["cp"], cell.get("name") or ""
        items.append(it)
    if not (whole and complete):
        by_cp, by_iv = {}, set()
        for it in items:
            by_cp.setdefault(it["gcp"], []).append(it["gname"])
            by_iv.add((it.get("cp"), tuple(it["iv"])))

        def superseded(old):
            if (old.get("cp"), tuple(old.get("iv") or ())) in by_iv:
                return True            # stejný kus, jen mezitím přejmenovaný
            return any(same_name(g, old.get("gname") or "") for g in by_cp.get(old.get("gcp"), []))
        for old in mem.box_start:
            if superseded(old):
                continue
            if whole:
                misses = old.get("misses", 0) + 1
                if old.get("removable") or misses >= 2:
                    continue           # ve hře už není (převedený)
                old = dict(old, misses=misses)
            items.append(old)
    mem.set_box(items)


def ensure_scanned(bot, st, mem=None):
    """Celý box přečtený (seznam + IV a tagy každého kusu) – pro IV tagy, PvP tagy i přejmenování.
    Kusy, které bot zná z minulého běhu (stejné CP i jméno), se nečtou znovu."""
    if st.seq is None:
        st.seq = grid_scan(bot)
        if mem is not None and not getattr(bot, "no_cache", False):
            st.cache_hits = from_memory(st, mem)
            if st.cache_hits:
                left = len(st.seq) - st.cache_hits
                log(T(f"   z paměti: {pokemon_count(st.cache_hits)} (minule přečtení, stejné CP i jméno) – "
                      f"čtu jen {pokemon_count(left)}",
                      f"   from memory: {pokemon_count(st.cache_hits)} (read last time, same CP and name) – "
                      f"reading just {pokemon_count(left)}"))
                emit("info", text=T(f"Z paměti: {pokemon_count(st.cache_hits)}, čtu jen {pokemon_count(left)}.",
                                    f"From memory: {pokemon_count(st.cache_hits)}, reading just {pokemon_count(left)}."))
    if not st.scanned:
        if bot.fast:
            scan_details(bot, st)
        else:
            scan_details_slow(bot, st)
        st.scanned = True
        count_tags(bot, st)
        if mem is not None:
            identify_all(st)
            save_box(st, mem)
            remember_box(st, mem, whole=True, complete=not st.cache_hits)


def species_of(rec):
    """Druh a úroveň kusu (spočítá se jednou a uloží do záznamu)."""
    if "sid" not in rec:
        rec["sid"], rec["level"] = (None, None)
        if rec.get("iv") and rec.get("cp"):
            rec["sid"], rec["level"] = pokecalc.identify(rec.get("name"), rec.get("types"), rec["cp"], rec.get("hp"),
                                                         rec["iv"], rec.get("candy"))
    return rec["sid"], rec["level"]


def identify_all(st):
    """Druh každého kusu. Kde CP a HP sedí na víc druhů (přezdívka), rozhodnou sousedé:
    box je seřazený podle čísla v Pokédexu, takže číslo kusu leží mezi čísly sousedů."""
    if st.identified:
        return
    order = sorted(st.recs)
    for i in order:
        species_of(st.recs[i])
    dex = {i: pokecalc.SPECIES[st.recs[i]["sid"]]["dex"] for i in order if st.recs[i].get("sid")}
    for i in order:
        rec = st.recs[i]
        if rec.get("sid") or not rec.get("iv") or not rec.get("cp"):
            continue
        lo = max((d for j, d in dex.items() if j < i), default=1)
        hi = min((d for j, d in dex.items() if j > i), default=99999)
        rec["sid"], rec["level"] = pokecalc.identify(rec.get("name"), rec.get("types"), rec["cp"], rec.get("hp"),
                                                     rec["iv"], rec.get("candy"), dex_range=(lo, hi))
    st.identified = True


def fast_pvp(bot, mem, args, report, st):
    """3. část: pořadí IV pro PvP ligy → hromadně tagy lig (přidat, kde pořadí sedí; odebrat, kde už ne)."""
    ensure_scanned(bot, st, mem)
    leagues = [lg for lg in PVP if PVP[lg]["enabled"]]
    if not st.pvp_planned:
        identify_all(st)
        add = {lg: [] for lg in leagues}
        drop = {lg: [] for lg in leagues}
        st.pvp_index = {}
        unknown = 0
        for i in sorted(st.recs):
            rec = st.recs[i]
            if not rec.get("iv") or rec.get("removable"):
                continue
            sid, level = species_of(rec)
            if not sid:
                unknown += 1
                continue
            ranks = {lg: pokecalc.league_rank(sid, rec["iv"], lg) for lg in leagues}
            rec["ranks"] = {lg: (r[0] if r else None) for lg, r in ranks.items()}
            tags = set(rec.get("tags") or [])
            want = []
            for lg in leagues:
                name = PVP[lg]["name"]
                ok = rec["ranks"][lg] is not None and rec["ranks"][lg] <= PVP[lg]["max_rank"]
                if ok:
                    want.append(name)
                    if name not in tags:
                        add[lg].append(i)
                elif name in tags:
                    drop[lg].append(i)
            rk = "  ".join(f"{pokecalc.LEAGUE_LETTER[lg]}{rec['ranks'][lg] or '–'}" for lg in leagues)
            dex = pokecalc.SPECIES[sid]["dex"]
            ivs = "/".join(f"{v:02d}" for v in rec["iv"])
            log(f"   CP{rec['cp']:<5} #{dex:04d}  {ivs}  {rk}  -> {', '.join(n.split()[0] for n in want) or '–'}")
            emit("pvp", cp=rec["cp"], name=rec["name"], dex=dex, iv=list(rec["iv"]), ranks=rec["ranks"], tags=want)
            if want:
                st.pvp_index[i] = want
        if unknown:
            log(T(f"   (u {pokemon_count(unknown)} se nepodařilo poznat druh – PvP pořadí nejde spočítat)",
                  f"   (couldn't recognize the species of {pokemon_count(unknown)} – no PvP rank for them)"))
        st.passes = [(PVP[lg]["name"], False, add[lg]) for lg in leagues if add[lg]] + \
                    [(PVP[lg]["name"], True, drop[lg]) for lg in leagues if drop[lg]]
        st.pvp_planned = True
        if st.passes:
            log(T("\n   Plán PvP tagů: ", "\n   PvP tag plan: ") + ", ".join(f"{'−' if rm else '+'}{n} ({len(ix)})" for n, rm, ix in st.passes))

    def done(tag, remove, idxs):
        report.pvp_tagged += 0 if remove else len(idxs)
        emit("tagged", tag=tag, color=tag_color(tag), remove=remove,
             items=[{"cp": st.seq[i]["cp"], "name": st.seq[i]["name"]} for i in idxs])
    run_passes(bot, st, done)


def rename_values(rec):
    """Hodnoty dílků šablony pro kus (bez druhu jen IV)."""
    iv = rec["iv"]
    sid, level = species_of(rec)
    if sid:
        return pokecalc.chip_values(pokecalc.info(sid, iv, level, rec["cp"]), iv)
    return pokecalc.iv_values(iv)


def save_box(st, mem):
    """Pro aplikaci: přehled přečteného boxu (~/.pogo/last_box.json) – počet kusů v rozsahu IV
    a ukázky jmen v nastavení přejmenování."""
    out = []
    for i in sorted(st.recs):
        rec = st.recs[i]
        if not rec.get("iv"):
            continue
        name = rec.get("name") or ""
        out.append({"cp": rec["cp"], "name": name, "iv": list(rec["iv"]), "tags": rec.get("tags") or [],
                    "custom": not pokecalc.is_species_name(name) and not mem.renamed(rec["cp"], name),
                    "values": rename_values(rec)})
    try:
        tmp = BOX_FILE.with_name(BOX_FILE.name + ".tmp")
        tmp.write_text(json.dumps({"t": time.time(), "items": out}, ensure_ascii=False))
        tmp.replace(BOX_FILE)
    except OSError:
        pass


def rename_here(bot, fr, new):
    """Otevřený detail kusu → klepnout na jméno → smazat → napsat nové → potvrdit → ověřit v detailu."""
    fr = bot.settle(fr)
    old = detail_name(fr.texts)
    t = find_text(fr.texts, [old], exact=True, region=(0.15, 0.36, 0.85, 0.48)) if old else None
    spots = ([(t["cx"], t["cy"]), (min(0.95, t["x1"] + 0.05), t["cy"])] if t else []) + [(0.5, 0.42)]
    for k, p in enumerate(spots):
        t0 = bot.tap(p[0], p[1], T("jméno (přejmenovat)", "name (rename)") if k == 0 else T("tužka u jména", "pencil next to the name"), fr=fr)
        ok, fr = bot.wait_for(lambda f: keyboard_on(f.texts), 2.5, after=t0 + FRAME_LAG, label="klávesnice")
        if ok:
            break
    else:
        raise StepError(T("přejmenování se neotevřelo", "renaming didn't open"))
    try:                                   # smazat staré jméno: pole s klávesnicí umí „clear“
        bot.d.switch_to.active_element.clear()
    except Exception:
        bot.type_text("\b" * (len(old or "") + 4))
    bot.type_text(new)
    t0 = time.time()
    bot.type_text("\n")
    named = lambda f: not keyboard_on(f.texts) and alnum(detail_name(f.texts)) == alnum(new)
    ok, fr = bot.wait_for(named, 3, after=t0 + FRAME_LAG, label="nové jméno")
    if not ok and not keyboard_on(fr.texts):
        d = confirm_button(fr.texts)       # hra může chtít potvrdit OK
        if d is not None:
            t0 = bot.tap(d["cx"], d["cy"], T(f"potvrdit jméno ({d['text']})", f"confirm the name ({d['text']})"), fr=fr)
            ok, fr = bot.wait_for(named, 3, after=t0 + FRAME_LAG, label="nové jméno")
    if not ok:
        raise StepError(T(f"jméno „{new}“ se neuložilo (v detailu: {detail_name(fr.texts)!r})",
                          f"the name “{new}” didn't save (the detail shows {detail_name(fr.texts)!r})"))
    close_detail(bot, fr)
    return old


def open_in_view(bot, vseq, vidx, nav):
    """Ve výsledcích hledání najde Pokémona vseq[vidx] (od aktuální polohy dolů) a otevře jeho detail.
    nav = poloha v seznamu ({"lo": odkud párovat, "top": seznam je nahoře}). Když ve výsledcích
    není, vyhodí NotInSearch – hledá se dál od stejného místa."""
    while True:
        cells, fr = read_grid(bot)
        pairs = match_view(vseq, cells, nav["lo"])
        k = next((k for k, v in pairs.items() if v == vidx), None)
        if k is not None:
            return open_detail(bot, cells[k])
        if not pairs:
            raise StepError(T("ve výsledcích hledání se nedá zorientovat", "can't find my way in the search results"))
        if min(pairs.values()) > vidx and not nav["top"]:
            raise LostPosition(T("Pokémon, u kterého se má pokračovat, je výš v seznamu",
                                 "the Pokémon to continue from is higher up in the list"))
        if max(pairs.values()) > vidx or not scroll_next(bot, cells):
            raise NotInSearch(T(f"CP{vseq[vidx]['cp']} ve výsledcích hledání není", f"CP{vseq[vidx]['cp']} isn't in the search results"))
        nav["top"] = False
        nav["lo"] = next_lo(cells, pairs, nav["lo"])


def fast_rename(bot, mem, args, report, st):
    """4. část: kusy s IV v rozsahu přejmenuje podle šablony (vlastní přezdívky vynechá)."""
    ensure_scanned(bot, st, mem)
    template = RENAME["template"] or pokecalc.DEFAULT_TEMPLATE
    need_species = any(c.get("k") in pokecalc.NEEDS_SPECIES for c in template)
    if not st.rename_planned:
        identify_all(st)
        lo, hi = RENAME["min"], RENAME["max"]
        log(T(f"\n── Přejmenování · IV {lo}–{hi} %", f"\n── Renaming · IV {lo}–{hi}%"))
        st.rename_todo = []
        skipped = 0
        for i in sorted(st.recs):
            rec = st.recs[i]
            iv = rec.get("iv")
            if not iv or not lo <= round(sum(iv) * 100 / 45) <= hi:
                continue
            pct = round(sum(iv) * 100 / 45)
            if RENAME["skip_removable"] and rec.get("removable"):
                continue
            if RENAME["only_tag"] and RENAME["only_tag"] not in (rec.get("tags") or []):
                continue
            cur = rec.get("name") or ""
            if st.seq[i].get("miss", 0) >= 2:
                log(f"   CP{rec['cp']:<5} {pct_text(pct)}  {cur} · " +
                    T("ve hře nenalezen (CP se asi přečetlo špatně), přeskakuji",
                      "not found in the game (probably a misread CP), skipping"))
                skipped += 1
                continue
            if need_species and not species_of(rec)[0]:
                log(f"   CP{rec['cp']:<5} {pct_text(pct)}  {cur} · " + T("druh nepoznán, přeskakuji", "species unknown, skipping"))
                skipped += 1
                continue
            new = pokecalc.render_name(template, rename_values(rec))
            if not new or alnum(new) == alnum(cur):
                continue                   # už se jmenuje správně
            if not RENAME["overwrite_custom"] and not pokecalc.is_species_name(cur) and not mem.renamed(rec["cp"], cur):
                log(f"   CP{rec['cp']:<5} {pct_text(pct)}  {cur} · " + T("vlastní přezdívka, přeskakuji", "custom nickname, skipping"))
                emit("rename", cp=rec["cp"], old=cur, new=None, skipped="custom")
                skipped += 1
                continue
            st.rename_todo.append((i, new))
        st.rename_skipped = skipped
        st.rename_planned = True
    while st.rename_todo:
        # hledání podle CP ukáže jen kusy k přejmenování (po dávkách) – nehledají se v celém seznamu
        batch = [i for i, _ in st.rename_todo[:SEARCH_BATCH]]
        query, view = search_view(st.seq, batch)
        vseq, vpos = [st.seq[k] for k in view], {k: n for n, k in enumerate(view)}
        show_search(bot, query)
        lost = empty_search(bot, st.seq, batch, query)
        if lost is not None:           # hledání nic nenašlo – jisté kusy vynechat, jinak napsat znovu
            for i in lost:
                rec = st.recs[i]
                log(f"   ✖ CP{rec['cp']} {rec.get('name')}: " + T("ve hře nenalezen, přeskakuji", "not found in the game, skipping"))
            st.rename_todo = [x for x in st.rename_todo if x[0] not in set(lost)]
            st.rename_skipped += len(lost)
            continue
        nav = {"lo": 0, "top": True}
        for _ in batch:
            i, new = st.rename_todo[0]
            rec = st.recs[i]
            step(T("Přejmenovávám: ", "Renaming: ") + f"{rec.get('name')} → {new}")
            try:
                if i not in vpos:
                    raise NotInSearch(T(f"CP{rec['cp']} ve výsledcích hledání není", f"CP{rec['cp']} isn't in the search results"))
                old = rename_here(bot, open_in_view(bot, vseq, vpos[i], nav), new)
            except NotInSearch:
                st.rename_todo.pop(0)
                mark_missing(st.seq, [i], sure=True)
                st.rename_skipped += 1
                log(f"   ✖ CP{rec['cp']} {rec.get('name')}: " +
                    T("ve výsledcích hledání ho nevidím (CP se asi přečetlo špatně), přeskakuji",
                      "not in the search results (probably a misread CP), skipping"))
                continue
            except (Fatal, NeedTop, LostPosition):
                raise
            except StepError:
                st.rename_fails = getattr(st, "rename_fails", 0) + 1
                if st.rename_fails >= 2:       # tenhle kus se nedaří přejmenovat – dál
                    log(f"   ✖ CP{rec['cp']} {rec.get('name')}: " + T("přejmenování se nepovedlo, přeskakuji", "renaming failed, skipping"))
                    st.rename_todo.pop(0)
                    st.rename_fails = 0
                    ensure_box(bot)            # zpátky do výsledků hledání
                    continue
                raise
            st.rename_fails = 0
            st.rename_todo.pop(0)
            st.seq[i]["name"] = rec["name"] = new      # v mřížce je teď nové jméno
            mem.set_renamed(rec["cp"], new)
            report.renamed += 1
            bot.progress += 1
            pct = round(sum(rec["iv"]) * 100 / 45)
            log(f"   CP{rec['cp']:<5} {pct_text(pct)}  {old} → {new}")
            emit("rename", cp=rec["cp"], old=old, new=new)
    log(T("   ✔ přejmenováno: ", "   ✔ renamed: ") + pokemon_count(report.renamed) +
        (T(f" · vynecháno {st.rename_skipped}", f" · skipped {st.rename_skipped}") if st.rename_skipped else ""))


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
    report.show(book, gid, quiet=True)

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
        log(T(f"\n   měřím CP{r.cp} {r.name}", f"\n   measuring CP{r.cp} {r.name}"))
        step(T("Měřím IV: ", "Measuring IV: ") + f"{r.name or 'Pokémon'} (CP {r.cp})")
        emit("measuring", group=gid, cp=r.cp, name=r.name)
        try:
            iv, types = measure(bot, c)
        except StepError:
            r.fails += 1
            if r.fails >= 2:
                r.status = "failed"
                log(f"   CP{r.cp}: " + T("nejde změřit, přeskakuji ho", "can't measure it, skipping"))
            raise
        r.types = types or r.types
        if iv is None:
            r.fails += 1
            log(f"   CP{r.cp}: " + T("IV se nepodařilo přečíst", "couldn't read the IV") +
                (T(", přeskakuji", ", skipping") if r.fails >= 2 else T(", zkusím znovu", ", retrying")))
            if r.fails >= 2:
                r.status = "failed"
            continue
        r.iv, r.status = iv, "done"
        book.progress += 1
        report.measured += 1
        log(f"   CP{r.cp}: IV {'/'.join(map(str, iv))}")
        if not r.ambiguous:
            mem.set_iv(r.sig, iv, r.types)
        report.show(book, gid, quiet=True)

    if decide_group(group):
        log(T("   pozor: ve skupině jsou různé formy (jiné typy) – každou posuzuji zvlášť",
                  "   note: the group has different forms (other types) – judging each one separately"))
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
    scrolled_from = tried_top = None
    while True:
        cells, fr = read_grid(bot)
        if classify(fr) != "box":
            raise StepError(T("nejsem v inventáři", "not in the storage"))
        book.assign(cells)
        view = tuple(c["cp"] for c in cells)
        runs = make_runs(cells)
        work = next((r for r in runs if needs_work(r)), None)
        if work is None:
            # posun nikam nevedl (pořád stejné buňky) = konec seznamu
            if report.limit_reached(book) or view == scrolled_from or not scroll_next(bot, cells):
                return
            scrolled_from = view
            continue
        if work[-1] is cells[-1] and work[0] is not cells[0] and view != tried_top:
            # skupina může pokračovat pod okrajem -> nejdřív ji posunout nahoru (jen jednou z jednoho místa)
            tried_top = view
            if bring_to_top(bot, cells, work[0]):
                continue
        if len(work) >= 2 and all(c["rec"] is None for c in work) and report.limit_reached(book):
            return
        handle_run(bot, book, mem, args, work, report)


def process_all(bot, book2, mem, args, report):
    """2. část: projde celý box (bez filtru) a každého zařadí do IV tagu."""
    scrolled_from = None
    while True:
        cells, fr = read_grid(bot)
        if classify(fr) != "box":
            raise StepError(T("nejsem v inventáři", "not in the storage"))
        book2.assign(cells)
        view = tuple(c["cp"] for c in cells)
        cell = next((c for c in cells if c["rec"] is None or c["rec"].status == "new"), None)
        if cell is None:
            if view == scrolled_from or not scroll_next(bot, cells):
                return                    # posun nikam nevedl = konec seznamu
            scrolled_from = view
            continue
        if cell["rec"] is None:
            cell["rec"] = Rec(cell, 0)
            book2.recs.append(cell["rec"])
        r = cell["rec"]
        try:
            categorize(bot, mem, cell, r, args)
        except TagCreated:
            raise
        except StepError:
            r.fails += 1
            if r.fails >= 2:
                r.status, r.note = "failed", T("nepovedlo se, přeskakuji", "failed, skipping")
                report.show_iv(r)
            raise
        book2.progress += 1
        report.show_iv(r)


def friendly_problem(e):
    """Krátká věta pro aplikaci: co se stalo. Bot se pak vrací do boxu a pokračuje."""
    if isinstance(e, Danger):
        return T("Klepnutí by bylo moc blízko tlačítka Transfer nebo Evolve – bot ho neudělal a vrací se do inventáře.",
                 "The tap would be too close to the Transfer or Evolve button – the bot skipped it and goes back to the storage.")
    if isinstance(e, LostPosition):
        return T("Při posouvání inventáře se ztratilo místo – bot ho projede znovu shora (změřené Pokémony si pamatuje).",
                 "Lost the place while scrolling the storage – the bot goes through it again from the top (it remembers "
                 "the measured Pokémon).")
    if isinstance(e, StepError):
        return T(f"Nečekaná situace ({e}) – bot se vrací do inventáře a pokračuje.",
                 f"Unexpected situation ({e}) – the bot goes back to the storage and continues.")
    return T(f"Výpadek spojení nebo hry ({short_err(e)[:120]}) – bot to zkusí znovu.",
             f"Connection or game hiccup ({short_err(e)[:120]}) – the bot tries again.")


PHASE_OF = {"duplicates": 1, "iv": 2, "pvp": 3, "rename": 4}
PHASE_TITLE = {1: ("1. část: hledám duplicity", "Part 1: finding duplicates"),
               2: ("2. část: třídím celý inventář do IV tagů", "Part 2: sorting the whole storage into IV tags"),
               3: ("3. část: PvP tagy podle pořadí IV v ligách", "Part 3: PvP tags by IV rank in the leagues"),
               4: ("4. část: přejmenování", "Part 4: renaming")}


def phase_title(n):
    return T(*PHASE_TITLE[n])


def run(bot, book, book2, mem, args, report):
    """Celý běh. Na konci (i po Stop nebo chybě) si zapamatuje, co o inventáři ví – další běh pak
    čte jen nové kusy."""
    bot.no_cache = bool(getattr(args, "fresh", False))     # „Změřit IV znovu“
    st2 = FastState()
    try:
        run_phases(bot, book, book2, mem, args, report, st2)
    finally:
        if st2.seq is not None and st2.recs:      # i po Stop: co se stihlo přečíst, příště se nečte
            try:
                remember_box(st2, mem, whole=True, complete=st2.scanned and not st2.cache_hits)
            except Exception as e:
                log(T(f"   (paměť se nepodařilo uložit: {e})", f"   (couldn't save the memory: {e})"))


def run_phases(bot, book, book2, mem, args, report, st2):
    fails, last_progress = 0, -1
    need_top, cleanup = True, False
    phases = [PHASE_OF[x] for x in STEPS if x in args.steps]
    phase = phases[0]
    announced = 0
    st1 = FastState()                        # rozpracovaný průchod (přežije chybu)

    def next_phase():
        later = [p for p in phases if p > phase]
        return later[0] if later else None

    while True:
        try:
            if phase != announced:
                announced = phase
                emit("phase", n=phase)
                if phase > 1:
                    log(f"\n========== {phase_title(phase)} ==========")
                step(phase_title(phase))
            ensure_app(bot)
            # duplicity + další krok: celý box se přečte jednou a duplicity z něj převezmou IV
            shared = phase == 1 and bot.fast and any(x in args.steps for x in ("iv", "pvp", "rename"))
            full_first = shared and not st2.scanned
            bot.mode = "all" if phase != 1 or full_first else "duplicit"
            fr = ensure_box(bot)
            if phase == 1 and bot.mode == "duplicit" and classify(fr) == "box_other" and search_empty(bot):
                log(T(f"\nHledání „{SEARCH_QUERY}“ nenašlo žádné Pokémony – duplicity nejsou.",
                      f"\nThe search “{SEARCH_QUERY}” found no Pokémon – there are no duplicates."))
                emit("info", text=T(f"Hledání „{SEARCH_QUERY}“ nenašlo žádné Pokémony, takže duplicity nejsou.",
                                    f"The search “{SEARCH_QUERY}” found no Pokémon, so there are no duplicates."))
                phase, need_top = next_phase(), True
                if phase is None:
                    return
                continue
            if not bot.tags_checked:
                if bot.tag_checks >= 3:
                    bot.tags_checked = True
                    log(T("   Kontrolu tagů se nepodařilo dokončit – chybějící tagy založím, až budou potřeba.",
                          "   Couldn't finish checking the tags – missing tags get created when they're needed."))
                    emit("problem", text=T("Kontrolu tagů se nepodařilo dokončit. Chybějící tagy bot založí, "
                                           "až je bude potřebovat.",
                                           "Couldn't finish checking the tags. The bot creates missing tags when it needs them."))
                elif wanted_tags(args):
                    check_tags(bot, args)
                    continue            # zpátky do boxu a pak teprve práce
                else:
                    bot.tags_checked = True
            if phase == 1:
                if bot.fast and full_first:
                    if not getattr(st2, "announced", False):
                        log(T("\nČtu celý inventář jednou – IV a tagy použiju pro duplicity i další kroky.",
                              "\nReading the whole storage once – the IVs and tags serve the duplicates and the other steps."))
                        st2.announced = True
                    ensure_scanned(bot, st2, mem)
                    continue
                if bot.fast:
                    fast_duplicates(bot, book, mem, args, report, st1, st2 if shared else None)
                else:
                    if need_top:
                        if not bot.fresh_list:
                            reopen_box(bot)
                            continue
                        need_top = False
                    bot.fresh_list = False
                    process(bot, book, mem, args, report)
                    if book.outstanding() and not cleanup:
                        cleanup, need_top = True, True
                        log(T("\nDoznačuji Pokémony, kteří mezitím odjeli z obrazovky...",
                              "\nTagging the Pokémon that scrolled off the screen meanwhile..."))
                        step(T("Doznačuji Pokémony, kteří mezitím odjeli z obrazovky",
                               "Tagging the Pokémon that scrolled off the screen meanwhile"))
                        continue
                if report.limit_reached(book):
                    return
            elif phase == 2:
                if bot.fast:
                    fast_iv(bot, book2, mem, args, report, st2)
                else:
                    if need_top:
                        if not bot.fresh_list:
                            reopen_box(bot)
                            continue
                        need_top = False
                    bot.fresh_list = False
                    process_all(bot, book2, mem, args, report)
            elif phase == 3:
                fast_pvp(bot, mem, args, report, st2)
            else:
                fast_rename(bot, mem, args, report, st2)
            phase, need_top = next_phase(), True
            if phase is None:
                return
            continue
        except (Fatal, KeyboardInterrupt):
            raise
        except TagCreated as e:
            log(f"   ({e})")         # není to chyba: výběr tagů se zavře bez uložení a krok proběhne znovu
            continue
        except NeedTop:
            continue                 # inventář se zavřel a ensure_box ho otevře od začátku
        except NoNavigation as e:
            log(T(f"\n   Rychlý režim nejde ({e}) – pokračuji pomalým (každý Pokémon zvlášť).",
                  f"\n   Fast mode doesn't work ({e}) – continuing in slow mode (each Pokémon separately)."))
            emit("problem", text=T("V appraisalu nejde přejít na dalšího Pokémona, takže bot pokračuje pomaleji: "
                                   "každého Pokémona otevře zvlášť.",
                                   "The appraisal can't move to the next Pokémon, so the bot continues more slowly: "
                                   "it opens each Pokémon separately."))
            bot.fast, need_top = False, True
            continue
        except Exception as e:
            progress = book.progress + book2.progress + bot.progress
            if progress != last_progress:
                fails, last_progress = 0, progress
            fails += 1
            d = bot.dump("chyba")
            log(f"\n!! {short_err(e)}")
            log(T(f"   (posledních pár snímků: {d})", f"   (last few screenshots: {d})"))
            emit("problem", text=friendly_problem(e))
            if fails > MAX_FAILS:
                raise Fatal(T(f"{MAX_FAILS}× po sobě se nepodařilo pokročit, končím. Snímky obrazovky jsou ve "
                              f"složce s výsledky (chyba_XX).",
                              f"No progress {MAX_FAILS}× in a row, stopping. Screenshots are in the results folder "
                              f"(chyba_XX)."))
            if not session_alive(bot.d):
                reconnect(bot)
            if isinstance(e, LostPosition):
                need_top = True
            log(T("   Vracím se do inventáře a pokračuji...", "   Going back to the storage and continuing..."))


def parse_steps(args):
    """Kroky z --steps (aplikace), nebo ze starších --no-iv / --only-iv."""
    if args.steps:
        steps = {x.strip() for x in args.steps.split(",") if x.strip() in STEPS}
    else:
        steps = {"duplicates", "iv"}
        if args.no_iv or not SORT_ALL:
            steps.discard("iv")
        if args.only_iv:
            steps = {"iv"}
    return steps or {"iv"}


def stop_signals():
    """Stop v aplikaci / Ctrl+C = KeyboardInterrupt (bot dokončí krok a uloží výsledky). run.sh spouští
    bota na pozadí a neinteraktivní bash takovému procesu SIGINT vypne – proto ho zapnout znovu;
    SIGTERM (zavření aplikace) se chová stejně."""
    def stop(signum, frame):
        raise KeyboardInterrupt
    try:
        signal.signal(signal.SIGINT, signal.default_int_handler)
        signal.signal(signal.SIGTERM, stop)
    except ValueError:
        pass                                   # ne v hlavním vlákně (testy)


def main():
    global LOG_FILE
    stop_signals()
    ap = argparse.ArgumentParser()
    ap.add_argument("--max-groups", type=int, default=0, help="projít jen prvních N skupin duplicit")
    ap.add_argument("--fresh", action="store_true", help="IV z paměti nepoužívat, změřit znovu")
    ap.add_argument("--only-iv", action="store_true", help="jen 2. část: celý inventář do IV tagů")
    ap.add_argument("--no-iv", action="store_true", help="jen duplicity, bez 2. části")
    ap.add_argument("--steps", default="", help="kroky oddělené čárkou: duplicates,iv,pvp,rename")
    args = ap.parse_args()
    load_config()
    args.steps = parse_steps(args)
    if not args.max_groups:
        args.max_groups = MAX_GROUPS

    run_dir = OUT_DIR / time.strftime("%Y%m%d_%H%M%S")
    (run_dir / "iv").mkdir(parents=True, exist_ok=True)
    LOG_FILE = run_dir / "log.txt"
    names = {"duplicates": T("duplicity", "duplicates"), "iv": T("IV tagy", "IV tags"), "pvp": T("PvP tagy", "PvP tags"),
             "rename": T("přejmenování", "renaming")}
    parts = [names[x] for x in STEPS if x in args.steps]
    log(T("Úkol: ", "Task: ") + " + ".join(parts))
    if "duplicates" in args.steps:
        log(T("Hledání ve hře: ", "Search in the game: ") + SEARCH_QUERY)
        log(T(f"Horší duplicity dostanou tag {TAG_NAME}", f"Worse duplicates get the {TAG_NAME} tag")
            + (T(f" (projdu max. {args.max_groups} skupin)", f" (checking at most {args.max_groups} groups)")
               if args.max_groups else ""))
    log(T("Výsledky a screenshoty: ", "Results and screenshots: ") + str(run_dir))
    emit("run", dir=str(run_dir), query=SEARCH_QUERY, tag=TAG_NAME, parts=parts)
    if LIVE:
        try:
            LIVE_FILE.unlink()
        except OSError:
            pass

    mem = Memory(MEMORY_FILE)
    book = Book()
    book2 = Book()
    report = Report(run_dir, args.max_groups)
    emit("phase", n=0)
    step(T("Připojuji se k iPhonu", "Connecting to the iPhone"))
    log(T("Připojuji se k iPhonu...", "Connecting to the iPhone..."))
    try:
        devs = list_devices()
        udid = UDID or (devs[0][2] if devs else detect_udid())
        dev = next((d for d in devs if d[2] == udid), None)
        if dev:
            log(f"   iPhone: {dev[0]} (iOS {dev[1]})")
            emit("device", name=dev[0], ios=dev[1])
        step(T("Spouštím ovládání iPhonu (WebDriverAgent) – napoprvé to trvá pár minut",
               "Starting iPhone control (WebDriverAgent) – the first time takes a few minutes"))
        driver = open_session(udid)
        bot = Bot(driver, run_dir)
    except Fatal as e:
        log(T(f"\nKONEC: {e}", f"\nEND: {e}"))
        emit("fatal", text=str(e))
        return 1
    except KeyboardInterrupt:
        log(T("\nZastaveno ještě před připojením k iPhonu.", "\nStopped before connecting to the iPhone."))
        return 130
    except Exception as e:
        msg = explain_connect_error(e)
        log(f"\n{msg}")
        log(T(f"   (technicky: {short_err(e)})", f"   (technical: {short_err(e)})"))
        emit("fatal", text=msg)
        return 1
    bot.udid = udid
    emit("connected")
    bot.wait_stream()
    rc = 0
    try:
        run(bot, book, book2, mem, args, report)
    except Fatal as e:
        log(T(f"\nKONEC: {e}", f"\nEND: {e}"))
        emit("fatal", text=str(e))
        rc = 1
    except KeyboardInterrupt:
        log(T("\nZastaveno (Stop / Ctrl+C), výsledky se ukládají.", "\nStopped (Stop / Ctrl+C), saving the results."))
        rc = 130
    except Exception as e:
        import traceback
        log(T(f"\nNečekaná chyba: {short_err(e)}", f"\nUnexpected error: {short_err(e)}"))
        log(traceback.format_exc())
        emit("fatal", text=T(f"Nečekaná chyba: {short_err(e)[:200]}", f"Unexpected error: {short_err(e)[:200]}"))
        rc = 1
    finally:
        try:
            report.save(book)
            report.save_iv(book2)
            dup = report.summary(book) if book.recs else None
            iv = report.summary_iv(book2) or None
            if bot.created_tags:
                log(T("Založené tagy: ", "Created tags: ") + ", ".join(bot.created_tags))
            if bot.broken_tags:
                log(T("Tyto tagy se nepodařilo založit (založ je ve hře ručně): ",
                      "Couldn't create these tags (create them in the game yourself): ") + ", ".join(sorted(bot.broken_tags)))
            emit("summary", dup=dup, iv=iv, created=bot.created_tags, broken=sorted(bot.broken_tags),
                 minutes=round((time.time() - report.t0) / 60, 1), dir=str(run_dir))
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
