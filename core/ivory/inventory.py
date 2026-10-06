"""What the bot knows about the storage: reusing memory, reading what is missing, saving it for the app."""
import time

from . import config as cfg
from .errors import LostPosition, NotInSearch, StepError
from .output import emit, log, pokemon_count, step, T
from .vision import alnum
from .grid import names_ok
from .detail import appraise, close_detail, open_detail
from .scroll import read_grid, scroll_next
from .monrec import identify_all, live_mon
from .scanstate import count_tags, require_top
from .gridscan import grid_scan, same_cell
from .locate import match_view, open_cell
from .ivscan import drop_phantoms, read_here, scan_details, unread
from .batch import empty_search, next_lo, search_view, show_search
from .memory_box import from_memory, remember_box, save_box


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
        bot.progress += 1
        ivs = "/".join(map(str, iv)) if iv else "?"
        log(f"   {i + 1}/{total} CP{rec['cp']} {rec['name']}: IV {ivs}")
        emit("scan", what="iv", n=i + 1, total=total, **live_mon(rec))
        close_detail(bot, fr)


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
            bot.progress += 1
            ivs = "/".join(map(str, iv)) if iv else "?"
            log(f"   {n}/{total} CP{rec['cp']} {rec['name']}: IV {ivs}" +
                (f" · {', '.join(rec['have'])}" if rec["have"] else ""))
            emit("scan", what="iv", n=n, total=total, **live_mon(rec))
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


def open_in_view(bot, vseq, vidx, nav, loose=False):
    """Finds Pokémon vseq[vidx] in the search results (from the current position down) and opens its
    detail screen. nav = position in the list ({"lo": where matching starts, "top": the list is at the
    top}). If it isn't in the results, raises NotInSearch – searching goes on from the same place.
    loose: the game may order Pokémon with the same Pokédex number and CP differently in the results than
    in the whole list – if vseq[vidx] doesn't match, the only unmatched cell with the same CP and name is
    opened (the caller checks on the detail screen who it is)."""
    grid = None                                  # the screen a scroll already settled on
    while True:
        cells, fr = grid or read_grid(bot)
        grid = None
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
        grid = None if max(pairs.values()) > vidx else scroll_next(bot, cells, fr=fr)
        if grid is None:
            raise NotInSearch(T(f"CP{vseq[vidx]['cp']} ve výsledcích hledání není", f"CP{vseq[vidx]['cp']} isn't in the search results"))
        nav["top"] = False
        nav["lo"] = next_lo(cells, pairs, nav["lo"])
