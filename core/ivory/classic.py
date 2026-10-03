"""Slow mode (fast mode off) for parts 1 and 2: finds duplicates screen by screen, measures them one
by one and tags the worse ones via multi-select; sorts each Pokémon into an IV tag through its detail
screen."""
from . import config as cfg
from .errors import StepError, TagCreated
from .output import emit, log, pokemon_count, step, T
from .vision import find_text, in_region
from .grid import make_runs, names_ok
from .screens import classify, detail_types, tag_button, tag_count, tag_list_on
from .navigation import bring_to_top, read_grid, scroll_next
from .records import decide_group, Rec
from .detail import appraise, close_detail, measure, open_detail
from .tags import (
    detail_chips, iv_tag, open_tag_list, pick_tag, row_checked, same_tag, scroll_tag_list, set_row,
    wait_checked)


def set_iv_tag(bot, fr, target, wrong=()):
    """On the detail screen, sets the IV tags via ≡ -> TAG: target checked, every other IV tag unchecked.
    It tells what is checked by the green check mark in the picker, so it also removes a wrong IV tag that
    wasn't visible on the detail screen. Doesn't tap an already checked target – a tap would uncheck it.
    Returns (detail screen frame, list of removed tags)."""
    fr = open_tag_list(bot, fr)
    ivnames = [n for _, n in cfg.IV_TAGS]
    removed, has_target = [], False
    pending = {w for w in wrong if w != target}       # wrong tags the detail screen showed
    for _ in range(cfg.TAG_SCROLL_MAX + 1):
        for t in [x for x in fr.texts if in_region(x, (0.0, 0.15, 1.0, 0.82))]:
            name = next((n for n in ivnames if same_tag(t["text"], n)), None)
            if name is None or name in removed or (name == target and has_target):
                continue
            if name == target:
                fr = set_row(bot, fr, name, True)
                has_target = True
            else:
                on = row_checked(fr.img, t)
                if not on and name in pending:       # the detail screen showed it – the check mark may come later
                    on, fr = wait_checked(bot, fr, name)
                if on:
                    fr = set_row(bot, fr, name, False)
                    removed.append(name)
            pending.discard(name)
        if has_target and not pending:
            break                                    # nothing more to change
        fr, moved = scroll_tag_list(bot, fr, "dolů")
        if not moved:
            break
    if not has_target:
        fr = pick_tag(bot, fr, target)      # tag wasn't visible: finds it (also further up) or creates it
    d = find_text(fr.texts, [cfg.L["done"]], exact=True, region=(0.0, 0.7, 1.0, 0.95))
    if d is None:
        raise StepError(T("nevidím DONE", "can't see DONE"))
    _, fr = bot.act((d["cx"], d["cy"]), "DONE", lambda f: classify(f) in ("detail", "detail_menu"),
                    timeout=3, fr=fr, tries=1)
    if classify(fr) == "detail_menu":
        _, fr = bot.act(cfg.P_CORNER, T("zavřít menu", "close menu"), lambda f: classify(f) == "detail", fr=fr, tries=1, overlay=True)
    def saved(f):
        h = detail_chips(f.texts)[0]
        return target in h and not any(n in h for n in ivnames if n != target)
    ok, fr = bot.wait_for(saved, 3.0, label="štítky v detailu")   # the chip appears only a moment after DONE
    if not ok:
        raise StepError(T(f"tag se neuložil (štítky v detailu: {detail_chips(fr.texts)[0]})",
                          f"the tag didn't save (chips in the detail: {detail_chips(fr.texts)[0]})"))
    return fr, sorted(set(removed) | {w for w in wrong if w != target})


def categorize(bot, mem, cell, rec, args):
    """Puts one Pokémon into the right IV tag (via the detail screen). Removes IV tags that don't
    match its IV."""
    step(T(f"Třídím do IV tagů: {cell['name'] or 'Pokémon'} (CP {cell['cp']})",
           f"Sorting into IV tags: {cell['name'] or 'Pokémon'} (CP {cell['cp']})"))
    fr = open_detail(bot, cell)
    have, removable = detail_chips(fr.texts)
    if removable:
        rec.status, rec.note = "skip", T(f"má tag {cfg.TAG_NAME} – přeskakuji", f"has the {cfg.TAG_NAME} tag – skipping")
        close_detail(bot, fr)
        return
    cached = None if args.fresh else mem.get_iv(rec.sig)
    if len(have) == 1 and not cfg.RECHECK_TAGGED and not (cached and iv_tag(cached[0]) != have[0]):
        # already tagged and "Skip already tagged" is on (fixed when the IVs in memory say the tag is wrong)
        rec.status, rec.note, rec.target, rec.had = "skip", T(f"už má {have[0]}", f"already has {have[0]}"), have[0], True
        close_detail(bot, fr)
        return
    if cached:
        rec.iv, rec.cached = cached[0], True
    else:
        iv, fr = appraise(bot, fr, cell["cp"])
        if iv is None:
            close_detail(bot, fr)
            raise StepError(T(f"CP{cell['cp']}: IV se nepodařilo přečíst", f"CP{cell['cp']}: couldn't read the IV"))
        rec.iv = iv
        mem.set_iv(rec.sig, iv, detail_types(fr.texts))
    target = iv_tag(rec.iv)
    rec.target = target
    wrong = [n for n in have if n != target]
    if target in have and not wrong:
        rec.status, rec.note, rec.had = "done", T(f"{target} (už měl)", f"{target} (already had it)"), True
    else:
        fr, removed = set_iv_tag(bot, fr, target, wrong)
        rec.status, rec.had, rec.removed = "done", target in have, removed
        rec.note = target + (T(f" (odebráno: {', '.join(removed)})", f" (removed: {', '.join(removed)})") if removed else "")
    close_detail(bot, fr)


