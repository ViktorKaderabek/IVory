"""Slow mode, the tagging part: the tag picker opened on one Pokémon at a time (part 2), and the
transfer tag put on the worse duplicates through multi-select (part 1)."""
from . import config as cfg
from .errors import StepError, TagCreated
from .output import emit, log, pokemon_count, step, T
from .vision import find_text, in_region
from .read_detail import detail_types
from .read_box import tag_button, tag_count, tag_list_on
from .screens import classify
from .detail import appraise, close_detail, open_detail
from .scroll import read_grid
from .ivtags import detail_chips, iv_tag
from .pixels import row_checked
from .taglist import open_tag_list, scroll_tag_list, set_row, wait_checked
from .tagcreate import pick_tag
from .ivtags import same_tag


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
