"""Settings and run-wide state.

The defaults below are overridden by ~/.pogo/config.json (written by the app, applied by
runner.load_config). Other modules read them as `cfg.NAME`, so a changed value is seen everywhere.
"""
import os
import re
from pathlib import Path


APPIUM_URL = "http://127.0.0.1:4723"
UDID = ""                      # empty = the first connected iPhone
APPLE_ID = ""                  # signs WebDriverAgent; a profile is only valid for the UDIDs it names,
                               # so it has to be the phone owner's own account
BUNDLE_ID = "com.nianticlabs.pokemongo"
OUT_DIR = Path.home() / "Desktop" / "pogo_runs"
STATE_DIR = Path.home() / ".pogo"
CAL_FILE = STATE_DIR / "calibration.json"   # how the game shows the typed search, and the scroll gain
MEMORY_FILE = STATE_DIR / "pamet.json"      # measured IVs and who was already tagged
CONFIG_FILE = STATE_DIR / "config.json"     # settings from the app (override the values below)
LIVE_FILE = STATE_DIR / "live.jpg"          # latest screenshot for the live preview in the app
BOX_FILE = STATE_DIR / "last_box.json"      # the storage as read, for the app (IV ranges, name samples)
MAX_GROUPS = 0                 # 0 = all groups of duplicates

SEARCH_QUERY = "count & !legendary & !ultra beasts"   # what the bot types into the Search field in the storage
TAG_NAME = "Removable"         # tag for the worse duplicates; the bot creates it if it's missing in the game
KEEP_N = 1                     # how many of the best in each group of the same Pokémon to keep

# Part 2: after the duplicates, go through the WHOLE storage (no search) and tag each Pokémon by its IVs.
SORT_ALL = True
IV_TAGS = [                    # (minimum %, tag name) – the first one that fits is used
    (100, "100% Perfect"),
    (95, "95-99% Insane"),
    (90, "90-95% Amazing"),
    (85, "85-90% Great"),
    (80, "80-85% Good"),
    (70, "70-80% Mid"),
    (0, "70-0% Garbage"),
]
RECHECK_TAGGED = False         # False = skip Pokémon that already have exactly one of the IV tags (faster)
FAST = True                    # fast mode: read IVs with the ▶ arrow in the appraisal, tag in batches
SEARCH_BATCH = 30              # max. Pokémon in one search by CP (limits the search length)
TAGGED_DAYS = 30               # how long to remember who was already tagged

# Tag colors in the game (in the order of the game's picker). The RGB values are only approximate: the bot
# finds the color circles in the dialog and taps the one closest to the requested color.
TAG_PALETTE = {
    "blue": (60, 130, 230), "green": (70, 180, 100), "purple": (150, 95, 215), "yellow": (240, 200, 50),
    "red": (225, 70, 70), "orange": (240, 140, 50), "gray": (145, 150, 155), "black": (40, 40, 45),
}
COLOR_CZ = {"blue": "modrá", "green": "zelená", "purple": "fialová", "yellow": "žlutá", "red": "červená",
            "orange": "oranžová", "gray": "šedá", "black": "černá"}
TAG_COLOR = "red"              # color of the TAG_NAME tag when the bot creates it
DEFAULT_IV_COLORS = ["yellow", "orange", "purple", "blue", "green", "gray", "black"]   # best first
TAG_COLORS = {name: DEFAULT_IV_COLORS[i % len(DEFAULT_IV_COLORS)] for i, (_, name) in enumerate(IV_TAGS)}

# Steps of a run (always in this order): duplicates, IV tags, PvP tags, renaming, Battle tags, weak Pokémon
STEPS = ["duplicates", "iv", "pvp", "rename", "battle", "weak"]

# PvP tags: a Pokémon whose IV rank for a league is within max_rank gets that league's tag (1 = best of 4096)
PVP = {
    "great": {"name": "Great League", "enabled": True, "max_rank": 100, "color": "blue"},
    "ultra": {"name": "Ultra League", "enabled": True, "max_rank": 100, "color": "yellow"},
    "master": {"name": "Master League", "enabled": True, "max_rank": 50, "color": "purple"},
}

