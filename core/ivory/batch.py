"""Bulk tagging: an in-game CP search narrows the storage, then multi-select tags many Pokémon at once."""
from . import config as cfg
from .errors import Fatal, NeedTop, StepError, TagCreated
from .output import emit, log, pokemon_count, step, T
from .vision import find_text
from .grid import complete_cells
from .screens import classify, filter_key, search_bar_text, search_count, tag_button, tag_count, tag_list_on
from .navigation import ensure_box, read_grid, scroll_next
from .tags import LIST_REGION, pick_tag, row_state, scan_tag_list, set_row, wait_checked
from .scan import emit_counts, match_view, require_top


def cp_query(cps, base=None):
    """A search that shows only Pokémon with the given CPs (cp2260,cp2268,…); base = an extra condition (&…)."""
    q = ",".join(f"cp{c}" for c in sorted(cps))
    return f"{q}&{base}" if base else q


def search_view(seq, idxs, base=None):
    """For bulk work through the search: (search, view), where view = the indexes of seq the game shows
    once the search is typed, in the same order (the list is still sorted by number)."""
    cps = {seq[i]["cp"] for i in idxs}
    # Pokémon the CP search already ruled out (miss >= 2: not in the game with that CP) won't be in the results
    return cp_query(cps, base), [k for k in range(len(seq)) if seq[k]["cp"] in cps and seq[k].get("miss", 0) < 2]


def show_search(bot, query):
    """The storage showing only the results of the search query, from the top of the list."""
    bot.mode, bot.query = "cp", query
    ensure_box(bot)
    require_top(bot)


def next_lo(cells, pairs, lo):
    """Where to start pairing the next screen: after a scroll the last row stays at the top (one row of margin)."""
    if not pairs:
        return lo
    last = max(c["row"] for c in cells)
    row = [pairs[k] for k, c in enumerate(cells) if c["row"] == last and k in pairs]
    return max(lo, (min(row) if row else max(pairs.values())) - 3)


def search_empty(bot):
    """Did the search find nothing? The header shows "(0)", or no cell appears even after a moment."""
    done = lambda f: complete_cells(f.texts) or search_count(f.texts) == 0
    fr = bot.frame()
    if not done(fr):
        _, fr = bot.wait_for(done, 1.5, label="výsledky hledání")
    return not complete_cells(fr.texts) and classify(fr) == "box_other"


def mark_missing(seq, idxs, sure):
    """Pokémon seq[i] that the CP search didn't find. The first time they get one more try (the cell
    may just have been misread); when it is certain they aren't in the game, or the search missed them
    a second time, they are skipped in later steps too. Returns the ones being skipped."""
    out = []
    for i in idxs:
        seq[i]["miss"] = seq[i].get("miss", 0) + (2 if sure else 1)
        if seq[i]["miss"] >= 2:
            out.append(i)
    return out


def empty_search(bot, seq, idxs, query):
    """When the search found nothing, marks Pokémon seq[i] as missing and returns the ones being skipped
    (otherwise None). It is certain when the Search field holds exactly the search that was typed;
    otherwise it may have been mistyped, so next time it is cleared and typed again."""
    if not search_empty(bot):
        return None
    exact = filter_key(search_bar_text(bot.frame().texts)) == filter_key(query)
    if not exact:
        bot.typed_query = None             # next time clear the search and type it again
    log(T("   hledání nic nenašlo – ", "   the search found nothing – ") +
        (T("Pokémon s tímhle CP ve hře není (CP se nejspíš přečetlo špatně), přeskakuji",
           "there's no Pokémon with this CP in the game (the CP was probably misread), skipping") if exact
         else T("zkusím ho napsat znovu", "typing it again")))
    return mark_missing(seq, idxs, sure=exact)


