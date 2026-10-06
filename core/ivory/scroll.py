"""Reading the storage grid and scrolling it: one screen of cells, how far the list moved, and back
to the top of the list."""
import time

from . import config as cfg
from .errors import LostPosition, StepError
from .output import log, T
from .calibration import cal_set
from .vision import img_diff
from .grid import complete_cells, grid_cells, names_ok, sprite_sim, with_details
from .read_box import BOX_STATES
from .screens import classify


# --- Reading and scrolling the grid ---
def same_grid(a, b):
    """The same cells in the same places on two frames (the list isn't moving)."""
    return len(a) == len(b) and all(
        x["cp"] == y["cp"] and abs(x["cy"] - y["cy"]) < 0.004 for x, y in zip(a, b))


def read_grid(bot, timeout=4.0):
    """Waits until the grid stands still (no animation/scrolling) and returns (cells, frame).
    Frames are first compared by pixels, which is cheap; the accurate OCR (100 ms on a grid frame)
    then runs only on the frames that already stand still, not on every frame of the animation."""
    end = time.time() + timeout
    prev, last = None, None          # the previous frame, and the cells of the last frame that was read
    while True:
        fr = bot.frame(after=prev.t + 0.005 if prev else None)
        # the first frame is only the baseline to compare against, so reading it costs nothing extra:
        # a grid that already stands still is done in two frames, as it was before
        still = prev is None or img_diff(prev.img, fr.img) < 2.5
        prev = fr
        late = time.time() > end
        if not still and not late:
            continue
        cells = complete_cells(fr.texts)
        if cells and last is not None and same_grid(last, cells):
            return with_details(cells, fr), fr
        if time.time() > end:
            if cells:
                return with_details(cells, fr), fr
            raise StepError(T("nevidím mřížku inventáře", "can't see the storage grid"))
        last = cells or None


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


def scroll_by(bot, cells, anchor, multi=False, fr=None):
    """Scrolls the grid so that the row with `anchor` is at the top. Returns the grid it ended on –
    (cells, frame), already settled, so the caller doesn't have to read the same screen again – or
    None at the end of the list.
    The game moves the list further than the finger travels (about 1.6× on iPhone): the ratio is measured
    on every scroll (bot.scroll_gain), so the scroll lands right the first time. If it still overshoots,
    it goes back by exactly the overshoot.
    bot.last_shift = how far the list moved (for stitching the list together without duplicate rows).
    multi=True: scrolling inside multi-select."""
    bot.last_shift = None
    want = anchor["cy"] - (cfg.TOP_ROW_Y + 0.02)
    # half-hidden rows too – the shift is measured from them. fr = the frame the cells were read from
    # (its OCR is already done); without it the state before the drag has to be read again.
    old = grid_cells((fr or bot.frame()).texts)
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
        return None    # end of the list
    for _ in range(4):
        hit = next((c for c in cells2 if cell_matches(anchor, c, multi)), None)
        if hit is not None:
            bot.last_shift = anchor["cy"] - hit["cy"]
            return cells2, fr
        # overshot: the anchor is above the top edge – move the list back by exactly the missing amount
        shift = grid_shift(old, grid_cells(fr.texts))
        lost = (cfg.TOP_ROW_Y + 0.04) - (anchor["cy"] - shift) if shift is not None else 0.17
        back = min(0.30, max(0.05, lost / bot.scroll_gain))
        bot.drag((0.5, 0.42), (0.5, 0.42 + back), T("kousek zpět", "a bit back"), ms=int(250 + 700 * back), hold=0.3)
        cells2, fr = read_grid(bot)
    raise LostPosition(T("při posunu jsem ztratil místo v inventáři", "lost my place in the storage while scrolling"))


def bring_to_top(bot, cells, cell, fr=None):
    """Scrolls `cell` to the top of the screen; None when it is near the top already."""
    if cell["cy"] - cfg.TOP_ROW_Y < 0.08:
        return None
    return scroll_by(bot, cells, cell, fr=fr)


def scroll_next(bot, cells, multi=False, fr=None):
    """Next screen; the last row stays at the top as an overlap. Returns its (cells, frame), or None
    at the end of the list."""
    last_row = max(c["row"] for c in cells)
    anchor = next(c for c in cells if c["row"] == last_row)
    if anchor["cy"] - cfg.TOP_ROW_Y < 0.08:
        anchor = cells[-1]
    return scroll_by(bot, cells, anchor, multi, fr=fr)


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
