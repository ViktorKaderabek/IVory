"""The Pokémon detail screen: opening it and measuring IVs in the appraisal."""
import time

import cv2

from . import config as cfg
from .errors import StepError
from .output import T
from .vision import alnum, crop_norm, find_text
from .read_detail import bar_labels, detail_cp, detail_name, detail_types, dialog_text
from .read_dialog import nickname_dialog
from .screens import classify
from .bars import read_bars
from .device import SAVER


def check_detail(bot, fr, cell):
    """Checks that the right Pokémon opened (by CP, or by name). If the CP at the top of the detail screen
    isn't visible (the screen is still sliding in, or a notification from another app covers it), it waits
    longer (5 s); a different CP fails much sooner (after 3 reads or 1.5 s)."""
    t0 = time.time()
    cp, wrong = None, 0
    while True:
        cp, nm = detail_cp(fr.texts), detail_name(fr.texts)
        if cp == cell["cp"]:
            return fr
        if cp is None and nm and cell["name"] and alnum(nm) == alnum(cell["name"]) and time.time() > t0 + 0.75:
            return fr
        wrong += cp is not None
        if wrong >= 3 or time.time() > t0 + (1.5 if wrong else 5.0):
            raise StepError(T(f"otevřel se jiný Pokémon (CP{cp} místo CP{cell['cp']})",
                              f"a different Pokémon opened (CP{cp} instead of CP{cell['cp']})"))
        fr = bot.frame(after=fr.t + 0.005)


def save_bars(bot, fr, labels, bars, vals, cp):
    """Saves a crop of the bars with the measurement drawn in (the whole bar in blue, the fill in green)."""
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
    """Taps through the intro speech and reads the bars once their animation has finished. None = failed.
    The Attack/Defense/HP labels are found with the fast OCR (same IVs as the accurate OCR on real
    screenshots, 5× faster) and then reused: while the appraisal stays open they don't move, so each
    new frame's bars are read straight from the pixels and only a frame that doesn't fit them is read
    by OCR again. Before the values are accepted, OCR confirms the labels are still really there.
    The values must hold still for BAR_STABLE s; while they equal prev, the previous Pokémon's values
    (after moving on with the ▶ arrow the bars may still be redrawing), it waits at least BAR_SETTLE.
    quick(frame, IV) returns the read Pokémon when the IVs from the bars exactly fit its CP and HP; then
    it is enough that the bars hold still for BAR_QUICK s. The frame with the bars ends up in
    bot.bars_frame, the Pokémon from the quick confirmation in bot.bars_rec."""
    end = time.time() + 9
    first = cur = cur_since = None
    d_prev, d_since = None, time.time()
    last_tap, taps = 0.0, 0
    after = None
    bot.bars_frame = bot.bars_rec = None
    tried = None
    labels = None
    while time.time() < end:
        fr = bot.frame(after=after)
        after = fr.t + 0.005
        # The labels stay in the same place for as long as the appraisal is open, so the bars of each
        # new frame are read straight from the pixels (1.6 ms); OCR (21 ms) runs only when that fails.
        vals, bars = read_bars(fr.img, labels) if labels else (None, None)
        if vals is None:
            labels = bar_labels(fr.fast)
            vals, bars = read_bars(fr.img, labels) if labels else (None, None)
        if labels:
            if first is None:
                first = fr.t
            if vals != cur:
                cur, cur_since = vals, fr.t
                continue
            if vals is None:
                continue
            new = prev is not None and tuple(vals) != tuple(prev)
            if quick and new and any(vals) and fr.t - cur_since >= cfg.BAR_QUICK and tried != vals:
                tried = vals
                bot.bars_rec = quick(fr, vals)
            if bot.bars_rec is not None or (fr.t - cur_since >= cfg.BAR_STABLE and (fr.t - first >= cfg.BAR_SETTLE or new)):
                if bar_labels(fr.fast) is None:
                    labels = None        # the appraisal closed: the values came from stale label positions
                    continue
                bot.remember("bary", f"CP{cp}", fr)
                save_bars(bot, fr, labels, bars, vals, cp)
                bot.bars_frame = fr
                return vals
            continue
        tx = fr.texts
        if classify(fr) != "appraisal":
            if taps and time.time() - last_tap > 1.5:
                return None   # the appraisal closed before the bars could be read
            continue
        d = dialog_text(tx)
        if d != d_prev:
            d_prev, d_since = d, fr.t
        if d and fr.t - d_since >= 0.25 and time.time() - last_tap >= 0.6 and taps < 8:
            last_tap = bot.tap(*cfg.P_NEUTRAL, T("appraisal dál", "appraisal next"), fr=fr)
            taps += 1
            after = last_tap + cfg.FRAME_LAG
    return None


