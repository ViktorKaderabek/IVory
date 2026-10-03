"""The four steps of a run: duplicates, IV tags, PvP tags and renaming."""
import time

import pokecalc

from . import config as cfg
from .errors import Fatal, LostPosition, NameRefused, NeedTop, NotInSearch, StepError
from .output import emit, log, pct_text, pokemon_count, step, T
from .vision import alnum, find_text
from .grid import make_runs, names_ok, sprite_sim
from .screens import detail_cp, detail_hp, detail_name, keyboard_on, name_refused, nickname_dialog
from .navigation import ensure_box
from .records import decide_group, Rec
from .detail import cancel_nickname, close_detail
from .tags import confirm_button, iv_tag
from .scan import grid_scan, scan_details
from .batch import empty_search, mark_missing, run_passes, search_view, show_search
from .inventory import (
    ensure_scanned, from_memory, identify_all, open_in_view, remember_box, rename_values, same_name,
    species_of)


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


def fast_iv(bot, book2, mem, args, report, st):
    """Part 2, fast: whole storage → IV and tags of all of them via the ▶ arrow → add the right IV tags in
    bulk (best first) and remove the ones that don't fit."""
    ensure_scanned(bot, st, mem)
    if not st.iv_planned:
        add = {n: [] for _, n in cfg.IV_TAGS}
        drop = {n: [] for _, n in cfg.IV_TAGS}
        st.index_rec = {}
        for i, cell in enumerate(st.seq):
            rec = st.recs.get(i) or {}
            r = Rec(cell, 0)
            st.index_rec[i] = r
            book2.recs.append(r)
            r.iv, r.types = rec.get("iv"), rec.get("types")
            r.cached = bool(rec.get("cached"))
            if rec.get("removable"):
                r.status, r.note = "skip", T(f"má tag {cfg.TAG_NAME} – přeskakuji", f"has the {cfg.TAG_NAME} tag – skipping")
                continue
            if not r.iv:
                r.status, r.note = "failed", T("IV se nepodařilo přečíst", "couldn't read the IV")
                continue
            mem.set_iv(r.sig, r.iv, r.types, save=False)
            have = [h for h in (rec.get("have") or []) if h in drop]   # only IV tags from the current settings
            r.target = iv_tag(r.iv)
            r.had = r.target in have
            r.removed = [h for h in have if h != r.target]
            # "done" only once the tag is really set (a bulk batch can fail)
            r.status = "done" if r.had and not r.removed else "pending"
            r.note = r.target + (T(" (už měl)", " (already had it)") if r.had and not r.removed else "") + \
                (T(f" (odebrat: {', '.join(r.removed)})", f" (remove: {', '.join(r.removed)})") if r.removed else "")
            if not r.had:
                add[r.target].append(i)
            for h in r.removed:
                drop[h].append(i)
        st.passes = [(n, False, add[n]) for _, n in cfg.IV_TAGS if add[n]] + \
                    [(n, True, drop[n]) for _, n in cfg.IV_TAGS if drop[n]]
        st.pending = {}
        for _, _, ix in st.passes:
            for i in ix:
                st.pending[i] = st.pending.get(i, 0) + 1
        st.iv_planned = True
        mem.save()
        if st.passes:
            log(T("\n   Plán hromadného tagování: ", "\n   Bulk tagging plan: ") + ", ".join(
                f"{'−' if rm else '+'}{n} ({len(ix)})" for n, rm, ix in st.passes))

    def done(tag, remove, idxs):
        book2.progress += 1
        for i in idxs:
            st.pending[i] -= 1
            if st.pending[i] == 0:          # all changes for this Pokémon are done
                st.index_rec[i].status = "done"
                report.show_iv(st.index_rec[i])
    run_passes(bot, st, done)
    for i, r in st.index_rec.items():
        if r.status == "pending":            # the batch with its tag failed even on the third try
            r.status, r.note = "failed", f"{r.note} – " + (
                T("ve hře nenalezen (CP se asi přečetlo špatně)", "not found in the game (probably a misread CP)")
                if st.seq[i].get("miss", 0) >= 2 else T("tag se nepodařilo nastavit", "couldn't set the tag"))
    for r in st.index_rec.values():          # the ones that needed nothing (already had it / skipped / error)
        if r.status != "done" or (r.had and not r.removed):
            report.show_iv(r)


