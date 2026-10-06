"""Setup before a run: the tags the chosen steps need have to exist in the game, so the bot reads the
tag picker once and creates whatever is missing, in its color from the settings."""
from . import config as cfg
from .errors import Fatal
from .output import emit, log, step, T
from .vision import alnum
from .detail import open_detail
from .scroll import read_grid
from .taglist import collect_tag_names, leave_tag_list, open_tag_list
from .ivtags import same_tag
from .tagcreate import create_tag


def wanted_tags(args):
    """The tags from the settings that this run needs."""
    names = ([cfg.TAG_NAME] if "duplicates" in args.steps else []) + \
        ([n for _, n in cfg.IV_TAGS] if "iv" in args.steps else []) + (cfg.league_tags() if "pvp" in args.steps else []) + \
        (cfg.battle_tags() if "battle" in args.steps else []) + \
        ([cfg.TAG_NAME] if "weak" in args.steps else [])
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
