"""Reading the IV and tags of every Pokémon in the list: detail screen + appraisal, then the ▶ arrow
to the next one. Each Pokémon read is matched back to the scrolled list, which may have a doubled
cell or be missing one.

Fast mode goes about it like this:
 1) one pass through the list, scrolling only (order, CP, name, sprite)
 2) the first Pokémon is opened, then the appraisal, and the ▶ arrow (or a swipe) moves to the next
    one; the IV and tags of each are read without closing the detail screen
 3) the decisions are made in memory (worse duplicates, the right IV tag)
 4) the tags are set in bulk: everyone in the list who should get (or lose) the same tag is selected,
    and the tag is set for all of them at once
"""
import time
from concurrent.futures import ThreadPoolExecutor

import pokecalc

from . import config as cfg
from . import timing
from .errors import NoNavigation, NotOnScreen, StepError
from .output import emit, log, pokemon_count, step, T
from .vision import alnum
from .grid import names_ok
from .read_detail import bar_labels, detail_candy, detail_cp, detail_hp, detail_name, detail_types
from .screens import classify
from .detail import close_detail, open_detail_menu, read_appraisal
from .ivtags import detail_chips, detail_tags
from .monrec import live_mon
from .scanstate import require_top
from .locate import open_cell
from .nextmon import next_pokemon


READER = ThreadPoolExecutor(max_workers=1)  # accurate OCR of the Pokémon just read runs while the ▶ arrow moves on


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
            with timing.span(T("hledání v seznamu", "finding it in the list")):
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

        with timing.span(T("čtení barů", "reading the bars")):
            iv = read_appraisal(bot, st.seq[start]["cp"], quick=quick)
        while True:
            here = bot.bars_frame if iv else bot.frame()
            st.quick_n = getattr(st, "quick_n", 0) + (bot.bars_rec is not None)
            # accurate OCR of this Pokémon runs in the background while the ▶ arrow moves to the next one
            job = Done(bot.bars_rec) if bot.bars_rec is not None else READER.submit(read_here, bot, here, iv)
            ahead = next((k for k in unread(st, total) if k > expect), None)
            go_on = ahead is not None and ahead - expect <= 12
            with timing.span(T("přechod na dalšího (▶)", "moving on (▶)")):
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
                emit("scan", what="iv", n=min(n, expected), total=expected, **live_mon(rec))
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
                emit("scan", what="iv", n=min(n, expected), total=expected, **live_mon(rec))
                step(T("Čtu IV: ", "Reading IV: ") + f"{min(n, expected)}/{expected}")
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
            with timing.span(T("čtení barů", "reading the bars")):
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
        emit("speed", per=round(dt / n, 2), n=n,
             parts={name: round(sec / n, 3) for name, sec, _, _ in timing.report(dt, n)})
        parts = timing.line(dt, n)
        if parts:
            log(T(f"   ⏱ z toho na kus: {parts}", f"   ⏱ of that, each: {parts}"))
        timing.reset()
    gone = drop_phantoms(st, total)
    added = getattr(st, "added", 0)
    if gone or added:
        log(T(f"   seznam srovnán podle detailů: {pokemon_count(len(st.recs))}",
              f"   list matched to the details: {pokemon_count(len(st.recs))}") +
            (T(f", {gone} zdvojených buněk vyhozeno", f", {gone} doubled cells dropped") if gone else "") +
            (T(f", {added} chybějících doplněno", f", {added} missing ones added") if added else ""))