def fast_pvp(bot, mem, args, report, st):
    """Part 3: IV rank for the PvP leagues → league tags in bulk (add where the rank fits, remove where it
    no longer does)."""
    ensure_scanned(bot, st, mem)
    leagues = [lg for lg in cfg.PVP if cfg.PVP[lg]["enabled"]]
    if not st.pvp_planned:
        identify_all(st)
        add = {lg: [] for lg in leagues}
        drop = {lg: [] for lg in leagues}
        st.pvp_index = {}
        unknown = 0
        for i in sorted(st.recs):
            rec = st.recs[i]
            if not rec.get("iv") or rec.get("removable"):
                continue
            sid, level = species_of(rec)
            if not sid:
                unknown += 1
                continue
            ranks = {lg: pokecalc.league_rank(sid, rec["iv"], lg) for lg in leagues}
            rec["ranks"] = {lg: (r[0] if r else None) for lg, r in ranks.items()}
            tags = set(rec.get("tags") or [])
            want = []
            for lg in leagues:
                name = cfg.PVP[lg]["name"]
                ok = rec["ranks"][lg] is not None and rec["ranks"][lg] <= cfg.PVP[lg]["max_rank"]
                if ok:
                    want.append(name)
                    if name not in tags:
                        add[lg].append(i)
                elif name in tags:
                    drop[lg].append(i)
            rk = "  ".join(f"{pokecalc.LEAGUE_LETTER[lg]}{rec['ranks'][lg] or '–'}" for lg in leagues)
            dex = pokecalc.SPECIES[sid]["dex"]
            ivs = "/".join(f"{v:02d}" for v in rec["iv"])
            log(f"   CP{rec['cp']:<5} #{dex:04d}  {ivs}  {rk}  -> {', '.join(n.split()[0] for n in want) or '–'}")
            emit("pvp", cp=rec["cp"], name=rec["name"], dex=dex, iv=list(rec["iv"]), ranks=rec["ranks"], tags=want)
            if want:
                st.pvp_index[i] = want
        if unknown:
            log(T(f"   (u {pokemon_count(unknown)} se nepodařilo poznat druh – PvP pořadí nejde spočítat)",
                  f"   (couldn't recognize the species of {pokemon_count(unknown)} – no PvP rank for them)"))
        st.passes = [(cfg.PVP[lg]["name"], False, add[lg]) for lg in leagues if add[lg]] + \
                    [(cfg.PVP[lg]["name"], True, drop[lg]) for lg in leagues if drop[lg]]
        st.pvp_planned = True
        if st.passes:
            log(T("\n   Plán PvP tagů: ", "\n   PvP tag plan: ") + ", ".join(f"{'−' if rm else '+'}{n} ({len(ix)})" for n, rm, ix in st.passes))

    def done(tag, remove, idxs):
        report.pvp_tagged += 0 if remove else len(idxs)
        emit("tagged", tag=tag, color=cfg.tag_color(tag), remove=remove,
             items=[{"cp": st.seq[i]["cp"], "name": st.seq[i]["name"]} for i in idxs])
    run_passes(bot, st, done)


def rename_here(bot, fr, new):
    """Open detail screen → tap the name → clear it → type the new name → confirm → check it on the detail
    screen. When the game refuses the name ("This name contains inappropriate text"), closes the dialog with
    CANCEL and the detail screen, and raises NameRefused."""
    fr = bot.settle(fr)
    old = detail_name(fr.texts)
    t = find_text(fr.texts, [old], exact=True, region=(0.15, 0.36, 0.85, 0.48)) if old else None
    spots = ([(t["cx"], t["cy"]), (min(0.95, t["x1"] + 0.05), t["cy"])] if t else []) + [(0.5, 0.42)]
    for k, p in enumerate(spots):
        t0 = bot.tap(p[0], p[1], T("jméno (přejmenovat)", "name (rename)") if k == 0 else T("tužka u jména", "pencil next to the name"), fr=fr)
        ok, fr = bot.wait_for(lambda f: keyboard_on(f.texts), 2.5, after=t0 + cfg.FRAME_LAG, label="klávesnice")
        if ok:
            break
    else:
        raise StepError(T("přejmenování se neotevřelo", "renaming didn't open"))
    try:                                   # clear the old name: the keyboard field supports "clear"
        bot.d.switch_to.active_element.clear()
    except Exception:
        bot.type_text("\b" * (len(old or "") + 4))
    bot.type_text(new)
    t0 = time.time()
    bot.type_text("\n")
    named = lambda f: (not keyboard_on(f.texts) and not nickname_dialog(f.texts)
                       and alnum(detail_name(f.texts)) == alnum(new))
    over = lambda f: named(f) or name_refused(f.texts)
    ok, fr = bot.wait_for(over, 3, after=t0 + cfg.FRAME_LAG, label="nové jméno")
    if not ok and not keyboard_on(fr.texts):
        d = confirm_button(fr.texts)       # the game may want an OK to confirm
        if d is not None:
            t0 = bot.tap(d["cx"], d["cy"], T(f"potvrdit jméno ({d['text']})", f"confirm the name ({d['text']})"), fr=fr)
            # the game checks the name on its server, so a refusal may take a few seconds
            ok, fr = bot.wait_for(over, 8, after=t0 + cfg.FRAME_LAG, label="nové jméno")
    if name_refused(fr.texts):
        cancel_nickname(bot, fr)
        close_detail(bot)
        raise NameRefused(T(f"hra jméno „{new}“ odmítla (nevhodný text)", f"the game refused the name “{new}” (inappropriate text)"))
    if not ok:
        if nickname_dialog(fr.texts):
            cancel_nickname(bot, fr)       # going back to the storage with the dialog open would tap the keyboard
        raise StepError(T(f"jméno „{new}“ se neuložilo (v detailu: {detail_name(fr.texts)!r})",
                          f"the name “{new}” didn't save (the detail shows {detail_name(fr.texts)!r})"))
    close_detail(bot, fr)
    return old


