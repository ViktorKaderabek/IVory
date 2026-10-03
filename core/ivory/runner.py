"""Command-line entry: loads the settings, connects to the iPhone and runs the chosen steps."""
import argparse
import json
import signal
import time

from . import config as cfg
from .errors import Danger, Fatal, LostPosition, NeedTop, NoNavigation, StepError, TagCreated
from .output import emit, log, short_err, step, T
from .vision import alnum
from .screens import classify
from .device import Bot, SAVER
from .session import (
    detect_udid, ensure_app, explain_connect_error, list_devices, open_session, reconnect, session_alive)
from .navigation import ensure_box, reopen_box
from .records import Book, Memory
from .report import Report
from .tags import check_tags, wanted_tags
from .classic import process, process_all
from .scan import FastState
from .batch import search_empty
from .inventory import ensure_scanned, remember_box
from .steps import fast_duplicates, fast_iv, fast_pvp, fast_rename


def load_config():
    """Overrides the defaults in config.py with ~/.pogo/config.json (written by the app)."""
    try:
        c = json.loads(cfg.CONFIG_FILE.read_text())
    except FileNotFoundError:
        return
    except Exception as e:
        log(T(f"Nastavení {cfg.CONFIG_FILE} nejde přečíst ({e}), beru výchozí hodnoty",
              f"Can't read the settings in {cfg.CONFIG_FILE} ({e}), using the defaults"))
        return
    cfg.LANG = "cs" if str(c.get("language") or "").strip().lower() == "cs" else "en"
    cfg.UDID = str(c.get("udid") or "").strip()
    cfg.TEAM_ID = str(c.get("team_id") or "").strip()
    cfg.SIGNING_ID = c.get("signing_id") or cfg.SIGNING_ID
    cfg.SEARCH_QUERY = " ".join(str(c.get("search_query") or "").split()) or cfg.SEARCH_QUERY
    cfg.TAG_NAME = str(c.get("remove_tag") or "").strip() or cfg.TAG_NAME
    cfg.TAG_COLOR = cfg.color_name(c.get("remove_tag_color"), cfg.TAG_COLOR)
    cfg.KEEP_N = max(1, int(c.get("keep_best", cfg.KEEP_N)))
    tags, seen = [], set()
    for t in c.get("iv_tags") or []:
        name = str(t.get("name", "")).strip()
        if not name or alnum(name) in seen:
            continue                      # no name, or a duplicate – not used
        seen.add(alnum(name))
        tags.append((min(100, max(0, int(t.get("min", 0)))), name, t.get("color")))
    if tags:
        tags.sort(key=lambda t: -t[0])
        cfg.IV_TAGS = [(m, n) for m, n, _ in tags]
        cfg.TAG_COLORS = {n: cfg.color_name(col, cfg.DEFAULT_IV_COLORS[min(i, len(cfg.DEFAULT_IV_COLORS) - 1)])
                      for i, (_, n, col) in enumerate(tags)}
    cfg.RECHECK_TAGGED = bool(c.get("recheck_tagged", cfg.RECHECK_TAGGED))
    cfg.FAST = bool(c.get("fast_mode", cfg.FAST))
    for key, lg in (c.get("pvp") or {}).items():
        if key in cfg.PVP and isinstance(lg, dict):
            cfg.PVP[key]["enabled"] = bool(lg.get("enabled", cfg.PVP[key]["enabled"]))
            cfg.PVP[key]["max_rank"] = max(1, min(4096, int(lg.get("max_rank", cfg.PVP[key]["max_rank"]))))
            cfg.PVP[key]["color"] = cfg.color_name(lg.get("color"), cfg.PVP[key]["color"])
            cfg.PVP[key]["name"] = str(lg.get("name") or cfg.PVP[key]["name"]).strip() or cfg.PVP[key]["name"]
    rn = c.get("rename") or {}
    cfg.RENAME["min"] = max(0, min(100, int(rn.get("min", cfg.RENAME["min"]))))
    cfg.RENAME["max"] = max(cfg.RENAME["min"], min(100, int(rn.get("max", cfg.RENAME["max"]))))
    if isinstance(rn.get("template"), list) and rn["template"]:
        cfg.RENAME["template"] = [t for t in rn["template"] if isinstance(t, dict) and t.get("k")]
    for k in ("overwrite_custom", "skip_removable"):
        if k in rn:
            cfg.RENAME[k] = bool(rn[k])
    cfg.RENAME["only_tag"] = str(rn.get("only_tag") or "").strip()
    cfg.MAX_GROUPS = int(c.get("max_groups", cfg.MAX_GROUPS))


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


