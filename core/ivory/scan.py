"""Fast scan of the storage: read the grid by scrolling, then walk through the appraisals with the ▶ arrow."""
import difflib
import time
from concurrent.futures import ThreadPoolExecutor

import pokecalc

from . import config as cfg
from .errors import LostPosition, NeedTop, NoNavigation, NotOnScreen, StepError
from .output import emit, log, pokemon_count, step, T
from .vision import alnum, norm
from .grid import names_ok
from .screens import (
    bar_labels, box_count, classify, detail_candy, detail_cp, detail_hp, detail_name, detail_types, HP_RE)
from .bars import read_bars
from .navigation import read_grid, reopen_box, scroll_next
from .detail import close_detail, open_detail, open_detail_menu, read_appraisal, save_card
from .tags import detail_chips, detail_tags


READER = ThreadPoolExecutor(max_workers=1)  # accurate OCR of the Pokémon just read runs while the ▶ arrow moves on


# Fast mode:
# 1) one pass through the list, scrolling only (order, CP, name, sprite)
# 2) the first Pokémon is opened, then the appraisal, and the ▶ arrow (or a swipe) moves to the next one;
#    the IV and tags of each are read without closing the detail screen
# 3) decisions are made in memory (worse duplicates, the right IV tag)
# 4) tags are set in bulk: everyone in the list who should get (or lose) the same tag is selected,
#    and the tag is set for all of them at once
class FastState:
    """A fast pass over one list, in progress; it survives an error and a return to the storage."""

    def __init__(self):
        self.seq = None          # list cells in order
        self.recs = {}           # index -> Pokémon read from the detail screen
        self.scanned = False
        self.planned = False     # duplicates decided
        self.iv_planned = False
        self.pvp_planned = False
        self.rename_planned = False
        self.battle_planned = False
        self.weak_planned = False
        self.identified = False
        self.passes = []         # [(tag, remove?, indexes)]: bulk taggings still to do
        self.pass_fails = 0      # failed attempts at the current batch
        self.group_of = {}       # index -> group number (duplicates)
        self.upto = None         # how far to read (limit on duplicate groups)
        self.index_rec = {}      # index -> Rec (results for the summary)
        self.phantom = set()     # list cells that aren't in the game (doubled while scrolling)
        self.extra = []          # Pokémon read that are missing from the list
        self.scan_fail = {}      # index -> how many times reading from it failed
        self.skipped = set()     # Pokémon that repeatedly failed to open (most likely they are in the game)
        self.cache_hits = 0      # how many Pokémon were taken from memory (previous run) instead of being read


def emit_counts(bot, changed=None, delta=0):
    """The "Tags in your storage" panel: how many Pokémon have each tag (updated as it goes)."""
    emit("tagcounts", counts=bot.tag_counts, total=bot.box_total, changed=changed, delta=delta)


def count_tags(bot, st):
    """After reading the whole storage: the number of Pokémon in each known tag, as it is in the game now."""
    known = [cfg.TAG_NAME] + [n for _, n in cfg.IV_TAGS] + [lg["name"] for lg in cfg.PVP.values()] + cfg.battle_tags()
    bot.tag_counts = {n: 0 for n in known}
    for rec in st.recs.values():
        for n in rec.get("tags") or []:
            if n in bot.tag_counts:
                bot.tag_counts[n] += 1
    bot.box_total = len(st.seq)
    emit_counts(bot)


def require_top(bot):
    """The step needs the list from the top: if it isn't there, the storage is closed and opened again."""
    if not bot.fresh_list:
        reopen_box(bot)
        raise NeedTop(T("seznam potřebuju od začátku", "I need the list from the top"))
    bot.fresh_list = False


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
    while True:
        cells, fr = read_grid(bot)
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
        if not scroll_next(bot, cells):
            if pairs:
                raise gone                       # end of the list – the Pokémon would be past it
            raise StepError(T(f"Pokémona č. {idx + 1} v seznamu nenacházím", f"can't find Pokémon no. {idx + 1} in the list"))
        if hint is not None:
            hint += max(1, len(cells) - 3)


def detail_fp(fr):
    """Fingerprint of the Pokémon on the detail screen; it changes when moving to the next one."""
    tx = fr.texts
    hp = next((alnum(t["text"]) for t in tx if HP_RE.match(norm(t["text"]))), "")
    labels = bar_labels(tx)
    return detail_cp(tx), alnum(detail_name(tx)), hp, read_bars(fr.img, labels)[0] if labels else None


def quick_fp(fr):
    """Fingerprint of the Pokémon from the fast OCR (16 ms instead of 86): CP, name, HP and the bar
    values (bars from pixels)."""
    tx = fr.fast
    hp = next((alnum(t["text"]) for t in tx if HP_RE.match(norm(t["text"]))), "")
    labels = bar_labels(tx)
    return detail_cp(tx), alnum(detail_name(tx)), hp, (read_bars(fr.img, labels)[0] if labels else None)


