"""The renaming step: a name built from the template for every Pokémon in the IV range. The name is
typed into the game's Set Nickname dialog, which is the one place the bot types into – so it checks who
is open before every rename, and a name the game refuses is remembered and never tried again."""
import time

import pokecalc

from . import config as cfg
from .errors import Fatal, LostPosition, NameRefused, NeedTop, NotInSearch, StepError
from .output import emit, log, pct_text, pokemon_count, step, T
from .vision import alnum, find_text
from .read_box import keyboard_on
from .read_detail import detail_cp, detail_hp, detail_name
from .read_dialog import name_refused, nickname_dialog
from .navigate import ensure_box
from .detail import cancel_nickname, close_detail
from .tagcreate import confirm_button
from .batch import empty_search, mark_missing, search_view, show_search
from .memory_box import same_name
from .inventory import ensure_scanned, open_in_view
from .monrec import identify_all, rename_values, species_of


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
