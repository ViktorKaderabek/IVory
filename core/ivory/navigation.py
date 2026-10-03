"""Getting to the Pokémon storage from anywhere in the game, entering the search, and reading and
scrolling the grid."""
import re
import time

from . import config as cfg
from .errors import Danger, Fatal, LostPosition, StepError
from .output import emit, log, state_name, step, T
from .calibration import cal_set
from .vision import find_text, img_diff, norm
from .grid import complete_cells, grid_cells, names_ok, sprite_sim, with_details
from .screens import (
    bar_matches, BOX_STATES, classify, confirm_dialog, filter_key, keyboard_on, multiselect_look,
    multiselect_on, return_key, safe_button, search_bar_text, search_count, sort_active, sort_menu_on,
    tag_list_on, transfer_dialog)
from .session import ensure_app, restart_game
from .detail import cancel_nickname


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


def handle_unknown(bot, fr, attempt):
    if attempt == 1 and ensure_app(bot):
        return
    if attempt <= 2:
        time.sleep(0.6)   # maybe just an animation / loading
        return
    t = safe_button(fr.texts)
    if t:
        bot.tap(t["cx"], t["cy"], T(f"zavřít okno: {t['text']}", f"close window: {t['text']}"), fr=fr)
        time.sleep(0.6)
    elif multiselect_on(fr.texts) or multiselect_look(fr.img) or \
            find_text(fr.texts, ["transfer"], region=(0.0, 0.8, 1.0, 1.0)):
        # multi-select: TRANSFER at the bottom center, closed with the X at the top left
        bot.tap(*cfg.P_MULTI_CLOSE, T("zrušit výběr (X vlevo nahoře)", "cancel selection (X top left)"), fr=fr)
        time.sleep(0.8)
    elif attempt % 3 == 0:
        bot.tap(*cfg.P_BOTTOM_X, T("zavřít (X dole)", "close (X at the bottom)"), fr=fr)
        time.sleep(0.8)
    else:
        time.sleep(0.6)