# Battle tags: the app picks the Pokémon (the best raid attackers of each type, the chosen PvP teams) and writes
# them into config.json; a picked Pokémon gets the tag, anyone else who has it loses it
BATTLE = {"tags": []}          # [{"name": "Raid", "color": "red", "mons": [{"cp": 2400, "iv": (15, 14, 13)}]}]

# Weak Pokémon: everyone under max_iv % gets the TAG_NAME tag (the one for transferring). It runs last, so it
# sees the tags the other steps set. The keep_* switches protect the rarer ones; the bot can't tell shadow, lucky
# or Dynamax apart, so for those there is keep_tag: a tag the user puts on them in the game.
WEAK = {"max_iv": 70, "keep_legendary": True, "keep_mythical": True, "keep_ultra_beast": True,
        "keep_regional": True, "keep_best": True, "keep_battle": True, "keep_tag": ""}

# Renaming: Pokémon with IVs in the range get a name built from the template (max. 12 characters)
RENAME = {"min": 85, "max": 100, "template": None, "overwrite_custom": False, "skip_removable": True,
          "only_tag": ""}

# Texts in the game UI (change them if your game is in another language)
L = {
    "attack": "Attack", "defense": "Defense", "hp": "HP",
    "appraise": "APPRAISE", "number": "NUMBER", "done": "DONE",
    "select_all": "SELECT ALL", "see_more": "See More", "mixed": "Mixed",
    "add_new_tag": "Add New Tag", "enter_tag_name": "Enter tag name",
    "menu": ["POKEDEX", "POKEMON", "SHOP", "ITEMS", "BATTLE"],
    "sort_options": ["RECENT", "FAVORITE", "NUMBER", "HP", "NAME", "COMBAT POWER"],
    # safe buttons for closing unknown windows
    "safe_close": ["OK", "CLOSE", "DISMISS", "NOT NOW", "LATER", "NO THANKS", "CANCEL", "NO",
                   "I'M A PASSENGER", "RETRY", "TRY AGAIN"],
    # buttons that confirm the new tag dialog (also for a game / system in Czech)
    "confirm": ["CREATE", "SAVE", "ADD", "OK", "DONE", "HOTOVO", "ULOŽIT", "VYTVOŘIT", "PŘIDAT"],
    # the Enter key on the iPhone keyboard (depends on the language and the field)
    "return_keys": ["search", "done", "go", "return", "enter", "hledat", "hotovo", "přejít", "zadat"],
    # the renaming dialog: its title, the button that closes it without saving, and the game refusing a name
    # ("This name contains inappropriate text.")
    "set_nickname": "Set Nickname", "cancel": "CANCEL", "name_refused": ["inappropriate"],
}
# Buttons with this text (in capitals) are never tapped, and neither is anything in their row.
DANGER_RE = re.compile(r"^(TRANSFER|YES|CONFIRM|TRADE|BUY|PURCHASE|RELEASE)\b")
# Rows on the Pokémon detail screen: they block the whole row; only the floating X and ≡ buttons
# (which sit above them) may be tapped beside the text.
DANGER_ROW_RE = re.compile(r"^(EVOLVE|POWER UP|PURIFY|MEGA EVOLVE)\b")
DANGER_BAND = 0.04             # ± height of the band around a dangerous button
APPRAISAL_WORDS = ["analyze", "analyse", "caught on", "categorized", "overall", "statistic", "available to"]

# Fixed points (fraction of the screen width/height), measured from screenshots
P_POKEBALL = [(0.50, 0.935), (0.50, 0.915), (0.50, 0.955)]   # Poké Ball on the map
P_BOTTOM_X = (0.50, 0.94)      # X at the bottom center (detail screen, storage, tag list)
P_CORNER = (0.87, 0.94)        # bottom right: ≡ on the detail screen, sort in the storage, X of an open menu
P_MULTI_CLOSE = (0.107, 0.117) # X at the top left in multi-select
P_SEARCH_BAR = (0.50, 0.178)   # the Search field in the storage
P_SEARCH_BACK = (0.105, 0.178) # the "<" arrow next to an active search (cancels it)
P_SEARCH_CLEAR = (0.915, 0.176)
P_BOX_TAB = (0.50, 0.085)      # the POKÉMON tab at the top of the storage
P_NEUTRAL = (0.50, 0.30)       # tapping anywhere advances / closes the appraisal
P_NICK_CANCEL = (0.50, 0.61)   # CANCEL in the Set Nickname dialog (when OCR misreads it)
MENU_ICON_DY = 0.06            # the POKÉMON icon in the menu is BELOW its label