PHASE_OF = {"duplicates": 1, "iv": 2, "pvp": 3, "rename": 4}
PHASE_TITLE = {1: ("1. část: hledám duplicity", "Part 1: finding duplicates"),
               2: ("2. část: třídím celý inventář do IV tagů", "Part 2: sorting the whole storage into IV tags"),
               3: ("3. část: PvP tagy podle pořadí IV v ligách", "Part 3: PvP tags by IV rank in the leagues"),
               4: ("4. část: přejmenování", "Part 4: renaming")}


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
            shared = phase == 1 and bot.fast and any(x in args.steps for x in ("iv", "pvp", "rename"))
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
            else:
                fast_rename(bot, mem, args, report, st2)
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


def parse_steps(args):
    """Steps from --steps (the app), or from the older --no-iv / --only-iv."""
    if args.steps:
        steps = {x.strip() for x in args.steps.split(",") if x.strip() in cfg.STEPS}
    else:
        steps = {"duplicates", "iv"}
        if args.no_iv or not cfg.SORT_ALL:
            steps.discard("iv")
        if args.only_iv:
            steps = {"iv"}
    return steps or {"iv"}


def stop_signals():
    """Stop in the app / Ctrl+C = KeyboardInterrupt (the bot finishes the step and saves the results). run.sh
    starts the bot in the background, and a non-interactive bash disables SIGINT for such a process – so turn
    it back on; SIGTERM (closing the app) behaves the same."""
    def stop(signum, frame):
        raise KeyboardInterrupt
    try:
        signal.signal(signal.SIGINT, signal.default_int_handler)
        signal.signal(signal.SIGTERM, stop)
    except ValueError:
        pass                                   # not in the main thread (tests)


