"""What the bot knows about the storage: reusing memory, reading what is missing, saving it for the app."""
import difflib
import json
import time

import pokecalc

from . import config as cfg
from .errors import LostPosition, NotInSearch, StepError
from .output import emit, log, pokemon_count, step, T
from .vision import alnum
from .grid import names_ok
from .navigation import read_grid, scroll_next
from .detail import appraise, close_detail, open_detail, save_card
from .scan import (
    count_tags, drop_phantoms, grid_scan, match_view, open_cell, read_here, require_top, same_cell,
    scan_details, unread)
from .batch import empty_search, next_lo, search_view, show_search


def scan_details_slow(bot, st):
    """Fallback when the appraisal can't move on to the next Pokémon: opens each Pokémon separately."""
    total = len(st.seq)
    started = False
    for i in range(total):
        if i in st.recs:
            continue
        if not started:                    # Pokémon are opened top to bottom – start at the top of the list
            require_top(bot)
            started = True
        step(T("Čtu IV: ", "Reading IV: ") + f"{i + 1}/{total}")
        fr = open_cell(bot, st.seq, i)
        fr = bot.settle(fr)
        rec = read_here(bot, fr, None)
        iv, fr = appraise(bot, fr, st.seq[i]["cp"])
        rec["iv"] = tuple(iv) if iv else None
        rec["t"] = time.time()
        st.recs[i] = rec
        if iv:
            save_card(bot.bars_frame, rec)
        bot.progress += 1
        ivs = "/".join(map(str, iv)) if iv else "?"
        log(f"   {i + 1}/{total} CP{rec['cp']} {rec['name']}: IV {ivs}")
        emit("scan", what="iv", n=i + 1, total=total, cp=rec["cp"], name=rec["name"], iv=list(iv) if iv else None)
        close_detail(bot, fr)


CACHE_KEYS = ("cp", "name", "types", "hp", "candy", "iv", "have", "removable", "tags", "sid", "level", "t")


def same_name(a, b):
    """Grid name across two runs: OCR may differ by a letter, but not by species (Pidgey ≠ Pidgeot)."""
    a, b = alnum(a), alnum(b)
    if not a or not b:
        return False
    if a == b or names_ok(a, b):
        return True
    return min(len(a), len(b)) >= 6 and difflib.SequenceMatcher(None, a, b).ratio() >= 0.85


def from_memory(st, mem):
    """Repeat run: Pokémon the bot knows from last time (same CP and name in the list, and exactly one
    such entry in memory) are not read again – IV, types, HP and tags come from memory. The name is
    compared with both the grid name and the detail-screen name (it may have been missing from the grid
    last time). Returns the number of such Pokémon."""
    by_cp = {}
    for it in mem.box_items():
        if it.get("iv"):
            by_cp.setdefault(it.get("gcp"), []).append(it)
    hits = {}
    cp_count = {}
    for c in st.seq:
        cp_count[c["cp"]] = cp_count.get(c["cp"], 0) + 1
    for i, c in enumerate(st.seq):
        known = by_cp.get(c["cp"], [])
        cands = [it for it in known
                 if same_name(c["name"], it.get("gname") or "") or same_name(c["name"], it.get("name") or "")]
        if not cands and not alnum(c["name"]) and len(known) == 1 and cp_count[c["cp"]] == 1:
            cands = known              # OCR missed the name – this CP appears only once in the list and in memory
        if len(cands) == 1:
            hits[i] = cands[0]
    uses = {}
    for it in hits.values():
        uses[id(it)] = uses.get(id(it), 0) + 1
    n = 0
    for i, it in hits.items():
        if uses[id(it)] > 1 or i in st.recs:
            continue                   # two cells for one entry (same CP and name) – better read them
        rec = {k: it.get(k) for k in CACHE_KEYS}
        rec["iv"] = tuple(rec["iv"])
        rec["tags"] = list(rec.get("tags") or [])
        # Which of these are IV tags, and whether it has the TAG_NAME tag, by the current settings (tag
        # names may have changed since last time)
        ivnames = {n for _, n in cfg.IV_TAGS}
        rec["have"] = [t for t in rec["tags"] if t in ivnames]
        rec["removable"] = cfg.TAG_NAME in rec["tags"]
        rec["cached"] = True
        if not rec.get("sid"):
            rec.pop("sid", None)       # recognize the species again (neighbors in the list help)
            rec.pop("level", None)
        st.recs[i] = rec
        n += 1
    return n


