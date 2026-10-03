"""Log output, machine-readable events for the app and small wording helpers (Czech / English)."""
import json
import time

from . import config as cfg


STATE_NAMES = {   # screen: (Czech, English)
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


def T(cs, en):
    """Text in the log language: T("Czech text", "English text")."""
    return cs if cfg.LANG == "cs" else en


def log(msg=""):
    print(msg, flush=True)
    if cfg.LOG_FILE:
        try:
            with open(cfg.LOG_FILE, "a") as f:
                f.write(f"{time.strftime('%H:%M:%S')} {msg}\n")
        except OSError:
            pass


def emit(kind, **data):
    """An event for the app, which draws its progress view from it. Not written to log.txt."""
    if cfg.EVENTS:
        print("@@" + json.dumps({"e": kind, **data}, ensure_ascii=False), flush=True)


def step(text):
    """What the bot is doing right now (the big caption in the app)."""
    emit("step", text=text)


def pokemon_count(n):
    if cfg.LANG != "cs":
        return f"{n} Pokémon"
    return f"{n} Pokémon" if n == 1 else f"{n} Pokémoni" if 2 <= n <= 4 else f"{n} Pokémonů"


def pct_text(n):
    """A percentage in the log: "87 %" in Czech, "87%" in English."""
    return T(f"{n} %", f"{n}%")


def color_word(c):
    """The name of a tag color in the log."""
    return T(cfg.COLOR_CZ.get(c, c), c)


def short_err(e):
    lines = str(e).strip().splitlines()
    return (lines[0] if lines else repr(e))[:300]
