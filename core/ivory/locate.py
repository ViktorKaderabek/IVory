"""Finding a Pokémon from the scanned list on the screen again: pairing the cells on screen with the
entries of the list, scrolling to it and opening its detail screen."""
from .errors import LostPosition, NotOnScreen, StepError
from .output import T
from .scroll import read_grid, scroll_next
from .detail import open_detail
from .gridscan import same_cell


def match_view(vseq, cells, lo=0):
    """Search results screen -> {cell index: vseq index} (pairing starts at vseq[lo]). The order matches
    (the results are sorted like the whole list), but a Pokémon may be missing from the game (misread
    CP) or be extra, so pairing uses the longest common subsequence by CP and name, not a fixed offset.
    Among pairings of equal length the more contiguous one wins (a gap between pairs costs a point)."""
    lo = max(0, lo)
    cand = list(range(lo, len(vseq)))
    n, m = len(cells), len(cand)
    hit = [[same_cell(vseq[j], c) for j in cand] for c in cells]
    inner = [[0] * (m + 1) for _ in range(n + 1)]   # something is already paired – a gap costs a point
    lead = [[0] * (m + 1) for _ in range(n + 1)]    # nothing yet – skipping at the start is free
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
            b += 1                 # Pokémon vseq[cand[b]] isn't on the screen
        else:
            a += 1                 # a cell that isn't in vseq
    return out
def screen_pairs(vseq, cells, hint=None):
    """Which cells on the screen are which entries of vseq: {cell index: vseq index}, or {} when the
    screen can't be found in the list. Pairs by longest common subsequence (match_view), so an extra
    or missing cell (doubled / missed while scrolling, skipped) doesn't break the orientation.
    Pairs far from the others (the same CP by chance elsewhere in the list) are dropped."""
    need = max(min(2, len(cells)), int(0.6 * len(cells)))
    for lo in ([max(0, hint - 8)] if hint else []) + [0]:
        pairs = match_view(vseq, cells, lo)
        if pairs:
            offs = sorted(v - k for k, v in pairs.items())
            mid = offs[len(offs) // 2]
            pairs = {k: v for k, v in pairs.items() if abs(v - k - mid) <= 3}
        if len(pairs) >= need:
            return pairs
    return {}


def scroll_back(bot, cells, k, rows):
    """Scrolls the list back to the row `rows` rows above cell cells[k], with a slow drag and a hold (a fast
    downward drag at the top of the list would close the storage)."""
    ys = sorted({round(c["cy"], 2) for c in cells})
    gaps = [b - a for a, b in zip(ys, ys[1:]) if b - a > 0.08]
    pitch = gaps[len(gaps) // 2] if gaps else 0.166
    dist = 0.40 - (cells[k]["cy"] - rows * pitch)          # the wanted row a little below the top edge
    back = min(0.30, max(0.05, dist / bot.scroll_gain))
    bot.drag((0.5, 0.42), (0.5, 0.42 + back), T("zpět nahoru", "back up"), ms=int(250 + 700 * back), hold=0.3)


def open_cell(bot, seq, idx, skip=()):
    """Finds Pokémon seq[idx] in the list and opens its detail screen (looks down from the current
    position; if it is a little above the screen, scrolls the list back). skip = cells that aren't in
    the game (doubled while scrolling). If it is missing from the screen although its neighbors say
    it should be there (or it would be past the end of the list), raises NotOnScreen: most likely it
    is a doubled cell, and the scan can go on without returning to the top."""
    view = [k for k in range(len(seq)) if k not in skip or k == idx]
    vseq, vidx = [seq[k] for k in view], view.index(idx)
    gone = NotOnScreen(T(f"kus č. {idx + 1} (CP{seq[idx]['cp']}) na obrazovce není, i když by tam měl být",
                         f"no. {idx + 1} (CP{seq[idx]['cp']}) isn't on the screen although it should be"))
    hint, backs = None, 0
    grid = None                                  # the screen a scroll already settled on
    while True:
        cells, fr = grid or read_grid(bot)
        grid = None
        pairs = screen_pairs(vseq, cells, hint)
        if pairs:
            k = next((k for k, v in pairs.items() if v == vidx), None)
            if k is not None:
                return open_detail(bot, cells[k])
            first = min(pairs, key=pairs.get)
            if pairs[first] > vidx:              # the wanted Pokémon is above the screen
                if backs >= 4:
                    raise LostPosition(T("Pokémon, u kterého se má pokračovat, je výš v seznamu",
                                         "the Pokémon to continue from is higher up in the list"))
                backs += 1
                scroll_back(bot, cells, first, (pairs[first] - vidx + 2) // 3)
                hint = max(0, vidx - 6)
                continue
            if max(pairs.values()) > vidx:
                raise gone
            hint = pairs[first] - first
        grid = scroll_next(bot, cells, fr=fr)
        if not grid:
            if pairs:
                raise gone                       # end of the list – the Pokémon would be past it
            raise StepError(T(f"Pokémona č. {idx + 1} v seznamu nenacházím", f"can't find Pokémon no. {idx + 1} in the list"))
        if hint is not None:
            hint += max(1, len(cells) - 3)