def remember_box(st, mem, whole, complete=False):
    """Memory for the next run: what is known about each Pokémon now (IV, types, tags after tagging, name
    after renaming). Nothing is deleted by age – memory is reconciled with the storage:
    - whole = st is the whole storage. complete = it was also read in full (without memory), so whatever
      isn't in it isn't in the game – it gets deleted.
    - whole storage, read with memory: a Pokémon that wasn't in the list is deleted if it had the TAG_NAME
      tag (most likely transferred), or if it was missing for the second time in a row (grid OCR
      sometimes misses a cell).
    - only part of the storage (a list from a search): other entries are not affected.
    The comparison is with the memory from the start of the run, so saving repeatedly during one run
    duplicates nothing."""
    if mem is None or not st.seq:
        return
    now = time.time()
    items = []
    for i in sorted(st.recs):
        rec = st.recs[i]
        cell = st.seq[i] if i < len(st.seq) else None
        if cell is None or not rec.get("iv") or cell.get("cp") is None:
            continue
        it = {k: rec.get(k) for k in CACHE_KEYS}
        it["iv"] = list(rec["iv"])
        it["t"] = rec.get("t") or now
        # Grid name (it identifies the Pokémon next time); if OCR missed it, the detail-screen name
        it["gcp"], it["gname"] = cell["cp"], cell.get("name") or rec.get("name") or ""
        items.append(it)
    if not (whole and complete):
        by_cp, by_iv = {}, set()
        for it in items:
            by_cp.setdefault(it["gcp"], []).append(it["gname"])
            by_iv.add((it.get("cp"), tuple(it["iv"])))

        def superseded(old):
            if (old.get("cp"), tuple(old.get("iv") or ())) in by_iv:
                return True            # same Pokémon, just renamed in the meantime
            return any(same_name(g, old.get("gname") or "") for g in by_cp.get(old.get("gcp"), []))
        for old in mem.box_start:
            if superseded(old):
                continue
            if whole:
                misses = old.get("misses", 0) + 1
                if old.get("removable") or misses >= 2:
                    continue           # no longer in the game (transferred)
                old = dict(old, misses=misses)
            items.append(old)
    mem.set_box(items)


