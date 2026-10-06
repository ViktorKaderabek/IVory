"""Moving to the next Pokémon inside the appraisal (the ▶ arrow, otherwise a swipe), and telling from
the frame alone that the game really did move on."""
import difflib

from . import config as cfg
from .output import T
from .vision import alnum, norm
from .read_detail import HP_RE, bar_labels, detail_cp, detail_name
from .bars import read_bars


def detail_fp(fr):
    """Fingerprint of the Pokémon on the detail screen; it changes when moving to the next one."""
    tx = fr.texts
    hp = next((alnum(t["text"]) for t in tx if HP_RE.match(norm(t["text"]))), "")
    labels = bar_labels(tx)
    return detail_cp(tx), alnum(detail_name(tx)), hp, read_bars(fr.img, labels)[0] if labels else None


def quick_fp(fr):
    """Fingerprint of the Pokémon from the fast OCR (21 ms instead of 100): CP, name, HP and the bar
    values (bars from pixels)."""
    tx = fr.fast
    hp = next((alnum(t["text"]) for t in tx if HP_RE.match(norm(t["text"]))), "")
    labels = bar_labels(tx)
    return detail_cp(tx), alnum(detail_name(tx)), hp, (read_bars(fr.img, labels)[0] if labels else None)


def bars_at(fr, labels):
    """The bar values at label positions already known – pure pixel work (1.6 ms), without any OCR."""
    return read_bars(fr.img, labels)[0] if labels else None


def fp_change(a, b):
    """2 = certainly a different Pokémon (different name or bars), 1 = maybe (only CP or HP differ; the
    fast OCR may have misread them), 0 = the same. Whatever the fast OCR didn't read doesn't count."""
    if not (b[0] or b[1]):
        return 0
    if a[1] and b[1] and difflib.SequenceMatcher(None, a[1], b[1]).ratio() < 0.8:
        return 2
    if a[3] and b[3] and tuple(a[3]) != tuple(b[3]):
        return 2
    if (a[0] and b[0] and a[0] != b[0]) or (a[2] and b[2] and a[2] != b[2]):
        return 1
    return 0


def next_pokemon(bot, fr=None):
    """Moves to the next Pokémon in the appraisal: the ▶ arrow to the right of the bars, otherwise a
    left swipe across the Pokémon's image. Returns the frame with the new Pokémon, or None (end of
    the list / not possible). fr = frame of the current Pokémon. The change is noticed from the bars
    alone, read at the label positions of the current frame without any OCR; only when the bars came
    out the same does the fast OCR decide, and when just CP or HP differ, the accurate one."""
    fr = fr or bot.frame()
    labels = bar_labels(fr.fast)
    before = quick_fp(fr)

    def changed(f):
        # Different bars already mean another Pokémon (fp_change would say 2), and the bars are read
        # from the labels of the previous frame without OCR – so most frames cost no OCR at all.
        if labels and before[3]:
            now = bars_at(f, labels)
            if now is not None and tuple(now) != tuple(before[3]):
                return True
        c = fp_change(before, quick_fp(f))
        if c == 1:
            a, b = detail_fp(fr), detail_fp(f)
            return a[:3] != b[:3] and bool(b[0] or b[1])
        return c == 2
    # arrow only when the appraisal bars are visible – on the plain detail screen the EVOLVE row sits there
    for how in (("arrow", "swipe") if labels else ("swipe",)):
        if how == "arrow":
            t0 = bot.tap(0.975, labels[1]["cy"] + 0.01, T("další Pokémon (▶)", "next Pokémon (▶)"), fr=fr)
        else:
            t0 = bot.drag((0.80, 0.22), (0.20, 0.22), T("další Pokémon (swipe)", "next Pokémon (swipe)"), ms=260, hold=0, fr=fr)
        ok, f = bot.wait_for(changed, 2.5, after=t0 + cfg.NEXT_LAG, label="další Pokémon")
        if ok:
            return f
        fr = f
    return None
