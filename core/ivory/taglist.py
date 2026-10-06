"""The in-game tag picker: finding a tag's row, scrolling the list, and checking or unchecking it."""
from . import config as cfg
from .errors import StepError
from .output import log, T
from .vision import find_text, img_diff, in_region
from .read_box import tag_list_on
from .screens import classify
from .detail import close_detail, open_detail_menu
from .ivtags import same_tag
from .pixels import row_checked


# --- Tag picker ---
# --- Tag picker ---
LIST_REGION = (0.0, 0.12, 1.0, 0.9)


def tag_row(tx, name=None):
    """The row with the given tag in the tag list."""
    name = name or cfg.TAG_NAME
    return next((x for x in tx if in_region(x, (0.0, 0.15, 1.0, 0.82)) and same_tag(x["text"], name)), None)


def scroll_tag_list(bot, fr, direction):
    """Scrolls the tag list (direction "dolů" = down, "nahoru" = up). Returns (new frame, whether the
    list really moved). Movement is judged from the image only once it settles: at the start/end of the
    list the rows just bounce and return to place (text read in the middle of the bounce would wrongly
    report a move)."""
    a, b = ((0.5, 0.72), (0.5, 0.42)) if direction == "dolů" else ((0.5, 0.42), (0.5, 0.72))
    before = fr.img
    t0 = bot.drag(a, b, T(f"seznam tagů {direction}", f"tag list {'down' if direction == 'dolů' else 'up'}"), ms=350, hold=0.25, fr=fr)
    fr = bot.settle(bot.frame(after=t0 + 0.3), region=LIST_REGION, timeout=1.2)
    return fr, img_diff(before, fr.img, LIST_REGION) > 3.0


def scan_tag_list(bot, fr, directions, name=None):
    """Scrolls through the tag list until it finds the tag. Returns (row or None, frame)."""
    for direction in directions:
        for _ in range(cfg.TAG_SCROLL_MAX):
            t = tag_row(fr.texts, name)
            if t:
                return t, fr
            fr, moved = scroll_tag_list(bot, fr, direction)
            if not moved:
                break
    return tag_row(fr.texts, name), fr


def find_add_new_tag(bot, fr):
    """Finds 'Add New Tag' in the list (usually at the end of the list)."""
    for direction in ("dolů", "nahoru"):
        for _ in range(cfg.TAG_SCROLL_MAX):
            a = find_text(fr.texts, [cfg.L["add_new_tag"]], region=LIST_REGION)
            if a:
                return a, fr
            fr, moved = scroll_tag_list(bot, fr, direction)
            if not moved:
                break
    return None, fr


def wait_checked(bot, fr, name, timeout=0.8):
    """Is the row of tag `name` checked in the tag picker? The game may draw the check mark only a moment
    after the picker opens, so it waits a moment for it. Returns (checked, frame)."""
    def on(f):
        t = tag_row(f.texts, name)
        return t is not None and row_checked(f.img, t)
    if on(fr):
        return True, fr
    return bot.wait_for(on, timeout, label=f"fajfka {name}")


def row_state(f, name):
    """State of the row of tag `name` in the tag picker: "on" (green check mark), "mixed" (multi-select,
    only some of the selected Pokémon have the tag – gray "Mixed" on the right), "off", or None (row
    not visible)."""
    t = tag_row(f.texts, name)
    if t is None:
        return None
    if row_checked(f.img, t):
        return "on"
    if find_text(f.texts, [cfg.L["mixed"]], exact=True, region=(0.55, t["cy"] - 0.03, 1.0, t["cy"] + 0.03)):
        return "mixed"
    return "off"


