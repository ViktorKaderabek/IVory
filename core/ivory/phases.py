"""One run, phase by phase: the storage is read once and then each chosen step tags, renames or sweeps
from what was read. A failed step is retried from the storage; the run only stops when too many
attempts in a row make no progress.
"""
from . import config as cfg
from .errors import Danger, Fatal, LostPosition, NeedTop, NoNavigation, StepError, TagCreated
from .output import emit, log, short_err, step, T
from .screens import classify
from .session import ensure_app, reconnect, session_alive
from .scroll import reopen_box
from .navigate import ensure_box
from .tagcheck import check_tags, wanted_tags
from .scanstate import FastState
from .batch import search_empty
from .memory_box import remember_box
from .inventory import ensure_scanned
from .classic import process, process_all
from .step_dupes import fast_duplicates
from .step_tags import fast_battle, fast_iv, fast_pvp, fast_weak
from .step_rename import fast_rename


def friendly_problem(e):
    """A short sentence for the app: what happened. The bot then goes back to the storage and continues."""
    if isinstance(e, Danger):
        return T("Klepnutí by bylo moc blízko tlačítka Transfer nebo Evolve – bot ho neudělal a vrací se do inventáře.",
                 "The tap would be too close to the Transfer or Evolve button – the bot skipped it and goes back to the storage.")
    if isinstance(e, LostPosition):
        return T("Při posouvání inventáře se ztratilo místo – bot ho projede znovu shora (změřené Pokémony si pamatuje).",
                 "Lost the place while scrolling the storage – the bot goes through it again from the top (it remembers "
                 "the measured Pokémon).")
    if isinstance(e, StepError):
        return T(f"Nečekaná situace ({e}) – bot se vrací do inventáře a pokračuje.",
                 f"Unexpected situation ({e}) – the bot goes back to the storage and continues.")
    return T(f"Výpadek spojení nebo hry ({short_err(e)[:120]}) – bot to zkusí znovu.",
             f"Connection or game hiccup ({short_err(e)[:120]}) – the bot tries again.")


PHASE_OF = {"duplicates": 1, "iv": 2, "pvp": 3, "rename": 4, "battle": 5, "weak": 6}
PHASE_TITLE = {1: ("1. část: hledám duplicity", "Part 1: finding duplicates"),
               2: ("2. část: třídím celý inventář do IV tagů", "Part 2: sorting the whole storage into IV tags"),
               3: ("3. část: PvP tagy podle pořadí IV v ligách", "Part 3: PvP tags by IV rank in the leagues"),
               4: ("4. část: přejmenování", "Part 4: renaming"),
               5: ("5. část: Battle tagy pro raidy a PvP týmy", "Part 5: Battle tags for raids and PvP teams"),
               6: ("6. část: slabé kusy do tagu na přenesení", "Part 6: weak Pokémon into the transfer tag")}


def phase_title(n):
    return T(*PHASE_TITLE[n])


def run(bot, book, book2, mem, args, report):
    """The whole run. At the end (even after Stop or an error) it remembers what it knows about the
    storage – the next run then reads only new Pokémon."""
    bot.no_cache = bool(getattr(args, "fresh", False))     # "Measure IV again" in the app
    st2 = FastState()
    try:
        run_phases(bot, book, book2, mem, args, report, st2)
    finally:
        if st2.seq is not None and st2.recs:      # even after Stop: whatever got read isn't read next time
            try:
                remember_box(st2, mem, whole=True, complete=st2.scanned and not st2.cache_hits)
            except Exception as e:
                log(T(f"   (paměť se nepodařilo uložit: {e})", f"   (couldn't save the memory: {e})"))