def open_detail(bot, cell):
    """Taps the cell, waits for the detail screen to slide in and checks that it is the right Pokémon."""
    cp = cell["cp"]
    x, y = cell["cx"], cell["cy"] + cfg.CELL_TAP_DY
    _, fr = bot.act((x, y), T(f"otevřít CP{cp}", f"open CP{cp}"), lambda f: classify(f) == "detail",
                    timeout=2.5, alts=[(x, y - 0.025)])
    fr = bot.settle(fr)                      # the detail screen slides up from the bottom; wait until it stops
    return check_detail(bot, fr, cell)


def open_detail_menu(bot, fr):
    _, fr = bot.act(cfg.P_CORNER, "menu ≡", lambda f: classify(f) == "detail_menu", timeout=1.8, fr=fr, overlay=True)
    return fr


def appraise(bot, fr, cp):
    """From an open detail screen: ≡ -> APPRAISE -> read the bars -> close the appraisal.
    Returns (iv or None, detail screen frame)."""
    open_detail_menu(bot, fr)
    t, fr = bot.stable_text([cfg.L["appraise"]], exact=True, region=(0.4, 0.55, 1.0, 0.92))   # the menu fades in
    if t is None:
        raise StepError(T("v menu chybí APPRAISE", "APPRAISE is missing in the menu"))
    bot.act((t["cx"], t["cy"]), "APPRAISE", lambda f: classify(f) == "appraisal", timeout=2.5, fr=fr, tries=1)
    iv = read_appraisal(bot, cp)
    for _ in range(4):
        if classify(bot.frame()) != "appraisal":
            break
        try:
            bot.act(cfg.P_NEUTRAL, T("zavřít appraisal", "close appraisal"), lambda f: classify(f) != "appraisal", timeout=1.2, tries=1)
        except StepError:
            pass
    return iv, bot.settle(bot.frame())


def cancel_nickname(bot, fr):
    """Closes the Set Nickname dialog with CANCEL – the Pokémon keeps its name. Never with a tap at the
    bottom: with the keyboard open it would type into the name, and the game could then save that."""
    c = find_text(fr.texts, [cfg.L["cancel"]], exact=True, region=(0.1, 0.45, 0.9, 0.75))
    p = (c["cx"], c["cy"]) if c else cfg.P_NICK_CANCEL
    _, fr = bot.act(p, T("zrušit přejmenování (CANCEL)", "cancel renaming (CANCEL)"),
                    lambda f: not nickname_dialog(f.texts), timeout=2.5, fr=fr)
    return fr


def close_detail(bot, fr=None):
    fr = bot.settle(fr or bot.frame())
    bot.act(cfg.P_BOTTOM_X, T("zavřít detail", "close detail"), lambda f: classify(f) == "box", timeout=2.5, fr=fr, overlay=True)


def measure(bot, cell):
    """Opens the detail screen and the appraisal, reads the IVs and returns to storage. Returns (iv or None, types)."""
    fr = open_detail(bot, cell)
    types = detail_types(fr.texts)
    iv, fr = appraise(bot, fr, cell["cp"])
    close_detail(bot, fr)
    return iv, types