def read_missing(bot, st, todo):
    """Repeat run: reads only the Pokémon the bot doesn't know (new ones, or ones not matched with memory).
    A search by CP shows just them, and they are opened one by one (as in renaming) – the whole list is not
    scrolled through. A Pokémon missing from the results (a doubled cell from scrolling, a misread CP) is
    dropped from the list."""
    pending = [k for k in todo if k not in st.recs and k not in st.phantom]
    total = len(st.seq)
    while pending:
        batch = pending[:cfg.SEARCH_BATCH]
        query, view = search_view(st.seq, batch)
        vseq, vpos = [st.seq[k] for k in view], {k: n for n, k in enumerate(view)}
        show_search(bot, query)
        lost = empty_search(bot, st.seq, batch, query)
        if lost is not None:
            st.phantom.update(lost)
            pending = [k for k in pending if k not in st.phantom and k not in st.recs]
            continue
        nav = {"lo": 0, "top": True}
        for k in batch:
            if k in st.recs or k not in vpos or k in st.phantom:
                continue
            if st.scan_fail.get(k, 0) >= 2:    # keeps failing to open – skip it so the run doesn't stall
                log(T(f"   kus č. {k + 1} (CP{st.seq[k]['cp']}) se nedaří otevřít, vynechávám ho",
                      f"   can't open no. {k + 1} (CP{st.seq[k]['cp']}), skipping it"))
                st.phantom.add(k)
                st.skipped.add(k)
                continue
            st.scan_fail[k] = st.scan_fail.get(k, 0) + 1
            n = len(st.recs) + 1
            step(T("Čtu IV: ", "Reading IV: ") + f"{n}/{total}")
            try:
                fr = open_in_view(bot, vseq, vpos[k], nav)
            except NotInSearch:
                st.phantom.add(k)      # no such Pokémon in the game (a doubled cell in the list)
                continue
            fr = bot.settle(fr)
            rec = read_here(bot, fr, None)
            iv, fr = appraise(bot, fr, st.seq[k]["cp"])
            rec["iv"] = tuple(iv) if iv else None
            if rec["cp"] is None:
                rec["cp"] = st.seq[k]["cp"]
            rec["t"] = time.time()
            st.recs[k] = rec
            if iv:
                save_card(bot.bars_frame, rec)
            bot.progress += 1
            ivs = "/".join(map(str, iv)) if iv else "?"
            log(f"   {n}/{total} CP{rec['cp']} {rec['name']}: IV {ivs}" +
                (f" · {', '.join(rec['have'])}" if rec["have"] else ""))
            emit("scan", what="iv", n=n, total=total, cp=rec["cp"], name=rec["name"],
                 iv=list(iv) if iv else None)
            close_detail(bot, fr)
        pending = [k for k in pending if k not in st.recs and k not in st.phantom]
    gone = drop_phantoms(st, total)
    if gone:
        log(T(f"   seznam srovnán: {gone} zdvojených buněk vyhozeno", f"   list cleaned up: {gone} doubled cells dropped"))