def run_phases(bot, book, book2, mem, args, report, st2):
    fails, last_progress = 0, -1
    need_top, cleanup = True, False
    phases = [PHASE_OF[x] for x in cfg.STEPS if x in args.steps]
    phase = phases[0]
    announced = 0
    st1 = FastState()                        # pass in progress (survives an error)

    def next_phase():
        later = [p for p in phases if p > phase]
        return later[0] if later else None

    while True:
        try:
            if phase != announced:
                announced = phase
                emit("phase", n=phase)
                if phase > 1:
                    log(f"\n========== {phase_title(phase)} ==========")
                step(phase_title(phase))
            ensure_app(bot)
            # Duplicates + another step: the whole storage is read once and the duplicates take their IV from it
            shared = phase == 1 and bot.fast and any(x in args.steps for x in ("iv", "pvp", "rename", "battle", "weak"))
            full_first = shared and not st2.scanned
            bot.mode = "all" if phase != 1 or full_first else "duplicit"
            fr = ensure_box(bot)
            if phase == 1 and bot.mode == "duplicit" and classify(fr) == "box_other" and search_empty(bot):
                log(T(f"\nHledání „{cfg.SEARCH_QUERY}“ nenašlo žádné Pokémony – duplicity nejsou.",
                      f"\nThe search “{cfg.SEARCH_QUERY}” found no Pokémon – there are no duplicates."))
                emit("info", text=T(f"Hledání „{cfg.SEARCH_QUERY}“ nenašlo žádné Pokémony, takže duplicity nejsou.",
                                    f"The search “{cfg.SEARCH_QUERY}” found no Pokémon, so there are no duplicates."))
                phase, need_top = next_phase(), True
                if phase is None:
                    return
                continue
            if not bot.tags_checked:
                if bot.tag_checks >= 3:
                    bot.tags_checked = True
                    log(T("   Kontrolu tagů se nepodařilo dokončit – chybějící tagy založím, až budou potřeba.",
                          "   Couldn't finish checking the tags – missing tags get created when they're needed."))
                    emit("problem", text=T("Kontrolu tagů se nepodařilo dokončit. Chybějící tagy bot založí, "
                                           "až je bude potřebovat.",
                                           "Couldn't finish checking the tags. The bot creates missing tags when it needs them."))
                elif wanted_tags(args):
                    check_tags(bot, args)
                    continue            # back to the storage, and only then the work
                else:
                    bot.tags_checked = True
            if phase == 1:
                if bot.fast and full_first:
                    if not getattr(st2, "announced", False):
                        log(T("\nČtu celý inventář jednou – IV a tagy použiju pro duplicity i další kroky.",
                              "\nReading the whole storage once – the IVs and tags serve the duplicates and the other steps."))
                        st2.announced = True
                    ensure_scanned(bot, st2, mem)
                    continue
                if bot.fast:
                    fast_duplicates(bot, book, mem, args, report, st1, st2 if shared else None)
                else:
                    if need_top:
                        if not bot.fresh_list:
                            reopen_box(bot)
                            continue
                        need_top = False
                    bot.fresh_list = False
                    process(bot, book, mem, args, report)
                    if book.outstanding() and not cleanup:
                        cleanup, need_top = True, True
                        log(T("\nDoznačuji Pokémony, kteří mezitím odjeli z obrazovky...",
                              "\nTagging the Pokémon that scrolled off the screen meanwhile..."))
                        step(T("Doznačuji Pokémony, kteří mezitím odjeli z obrazovky",
                               "Tagging the Pokémon that scrolled off the screen meanwhile"))
                        continue
                if report.limit_reached(book):
                    return
            elif phase == 2:
                if bot.fast:
                    fast_iv(bot, book2, mem, args, report, st2)
                else:
                    if need_top:
                        if not bot.fresh_list:
                            reopen_box(bot)
                            continue
                        need_top = False
                    bot.fresh_list = False
                    process_all(bot, book2, mem, args, report)
            elif phase == 3:
                fast_pvp(bot, mem, args, report, st2)
            elif phase == 4:
                fast_rename(bot, mem, args, report, st2)
            elif phase == 5:
                fast_battle(bot, mem, args, report, st2)
            else:
                fast_weak(bot, mem, args, report, st2)
            phase, need_top = next_phase(), True
            if phase is None:
                return
            continue
        except (Fatal, KeyboardInterrupt):
            raise
        except TagCreated as e:
            log(f"   ({e})")         # not an error: the tag picker closes without saving and the step runs again
            continue
        except NeedTop:
            continue                 # the storage closed and ensure_box reopens it from the top
        except NoNavigation as e:
            log(T(f"\n   Rychlý režim nejde ({e}) – pokračuji pomalým (každý Pokémon zvlášť).",
                  f"\n   Fast mode doesn't work ({e}) – continuing in slow mode (each Pokémon separately)."))
            emit("problem", text=T("V appraisalu nejde přejít na dalšího Pokémona, takže bot pokračuje pomaleji: "
                                   "každého Pokémona otevře zvlášť.",
                                   "The appraisal can't move to the next Pokémon, so the bot continues more slowly: "
                                   "it opens each Pokémon separately."))
            bot.fast, need_top = False, True
            continue
        except Exception as e:
            progress = book.progress + book2.progress + bot.progress
            if progress != last_progress:
                fails, last_progress = 0, progress
            fails += 1
            d = bot.dump("chyba")
            log(f"\n!! {short_err(e)}")
            log(T(f"   (posledních pár snímků: {d})", f"   (last few screenshots: {d})"))
            emit("problem", text=friendly_problem(e))
            if fails > cfg.MAX_FAILS:
                raise Fatal(T(f"{cfg.MAX_FAILS}× po sobě se nepodařilo pokročit, končím. Snímky obrazovky jsou ve "
                              f"složce s výsledky (chyba_XX).",
                              f"No progress {cfg.MAX_FAILS}× in a row, stopping. Screenshots are in the results folder "
                              f"(chyba_XX)."))
            if not session_alive(bot.d):
                reconnect(bot)
            if isinstance(e, LostPosition):
                need_top = True
            log(T("   Vracím se do inventáře a pokračuji...", "   Going back to the storage and continuing..."))
