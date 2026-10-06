"""The Search field in the storage: what search is applied right now, and typing in the one the bot
needs (SEARCH_QUERY, or a list of CPs when tagging in bulk)."""
import re
import time

from . import config as cfg
from .errors import Fatal, StepError
from .output import emit, log, step, T
from .calibration import cal_set
from .vision import norm
from .grid import complete_cells
from .read_box import bar_matches, filter_key, keyboard_on, return_key, search_bar_text, search_count
from .screens import classify


# --- Getting to the storage ---
def cp_filter_ok(tx, query):
    """Is the CP search `query` applied in the storage? The Search field truncates a long CP list and
    OCR misreads it ("ср3а0"), so it is enough when most numbers in the field are from the list, or
    when every cell in the grid has a CP from the list."""
    cps = {int(x) for x in re.findall(r"cp(\d+)", query)}
    nums = [int(n) for n in re.findall(r"\d{2,5}", norm(search_bar_text(tx)))]
    if len(nums) >= 2 and sum(n in cps for n in nums) >= 0.6 * len(nums):
        return True
    cells = complete_cells(tx)
    return bool(cells) and all(c["cp"] in cps for c in cells)


def filter_state(bot, tx):
    """none = the Search field is empty, ok = it holds the search it should, other = a different search.
    CP searches look alike (the field truncates long text), so only the one the bot has just typed
    counts."""
    k = filter_key(search_bar_text(tx))
    if k in ("", "search"):
        return "none"
    if bot.mode == "cp":
        ok = bot.typed_query == bot.query and (bar_matches(k, filter_key(bot.query)) or cp_filter_ok(tx, bot.query))
        return "ok" if ok else "other"
    if bot.typed_query not in (None, cfg.SEARCH_QUERY):
        return "other"                     # the field still holds a CP search from tagging
    return "ok" if bar_matches(k, bot.filter_key) or bar_matches(k, filter_key(cfg.SEARCH_QUERY)) else "other"


def stale_search(bot, tx):
    """Is a search applied that isn't needed now? The header shows a result count "(n)", or the
    Search field holds a search the bot typed earlier."""
    if search_count(tx) is not None:
        return True
    k = filter_key(search_bar_text(tx))
    return k not in ("", "search") and (bool(re.match(r"cp\d", k)) or any(
        q and bar_matches(k, filter_key(q)) for q in (bot.typed_query, cfg.SEARCH_QUERY)))


def clear_search_field(bot, fr):
    """Clears the text already in the Search field: the X on the right of the field, otherwise the
    Delete key."""
    empty = lambda f: filter_key(search_bar_text(f.texts)) in ("", "search")
    try:
        _, fr = bot.act(cfg.P_SEARCH_CLEAR, T("smazat pole Search", "clear the Search field"), empty, timeout=1.5, fr=fr, tries=1)
        return fr
    except StepError:
        pass
    bot.type_text("\b" * (len(search_bar_text(bot.frame().texts)) + 5))
    ok, fr = bot.wait_for(empty, 2.0, label="pole Search smazané")
    if not ok:
        raise StepError(T("v poli Search zůstal starý text a nejde smazat", "the Search field keeps old text that can't be cleared"))
    return fr


def apply_search(bot, fr, attempt):
    """The search page is open: types the search (SEARCH_QUERY, or bot.query in "cp" mode) into the
    Search field and confirms it with Enter."""
    q = bot.query if bot.mode == "cp" else cfg.SEARCH_QUERY
    shown_q = q if len(q) <= 60 else q[:57] + "…"
    if attempt > 6:
        raise Fatal(T(f"Hledání „{shown_q}“ se nedaří zadat. Zkus ho napsat ve hře ručně; když tam funguje, "
                      f"pošli složku s chybou z výsledků.",
                      f"Can't enter the search “{shown_q}”. Try typing it in the game yourself; if it works there, "
                      f"send the error folder from the results."))
    want = filter_key(q)
    step(T(f"Píšu do hledání: {shown_q}", f"Typing the search: {shown_q}"))
    if not keyboard_on(fr.texts):
        _, fr = bot.act(cfg.P_SEARCH_BAR, T("pole Search", "Search field"), lambda f: keyboard_on(f.texts), timeout=2.5, fr=fr)
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
    ok, fr = bot.wait_for(done, 4, after=t0 + cfg.FRAME_LAG, label="hledání potvrzené")
    if not ok and keyboard_on(fr.texts):
        k = return_key(fr.texts)
        if k is not None:
            t0 = bot.tap(k["cx"], k["cy"], T(f"klávesa {k['text']}", f"key {k['text']}"), fr=fr)
            ok, fr = bot.wait_for(done, 3, after=t0 + cfg.FRAME_LAG, label="hledání potvrzené")
    if not ok:
        raise StepError(T("hledání se nepodařilo potvrdit", "couldn't confirm the search"))
    if bot.mode != "cp":
        key = filter_key(search_bar_text(fr.texts))
        if key and key != bot.filter_key:
            bot.filter_key = key
            cal_set("search", {"query": cfg.SEARCH_QUERY, "key": key})
        emit("search", query=cfg.SEARCH_QUERY)
    log(T(f"   ✔ hledání „{shown_q}“ je zadané", f"   ✔ search “{shown_q}” entered"))
    bot.fresh_list = True
