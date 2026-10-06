"""Slow mode (fast mode off) for parts 1 and 2: finds duplicates screen by screen, measures them one
by one and tags the worse ones via multi-select; sorts each Pokémon into an IV tag through its detail
screen."""
from .errors import StepError, TagCreated
from .output import emit, log, step, T
from .grid import make_runs, names_ok
from .screens import classify
from .detail import measure
from .scroll import bring_to_top, read_grid, scroll_next
from .records import decide_group, Rec
from .classic_tags import categorize, tag_recs


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
    grid = None                           # the screen a scroll already settled on
    while True:
        cells, fr = grid or read_grid(bot)
        grid = None
        if classify(fr) != "box":
            raise StepError(T("nejsem v inventáři", "not in the storage"))
        book.assign(cells)
        view = tuple(c["cp"] for c in cells)
        runs = make_runs(cells)
        work = next((r for r in runs if needs_work(r)), None)
        if work is None:
            # scrolling led nowhere (still the same cells) = end of the list
            if report.limit_reached(book) or view == scrolled_from:
                return
            grid = scroll_next(bot, cells, fr=fr)
            if not grid:
                return                    # end of the list
            scrolled_from = view
            continue
        if work[-1] is cells[-1] and work[0] is not cells[0] and view != tried_top:
            # the group may go on below the edge -> scroll it to the top first (only once per position)
            tried_top = view
            grid = bring_to_top(bot, cells, work[0], fr=fr)
            if grid:
                continue
        if len(work) >= 2 and all(c["rec"] is None for c in work) and report.limit_reached(book):
            return
        handle_run(bot, book, mem, args, work, report)


def process_all(bot, book2, mem, args, report):
    """Part 2: goes through the whole storage (no search) and puts each Pokémon into an IV tag."""
    scrolled_from = None
    grid = None                           # the screen a scroll already settled on
    while True:
        cells, fr = grid or read_grid(bot)
        grid = None
        if classify(fr) != "box":
            raise StepError(T("nejsem v inventáři", "not in the storage"))
        book2.assign(cells)
        view = tuple(c["cp"] for c in cells)
        cell = next((c for c in cells if c["rec"] is None or c["rec"].status == "new"), None)
        if cell is None:
            if view == scrolled_from:
                return                    # scrolling led nowhere = end of the list
            grid = scroll_next(bot, cells, fr=fr)
            if not grid:
                return                    # end of the list
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