def nav_step(bot, st, fr, attempt):
    """One step towards the storage. Returns the frame once the storage is ready (search + sorting)."""
    tx = fr.texts
    if st == "nickname_dialog":
        # an unfinished renaming: CANCEL keeps the old name (taps at the bottom would type into it)
        cancel_nickname(bot, fr)
        return None
    if keyboard_on(tx) and st not in ("search_page", "transfer_dialog", "confirm_dialog"):
        # the keyboard is open (e.g. after an unfinished tag creation) – hide it first,
        # otherwise taps near the bottom would hit keys
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
        # a half-finished new tag dialog (e.g. after an error) – close it without saving
        c = find_text(tx, ["cancel", "close", "zrušit", "zavřít"], exact=True) or safe_button(tx)
        p = (c["cx"], c["cy"]) if c else cfg.P_BOTTOM_X
        bot.act(p, T("zavřít dialog pro nový tag", "close the new tag dialog"), lambda f: classify(f) != "tag_dialog", fr=fr, tries=1)
    elif st == "tag_list":
        bot.act(cfg.P_BOTTOM_X, T("zavřít výběr tagů (bez uložení)", "close the tag picker (without saving)"), lambda f: not tag_list_on(f.texts), fr=fr, tries=1)
    elif st == "multiselect":
        bot.act(cfg.P_MULTI_CLOSE, T("zrušit multiselect", "cancel multi-select"), lambda f: classify(f) != "multiselect", fr=fr, tries=1)
    elif st == "appraisal":
        bot.act(cfg.P_NEUTRAL, T("zavřít appraisal", "close appraisal"), lambda f: classify(f) != "appraisal", timeout=1.5, fr=fr, tries=1)
    elif st == "detail_menu":
        bot.act(cfg.P_CORNER, T("zavřít menu", "close menu"), lambda f: classify(f) != "detail_menu", fr=fr, tries=1, overlay=True)
    elif st == "detail":
        bot.act(cfg.P_BOTTOM_X, T("zavřít detail", "close detail"), lambda f: classify(f) != "detail", timeout=2.5, fr=fr, tries=1,
                overlay=True)
    elif st == "sort_menu":
        t, fr = bot.stable_text([cfg.L["number"]], exact=True, region=(0.4, 0.3, 1.0, 0.9))
        if bot.need_sort and t and not sort_active(fr.img, t):
            # tap only when NUMBER isn't active yet – tapping it again would reverse the sort order
            bot.act((t["cx"], t["cy"]), T("řadit podle NUMBER", "sort by NUMBER"), lambda f: not sort_menu_on(f.texts), fr=fr, tries=1)
        else:
            if bot.need_sort and t:
                log(T("   řazení podle čísla už je nastavené", "   sorting by number is already set"))
            bot.act(cfg.P_CORNER, T("zavřít řazení", "close the sort menu"), lambda f: not sort_menu_on(f.texts), fr=fr, tries=1, overlay=True)
        if t:
            bot.need_sort = False
    elif st == "search_page":
        if bot.mode == "all":
            bot.act(cfg.P_SEARCH_BACK, T("zavřít hledání", "close search"), lambda f: classify(f) != "search_page", timeout=2.5, fr=fr,
                    tries=1)
        else:
            apply_search(bot, fr, attempt)
    elif st == "box" and bot.mode == "all":
        if filter_state(bot, tx) != "none":
            p = cfg.P_SEARCH_CLEAR if attempt % 2 else cfg.P_SEARCH_BACK
            bot.act(p, T("zrušit hledání (celý inventář)", "cancel search (whole storage)"),
                    lambda f: classify(f) == "search_page" or filter_state(bot, f.texts) == "none",
                    timeout=2.5, fr=fr, tries=1)
            bot.fresh_list = True
        elif bot.need_sort:
            bot.act(cfg.P_CORNER, T("řazení", "sort"), lambda f: sort_menu_on(f.texts), fr=fr, tries=1, overlay=True)
        else:
            return fr
    elif st == "box":
        fs = filter_state(bot, tx)
        if fs == "none":
            bot.act(cfg.P_SEARCH_BAR, T("pole Search", "Search field"), lambda f: classify(f) == "search_page", timeout=2.5, fr=fr, tries=1)
        elif fs == "other":
            p = cfg.P_SEARCH_BACK if attempt % 2 else cfg.P_SEARCH_CLEAR
            bot.act(p, T("zrušit jiné hledání", "cancel the other search"),
                    lambda f: classify(f) == "search_page" or filter_state(bot, f.texts) != "other",
                    timeout=2.5, fr=fr, tries=1)
        elif bot.need_sort:
            bot.act(cfg.P_CORNER, T("řazení", "sort"), lambda f: sort_menu_on(f.texts), fr=fr, tries=1, overlay=True)
        else:
            return fr
    elif st in ("box_tags", "box_other"):
        ours = st == "box_other" and bot.mode != "all" and filter_state(bot, tx) == "ok"
        if ours and (attempt >= 3 or search_count(tx) == 0):
            return fr   # our search, it just found nothing – the caller decides what to do next
        if attempt == 1 or ours:
            time.sleep(0.5)   # the storage (or the search results) may still be loading
            return None
        if st == "box_other" and stale_search(bot, tx):
            # an earlier search with no results (e.g. a CP that isn't in the game): the POKÉMON tab
            # won't help here, the search has to be canceled
            p = cfg.P_SEARCH_BACK if attempt % 2 == 0 else cfg.P_SEARCH_CLEAR
            bot.act(p, T("zrušit hledání bez výsledků", "cancel the search without results"),
                    lambda f: classify(f) != "box_other" or filter_state(bot, f.texts) == "none",
                    timeout=2.5, fr=fr, tries=1)
            if bot.mode == "all":
                bot.fresh_list = True
            return None
        t = find_text(tx, ["pokemon"], region=(0.3, 0.0, 0.7, 0.16))
        p = (t["cx"], t["cy"]) if t else cfg.P_BOX_TAB
        bot.act(p, T("záložka POKÉMON", "POKÉMON tab"), lambda f: classify(f) != st, timeout=2.5, fr=fr, tries=1)
    elif st == "main_menu":
        t, fr = bot.stable_text(["pokemon"], exact=True, region=(0.0, 0.5, 0.5, 1.0))
        cands = ([(t["cx"], t["cy"] + cfg.MENU_ICON_DY), (t["cx"], t["cy"] + 0.035), (t["cx"], t["cy"])]
                 if t else [(0.22, 0.835)])
        p = cands[(attempt - 1) % len(cands)]
        bot.act(p, "POKÉMON", lambda f: classify(f) in BOX_STATES, timeout=6, fr=fr, tries=1)
        bot.fresh_list = True      # a freshly opened storage starts at the top
    elif st == "map":
        p = cfg.P_POKEBALL[(attempt - 1) % len(cfg.P_POKEBALL)]
        bot.act(p, "Poké Ball", lambda f: classify(f) == "main_menu", timeout=2.5, fr=fr, tries=1)
    else:
        handle_unknown(bot, fr, attempt)
    return None


def ensure_box(bot):
    """Gets to the storage from anywhere: with the search entered (SEARCH_QUERY, bot.query in "cp" mode,
    none in "all" mode) and sorted by number. Returns the storage frame."""
    start = time.time()
    restarted = False
    last, same = None, 0
    while True:
        stuck = same > (15 if last == "unknown" else 8)
        if time.time() - start > cfg.NAV_TIMEOUT or stuck:
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


# --- Reading and scrolling the grid ---
def read_grid(bot, timeout=4.0):
    """Waits until the grid stands still (no animation/scrolling) and returns (cells, frame)."""
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
    """The same cell (after scrolling)? CP + sprite, and the name when it is fully visible – in the
    bottom row of the screen the name is often half hidden behind buttons and misread. In multi-select
    a selected cell has a green background, so CP, column and name are enough there."""
    low = max(ref.get("cy", 0), c.get("cy", 0)) > 0.70
    if ref["cp"] != c["cp"] or not (low or names_ok(ref["name"], c["name"])):
        return False
    if multi:
        return abs(ref["cx"] - c["cx"]) < 0.08
    return sprite_sim(ref["sprite"], c["sprite"]) >= cfg.SAME_SPECIES_THR