def fp_change(a, b):
    """2 = certainly a different Pokémon (different name or bars), 1 = maybe (only CP or HP differ; the
    fast OCR may have misread them), 0 = the same. Whatever the fast OCR didn't read doesn't count."""
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
    """Moves to the next Pokémon in the appraisal: the ▶ arrow to the right of the bars, otherwise a
    left swipe across the Pokémon's image. Returns the frame with the new Pokémon, or None (end of
    the list / not possible). fr = frame of the current Pokémon. The change is detected with the
    fast OCR; when only CP or HP differ, it is confirmed with the accurate one."""
    fr = fr or bot.frame()
    labels = bar_labels(fr.fast)
    before = quick_fp(fr)

    def changed(f):
        c = fp_change(before, quick_fp(f))
        if c == 1:
            a, b = detail_fp(fr), detail_fp(f)
            return a[:3] != b[:3] and bool(b[0] or b[1])
        return c == 2
    # arrow only when the appraisal bars are visible – on the plain detail screen the EVOLVE row sits there
    for how in (("arrow", "swipe") if labels else ("swipe",)):
        if how == "arrow":
            t0 = bot.tap(0.975, labels[1]["cy"] + 0.01, T("další Pokémon (▶)", "next Pokémon (▶)"), fr=fr)
        else:
            t0 = bot.drag((0.80, 0.22), (0.20, 0.22), T("další Pokémon (swipe)", "next Pokémon (swipe)"), ms=260, hold=0, fr=fr)
        ok, f = bot.wait_for(changed, 2.5, after=t0 + cfg.FRAME_LAG, label="další Pokémon")
        if ok:
            return f
        fr = f
    return None


def read_here(bot, fr, iv):
    """What is visible on the detail screen / in the appraisal: CP, name, types, HP, candy, IV and tags."""
    tx = fr.texts
    have, removable = detail_chips(tx)
    return {"cp": detail_cp(tx), "name": detail_name(tx), "types": detail_types(tx), "hp": detail_hp(tx),
            "candy": detail_candy(tx), "iv": tuple(iv) if iv else None, "have": have, "removable": removable,
            "tags": detail_tags(tx)}


class Done:
    """A ready result with the same interface as a Future from ThreadPoolExecutor."""

    def __init__(self, value):
        self.value = value

    def result(self):
        return self.value


def cp_match(cell_cp, rec_cp):
    """CP from the grid vs. from the detail screen: 2 = equal, 1 = the OCR in the appraisal read only the
    start or an extra digit (2134 / 21, 3277 / 32772), 0 = no. A match of 1 only counts with the same
    name (match_score)."""
    if cell_cp is None or rec_cp is None:
        return 0
    if cell_cp == rec_cp:
        return 2
    a, b = str(cell_cp), str(rec_cp)
    return 1 if min(len(a), len(b)) >= 2 and (a.startswith(b) or b.startswith(a)) else 0


def match_score(cell, rec):
    """How well a Pokémon read from the detail screen matches a list cell; 0 = not at all."""
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
    """The list index for a Pokémon just read. expect is the expected one; the scrolled list may have
    a doubled cell (skipped over) or be missing a cell (steps back). None = nothing nearby matches."""
    best, best_key = None, None
    for j in range(max(0, expect - 3), min(len(st.seq), expect + 10)):
        if j < expect and j in st.recs:
            continue                          # back only to an unread cell (else it overwrites another Pokémon)
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
    """After all Pokémon are read, reconciles the list with what the ▶ arrow showed: drops cells that
    aren't in the game (doubled while scrolling) and inserts Pokémon that were missing while scrolling
    in their place (then they can be tagged through the CP search like the rest). Returns the number
    of dropped cells."""
    gone = {k for k in st.phantom if k < total and k not in st.recs}
    st.phantom, st.skipped = set(), set()
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
    """Neither the ▶ arrow nor a swipe goes anywhere: is this the last Pokémon in the storage? When the
    count from the storage header is known, all of them must have been read (except the skipped ones
    that couldn't be opened); otherwise at most a few cells may be left (doubled at the end of the list)."""
    left = [k for k in unread(st, total) if k > last]
    if not left:
        return True
    if bot.shown_count and total == len(st.seq):
        return len(st.recs) + len(st.extra) + len(st.skipped) >= bot.shown_count
    return len(left) <= 3