def set_row(bot, fr, name, checked):
    """Checks the row of tag `name` in the tag picker (checked=True) or unchecks it, and verifies it on
    the following frames. Doesn't tap a row that is already in the right state – a tap would toggle it
    (and so remove the tag being added from the Pokémon). A tap turns "Mixed" (only some of the selected
    have the tag) into unchecked; only the next tap gives it to all – so it keeps tapping until the row
    shows what it should. When the state can't be set, raises StepError: DONE is then not pressed and
    the picker closes without saving."""
    want = "on" if checked else "off"
    what = "tag" if checked else T("odebrat", "remove")
    taps, waited, noted = 0, False, False
    for _ in range(9):                       # at most 2 scrolls and 3 taps, then a final check
        fr = bot.settle(fr, region=LIST_REGION, timeout=0.8)
        t = tag_row(fr.texts, name)
        if t is None:
            raise StepError(T(f"ve výběru tagů nevidím {name}", f"can't see {name} in the tag picker"))
        s = row_state(fr, name)
        if s == want:
            if taps == 0 and checked:
                log(T(f"   tag {name} už je zaškrtnutý – neklepu na něj (odebral by se)",
                      f"   tag {name} is already checked – not tapping it (that would remove it)"))
            if taps >= 2:
                bot.dump("tagy")                # to check how the game toggles "Mixed"
            return fr
        if taps == 3:
            break
        if s == "mixed" and not noted:
            noted = True
            log(T(f"   tag {name}: má ho jen část vybraných (Mixed) – " + ("dám ho všem" if checked else "odeberu ho všem"),
                  f"   tag {name}: only some of the selected have it (Mixed) – " +
                  ("giving it to all" if checked else "removing it from all")))
        if checked and s == "off" and not waited:
            # the check mark may appear only a moment after the picker opens – a tap would remove the tag
            waited = True
            on, fr = wait_checked(bot, fr, name)
            if on:
                log(T(f"   tag {name} už je zaškrtnutý – neklepu na něj (odebral by se)",
                      f"   tag {name} is already checked – not tapping it (that would remove it)"))
                return fr
            continue
        if t["cy"] > 0.77:
            # the row is down in the fade above DONE, where the game ignores taps – scroll down so it moves up
            fr, moved = scroll_tag_list(bot, fr, "dolů")
            if moved:
                continue
        t0 = bot.tap(t["cx"], t["cy"], f"{what} {name}" + (T(" (znovu)", " (again)") if taps else ""), fr=fr)
        taps += 1
        # wait for the change (a tap turns "Mixed" into nothing, not a check mark) – the loop decides
        # on the next tap
        _, fr = bot.wait_for(lambda f: row_state(f, name) not in (s, None), 1.5, after=t0 + cfg.FRAME_LAG,
                             label=f"{what} {name}")
    raise StepError(T(f"tag {name} se ve výběru nedaří {'zaškrtnout' if checked else 'odškrtnout'} – nic neukládám",
                      f"can't {'check' if checked else 'uncheck'} tag {name} in the picker – saving nothing"))


def open_tag_list(bot, fr):
    """From the Pokémon's detail screen: ≡ -> TAG -> tag picker."""
    open_detail_menu(bot, fr)
    t, fr = bot.stable_text(["tag"], exact=True, region=(0.4, 0.3, 1.0, 0.92))
    if t is None:
        raise StepError(T("v menu chybí TAG", "TAG is missing in the menu"))
    _, fr = bot.act((t["cx"], t["cy"]), "TAG", lambda f: tag_list_on(f.texts), timeout=2.5, fr=fr, tries=1)
    return bot.settle(fr, region=LIST_REGION)


def leave_tag_list(bot, fr):
    """Closes the tag picker without saving (X) and goes back from the detail screen to the storage."""
    _, fr = bot.act(cfg.P_BOTTOM_X, T("zavřít výběr tagů (bez uložení)", "close the tag picker (without saving)"), lambda f: not tag_list_on(f.texts),
                    fr=fr, tries=1)
    fr = bot.settle(fr)
    if classify(fr) == "detail_menu":
        _, fr = bot.act(cfg.P_CORNER, T("zavřít menu", "close menu"), lambda f: classify(f) == "detail", fr=fr, tries=1, overlay=True)
    close_detail(bot, fr)


def collect_tag_names(bot, fr):
    """Scrolls through the whole tag picker from top to bottom and returns the texts of all rows."""
    for _ in range(cfg.TAG_SCROLL_MAX):
        fr, moved = scroll_tag_list(bot, fr, "nahoru")
        if not moved:
            break
    seen = []
    for _ in range(cfg.TAG_SCROLL_MAX + 1):
        seen += [x["text"] for x in fr.texts if in_region(x, LIST_REGION)]
        fr, moved = scroll_tag_list(bot, fr, "dolů")
        if not moved:
            break
    seen += [x["text"] for x in fr.texts if in_region(x, LIST_REGION)]
    return seen, fr