# Storage grid: a cell is anchored on its "CP1234" text; the sprite is below it and the name lower still.
GRID_TOP, GRID_BOTTOM = 0.215, 0.785   # a cell is fully visible when its CP is within this band
TOP_ROW_Y = 0.27                       # where scrolling brings a row
SPRITE_HALF_W = 0.11
SPRITE_TOP, SPRITE_BOTTOM = 0.025, 0.09   # without the CP and the name (nicknames spoiled the similarity)
NAME_DY = (0.07, 0.14)
SAME_SPECIES_THR = 0.85
CELL_TAP_DY = 0.05             # tap on the sprite
SELECT_TAP_DY = 0.03           # in multi-select, just below the CP (further from the buttons at the bottom)
SCROLL_FROM_Y = 0.80

# IV bars (orange = fill, gray = the rest, pinkish red = 15)
BAR_MAX_W = 0.42               # how far right of the label to look for the bar
BAR_LEFT_PAD = 0.03            # the bar starts a little left of the label
BAR_GAP = 0.012                # max. gap between bar segments (fraction of the width)
BAR_MIN_W = 0.15               # a shorter run is not a bar
FILL_MIN_R, FILL_MIN_RB = 170, 70
TRACK_MIN, TRACK_MAX = 180, 238
BAR_SETTLE = 0.7               # the bars fill with an animation: read no sooner than X s after they appear
BAR_STABLE = 0.3               # ... and only once the values haven't changed for X s
BAR_QUICK = 0.1                # enough if the bars stood still for X s and the IVs match the Pokémon's CP and HP exactly

# Speed and robustness
MJPEG_PORT = 9100              # wda.py forwards it from the phone to localhost
MJPEG_QUALITY = 60
MJPEG_FPS = 60                 # more frames = the bot notices the next Pokémon sooner
MJPEG_SCALE = 75               # stream resolution in % (OCR reads it without trouble)
USE_STREAM = os.environ.get("POGO_NO_STREAM") != "1"
EVENTS = os.environ.get("POGO_EVENTS") == "1"   # events for the app ("@@{json}" lines)
LIVE = os.environ.get("POGO_LIVE") == "1"       # live screen preview for the app (LIVE_FILE)
FRAME_LAG = 0.12               # a frame counts as a tap's result only if taken at least X s after the tap
# Moving to the next Pokémon with the ▶ arrow is recognized by what is on the frame (other bars, another
# name), not by "the screen changed", so a frame from just before the tap only reads as "not yet" – it
# needs no lag, and waiting one out would cost a tenth of a second on every Pokémon.
NEXT_LAG = 0.02
# While waiting for a tap to take effect, every frame is checked with the fast OCR and the frame is
# read with the accurate one at least this often. Text the fast OCR can't read therefore costs a
# fraction of a second, not the whole timeout.
CHECK_FULL = 0.2
LONG_PRESS_SEC = 0.9
NAV_TIMEOUT = 90               # seconds to get to the storage, then the game is restarted
MAX_FAILS = 12                 # errors in a row without progress, then the run ends
TAG_SCROLL_MAX = 12
RING = 30                      # how many recent frames to save when something goes wrong
LOG_FILE = None


LANG = "en"                    # log language: "en" / "cs" (config.json "language", set by the app)


def color_name(value, default):
    v = str(value or "").strip().lower()
    v = {"grey": "gray", "violet": "purple"}.get(v, v)
    return v if v in TAG_PALETTE else default


def tag_color(name):
    """The color a tag gets when the bot creates it."""
    if name == TAG_NAME:
        return TAG_COLOR
    for lg in PVP.values():
        if lg["name"] == name:
            return lg["color"]
    for t in BATTLE["tags"]:
        if t["name"] == name:
            return t["color"]
    return TAG_COLORS.get(name)


def league_tags():
    """Tag names of the enabled PvP leagues."""
    return [lg["name"] for lg in PVP.values() if lg["enabled"]]


def battle_tags():
    """Tag names of the Battle tags."""
    return [t["name"] for t in BATTLE["tags"]]