def scan_details(bot, st, upto=None):
    """IV and tags of all Pokémon in st.seq: detail screen + appraisal, then the ▶ arrow to the next one.
    Each Pokémon read is matched by CP and name against the scrolled list (which may have a doubled
    cell or be missing one). After an error it continues from the first unread one; Pokémon already
    read are not read again."""
    total = len(st.seq) if upto is None else upto
    expected = bot.shown_count if upto is None and bot.shown_count else total
    first_segment = True
    while True:
        todo = unread(st, total)
        if not todo:
            break
        start = todo[0]
        if st.scan_fail.get(start, 0) >= 2:      # reading from here keeps failing – skip this Pokémon
            log(T(f"   kus č. {start + 1} (CP{st.seq[start]['cp']}) se nedaří otevřít, vynechávám ho",
                  f"   can't open no. {start + 1} (CP{st.seq[start]['cp']}), skipping it"))
            st.phantom.add(start)
            st.skipped.add(start)
            continue
        if first_segment:
            require_top(bot)                     # going back to the top (NeedTop) isn't a failed attempt
            first_segment = False
        st.scan_fail[start] = st.scan_fail.get(start, 0) + 1
        step(T("Čtu IV: ", "Reading IV: ") + f"{len(st.recs) + 1}/{expected}")
        try:
            fr = open_cell(bot, st.seq, start, st.phantom)
        except NotOnScreen as e:
            log(f"   ({e})")
            if st.scan_fail[start] >= 2:         # failed again – the cell isn't in the game, go on without it
                st.phantom.add(start)
            continue                             # retry from where the list is now
        open_detail_menu(bot, fr)
        t, fr = bot.stable_text([cfg.L["appraise"]], exact=True, region=(0.4, 0.55, 1.0, 0.92))
        if t is None:
            raise StepError(T("v menu chybí APPRAISE", "APPRAISE is missing in the menu"))
        bot.act((t["cx"], t["cy"]), "APPRAISE", lambda f: classify(f) == "appraisal", timeout=2.5, fr=fr, tries=1)
        expect, last, seen_cp, first = start, start - 1, None, True

        def quick(f, vals):                    # IV from the bars fit the Pokémon's CP and HP exactly → bars settled
            r = read_here(bot, f, vals)
            return r if pokecalc.iv_fits(r["name"], r["types"], r["cp"], r["hp"], vals, r["candy"]) else None

        iv = read_appraisal(bot, st.seq[start]["cp"], quick=quick)
        while True:
            here = bot.bars_frame if iv else bot.frame()
            st.quick_n = getattr(st, "quick_n", 0) + (bot.bars_rec is not None)
            # accurate OCR of this Pokémon runs in the background while the ▶ arrow moves to the next one
            job = Done(bot.bars_rec) if bot.bars_rec is not None else READER.submit(read_here, bot, here, iv)
            ahead = next((k for k in unread(st, total) if k > expect), None)
            go_on = ahead is not None and ahead - expect <= 12
            fr = next_pokemon(bot, here) if go_on else None
            rec = job.result()
            if rec["cp"] is None:
                rec["cp"] = seen_cp                # CP seen when moving to this Pokémon
            j = align(st, expect, rec)
            ivs = "/".join(map(str, rec["iv"])) if rec["iv"] else "?"
            if j is None:
                key = (rec["cp"], alnum(rec["name"] or ""), rec["iv"])
                if all((x["cp"], alnum(x["name"] or ""), x["iv"]) != key for x in st.extra):
                    rec["after"] = last            # belongs right after this index in the list
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
                        st.phantom.add(k)         # a cell that isn't in the game (doubled)
                st.phantom.discard(j)
                if rec["cp"] is None:
                    rec["cp"] = st.seq[j]["cp"]   # CP wasn't readable in the appraisal – the grid has it
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
            if iv:
                save_card(here, rec)               # a picture for the Stats screen in the app
            nxt = next((k for k in unread(st, total) if k > last), None)
            if not go_on or nxt is None or nxt - last > 12:
                break                          # done, or the next unread one is far away – it gets opened again
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
            if not bar_labels(fr.fast) and classify(fr) == "detail":   # the appraisal closed – open it again
                open_detail_menu(bot, fr)
                t, fr = bot.stable_text([cfg.L["appraise"]], exact=True, region=(0.4, 0.55, 1.0, 0.92))
                if t is None:
                    raise StepError(T("v menu chybí APPRAISE", "APPRAISE is missing in the menu"))
                bot.act((t["cx"], t["cy"]), "APPRAISE", lambda f: classify(f) == "appraisal", timeout=2.5, fr=fr,
                        tries=1)
            iv = read_appraisal(bot, seen_cp or st.seq[min(expect, len(st.seq) - 1)]["cp"], prev=rec["iv"],
                                quick=quick)
        for _ in range(4):                     # close the appraisal and the detail screen
            if classify(bot.frame()) != "appraisal":
                break
            try:
                bot.act(cfg.P_NEUTRAL, T("zavřít appraisal", "close appraisal"), lambda f: classify(f) != "appraisal", timeout=1.2, tries=1)
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
