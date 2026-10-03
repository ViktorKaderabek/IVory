"""The in-game tag picker: finding, creating, checking and unchecking tags; IV tag names and the tag
chips on the detail screen."""
import difflib
import time

import cv2
import numpy as np

from . import config as cfg
from .errors import Fatal, StepError, TagCreated
from .output import color_word, emit, log, step, T
from .vision import alnum, changed_frac, crop_norm, find_text, img_diff, in_region
from .screens import classify, find_swatches, keyboard_on, tag_dialog_on, tag_list_on
from .navigation import read_grid
from .detail import close_detail, open_detail, open_detail_menu


# --- Tag picker ---
LIST_REGION = (0.0, 0.12, 1.0, 0.9)


def same_tag(text, name):
    a, b = alnum(text), alnum(name)
    if not a or not b:
        return False
    if a == b or (a.endswith(b) and len(a) <= len(b) + 2):
        return True
    return len(b) >= 6 and difflib.SequenceMatcher(None, a, b).ratio() >= 0.88


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


def keyboard_top(tx):
    """Top edge of the keyboard (as a fraction of the height) when it is visible; otherwise 1.0."""
    keys = [x["y0"] for x in tx if x["cy"] > 0.55 and len(x["text"].strip()) == 1 and x["text"].strip().isalpha()]
    return min(keys) - 0.02 if len(keys) >= 6 else 1.0


def _lab(rgb):
    return cv2.cvtColor(np.uint8([[rgb]]), cv2.COLOR_RGB2LAB)[0, 0].astype(float)


def nearest_swatch(swatches, color):
    """The swatch for a color: swatches and colors are paired up (each color only once), so that e.g.
    orange isn't mistaken for yellow when both are visible."""
    ref = {n: _lab(rgb) for n, rgb in cfg.TAG_PALETTE.items()}
    labs = [_lab(sw["rgb"]) for sw in swatches]
    pairs = sorted((float(np.linalg.norm(a - ref[n])), i, n) for i, a in enumerate(labs) for n in ref)
    used_i, used_n, assign = set(), set(), {}
    for _, i, n in pairs:
        if i not in used_i and n not in used_n:
            assign[n] = i
            used_i.add(i)
            used_n.add(n)
    if color in assign:
        return swatches[assign[color]]
    return min(swatches, key=lambda sw: float(np.linalg.norm(_lab(sw["rgb"]) - ref[color])))


def pick_swatch(bot, fr, swatches, color):
    """Taps the color swatch and waits until the selection shows."""
    sw = nearest_swatch(swatches, color)
    H, W = fr.img.shape[:2]
    rx, ry = 2 * sw["r"], 2 * sw["r"] * W / H
    box = (sw["cx"] - rx, sw["cy"] - ry, sw["cx"] + rx, sw["cy"] + ry)
    before = crop_norm(fr.img, *box).copy()
    t0 = bot.tap(sw["cx"], sw["cy"], T(f"barva {cfg.COLOR_CZ.get(color, color)}", f"color {color}"), fr=fr)
    ok, fr = bot.wait_for(lambda f: changed_frac(before, crop_norm(f.img, *box)) > 0.01, 1.2,
                          after=t0 + cfg.FRAME_LAG, label="barva vybraná")
    log(T("   barva tagu: ", "   tag color: ") + color_word(color) +
        ("" if ok else T(" (vypadá, že už byla vybraná)", " (looks like it was already selected)")))
    return fr


def confirm_button(tx):
    """The button that confirms the new tag dialog (CREATE / SAVE / DONE / OK …). When several are
    visible (the tag picker's DONE is often under the dialog), takes the topmost one – that one belongs
    to the dialog."""
    words = {alnum(w) for w in cfg.L["confirm"]}
    hits = [t for t in tx if alnum(t["text"]) in words and len(t["text"].strip()) <= 12]
    return min(hits, key=lambda t: t["cy"]) if hits else None


