"""Command-line entry: loads the settings, connects to the iPhone and runs the chosen steps."""
import argparse
import signal
import time

from . import config as cfg
from .errors import Fatal
from .output import emit, log, short_err, step, T
from .device import Bot, SAVER
from .phone import developer_mode_on, ios_too_old, list_devices, reveal_developer_mode
from .session import detect_udid, explain_connect_error, open_session
from .wda import ensure_wda
from .records import Book, Memory
from .report import Report
from .settings import load_config
from .phases import run


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


def _close_wda(wda):
    """Takes down the tunnel, the XCUITest runner and the port forwards. Left running they would
    hold the phone's testmanagerd and the next run would find the ports taken."""
    if wda is not None:
        wda.stop()


def main():
    stop_signals()
    ap = argparse.ArgumentParser()
    ap.add_argument("--max-groups", type=int, default=0, help="projít jen prvních N skupin duplicit")
    ap.add_argument("--fresh", action="store_true", help="IV z paměti nepoužívat, změřit znovu")
    ap.add_argument("--only-iv", action="store_true", help="jen 2. část: celý inventář do IV tagů")
    ap.add_argument("--no-iv", action="store_true", help="jen duplicity, bez 2. části")
    ap.add_argument("--steps", default="", help="kroky oddělené čárkou: duplicates,iv,pvp,rename,battle,weak")
    args = ap.parse_args()
    load_config()
    args.steps = parse_steps(args)
    if not args.max_groups:
        args.max_groups = cfg.MAX_GROUPS

    run_dir = cfg.OUT_DIR / time.strftime("%Y%m%d_%H%M%S")
    (run_dir / "iv").mkdir(parents=True, exist_ok=True)
    cfg.LOG_FILE = run_dir / "log.txt"
    names = {"duplicates": T("duplicity", "duplicates"), "iv": T("IV tagy", "IV tags"), "pvp": T("PvP tagy", "PvP tags"),
             "rename": T("přejmenování", "renaming"), "battle": T("Battle tagy", "Battle tags"),
             "weak": T("slabé kusy", "weak Pokémon")}
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
    wda = None
    try:
        devs = list_devices()
        udid = cfg.UDID or (devs[0][2] if devs else detect_udid())
        dev = next((d for d in devs if d[2] == udid), None)
        if dev:
            log(f"   iPhone: {dev[0]} (iOS {dev[1]})")
            emit("device", name=dev[0], ios=dev[1])
            if ios_too_old(dev[1]):
                raise Fatal(T(f"iPhone má iOS {dev[1]}, IVory potřebuje 17.4 nebo novější. "
                              f"Aktualizuj ho v Nastavení → Obecné → Aktualizace softwaru.",
                              f"The iPhone runs iOS {dev[1]}, IVory needs 17.4 or newer. "
                              f"Update it in Settings → General → Software Update."))
        if not developer_mode_on(udid):
            reveal_developer_mode(udid)          # makes the switch appear in Settings
            raise Fatal(T("Na iPhonu zapni Režim pro vývojáře: Nastavení → Soukromí a zabezpečení → "
                          "Režim pro vývojáře. Telefon se restartuje, pak spusť IVory znovu.",
                          "Turn on Developer Mode on the iPhone: Settings → Privacy & Security → "
                          "Developer Mode. The phone restarts; then start IVory again."), help="devmode")
        wda, wda_url = ensure_wda(udid, cfg.APPLE_ID, on_step=step)
        driver = open_session(udid, wda_url)
        bot = Bot(driver, run_dir)
        bot.wda = wda
    except Fatal as e:
        log(T(f"\nKONEC: {e}", f"\nEND: {e}"))
        emit("fatal", text=str(e), help=e.help)
        _close_wda(wda)
        return 1
    except KeyboardInterrupt:
        log(T("\nZastaveno ještě před připojením k iPhonu.", "\nStopped before connecting to the iPhone."))
        _close_wda(wda)
        return 130
    except Exception as e:
        msg = explain_connect_error(e)
        log(f"\n{msg}")
        log(T(f"   (technicky: {short_err(e)})", f"   (technical: {short_err(e)})"))
        emit("fatal", text=msg)
        _close_wda(wda)
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
            _close_wda(wda)
            SAVER.shutdown(wait=True)
    return rc
