"""Connecting to the iPhone through Appium / WebDriverAgent and keeping the game running.

WebDriverAgent is started by wda.py (no Xcode) and Appium is handed the finished URL, so it never
builds or signs anything itself.
"""
import time

from . import config as cfg
from .errors import Fatal, NotAuthorized, StepError
from .output import emit, log, short_err, step, T
from .phone import list_devices
from .wda import explain_wda_error
from .read_box import safe_button
from .read_box import BOX_STATES
from .screens import classify


def detect_udid():
    """UDID of the first connected iPhone."""
    devs = list_devices()
    if not devs:
        raise Fatal(T("Nevidím připojený iPhone. Připoj ho kabelem, odemkni a potvrď „Důvěřovat tomuto počítači“.",
                      "No iPhone connected. Connect it with a cable, unlock it and tap “Trust This Computer”."),
                    help="pair")
    return devs[0][2]


def not_authorized(e):
    """Did the iPhone refuse to be driven? ("Not authorized for performing UI testing actions",
    XCTDaemonErrorDomain code 41)."""
    low = str(e).lower()
    return "not authorized" in low or "xctdaemonerrordomain code=41" in low


def connect(udid, wda_url):
    from appium import webdriver
    from appium.options.ios import XCUITestOptions

    o = XCUITestOptions()
    o.platform_name = "iOS"
    o.udid = udid
    o.bundle_id = cfg.BUNDLE_ID
    o.automation_name = "XCUITest"
    o.no_reset = True
    o.new_command_timeout = 600
    # The one capability that keeps Xcode out of the run: with a WebDriverAgent already running,
    # Appium attaches to it instead of reaching for xcodebuild to build and sign its own.
    o.set_capability("webDriverAgentUrl", wda_url)
    o.set_capability("skipLogCapture", True)       # log capture would want the system device tooling
    o.set_capability("waitForIdleTimeout", 0)
    try:
        driver = webdriver.Remote(cfg.APPIUM_URL, options=o)
    except Exception as e:
        if not_authorized(e):
            raise NotAuthorized(short_err(e))
        raise
    settings = {"waitForIdleTimeout": 0, "animationCoolOffTimeout": 0,
                "mjpegServerScreenshotQuality": cfg.MJPEG_QUALITY, "mjpegServerFramerate": cfg.MJPEG_FPS,
                "mjpegScalingFactor": cfg.MJPEG_SCALE}
    for k, v in settings.items():
        try:
            driver.update_settings({k: v})
        except Exception as e:
            log(T(f"   (nastavení {k} se nepovedlo: {short_err(e)})", f"   (setting {k} failed: {short_err(e)})"))
    try:
        driver.get_window_size()       # is the bot really allowed to control the iPhone?
    except Exception as e:
        if not_authorized(e):
            try:
                driver.quit()
            except Exception:
                pass
            raise NotAuthorized(short_err(e))
        raise
    return driver


def open_session(udid, wda_url):
    """Connects to the WebDriverAgent wda.py started."""
    try:
        return connect(udid, wda_url)
    except NotAuthorized:
        raise Fatal(T("iPhone nepovolil ovládání. Odemkni ho a na iPhonu zapni Nastavení → Vývojář → "
                      "„Enable UI Automation“ (automatizace UI). Pak spusť znovu.",
                      "The iPhone doesn't allow control. Unlock it and turn on Settings → Developer → "
                      "“Enable UI Automation”. Then run again."), help="uiauto")


def explain_connect_error(e):
    """A plain-language sentence explaining a connection error."""
    low = str(e).lower()
    if any(w in low for w in ("connection refused", "max retries exceeded", "failed to establish", "newconnectionerror")):
        return T("Appium server neběží, nedá se k němu připojit. Spusť to znovu; podrobnosti jsou v ~/.pogo/appium.log.",
                 "The Appium server isn't running. Run again; details are in ~/.pogo/appium.log.")
    if "unknown device" in low or ("udid" in low and "not" in low) or "could not find a device" in low:
        return T("iPhone se nenašel. Připoj ho kabelem, odemkni, potvrď „Důvěřovat“ a zkontroluj iPhone v nastavení aplikace.",
                 "iPhone not found. Connect it with a cable, unlock it, tap “Trust” and check the iPhone in the app settings.")
    if not_authorized(e):
        return T("iPhone nepovolil ovládání. Odemkni ho a zapni na něm Nastavení → Vývojář → „Enable UI Automation“.",
                 "The iPhone refused control. Unlock it and turn on Settings → Developer → “Enable UI Automation”.")
    if "locked" in low or "passcode" in low:
        return T("iPhone je zamčený. Odemkni ho a spusť znovu.", "The iPhone is locked. Unlock it and run again.")
    text, _help = explain_wda_error(e)
    return text