def grid_shift(old, new):
    """How far the list moved up: the same CP in the same column on both frames (median)."""
    d = sorted(o["cy"] - n["cy"] for o in old for n in new
               if o["cp"] == n["cp"] and abs(o["cx"] - n["cx"]) < 0.06 and -0.3 < o["cy"] - n["cy"] < 1.2)
    return d[len(d) // 2] if d else None


def learn_gain(bot, shift, finger):
    """Ratio of list movement to finger drag (moving average, saved for the next run)."""
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
    """Scrolls the grid so that the row with `anchor` is at the top. Returns False at the end of the list.
    The game moves the list further than the finger travels (about 1.6× on iPhone): the ratio is measured
    on every scroll (bot.scroll_gain), so the scroll lands right the first time. If it still overshoots,
    it goes back by exactly the overshoot.
    bot.last_shift = how far the list moved (for stitching the list together without duplicate rows).
    multi=True: scrolling inside multi-select."""
    bot.last_shift = None
    want = anchor["cy"] - (cfg.TOP_ROW_Y + 0.02)
    old = grid_cells(bot.frame().texts)            # half-hidden rows too – the shift is measured from them
    before = [(c["cp"], round(c["cy"], 2)) for c in cells]
    moved = False
    for k in range(2):
        x = 0.5 if k == 0 else 0.3
        dy = min(0.55, max(0.08, want / bot.scroll_gain))
        bot.drag((x, cfg.SCROLL_FROM_Y), (x, cfg.SCROLL_FROM_Y - dy), f"posun o {dy:.2f}",
                 ms=int(250 + 900 * dy), hold=0.3)
        cells2, fr = read_grid(bot)
        if not multi and classify(fr) == "multiselect":
            raise StepError("posun omylem spustil multiselect")
        if [(c["cp"], round(c["cy"], 2)) for c in cells2] != before:
            moved = True
            shift = grid_shift(old, grid_cells(fr.texts))
            if shift is None:          # nothing from the previous screen is visible – it overshot a lot
                bot.scroll_gain = min(3.0, round(bot.scroll_gain * 1.4, 3))
            else:
                learn_gain(bot, shift, dy)
            break
    if not moved:
        if any(c["cy"] > cfg.GRID_BOTTOM + 0.02 for c in grid_cells(fr.texts)):
            raise StepError(T("seznam se nedá posunout, i když pod ním ještě něco je",
                              "the list won't scroll although there's more below"))
        return False   # end of the list
    for _ in range(4):
        hit = next((c for c in cells2 if cell_matches(anchor, c, multi)), None)
        if hit is not None:
            bot.last_shift = anchor["cy"] - hit["cy"]
            return True
        # overshot: the anchor is above the top edge – move the list back by exactly the missing amount
        shift = grid_shift(old, grid_cells(fr.texts))
        lost = (cfg.TOP_ROW_Y + 0.04) - (anchor["cy"] - shift) if shift is not None else 0.17
        back = min(0.30, max(0.05, lost / bot.scroll_gain))
        bot.drag((0.5, 0.42), (0.5, 0.42 + back), T("kousek zpět", "a bit back"), ms=int(250 + 700 * back), hold=0.3)
        cells2, fr = read_grid(bot)
    raise LostPosition(T("při posunu jsem ztratil místo v inventáři", "lost my place in the storage while scrolling"))


def bring_to_top(bot, cells, cell):
    if cell["cy"] - cfg.TOP_ROW_Y < 0.08:
        return False
    return scroll_by(bot, cells, cell)


def scroll_next(bot, cells, multi=False):
    """Next screen; the last row stays at the top as an overlap."""
    last_row = max(c["row"] for c in cells)
    anchor = next(c for c in cells if c["row"] == last_row)
    if anchor["cy"] - cfg.TOP_ROW_Y < 0.08:
        anchor = cells[-1]
    return scroll_by(bot, cells, anchor, multi)


def reopen_box(bot):
    """Back to the top of the list: closes the storage (X at the bottom) and ensure_box opens it again –
    a freshly opened storage always starts at the top. The game takes a fast downward swipe at the top
    of the list as closing the storage, so it doesn't scroll back to the top."""
    log(T("   na začátek seznamu: zavírám inventář, znovu se otevře nahoře",
          "   back to the top of the list: closing the storage, it reopens at the top"))
    fr = bot.frame()
    if classify(fr) not in BOX_STATES:
        return
    try:
        bot.act(cfg.P_BOTTOM_X, T("zavřít inventář", "close the storage"), lambda f: classify(f) not in BOX_STATES, timeout=3, fr=fr, tries=2)
        return
    except StepError:
        pass
    # the X didn't work: back to the top with slow drags (the game doesn't take a slow drag with a hold
    # as closing; and if the storage does close, never mind – it reopens at the top)
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
