"""The duplicates step: groups of the same Pokémon in the storage, the worse ones of each group get the
transfer tag."""
from . import config as cfg
from .output import emit, log, pokemon_count, T
from .grid import make_runs, names_ok, sprite_sim
from .records import decide_group, Rec
from .gridscan import grid_scan
from .ivscan import scan_details
from .batch_passes import run_passes
from .memory_box import from_memory, remember_box


def regroup(st, args):
    """Groups of identical Pokémon (duplicates) in st.seq[:st.upto]."""
    st.group_of = {}
    gid, upto = 0, len(st.seq) if st.upto is None else st.upto
    k = 0
    for run_ in make_runs(st.seq[:upto]):
        if len(run_) >= 2:
            gid += 1
            if args.max_groups and gid > args.max_groups:
                break
            for i in range(k, k + len(run_)):
                st.group_of[i] = gid
        k += len(run_)


def map_from_full(st, full):
    """Duplicates without reading IV a second time: the cells of the search list (a subset of the whole
    storage, in the same order) are matched with the already-read Pokémon of the whole storage by CP, name
    and sprite."""
    st.tag_map, j0, miss = {}, 0, 0
    for i, c in enumerate(st.seq):
        j = next((j for j in range(j0, len(full.seq)) if full.seq[j]["cp"] == c["cp"]
                  and names_ok(full.seq[j]["name"], c["name"])
                  and sprite_sim(full.seq[j]["sprite"], c["sprite"]) >= cfg.SAME_SPECIES_THR), None)
        if j is None:
            miss += 1
            continue
        st.tag_map[i] = j
        if j in full.recs:
            st.recs[i] = full.recs[j]      # same record – Removable carries over into the later steps too
        j0 = j + 1
    log(T(f"   IV beru z přečteného inventáře: {pokemon_count(len(st.recs))}",
          f"   taking IVs from the read storage: {pokemon_count(len(st.recs))}") +
        (T(f", {miss} se nepodařilo spárovat", f", {miss} couldn't be matched") if miss else ""))


def fast_duplicates(bot, book, mem, args, report, st, full=None):
    """Part 1, fast: list from the search → IV of all of them (with the ▶ arrow, or taken over from full,
    the already-read whole storage) → worse duplicates → TAG_NAME tag in bulk (via a search by CP)."""
    if st.seq is None:
        st.seq = grid_scan(bot)
        pos = {id(c): k for k, c in enumerate(st.seq)}
        gid, upto = 0, len(st.seq)
        for run_ in make_runs(st.seq):
            if len(run_) < 2:
                continue
            gid += 1
            if args.max_groups and gid > args.max_groups:
                upto = pos[id(run_[0])]
                break
            for c in run_:
                st.group_of[pos[id(c)]] = gid
        st.upto = upto
        log(T("   skupin stejných Pokémonů: ", "   groups of the same Pokémon: ") + str(len(set(st.group_of.values()))))
        if full is None and not getattr(bot, "no_cache", False):
            st.cache_hits = from_memory(st, mem)
            if st.cache_hits:
                log(T(f"   z paměti: {pokemon_count(st.cache_hits)} (minule přečtení, stejné CP i jméno)",
                      f"   from memory: {pokemon_count(st.cache_hits)} (read last time, same CP and name)"))
    if not st.scanned:
        if full is not None:
            map_from_full(st, full)
        else:
            scan_details(bot, st, st.upto)
            remember_box(st, mem, whole=False)
        st.scanned = True
        regroup(st, args)        # the list may have been corrected while reading (doubled cells dropped)
        if full is not None:
            st.tag_full = full   # tag in the whole storage (search by CP), indexes via st.tag_map
        else:
            st.tag_base = cfg.SEARCH_QUERY
    if not st.planned:
        targets = []
        groups = {}
        for i, gid in sorted(st.group_of.items()):
            r = Rec(st.seq[i], gid)
            rec = st.recs.get(i) or {}
            r.iv, r.types = rec.get("iv"), rec.get("types")
            r.status = "done" if r.iv else "failed"
            r.tagged = bool(rec.get("removable")) or mem.is_tagged(r.cp, r.name)
            if r.iv:
                if rec.get("cached"):
                    r.cached = True        # IV from the previous run (not read again)
                else:
                    report.measured += 1
                mem.set_iv(r.sig, r.iv, r.types, save=False)
            book.recs.append(r)
            groups.setdefault(gid, []).append((i, r))
        for gid, items in groups.items():
            group = [r for _, r in items]
            for r in group:      # same CP and name within the group – can't be told apart reliably
                r.ambiguous = sum(1 for o in group if o.cp == r.cp and names_ok(o.name, r.name)) > 1
            if decide_group(group):
                log(T("   pozor: ve skupině jsou různé formy (jiné typy) – každou posuzuji zvlášť",
                  "   note: the group has different forms (other types) – judging each one separately"))
            targets += [i for i, r in items if r.action == "remove" and not r.tagged and not r.ambiguous]
            report.show(book, gid)
        st.index_rec = {i: r for items in groups.values() for i, r in items}
        st.passes = [(cfg.TAG_NAME, False, targets)] if targets else []
        st.planned = True
        mem.save()

    def done(tag, remove, idxs):
        for i in idxs:
            r = st.index_rec[i]
            r.tagged = True
            mem.set_tagged(r.cp, r.name)
            rec = st.recs.get(i)
            if rec is not None:            # the later steps (IV, PvP, renaming) skip it
                rec["removable"] = True
                rec["tags"] = list(dict.fromkeys((rec.get("tags") or []) + [cfg.TAG_NAME]))
        emit("tagged", tag=cfg.TAG_NAME, color=cfg.TAG_COLOR,
             items=[{"cp": st.index_rec[i].cp, "name": st.index_rec[i].name} for i in idxs])
        book.progress += 1
        for gid in sorted({st.index_rec[i].gid for i in idxs}):
            report.show(book, gid)
    run_passes(bot, st, done)