def session_alive(driver):
    try:
        driver.get_window_size()
        return True
    except Exception:
        return False


def reconnect(bot):
    log(T("   Spojení s telefonem spadlo, připojuji znovu...", "   Lost the connection to the phone, reconnecting..."))
    step(T("Spojení s iPhonem spadlo – připojuji znovu", "Lost the connection to the iPhone – reconnecting"))
    try:
        bot.d.quit()
    except Exception:
        pass
    for attempt in range(3):
        if attempt == 1:
            # The phone usually drops the whole WebDriverAgent with the connection, so another try
            # would keep talking to a port nobody listens on any more. A WebDriverAgent that won't
            # come back ends the run (its Fatal says why).
            log(T("   startuji WebDriverAgent znovu...", "   starting WebDriverAgent again..."))
            bot.wda.stop()
            bot.wda.start()
        try:
            bot.d = open_session(bot.udid, bot.wda.url)
            bot.refresh()
            return
        except Fatal:
            raise
        except Exception as e:
            log(T(f"   nepovedlo se ({short_err(e)}), zkusím znovu za 5 s", f"   failed ({short_err(e)}), retrying in 5 s"))
            time.sleep(5)
    raise Fatal(T("Nepodařilo se znovu připojit k iPhonu. Je odemčený a připojený kabelem?",
                  "Couldn't reconnect to the iPhone. Is it unlocked and connected with a cable?"))


def ensure_app(bot):
    """Makes sure the phone is unlocked and the game is in front. Returns True if it had to do something."""
    acted = False
    try:
        if bot.d.is_locked():
            log(T("   Telefon je zamčený – zkouším odemknout (s kódem ho odemkni ručně, počkám)",
                  "   The phone is locked – trying to unlock it (with a passcode, unlock it yourself, I'll wait)"))
            emit("problem", text=T("iPhone je zamčený – odemkni ho, bot počká a pak pokračuje.",
                                   "The iPhone is locked – unlock it, the bot waits and then continues."))
            try:
                bot.d.unlock()
            except Exception:
                pass
            end = time.time() + 600
            while bot.d.is_locked() and time.time() < end:
                time.sleep(2)
            acted = True
        if bot.d.query_app_state(cfg.BUNDLE_ID) != 4:   # 4 = running in the foreground
            log(T("   Pokémon GO není v popředí – přepínám do něj", "   Pokémon GO isn't in front – switching to it"))
            bot.d.activate_app(cfg.BUNDLE_ID)
            time.sleep(2)
            acted = True
    except Exception as e:
        log(T(f"   (stav aplikace nezjištěn: {short_err(e)})", f"   (app state unknown: {short_err(e)})"))
    return acted


def restart_game(bot):
    log(T("   Restartuji Pokémon GO...", "   Restarting Pokémon GO..."))
    step(T("Restartuji Pokémon GO", "Restarting Pokémon GO"))
    emit("problem", text=T("Hra se zasekla – restartuji ji a pokračuji.", "The game got stuck – restarting it and continuing."))
    try:
        bot.d.terminate_app(cfg.BUNDLE_ID)
    except Exception:
        pass
    time.sleep(2)
    bot.d.activate_app(cfg.BUNDLE_ID)
    bot.need_sort = True
    end = time.time() + 75
    while time.time() < end:
        time.sleep(1.5)
        fr = bot.frame()
        st = classify(fr)
        if st in ("map", "main_menu") or st in BOX_STATES:
            log(T("   hra je načtená", "   the game is loaded"))
            return
        t = safe_button(fr.texts)
        if t:
            try:
                bot.tap(t["cx"], t["cy"], T(f"zavřít okno: {t['text']}", f"close window: {t['text']}"), fr=fr)
            except StepError:
                pass
    log(T("   hra se po restartu nenačetla do mapy, zkusím pokračovat",
          "   the game didn't load to the map after the restart, trying to continue"))
