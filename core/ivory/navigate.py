"""Getting to the Pokémon storage from anywhere in the game: whatever screen the bot wakes up on, it
closes or answers it until the storage is open, searched and sorted the way the step needs."""
import time

from . import config as cfg
from .errors import Danger, Fatal, StepError
from .output import emit, log, state_name, step, T
from .vision import find_text
from .read_box import (
    BOX_STATES, keyboard_on, multiselect_on, safe_button, search_count, sort_menu_on, tag_list_on)
from .read_dialog import confirm_dialog, transfer_dialog
from .pixels import multiselect_look, sort_active
from .screens import classify
from .session import ensure_app, restart_game
from .detail import cancel_nickname
from .search import apply_search, filter_state, stale_search


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
