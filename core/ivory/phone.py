"""Asking the iPhone about itself over usbmux / lockdown (pymobiledevice3).

pymobiledevice3 is async all the way down and the bot is plain threaded code, so everything async runs
on one private event loop in a daemon thread. WebDriverAgent's tunnel and forwards (wda.py) live on the
same loop, because they have to stay alive for the whole run.
"""
import asyncio
import concurrent.futures
import threading

from .output import log, T

MIN_IOS = (17, 4)          # the userspace tunnel needs CoreDeviceProxy, which 17.0-17.3 lack


class _Loop:
    """An asyncio loop in a daemon thread, so sync code can await pymobiledevice3."""

    def __init__(self):
        self.loop = asyncio.new_event_loop()
        threading.Thread(target=self.loop.run_forever, daemon=True, name="ivory-pmd").start()

    def call(self, coro, timeout=None):
        fut = asyncio.run_coroutine_threadsafe(coro, self.loop)
        try:
            return fut.result(timeout)
        except concurrent.futures.TimeoutError:
            # Otherwise the coroutine keeps going on the loop and whatever it starts later leaks.
            fut.cancel()
            raise


_LOOP = None


def run(coro, timeout=None):
    """Runs a pymobiledevice3 coroutine from sync code and returns its result."""
    global _LOOP
    if _LOOP is None:
        _LOOP = _Loop()
    return _LOOP.call(coro, timeout)


async def _lockdown(udid, autopair=True):
    from pymobiledevice3.lockdown import create_using_usbmux
    return await create_using_usbmux(udid, autopair=autopair)


async def _adevices():
    from pymobiledevice3 import usbmux
    found = []
    for dev in await usbmux.list_devices():
        try:
            ld = await _lockdown(dev.serial, autopair=False)
            info = ld.short_info or {}
            found.append((info.get("DeviceName") or "iPhone", ld.product_version or "", dev.serial))
        except Exception:
            # Not trusted yet: still listed, so the app can name the phone the user has to trust.
            found.append(("iPhone", "", dev.serial))
    return found


def list_devices():
    """Connected iPhones: [(name, iOS, UDID)]."""
    try:
        return run(_adevices(), timeout=30)
    except Exception as e:
        log(T(f"   (seznam zařízení se nepodařilo načíst: {e})", f"   (couldn't list the devices: {e})"))
        return []


def ios_too_old(version):
    """Is this iOS older than the userspace tunnel can serve? An unknown version gets the benefit of the
    doubt, so the run fails later with the real error instead."""
    try:
        parts = tuple(int(x) for x in str(version).split(".")[:2])
    except ValueError:
        return False
    return bool(parts) and parts < MIN_IOS


async def _adeveloper_mode(udid):
    ld = await _lockdown(udid)
    try:
        # Asked for by name: querying the whole amfi domain answers {} even with Developer Mode on.
        status = await ld.get_value(domain="com.apple.security.mac.amfi", key="DeveloperModeStatus")
    except Exception:
        return None
    return None if status is None else bool(status)


def developer_mode_status(udid):
    """True / False, or None when the phone can't be asked (not trusted yet, locked, restarting)."""
    try:
        return run(_adeveloper_mode(udid), timeout=30)
    except Exception:
        return None


def developer_mode_on(udid):
    """For the run: a phone that can't be asked is given the benefit of the doubt."""
    return developer_mode_status(udid) is not False


async def _apaired(udid):
    ld = await _lockdown(udid, autopair=False)
    return bool(getattr(ld, "paired", True))


def paired(udid):
    """Has the phone confirmed "Trust This Computer"? A lockdown session only opens once it has."""
    try:
        return bool(run(_apaired(udid), timeout=30))
    except Exception:
        return False


async def _areveal_developer_mode(udid):
    from pymobiledevice3.services.amfi import AmfiService
    async with AmfiService(await _lockdown(udid)) as amfi:
        await amfi.reveal_developer_mode_option_in_ui()


def reveal_developer_mode(udid):
    """Makes the Developer Mode switch appear in Settings; flipping it is up to the user."""
    try:
        run(_areveal_developer_mode(udid), timeout=30)
        return True
    except Exception:
        return False