def main():
    stop_signals()
    ap = argparse.ArgumentParser()
    ap.add_argument("--max-groups", type=int, default=0, help="projít jen prvních N skupin duplicit")
    ap.add_argument("--fresh", action="store_true", help="IV z paměti nepoužívat, změřit znovu")
    ap.add_argument("--only-iv", action="store_true", help="jen 2. část: celý inventář do IV tagů")
    ap.add_argument("--no-iv", action="store_true", help="jen duplicity, bez 2. části")
    ap.add_argument("--steps", default="", help="kroky oddělené čárkou: duplicates,iv,pvp,rename")
    args = ap.parse_args()
    load_config()
    args.steps = parse_steps(args)
    if not args.max_groups:
        args.max_groups = cfg.MAX_GROUPS

    run_dir = cfg.OUT_DIR / time.strftime("%Y%m%d_%H%M%S")
    (run_dir / "iv").mkdir(parents=True, exist_ok=True)
    cfg.LOG_FILE = run_dir / "log.txt"
    names = {"duplicates": T("duplicity", "duplicates"), "iv": T("IV tagy", "IV tags"), "pvp": T("PvP tagy", "PvP tags"),
             "rename": T("přejmenování", "renaming")}
    parts = [names[x] for x in cfg.STEPS if x in args.steps]
    log(T("Úkol: ", "Task: ") + " + ".join(parts))
    if "duplicates" in args.steps:
        log(T("Hledání ve hře: ", "Search in the game: ") + cfg.SEARCH_QUERY)
        log(T(f"Horší duplicity dostanou tag {cfg.TAG_NAME}", f"Worse duplicates get the {cfg.TAG_NAME} tag")
            + (T(f" (projdu max. {args.max_groups} skupin)", f" (checking at most {args.max_groups} groups)")
               if args.max_groups else ""))
    log(T("Výsledky a screenshoty: ", "Results and screenshots: ") + str(run_dir))
    emit("run", dir=str(run_dir), query=cfg.SEARCH_QUERY, tag=cfg.TAG_NAME, parts=parts)
    if cfg.LIVE:
        try:
            cfg.LIVE_FILE.unlink()
        except OSError:
            pass

    mem = Memory(cfg.MEMORY_FILE)
    book = Book()
    book2 = Book()
    report = Report(run_dir, args.max_groups)
    emit("phase", n=0)
    step(T("Připojuji se k iPhonu", "Connecting to the iPhone"))
    log(T("Připojuji se k iPhonu...", "Connecting to the iPhone..."))
    try:
        devs = list_devices()
        udid = cfg.UDID or (devs[0][2] if devs else detect_udid())
        dev = next((d for d in devs if d[2] == udid), None)
        if dev:
            log(f"   iPhone: {dev[0]} (iOS {dev[1]})")
            emit("device", name=dev[0], ios=dev[1])
        step(T("Spouštím ovládání iPhonu (WebDriverAgent) – napoprvé to trvá pár minut",
               "Starting iPhone control (WebDriverAgent) – the first time takes a few minutes"))
        driver = open_session(udid)
        bot = Bot(driver, run_dir)
    except Fatal as e:
        log(T(f"\nKONEC: {e}", f"\nEND: {e}"))
        emit("fatal", text=str(e))
        return 1
    except KeyboardInterrupt:
        log(T("\nZastaveno ještě před připojením k iPhonu.", "\nStopped before connecting to the iPhone."))
        return 130
    except Exception as e:
        msg = explain_connect_error(e)
        log(f"\n{msg}")
        log(T(f"   (technicky: {short_err(e)})", f"   (technical: {short_err(e)})"))
        emit("fatal", text=msg)
        return 1
    bot.udid = udid
    emit("connected")
    bot.wait_stream()
    rc = 0
    try:
        run(bot, book, book2, mem, args, report)
    except Fatal as e:
        log(T(f"\nKONEC: {e}", f"\nEND: {e}"))
        emit("fatal", text=str(e))
        rc = 1
    except KeyboardInterrupt:
        log(T("\nZastaveno (Stop / Ctrl+C), výsledky se ukládají.", "\nStopped (Stop / Ctrl+C), saving the results."))
        rc = 130
    except Exception as e:
        import traceback
        log(T(f"\nNečekaná chyba: {short_err(e)}", f"\nUnexpected error: {short_err(e)}"))
        log(traceback.format_exc())
        emit("fatal", text=T(f"Nečekaná chyba: {short_err(e)[:200]}", f"Unexpected error: {short_err(e)[:200]}"))
        rc = 1
    finally:
        try:
            report.save(book)
            report.save_iv(book2)
            dup = report.summary(book) if book.recs else None
            iv = report.summary_iv(book2) or None
            if bot.created_tags:
                log(T("Založené tagy: ", "Created tags: ") + ", ".join(bot.created_tags))
            if bot.broken_tags:
                log(T("Tyto tagy se nepodařilo založit (založ je ve hře ručně): ",
                      "Couldn't create these tags (create them in the game yourself): ") + ", ".join(sorted(bot.broken_tags)))
            emit("summary", dup=dup, iv=iv, created=bot.created_tags, broken=sorted(bot.broken_tags),
                 minutes=round((time.time() - report.t0) / 60, 1), dir=str(run_dir))
        finally:
            bot.stream.stop_ev.set()
            try:
                bot.d.quit()
            except Exception:
                pass
            SAVER.shutdown(wait=True)
    return rc