def create_tag(bot, fr, name, color=None):
    """Creates a tag in the tag picker: Add New Tag -> name -> color -> confirm. Returns the tag picker
    frame. The steps follow whatever is on screen at the moment (name field, keyboard, color swatches),
    so it doesn't matter whether the game opens the keyboard by itself, or whether the colors are above
    or below the field."""
    color = color or cfg.tag_color(name)
    bot.tag_attempts[name] = bot.tag_attempts.get(name, 0) + 1
    cz = f" ({color_word(color)})" if color else ""
    log(T(f"   zakládám tag „{name}“{cz}", f"   creating tag “{name}”{cz}"))
    step(T(f"Zakládám tag „{name}“{cz}", f"Creating tag “{name}”{cz}"))
    a, fr = find_add_new_tag(bot, fr)
    if a is None:
        raise Fatal(T(f"Tag „{name}“ ve hře chybí a ve výběru tagů nevidím „{cfg.L['add_new_tag']}“ "
                      f"(nemáš už 100 tagů?). Založ ho ve hře ručně a spusť znovu.",
                      f"Tag “{name}” is missing in the game and the tag picker has no “{cfg.L['add_new_tag']}” "
                      f"(do you have 100 tags already?). Create it in the game yourself and run again."))
    _, fr = bot.act((a["cx"], a["cy"]), cfg.L["add_new_tag"],
                    lambda f: keyboard_on(f.texts) or tag_dialog_on(f), timeout=3, fr=fr)
    colored, typed = color is None, False
    for _ in range(12):
        tx = fr.texts
        kb = keyboard_on(tx)
        if not colored:
            sw = find_swatches(fr.img, (0.02, 0.10, 0.98, min(0.92, keyboard_top(tx)) if kb else 0.92))
            if sw:
                fr = pick_swatch(bot, fr, sw, color)
                colored = True
                continue
        if not typed:
            if not kb:
                e = find_text(tx, [cfg.L["enter_tag_name"]])
                if e is None:
                    raise StepError(T("v dialogu pro nový tag nevidím pole pro název", "the new tag dialog has no name field"))
                _, fr = bot.act((e["cx"], e["cy"]), T("pole pro název tagu", "tag name field"), lambda f: keyboard_on(f.texts),
                                timeout=2.5, fr=fr)
                continue
            bot.type_text(name)
            ok, fr = bot.wait_for(lambda f: any(same_tag(x["text"], name) for x in f.texts), 3, label="název napsaný")
            if not ok:
                raise StepError(T("název tagu se nepodařilo napsat", "couldn't type the tag name"))
            typed = True
            continue
        if kb:
            # hide the keyboard (Enter) so that the colors and the confirm button are visible
            t0 = time.time()
            bot.type_text("\n")
            _, fr = bot.wait_for(lambda f: not keyboard_on(f.texts), 2.5, after=t0 + cfg.FRAME_LAG, label="bez klávesnice")
            if keyboard_on(fr.texts):
                d = confirm_button(fr.texts)
                if d is None:
                    raise StepError(T("klávesnice v dialogu pro nový tag nejde zavřít", "can't close the keyboard in the new tag dialog"))
                t0 = bot.tap(d["cx"], d["cy"], T(f"klávesnice: {d['text']}", f"keyboard: {d['text']}"), fr=fr)
                fr = bot.frame(after=t0 + 0.4)
            continue
        if tag_list_on(tx) and not tag_dialog_on(fr):
            break                          # the dialog closed by itself (Enter confirmed it)
        if not colored:
            log(T("   (kolečka s barvami nevidím – tag dostane výchozí barvu hry)",
                  "   (can't see the color circles – the tag gets the game's default color)"))
            colored = None
        d = confirm_button(tx)
        if d is None:
            raise StepError(T("v dialogu pro nový tag nevidím tlačítko pro potvrzení", "the new tag dialog has no confirm button"))
        t0 = bot.tap(d["cx"], d["cy"], T(f"potvrdit nový tag ({d['text']})", f"confirm the new tag ({d['text']})"), fr=fr)
        ok, fr = bot.wait_for(lambda f: tag_list_on(f.texts) and not keyboard_on(f.texts) and not tag_dialog_on(f),
                              3, after=t0 + cfg.FRAME_LAG, label="tag založený")
        if ok:
            break
    else:
        raise StepError(T("dialog pro nový tag se nepodařilo dokončit", "couldn't finish the new tag dialog"))
    color_ok = bool(colored) and color is not None
    log(T(f"   ✔ tag „{name}“ založený", f"   ✔ tag “{name}” created") +
        (T(", barva ", ", color ") + color_word(color) if color_ok else
         T(" (barvu se nepodařilo vybrat – změň ji ve hře)", " (couldn't pick the color – change it in the game)")
         if color else ""))
    emit("tag_created", name=name, color=color, color_ok=color_ok)
    bot.created_tags.append(name)
    return bot.settle(fr, region=LIST_REGION)


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


def pick_tag(bot, fr, name=None):
    """Finds the tag in the tag picker and checks it. Scans the list in both directions – the picker
    need not be at the top. When the tag is missing in the game, creates it and raises TagCreated: the
    picker is then closed without saving and opened again, so the new tag gets checked like any other."""
    name = name or cfg.TAG_NAME
    t, fr = scan_tag_list(bot, fr, ["dolů", "nahoru"], name)
    if t is None:
        if name in bot.broken_tags or bot.tag_attempts.get(name, 0) >= 2:
            bot.broken_tags.add(name)
            if name == cfg.TAG_NAME:
                raise Fatal(T(f"Tag „{name}“ se nedaří založit. Založ ho ve hře ručně (inventář → Tagy → +) a spusť znovu.",
                              f"Can't create tag “{name}”. Create it in the game yourself (storage → Tags → +) and run again."))
            raise StepError(T(f"tag „{name}“ ve hře chybí a nedaří se ho založit",
                              f"tag “{name}” is missing in the game and can't be created"))
        create_tag(bot, fr, name)
        raise TagCreated(T(f"tag „{name}“ je založený, vybírám ho znovu", f"tag “{name}” is created, picking it again"))
    return set_row(bot, fr, name, True)    # leaves it alone if already checked – a tap would uncheck it


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