def is_piece(fr, rec):
    """Is the open detail screen this Pokémon? A search by CP also shows other Pokémon with the same CP (two
    Kyurem with CP 2013) and a cell can be matched wrongly – a different Pokémon would then get a name
    computed from someone else's IV."""
    tx = fr.texts
    cp, name, hp = detail_cp(tx), detail_name(tx), detail_hp(tx)
    if cp is not None and cp != rec["cp"]:
        return False
    if name and rec.get("name") and not same_name(name, rec["name"]):
        return False
    return not (hp and rec.get("hp") and hp != rec["hp"])


def opened_todo(fr, st, vpos):
    """Position in st.rename_todo of the Pokémon whose detail screen is open: preferably the one that was
    tapped (0), otherwise another Pokémon from the search results with the same CP, name and HP.
    None = a Pokémon that isn't being renamed."""
    for j, (i, _) in enumerate(st.rename_todo):
        if (j == 0 or i in vpos) and is_piece(fr, st.recs[i]):
            return j
    return None


def fast_rename(bot, mem, args, report, st):
    """Part 4: renames Pokémon with IV in range by the template (skips custom nicknames)."""
    ensure_scanned(bot, st, mem)
    template = cfg.RENAME["template"] or pokecalc.DEFAULT_TEMPLATE
    need_species = any(c.get("k") in pokecalc.NEEDS_SPECIES for c in template)
    if not st.rename_planned:
        identify_all(st)
        lo, hi = cfg.RENAME["min"], cfg.RENAME["max"]
        log(T(f"\n── Přejmenování · IV {lo}–{hi} %", f"\n── Renaming · IV {lo}–{hi}%"))
        st.rename_todo = []
        skipped = 0
        for i in sorted(st.recs):
            rec = st.recs[i]
            iv = rec.get("iv")
            if not iv or not lo <= round(sum(iv) * 100 / 45) <= hi:
                continue
            pct = round(sum(iv) * 100 / 45)
            if cfg.RENAME["skip_removable"] and rec.get("removable"):
                continue
            if cfg.RENAME["only_tag"] and cfg.RENAME["only_tag"] not in (rec.get("tags") or []):
                continue
            cur = rec.get("name") or ""
            if st.seq[i].get("miss", 0) >= 2:
                log(f"   CP{rec['cp']:<5} {pct_text(pct)}  {cur} · " +
                    T("ve hře nenalezen (CP se asi přečetlo špatně), přeskakuji",
                      "not found in the game (probably a misread CP), skipping"))
                skipped += 1
                continue
            if need_species and not species_of(rec)[0]:
                log(f"   CP{rec['cp']:<5} {pct_text(pct)}  {cur} · " + T("druh nepoznán, přeskakuji", "species unknown, skipping"))
                skipped += 1
                continue
            new = pokecalc.render_name(template, rename_values(rec))
            if not new or alnum(new) == alnum(cur):
                continue                   # already has the right name
            if not cfg.RENAME["overwrite_custom"] and not pokecalc.is_species_name(cur) and not mem.renamed(rec["cp"], cur):
                log(f"   CP{rec['cp']:<5} {pct_text(pct)}  {cur} · " + T("vlastní přezdívka, přeskakuji", "custom nickname, skipping"))
                emit("rename", cp=rec["cp"], old=cur, new=None, skipped="custom")
                skipped += 1
                continue
            if mem.refused_name(new):
                log(f"   CP{rec['cp']:<5} {pct_text(pct)}  {cur} · " +
                    T(f"jméno „{new}“ hra už jednou odmítla, přeskakuji", f"the game refused the name “{new}” before, skipping"))
                emit("rename", cp=rec["cp"], old=cur, new=None, skipped="refused")
                skipped += 1
                continue
            st.rename_todo.append((i, new))
        st.rename_skipped = skipped
        st.rename_planned = True
    while st.rename_todo:
        # A search by CP shows only the Pokémon to rename (in batches) – no looking through the whole list
        batch = [i for i, _ in st.rename_todo[:cfg.SEARCH_BATCH]]
        query, view = search_view(st.seq, batch)
        vseq, vpos = [st.seq[k] for k in view], {k: n for n, k in enumerate(view)}
        show_search(bot, query)
        lost = empty_search(bot, st.seq, batch, query)
        if lost is not None:           # the search found nothing – skip the surely missing ones, otherwise retype it
            for i in lost:
                rec = st.recs[i]
                log(f"   ✖ CP{rec['cp']} {rec.get('name')}: " + T("ve hře nenalezen, přeskakuji", "not found in the game, skipping"))
            st.rename_todo = [x for x in st.rename_todo if x[0] not in set(lost)]
            st.rename_skipped += len(lost)
            continue
        nav = {"lo": 0, "top": True}
        for _ in batch:
            i, new = st.rename_todo[0]
            rec = st.recs[i]
            step(T("Přejmenovávám: ", "Renaming: ") + f"{rec.get('name')} → {new}")
            try:
                if i not in vpos:
                    raise NotInSearch(T(f"CP{rec['cp']} ve výsledcích hledání není", f"CP{rec['cp']} isn't in the search results"))
                fr = bot.settle(open_in_view(bot, vseq, vpos[i], nav, loose=True))
                j = opened_todo(fr, st, vpos)
                if j is None:
                    close_detail(bot, fr)
                    raise StepError(T(f"otevřel se jiný kus než CP{rec['cp']} {rec.get('name')} "
                                      f"(v detailu: {detail_name(fr.texts)!r}, CP{detail_cp(fr.texts)})",
                                      f"a different Pokémon than CP{rec['cp']} {rec.get('name')} opened "
                                      f"(the detail shows {detail_name(fr.texts)!r}, CP{detail_cp(fr.texts)})"))
                if j:                          # same CP and name: another Pokémon to rename opened
                    st.rename_todo.insert(0, st.rename_todo.pop(j))
                    i, new = st.rename_todo[0]
                    rec = st.recs[i]
                old = rename_here(bot, fr, new)
            except NotInSearch:
                st.rename_todo.pop(0)
                mark_missing(st.seq, [i], sure=True)
                st.rename_skipped += 1
                log(f"   ✖ CP{rec['cp']} {rec.get('name')}: " +
                    T("ve výsledcích hledání ho nevidím (CP se asi přečetlo špatně), přeskakuji",
                      "not in the search results (probably a misread CP), skipping"))
                continue
            except NameRefused:                # the same name would be refused again – no second try
                st.rename_todo.pop(0)
                st.rename_fails = 0
                st.rename_skipped += 1
                mem.set_refused_name(new)
                log(f"   ✖ CP{rec['cp']} {rec.get('name')}: " +
                    T(f"hra jméno „{new}“ odmítla (nevhodný text), nechávám původní",
                      f"the game refused the name “{new}” (inappropriate text), keeping the old one"))
                emit("rename", cp=rec["cp"], old=rec.get("name"), new=None, skipped="refused")
                emit("problem", text=T(f"Hra odmítla jméno „{new}“ pro CP{rec['cp']} {rec.get('name')} (prý nevhodný "
                                       f"text). Pokémon má dál původní jméno – přejmenuj ho ručně.",
                                       f"The game refused the name “{new}” for CP{rec['cp']} {rec.get('name')} "
                                       f"(inappropriate text, it says). The Pokémon keeps its name – rename it yourself."))
                continue
            except (Fatal, NeedTop, LostPosition):
                raise
            except StepError:
                st.rename_fails = getattr(st, "rename_fails", 0) + 1
                if st.rename_fails >= 2:       # renaming this Pokémon keeps failing – move on
                    log(f"   ✖ CP{rec['cp']} {rec.get('name')}: " + T("přejmenování se nepovedlo, přeskakuji", "renaming failed, skipping"))
                    st.rename_todo.pop(0)
                    st.rename_fails = 0
                    ensure_box(bot)            # back to the search results
                    continue
                raise
            st.rename_fails = 0
            st.rename_todo.pop(0)
            st.seq[i]["name"] = rec["name"] = new      # the grid now shows the new name
            mem.set_renamed(rec["cp"], new)
            report.renamed += 1
            bot.progress += 1
            pct = round(sum(rec["iv"]) * 100 / 45)
            log(f"   CP{rec['cp']:<5} {pct_text(pct)}  {old} → {new}")
            emit("rename", cp=rec["cp"], old=old, new=new)
    log(T("   ✔ přejmenováno: ", "   ✔ renamed: ") + pokemon_count(report.renamed) +
        (T(f" · vynecháno {st.rename_skipped}", f" · skipped {st.rename_skipped}") if st.rename_skipped else ""))