def tag_batch(bot, seq, idxs, tag, remove=False, base=None):
    """Adds a tag to Pokémon seq[i] in bulk (i in idxs, at most SEARCH_BATCH at once), or removes it.
    Types their CPs into the search (cp2260,cp2268,…), so the game shows only them (and a few others
    with the same CP) on one or two screens; the whole list isn't scrolled through. base = the search
    seq comes from (duplicates), appended after the CPs. Returns (seq indexes that got the tag, seq
    indexes that aren't in the game: the CP search didn't find them, most likely their CP was misread;
    they are skipped and the rest of the batch is tagged normally)."""
    gone = [i for i in idxs if seq[i].get("miss", 0) >= 2]
    need = sorted(i for i in idxs if seq[i].get("miss", 0) < 2)[:cfg.SEARCH_BATCH]
    if not need:
        return [], gone
    query, view = search_view(seq, need, base)
    vseq = [seq[k] for k in view]
    vpos = {k: n for n, k in enumerate(view)}
    want = {vpos[i] for i in need}
    show_search(bot, query)
    what = T(f"{'Odebírám' if remove else 'Přidávám'} tag {tag}: {pokemon_count(len(need))}",
             f"{'Removing' if remove else 'Adding'} tag {tag}: {pokemon_count(len(need))}")
    log(f"\n   {what}")
    step(what)
    lost = empty_search(bot, seq, need, query)
    if lost is not None:
        return [], gone + lost
    fr = bot.frame()
    found = search_count(fr.texts)             # how many Pokémon the search found ("(12)" in the header)
    exact = filter_key(search_bar_text(fr.texts)) == filter_key(query)   # search field holds the whole, correct search
    others = set(range(len(vseq))) - want      # in the search results, but won't get the tag
    chosen, state = set(), {"lo": 0, "fr": None, "scrolled": False}

    def toggle(c, v, fr, on):
        """Taps a cell (select / deselect) and waits until the count in TAG (n) changes."""
        n_want = len(chosen) + (1 if on else -1)
        if not chosen:
            t0 = bot.long_press(c["cx"], c["cy"] + cfg.CELL_TAP_DY, T(f"podržet CP{c['cp']}", f"hold CP{c['cp']}"), fr=fr)
            n, fr = bot.wait_for(lambda f: tag_count(f.texts), 2.5, after=t0 + cfg.FRAME_LAG, label="multiselect")
            if n != 1:
                raise StepError(T(f"multiselect se nespustil (TAG {n})", f"multi-select didn't start (TAG {n})"))
        else:
            t0 = bot.tap(c["cx"], c["cy"] + cfg.SELECT_TAP_DY, T(f"{'vybrat' if on else 'odebrat z výběru'} CP{c['cp']}", f"{'select' if on else 'deselect'} CP{c['cp']}"),
                         fr=fr)
            _, fr = bot.wait_for(lambda f: tag_count(f.texts) == n_want, 2.0, after=t0 + cfg.FRAME_LAG, label="výběr")
            if tag_count(fr.texts) != n_want:
                raise StepError(T(f"výběr nesedí (TAG {tag_count(fr.texts)}, čekal jsem {n_want})",
                                  f"the selection is off (TAG {tag_count(fr.texts)}, expected {n_want})"))
        (chosen.add if on else chosen.discard)(v)
        return fr

    def visit(todo, on, first_only=False):
        """Goes down the search results from the current position and taps the cells in todo (vseq
        indexes), only those paired by both CP and name. Returns the ones not found in the results."""
        left = set(todo)
        while left:
            cells, fr = read_grid(bot)
            pairs = match_view(vseq, cells, state["lo"])
            if not pairs:
                raise StepError(T("ve výsledcích hledání se nedá zorientovat", "can't find my way in the search results"))
            for k, c in enumerate(cells):
                v = pairs.get(k)
                if v in left and c["cp"] == vseq[v]["cp"]:
                    fr = toggle(c, v, fr, on)
                    left.discard(v)
                    if first_only:
                        state["fr"] = fr
                        return left
            state["fr"] = fr
            if not left or max(left) < max(pairs.values()):
                break                          # the rest should have been higher up – not in the results
            n_before = len(chosen)
            if not scroll_next(bot, cells, multi=bool(chosen)):
                break                          # end of the results
            state["scrolled"] = True
            if chosen and tag_count(bot.frame().texts) != n_before:
                raise StepError(T("posun změnil výběr", "scrolling changed the selection"))
            state["lo"] = next_lo(cells, pairs, state["lo"])
        return left

    def missed(left):
        """Pokémon that aren't in the results. They are certainly missing when the search in the field is
        complete and the game found that many fewer than the list expects; otherwise they get another
        try in the next batch."""
        sure = exact and found is not None and len(left) <= len(vseq) - found
        return mark_missing(seq, [view[v] for v in left], sure)

    visit(want, True, first_only=True)            # the selection starts by holding the first target
    if not chosen:
        log(T("   nikoho z nich ve výsledcích hledání nevidím, přeskakuji", "   none of them are in the search results, skipping"))
        return [], gone + missed(want)
    fr = state["fr"]
    sa = None
    if bot.select_all_ok and not state["scrolled"] and len(want) >= 3 and len(others) <= len(want) // 3 \
            and len(vseq) <= 100 and found in (None, len(vseq)):
        sa = find_text(fr.texts, [cfg.L["select_all"]], region=(0.3, 0.0, 1.0, 0.2))
    left = set()
    if sa is not None:
        # SELECT ALL selects all search results; the extra ones (same CP) are then tapped off again
        t0 = bot.tap(sa["cx"], sa["cy"], T("vybrat všechny výsledky (SELECT ALL)", "select all results (SELECT ALL)"), fr=fr)
        _, fr = bot.wait_for(lambda f: (tag_count(f.texts) or 0) >= len(vseq), 2.5, after=t0 + cfg.FRAME_LAG,
                             label="vybrat vše")
        cnt = tag_count(fr.texts)
        if cnt == len(vseq):
            chosen.update(range(len(vseq)))
            state["fr"] = fr
            if others and visit(others, False):
                raise StepError(T("kusy navíc se nepodařilo odebrat z výběru", "couldn't deselect the extra ones"))
        else:
            # the result count differs from the list (a Pokémon missing or extra): cancel and select one by one
            if cnt is None or cnt > len(vseq) + 3:
                bot.select_all_ok = False      # SELECT ALL probably ignores the search – one by one from now on
            log(T(f"   SELECT ALL vybral {cnt}, ve výsledcích čekám {len(vseq)} – vybírám po jednom",
                  f"   SELECT ALL picked {cnt}, the results should have {len(vseq)} – selecting one by one"))
            bot.act(cfg.P_MULTI_CLOSE, T("zrušit výběr", "cancel selection"), lambda f: classify(f) != "multiselect", fr=fr, tries=1)
            chosen.clear()
            left = visit(want, True)
            if not chosen:
                return [], gone + missed(want)
    else:
        left = visit(want - chosen, True)
    fr = state["fr"]
    selected = sorted(chosen)
    if not selected or tag_count(fr.texts) != len(selected) or set(selected) - want:
        raise StepError(T(f"výběr nesedí (TAG {tag_count(fr.texts)}, vybráno {len(selected)})",
                          f"the selection is off (TAG {tag_count(fr.texts)}, selected {len(selected)})"))
    if left:
        log(T("   ve výsledcích hledání nevidím: ", "   not in the search results: ") + ", ".join(f"CP{vseq[v]['cp']}" for v in sorted(left)))
    tb = tag_button(fr.texts)
    if tb is None:
        raise StepError(T("nevidím tlačítko TAG", "can't see the TAG button"))
    _, fr = bot.act((tb["cx"], tb["cy"]), f"TAG ({len(selected)})", lambda f: tag_list_on(f.texts),
                    timeout=2.5, fr=fr, tries=1)
    fr = bot.settle(fr, region=LIST_REGION)
    if remove:
        row, fr = scan_tag_list(bot, fr, ["dolů", "nahoru"], tag)
        if row is not None:
            on, fr = wait_checked(bot, fr, tag)      # the check mark may show only a moment after the tag picker opens
            if on or row_state(fr, tag) == "mixed":  # "Mixed": only some selected have it – remove it from them too
                fr = set_row(bot, fr, tag, False)
    else:
        fr = pick_tag(bot, fr, tag)
    d = find_text(fr.texts, [cfg.L["done"]], exact=True, region=(0.0, 0.7, 1.0, 0.95))
    if d is None:
        raise StepError(T("nevidím DONE", "can't see DONE"))
    bot.act((d["cx"], d["cy"]), "DONE", lambda f: classify(f) in ("box", "box_other"), timeout=3, fr=fr, tries=1)
    log(T(f"   ✔ tag {tag} {'odebrán' if remove else 'přidán'}: {pokemon_count(len(selected))}",
          f"   ✔ tag {tag} {'removed' if remove else 'added'}: {pokemon_count(len(selected))}"))
    return [view[v] for v in selected], gone + (missed(left) if left else [])