def wanted_tags(args):
    """The tags from the settings that this run needs."""
    names = ([cfg.TAG_NAME] if "duplicates" in args.steps else []) + \
        ([n for _, n in cfg.IV_TAGS] if "iv" in args.steps else []) + (cfg.league_tags() if "pvp" in args.steps else [])
    out = []
    for n in names:
        if all(alnum(n) != alnum(o) for o in out):
            out.append(n)
    return out


def check_tags(bot, args):
    """Preparation: checks in the game's tag picker that every tag from the settings exists, and creates the
    missing ones (in the color from the settings). Opens the first Pokémon in the storage for this; its tags
    are left unchanged (closed without saving)."""
    bot.tag_checks += 1
    wanted = [n for n in wanted_tags(args) if n not in bot.broken_tags]
    if not wanted:
        bot.tags_checked = True
        return
    cells, fr = read_grid(bot)
    step(T("Kontroluji tagy ve hře", "Checking the tags in the game"))
    log(T("\nKontroluji, že ve hře jsou všechny tagy z nastavení...", "\nChecking that every tag from the settings exists in the game..."))
    fr = open_detail(bot, cells[0])
    fr = open_tag_list(bot, fr)
    seen, fr = collect_tag_names(bot, fr)
    missing = [n for n in wanted if not any(same_tag(x, n) for x in seen)]
    for n in wanted:
        log(f"   {'✚' if n in missing else '✔'} {n}" + (T(" – ve hře chybí", " – missing in the game") if n in missing else ""))
    emit("tags", items=[{"name": n, "color": cfg.tag_color(n), "ok": n not in missing} for n in wanted])
    for n in missing:
        if bot.tag_attempts.get(n, 0) >= 2:
            bot.broken_tags.add(n)
            log(T(f"   ✖ tag „{n}“ se nepodařilo založit", f"   ✖ couldn't create tag “{n}”"))
            emit("problem", text=T(f"Tag „{n}“ se nepodařilo založit. Založ ho ve hře ručně (inventář → Tagy → +).",
                                   f"Couldn't create tag “{n}”. Create it in the game yourself (storage → Tags → +)."))
            if n == cfg.TAG_NAME:
                raise Fatal(T(f"Tag „{n}“ se nedaří založit. Založ ho ve hře ručně (inventář → Tagy → +) a spusť znovu.",
                              f"Can't create tag “{n}”. Create it in the game yourself (storage → Tags → +) and run again."))
            continue
        fr = create_tag(bot, fr, n)
    leave_tag_list(bot, fr)
    bot.tags_checked = True
    if not missing:
        log(T("   všechny tagy ve hře jsou", "   all tags exist in the game"))


# --- IV tags (part 2) ---
def iv_tag(iv):
    """Name of the IV tag for the IV percentage (sum / 45)."""
    total = sum(iv)
    for threshold, name in cfg.IV_TAGS:
        if total * 100 >= threshold * 45:
            return name
    return cfg.IV_TAGS[-1][1]


def detail_tags(tx):
    """All known tags (IV, TAG_NAME, PvP leagues, the tag renaming is limited to) that the Pokémon has
    on its detail screen."""
    region = (0.0, 0.44, 1.0, 0.68)
    known = [n for _, n in cfg.IV_TAGS] + [cfg.TAG_NAME] + [lg["name"] for lg in cfg.PVP.values()] + \
        ([cfg.RENAME["only_tag"]] if cfg.RENAME["only_tag"] else [])
    return [n for n in dict.fromkeys(known) if any(in_region(t, region) and same_tag(t["text"], n) for t in tx)]


def detail_chips(tx):
    """Tag chips under the name on the detail screen: (list of IV tags, whether it has TAG_NAME –
    "Removable" by default)."""
    region = (0.0, 0.44, 1.0, 0.68)
    have = []
    for _, name in cfg.IV_TAGS:
        if any(in_region(t, region) and same_tag(t["text"], name) for t in tx):
            have.append(name)
    removable = any(in_region(t, region) and same_tag(t["text"], cfg.TAG_NAME) for t in tx)
    return have, removable


def row_checked(img, t):
    """Is the row checked in the tag picker? The game draws a green check mark on the right of the row."""
    reg = crop_norm(img, 0.80, t["cy"] - 0.018, 0.98, t["cy"] + 0.018).astype(int)
    if reg.size == 0:
        return False
    r, g = reg[..., 0], reg[..., 1]
    return float(((g - r > 40) & (g > 120)).mean()) > 0.008