def tag_selected(bot, mem, sel, fr):
    c0 = sel[0][0]
    t0 = bot.long_press(c0["cx"], c0["cy"] + cfg.CELL_TAP_DY, T(f"podržet CP{c0['cp']}", f"hold CP{c0['cp']}"), fr=fr)
    n, fr = bot.wait_for(lambda f: tag_count(f.texts), 2.5, after=t0 + cfg.FRAME_LAG, label="multiselect")
    if n != 1:
        raise StepError(T(f"multiselect se nespustil (TAG {n})", f"multi-select didn't start (TAG {n})"))
    for c, _ in sel[1:]:
        want = n + 1
        for _ in range(2):
            t0 = bot.tap(c["cx"], c["cy"] + cfg.SELECT_TAP_DY, T(f"vybrat CP{c['cp']}", f"select CP{c['cp']}"), fr=fr)
            _, fr = bot.wait_for(lambda f: (tag_count(f.texts) or 0) >= want, 2.0,
                                 after=t0 + cfg.FRAME_LAG, label="výběr")
            cnt = tag_count(fr.texts)
            if cnt == want:
                break
            if cnt is None or cnt > want:
                raise StepError(T(f"výběr nesedí (TAG {cnt}, čekal jsem {want})", f"the selection is off (TAG {cnt}, expected {want})"))
        else:
            raise StepError(T(f"CP{c['cp']} se nepodařilo vybrat", f"couldn't select CP{c['cp']}"))
        n = want
    tb = tag_button(fr.texts)
    if tb is None:
        raise StepError(T("nevidím tlačítko TAG", "can't see the TAG button"))
    _, fr = bot.act((tb["cx"], tb["cy"]), f"TAG ({n})", lambda f: tag_list_on(f.texts),
                    timeout=2.5, fr=fr, tries=1)
    fr = pick_tag(bot, fr)
    d = find_text(fr.texts, [cfg.L["done"]], exact=True, region=(0.0, 0.7, 1.0, 0.95))
    if d is None:
        raise StepError(T("nevidím DONE", "can't see DONE"))
    bot.act((d["cx"], d["cy"]), "DONE", lambda f: classify(f) == "box", timeout=3, fr=fr, tries=1)
    for _, r in sel:
        r.tagged = True
        mem.set_tagged(r.cp, r.name)
    log(T(f"   ✔ tag {cfg.TAG_NAME} přidán: {pokemon_count(n)}", f"   ✔ tag {cfg.TAG_NAME} added: {pokemon_count(n)}"))
    emit("tagged", tag=cfg.TAG_NAME, color=cfg.TAG_COLOR, items=[{"cp": r.cp, "name": r.name} for _, r in sel])


def tag_recs(bot, book, mem, recs):
    cells, fr = read_grid(bot)
    book.assign(cells)
    sel = []
    for r in recs:
        hits = [c for c in cells if c["rec"] is r]
        if len(hits) == 1:
            sel.append((hits[0], r))
        else:
            r.tag_fails += 1   # can't see it unambiguously in the grid right now
    if not sel:
        return
    log(T(f"   označuji tagem {cfg.TAG_NAME}: ", f"   tagging with {cfg.TAG_NAME}: ") + ", ".join(f"CP{r.cp}" for _, r in sel))
    step(T(f"Označuji tagem {cfg.TAG_NAME}: {pokemon_count(len(sel))}", f"Tagging with {cfg.TAG_NAME}: {pokemon_count(len(sel))}"))
    try:
        tag_selected(bot, mem, sel, fr)
    except TagCreated:
        raise                          # the tag was just created – it will be retried, not an error
    except StepError:
        for _, r in sel:
            r.tag_fails += 1
        raise


# --- Main loop ---
def needs_work(run):
    for c in run:
        r = c["rec"]
        if r is None or r.status == "new":
            return True
        if r.action == "remove" and not r.tagged and not r.ambiguous and r.tag_fails < 2:
            return True
    return False


