"""Reading the storage list by scrolling: one screen of cells at a time, stitched together without
duplicating the overlapping rows."""
from .output import emit, log, pokemon_count, step, T
from .grid import names_ok
from .read_box import box_count, search_count
from .scroll import read_grid, scroll_next
from .scanstate import require_top


def same_cell(a, b):
    low = max(a.get("cy", 0), b.get("cy", 0)) > 0.70     # names in the bottom row are often half hidden
    return a["cp"] == b["cp"] and (low or names_ok(a["name"], b["name"]))


def merge_screen(seq, cells):
    """Appends the cells of a new screen to seq, leaving out the overlap with the previous screen.
    Tolerates one misread cell in the overlap (otherwise the whole row would be added twice)."""
    best = 0
    for k in range(min(len(cells), len(seq)), 0, -1):
        hits = sum(1 for i in range(k) if same_cell(seq[len(seq) - k + i], cells[i]))
        if hits == k or (k >= 3 and hits >= k - 1):
            best = k
            break
    seq.extend(cells[best:])


def merge_by_shift(seq, prev, cells, shift):
    """New cells after a scroll by shift: everything below the last row of the previous screen prev.
    A last-row cell that the previous screen didn't read is inserted in its place."""
    bottom = max(c["cy"] for c in prev)
    last = [c for c in prev if c["cy"] > bottom - 0.03]
    for c in sorted((c for c in cells if abs(c["cy"] + shift - bottom) < 0.06), key=lambda c: c["cx"]):
        if not any(o["cp"] == c["cp"] and abs(o["cx"] - c["cx"]) < 0.06 for o in last):
            k = len(seq) - len(last) + sum(1 for o in last if o["cx"] < c["cx"])
            seq.insert(k, c)
            last.append(c)
    seq.extend(c for c in cells if c["cy"] + shift > bottom + 0.06)


def grid_scan(bot):
    """Goes through the list from top to bottom (scrolling only) and returns all cells in order."""
    require_top(bot)
    step(T("Procházím seznam Pokémonů", "Going through the Pokémon list"))
    seq = []
    cells, fr = read_grid(bot)
    bot.shown_count = box_count(fr.texts) if bot.mode == "all" else None
    # How many the game says are in the list. Only for the progress the app draws – going through the
    # whole storage takes minutes, and without it the app has nothing to show moving the whole time.
    shown_total = bot.shown_count or search_count(fr.texts)
    merge_screen(seq, cells)
    while True:
        emit("scan", what="seznam", n=len(seq), total=shown_total)
        prev = cells
        nxt = scroll_next(bot, cells, fr=fr)     # the scroll already settled on the next screen
        if not nxt:
            break
        cells, fr = nxt
        if bot.last_shift is not None:
            merge_by_shift(seq, prev, cells, bot.last_shift)
        else:
            merge_screen(seq, cells)
    shown = bot.shown_count
    log(T(f"   v seznamu je {pokemon_count(len(seq))}", f"   the list has {pokemon_count(len(seq))}") +
        (T(f" (hra ukazuje {shown} – rozdíl srovná čtení IV)", f" (the game shows {shown} – reading the IV evens it out)")
         if shown and shown != len(seq) else ""))
    return seq
