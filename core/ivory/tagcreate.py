"""Checking a tag in the picker, and creating it when the game doesn't have it yet:
Add New Tag -> type the name -> pick the color closest to the one from the settings -> confirm."""
import time

import cv2
import numpy as np

from . import config as cfg
from .errors import Fatal, StepError, TagCreated
from .output import color_word, emit, log, step, T
from .vision import alnum, changed_frac, crop_norm, find_text
from .pixels import find_swatches
from .read_box import keyboard_on, tag_list_on
from .read_dialog import tag_dialog_on
from .taglist import find_add_new_tag, LIST_REGION, scan_tag_list, set_row
from .ivtags import same_tag


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