def handle_run(bot, book, mem, args, run, report):
    gids = sorted({c["rec"].gid for c in run if c["rec"] is not None})
    gid = gids[0] if gids else book.new_gid()
    for g in gids[1:]:
        for r in book.group(g):
            r.gid = gid
    for c in run:
        if c["rec"] is None:
            c["rec"] = Rec(c, gid)
            book.recs.append(c["rec"])
        c["rec"].gid = gid
    group = book.group(gid)
    if len(group) < 2:
        for r in group:
            r.status = "single"
        return
    for r in group:   # same CP and name -> can't be told apart reliably, not tagged
        r.ambiguous = sum(1 for o in group if o.cp == r.cp and names_ok(o.name, r.name)) > 1
        if r.status == "single":
            r.status = "new"
    report.show(book, gid, quiet=True)

    for c in run:
        r = c["rec"]
        if r.status != "new":
            continue
        cached = None if (r.ambiguous or args.fresh) else mem.get_iv(r.sig)
        if cached:
            r.iv, r.types = cached
            r.cached, r.status = True, "done"
            book.progress += 1
            continue
        log(T(f"\n   měřím CP{r.cp} {r.name}", f"\n   measuring CP{r.cp} {r.name}"))
        step(T("Měřím IV: ", "Measuring IV: ") + f"{r.name or 'Pokémon'} (CP {r.cp})")
        emit("measuring", group=gid, cp=r.cp, name=r.name)
        try:
            iv, types = measure(bot, c)
        except StepError:
            r.fails += 1
            if r.fails >= 2:
                r.status = "failed"
                log(f"   CP{r.cp}: " + T("nejde změřit, přeskakuji ho", "can't measure it, skipping"))
            raise
        r.types = types or r.types
        if iv is None:
            r.fails += 1
            log(f"   CP{r.cp}: " + T("IV se nepodařilo přečíst", "couldn't read the IV") +
                (T(", přeskakuji", ", skipping") if r.fails >= 2 else T(", zkusím znovu", ", retrying")))
            if r.fails >= 2:
                r.status = "failed"
            continue
        r.iv, r.status = iv, "done"
        book.progress += 1
        report.measured += 1
        log(f"   CP{r.cp}: IV {'/'.join(map(str, iv))}")
        if not r.ambiguous:
            mem.set_iv(r.sig, iv, r.types)
        report.show(book, gid, quiet=True)

    if decide_group(group):
        log(T("   pozor: ve skupině jsou různé formy (jiné typy) – každou posuzuji zvlášť",
                  "   note: the group has different forms (other types) – judging each one separately"))
    todo = []
    for c in run:
        r = c["rec"]
        if r.action == "remove" and not r.tagged and not r.ambiguous and r.tag_fails < 2:
            if mem.is_tagged(r.cp, r.name):
                r.tagged = True   # already has the tag from before (tagging again would untag it)
            else:
                todo.append(r)
    report.show(book, gid)
    if todo:
        tag_recs(bot, book, mem, todo)
        book.progress += 1
        report.show(book, gid)


def process(bot, book, mem, args, report):
    """Goes through the storage from the current position down to the end."""
    scrolled_from = tried_top = None
    while True:
        cells, fr = read_grid(bot)
        if classify(fr) != "box":
            raise StepError(T("nejsem v inventáři", "not in the storage"))
        book.assign(cells)
        view = tuple(c["cp"] for c in cells)
        runs = make_runs(cells)
        work = next((r for r in runs if needs_work(r)), None)
        if work is None:
            # scrolling led nowhere (still the same cells) = end of the list
            if report.limit_reached(book) or view == scrolled_from or not scroll_next(bot, cells):
                return
            scrolled_from = view
            continue
        if work[-1] is cells[-1] and work[0] is not cells[0] and view != tried_top:
            # the group may go on below the edge -> scroll it to the top first (only once per position)
            tried_top = view
            if bring_to_top(bot, cells, work[0]):
                continue
        if len(work) >= 2 and all(c["rec"] is None for c in work) and report.limit_reached(book):
            return
        handle_run(bot, book, mem, args, work, report)


def process_all(bot, book2, mem, args, report):
    """Part 2: goes through the whole storage (no search) and puts each Pokémon into an IV tag."""
    scrolled_from = None
    while True:
        cells, fr = read_grid(bot)
        if classify(fr) != "box":
            raise StepError(T("nejsem v inventáři", "not in the storage"))
        book2.assign(cells)
        view = tuple(c["cp"] for c in cells)
        cell = next((c for c in cells if c["rec"] is None or c["rec"].status == "new"), None)
        if cell is None:
            if view == scrolled_from or not scroll_next(bot, cells):
                return                    # scrolling led nowhere = end of the list
            scrolled_from = view
            continue
        if cell["rec"] is None:
            cell["rec"] = Rec(cell, 0)
            book2.recs.append(cell["rec"])
        r = cell["rec"]
        try:
            categorize(bot, mem, cell, r, args)
        except TagCreated:
            raise
        except StepError:
            r.fails += 1
            if r.fails >= 2:
                r.status, r.note = "failed", T("nepovedlo se, přeskakuji", "failed, skipping")
                report.show_iv(r)
            raise
        book2.progress += 1
        report.show_iv(r)