def ensure_scanned(bot, st, mem=None):
    """Makes sure the whole storage is read (list + IV and tags of every Pokémon) – for IV tags, PvP tags
    and renaming. Pokémon the bot knows from the previous run (same CP and name) are not read again."""
    if st.seq is None:
        st.seq = grid_scan(bot)
        if mem is not None and not getattr(bot, "no_cache", False):
            st.cache_hits = from_memory(st, mem)
            if st.cache_hits:
                left = len(st.seq) - st.cache_hits
                log(T(f"   z paměti: {pokemon_count(st.cache_hits)} (minule přečtení, stejné CP i jméno) – "
                      f"čtu jen {pokemon_count(left)}",
                      f"   from memory: {pokemon_count(st.cache_hits)} (read last time, same CP and name) – "
                      f"reading just {pokemon_count(left)}"))
                emit("info", text=T(f"Z paměti: {pokemon_count(st.cache_hits)}, čtu jen {pokemon_count(left)}.",
                                    f"From memory: {pokemon_count(st.cache_hits)}, reading just {pokemon_count(left)}."))
    if not st.scanned:
        todo = unread(st, len(st.seq))
        if st.cache_hits and len(todo) <= max(30, len(st.seq) // 8):
            read_missing(bot, st, todo)        # a few new Pokémon – via search, not the whole list
        elif bot.fast:
            scan_details(bot, st)
        else:
            scan_details_slow(bot, st)
        st.scanned = True
        count_tags(bot, st)
        if mem is not None:
            identify_all(st)
            save_box(st, mem)
            remember_box(st, mem, whole=True, complete=not st.cache_hits)


def species_of(rec):
    """Species and level of a Pokémon (computed once and stored in the record)."""
    if "sid" not in rec:
        rec["sid"], rec["level"] = (None, None)
        if rec.get("iv") and rec.get("cp"):
            rec["sid"], rec["level"] = pokecalc.identify(rec.get("name"), rec.get("types"), rec["cp"], rec.get("hp"),
                                                         rec["iv"], rec.get("candy"))
    return rec["sid"], rec["level"]


def identify_all(st):
    """Species of every Pokémon. Where CP and HP fit several species (a nickname), the neighbors decide:
    the storage is sorted by Pokédex number, so a Pokémon's number lies between its neighbors' numbers."""
    if st.identified:
        return
    order = sorted(st.recs)
    for i in order:
        species_of(st.recs[i])
    dex = {i: pokecalc.SPECIES[st.recs[i]["sid"]]["dex"] for i in order if st.recs[i].get("sid")}
    for i in order:
        rec = st.recs[i]
        if rec.get("sid") or not rec.get("iv") or not rec.get("cp"):
            continue
        lo = max((d for j, d in dex.items() if j < i), default=1)
        hi = min((d for j, d in dex.items() if j > i), default=99999)
        rec["sid"], rec["level"] = pokecalc.identify(rec.get("name"), rec.get("types"), rec["cp"], rec.get("hp"),
                                                     rec["iv"], rec.get("candy"), dex_range=(lo, hi))
    st.identified = True


def rename_values(rec):
    """Name template chip values for a Pokémon (only the IV ones when the species is unknown)."""
    iv = rec["iv"]
    sid, level = species_of(rec)
    if sid:
        return pokecalc.chip_values(pokecalc.info(sid, iv, level, rec["cp"]), iv)
    return pokecalc.iv_values(iv)


def save_box(st, mem):
    """For the app: an overview of the storage that was read (~/.pogo/last_box.json) – the number of
    Pokémon in an IV range and the sample names in the renaming settings."""
    out = []
    for i in sorted(st.recs):
        rec = st.recs[i]
        if not rec.get("iv"):
            continue
        name = rec.get("name") or ""
        out.append({"cp": rec["cp"], "name": name, "iv": list(rec["iv"]), "tags": rec.get("tags") or [],
                    "custom": not pokecalc.is_species_name(name) and not mem.renamed(rec["cp"], name),
                    "values": rename_values(rec)})
    try:
        tmp = cfg.BOX_FILE.with_name(cfg.BOX_FILE.name + ".tmp")
        tmp.write_text(json.dumps({"t": time.time(), "items": out}, ensure_ascii=False))
        tmp.replace(cfg.BOX_FILE)
    except OSError:
        pass


def open_in_view(bot, vseq, vidx, nav, loose=False):
    """Finds Pokémon vseq[vidx] in the search results (from the current position down) and opens its
    detail screen. nav = position in the list ({"lo": where matching starts, "top": the list is at the
    top}). If it isn't in the results, raises NotInSearch – searching goes on from the same place.
    loose: the game may order Pokémon with the same Pokédex number and CP differently in the results than
    in the whole list – if vseq[vidx] doesn't match, the only unmatched cell with the same CP and name is
    opened (the caller checks on the detail screen who it is)."""
    while True:
        cells, fr = read_grid(bot)
        pairs = match_view(vseq, cells, nav["lo"])
        k = next((k for k, v in pairs.items() if v == vidx), None)
        if k is None and loose:
            free = [k for k, c in enumerate(cells) if k not in pairs and same_cell(vseq[vidx], c)]
            k = free[0] if len(free) == 1 else None
        want = vseq[vidx]
        if loose and k is not None and alnum(cells[k]["name"]) and not names_ok(want["name"], cells[k]["name"]):
            # same_cell doesn't compare names of bottom cells – of two Pokémon with the same CP, pick the one
            # with the right name
            named = [j for j, c in enumerate(cells) if c["cp"] == want["cp"] and alnum(c["name"]) and
                     names_ok(want["name"], c["name"])]
            k = named[0] if len(named) == 1 else k
        if k is not None:
            return open_detail(bot, cells[k])
        if not pairs:
            raise StepError(T("ve výsledcích hledání se nedá zorientovat", "can't find my way in the search results"))
        if min(pairs.values()) > vidx and not nav["top"]:
            raise LostPosition(T("Pokémon, u kterého se má pokračovat, je výš v seznamu",
                                 "the Pokémon to continue from is higher up in the list"))
        if max(pairs.values()) > vidx or not scroll_next(bot, cells):
            raise NotInSearch(T(f"CP{vseq[vidx]['cp']} ve výsledcích hledání není", f"CP{vseq[vidx]['cp']} isn't in the search results"))
        nav["top"] = False
        nav["lo"] = next_lo(cells, pairs, nav["lo"])