def note_tag(rec, tag, remove):
    """After bulk tagging: updates the Pokémon's record to match the game now (memory for the next run)."""
    if rec is None:
        return
    rec["tags"] = [t for t in (rec.get("tags") or []) if t != tag] + ([] if remove else [tag])
    if tag in {n for _, n in cfg.IV_TAGS}:
        rec["have"] = [t for t in (rec.get("have") or []) if t != tag] + ([] if remove else [tag])
    if tag == cfg.TAG_NAME:
        rec["removable"] = not remove


def run_passes(bot, st, on_done):
    """Runs the remaining bulk taggings (st.passes); after each batch calls on_done(tag, remove, indexes).
    Tags in st.seq (with the search st.tag_base) or, when the duplicates step took its data from a fully
    read storage, in st.tag_full.seq through the index mapping st.tag_map. Pokémon the game can't find
    by CP are skipped and the run goes on."""
    full, fwd = getattr(st, "tag_full", None), getattr(st, "tag_map", None)
    back = {j: i for i, j in fwd.items()} if full is not None else None
    cell = (lambda i: full.seq[fwd[i]]) if full is not None else (lambda i: st.seq[i])
    while st.passes:
        tag, remove, idxs = st.passes[0]
        if full is not None:
            idxs = [i for i in idxs if i in fwd]
        if not idxs:
            st.passes.pop(0)
            continue
        try:
            if full is not None:
                done, gone = tag_batch(bot, full.seq, [fwd[i] for i in idxs], tag, remove)
                done, gone = [back[j] for j in done], [back[j] for j in gone]
            else:
                done, gone = tag_batch(bot, st.seq, idxs, tag, remove, getattr(st, "tag_base", None))
        except (Fatal, TagCreated, NeedTop):
            raise
        except StepError:
            st.pass_fails += 1
            if st.pass_fails >= 3:      # these Pokémon can't be selected – skip them so the run doesn't stall
                log(T(f"   ✖ tag {tag} se u {pokemon_count(len(idxs))} nepodařilo nastavit, vynechávám je",
                      f"   ✖ couldn't set tag {tag} for {pokemon_count(len(idxs))}, skipping them"))
                emit("problem", text=T(f"Tag {tag} se u {pokemon_count(len(idxs))} nepodařilo nastavit – "
                                       f"zkontroluj je ručně.",
                                       f"Couldn't set tag {tag} for {pokemon_count(len(idxs))} – check them yourself."))
                st.passes.pop(0)
                st.pass_fails = 0
                continue
            raise
        st.pass_fails = 0
        bot.progress += len(done)
        if tag in bot.tag_counts or not remove:
            bot.tag_counts[tag] = max(0, bot.tag_counts.get(tag, 0) + (-len(done) if remove else len(done)))
            emit_counts(bot, tag, -len(done) if remove else len(done))
        on_done(tag, remove, done)
        for i in done:
            note_tag(full.recs.get(fwd[i]) if full is not None else st.recs.get(i), tag, remove)
        if gone:
            cps = ", ".join(f"CP{cell(i)['cp']}" for i in gone)
            log(T(f"   ✖ tag {tag} vynechávám u {cps} – hledání podle CP je ve hře nenašlo (CP se nejspíš přečetlo špatně)",
                  f"   ✖ skipping tag {tag} for {cps} – the CP search didn't find them in the game (probably a misread CP)"))
            new = [i for i in gone if not cell(i).get("miss_noted")]
            for i in new:
                cell(i)["miss_noted"] = True
            if new:
                emit("problem", text=T(f"{pokemon_count(len(new))} se ve hře nepodařilo najít podle CP (nejspíš "
                                       f"špatně přečtené CP) – zkontroluj je ručně.",
                                       f"Couldn't find {pokemon_count(len(new))} in the game by CP (probably a misread "
                                       f"CP) – check them yourself."))
        skip = set(done) | set(gone)
        st.passes[0] = (tag, remove, [i for i in idxs if i not in skip])
