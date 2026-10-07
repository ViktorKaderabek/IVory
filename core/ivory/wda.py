"""Getting WebDriverAgent onto the iPhone and running, without Xcode.

  1. the runner built in advance ships with IVory and is signed with the user's Apple ID (signing.py),
  2. pymobiledevice3 installs it and starts it as an XCUITest bundle over a userspace RSD tunnel
     (no root: the kernel utun device would need it, the pure-Python TCP stack doesn't),
  3. ports 8100 (WebDriverAgent) and 9100 (its MJPEG stream) are forwarded to localhost, and Appium is
     handed the finished URL, so it never reaches for xcodebuild.
"""
import asyncio
import shutil
import tempfile

from .errors import Fatal
from .output import T
from .phone import run
from .signing import runner_id, sign_wda

WDA_PORT = 8100
MJPEG_PORT = 9100          # stream.py reads it on localhost
WDA_TIMEOUT = 120.0        # how long WebDriverAgent gets to come up


class _WontLaunch(Fatal):
    """The runner didn't come up. An expired 7-day signature looks exactly like this."""


# --- installing ------------------------------------------------------------

async def _ainstall(udid, ipa):
    from pymobiledevice3.lockdown import create_using_usbmux
    from pymobiledevice3.services.installation_proxy import InstallationProxyService
    async with InstallationProxyService(lockdown=await create_using_usbmux(udid)) as ip:
        await ip.install_from_local(str(ipa))


async def _ainstalled(provider, bundle_id):
    """Is IVory's own runner on the phone? Asked for by name, so a runner some other sideloading tool
    put there is never launched instead."""
    from pymobiledevice3.services.installation_proxy import InstallationProxyService
    async with InstallationProxyService(lockdown=provider) as ip:
        apps = await ip.get_apps(application_type="Any", bundle_identifiers=[bundle_id])
    return bundle_id in apps


def wda_installed(udid, apple_id):
    async def check():
        from pymobiledevice3.lockdown import create_using_usbmux
        return await _ainstalled(await create_using_usbmux(udid), runner_id(udid, apple_id))
    try:
        return bool(run(check(), timeout=60))
    except Exception:
        return False


def sign_and_install(udid, apple_id, on_step=lambda _key, _text: None):
    """Signs WebDriverAgent for this phone and installs it, without starting it."""
    on_step("sign", T("Podepisuji pomocnou aplikaci tvým Apple ID", "Signing the helper app with your Apple ID"))
    work = tempfile.mkdtemp(prefix="ivory-signed-")
    try:
        ipa = sign_wda(udid, apple_id, work)
        on_step("phone", T("Instaluji pomocnou aplikaci do iPhonu", "Installing the helper app on the iPhone"))
        run(_ainstall(udid, ipa), timeout=600)
    finally:
        shutil.rmtree(work, ignore_errors=True)


# --- what went wrong -------------------------------------------------------

# (what the error says, the setup step it points back to, what to tell the user in Czech / English)
_CAUSES = [
    (("explicitly trusted", "untrusted", "invalid code signature"), "trust",
     ("iPhone zatím nedůvěřuje pomocné aplikaci. Na iPhonu otevři Nastavení → Obecné → Správa VPN "
      "a zařízení, klepni na svoje Apple ID a potvrď Důvěřovat.",
      "The iPhone doesn't trust the helper app yet. On the iPhone open Settings → General → VPN & "
      "Device Management, tap your Apple ID and confirm Trust.")),
    (("userspacetunnelunavailable", "coredeviceproxy"), None,
     ("Tenhle iPhone potřebuje iOS 17.4 nebo novější. Aktualizuj ho v Nastavení → Obecné → "
      "Aktualizace softwaru.",
      "This iPhone needs iOS 17.4 or newer. Update it in Settings → General → Software Update.")),
    (("developer mode", "amfi"), "devmode",
     ("Na iPhonu zapni Režim pro vývojáře (Nastavení → Soukromí a zabezpečení → Režim pro vývojáře) "
      "a nech telefon restartovat.",
      "Turn on Developer Mode on the iPhone (Settings → Privacy & Security → Developer Mode) "
      "and let it restart.")),
    (("not authorized", "xctdaemonerrordomain code=41"), "uiauto",
     ("iPhone nepovolil ovládání. Zapni Nastavení → Vývojář → „Povolit automatizaci UI“.",
      "The iPhone refused control. Turn on Settings → Developer → “Enable UI Automation”.")),
    (("not paired", "pairing"), "pair",
     ("iPhone zatím počítači nedůvěřuje. Odemkni ho a potvrď „Důvěřovat tomuto počítači“.",
      "The iPhone doesn't trust this computer yet. Unlock it and tap “Trust This Computer”.")),
    (("appnotinstalled", "not installed"), None,
     ("WebDriverAgent na iPhonu chybí. IVory ho nainstaluje při dalším spuštění.",
      "WebDriverAgent is missing from the iPhone. IVory installs it on the next start.")),
    (("devicenotfound", "no device"), "pair",
     ("iPhone se nenašel. Připoj ho kabelem a odemkni.", "iPhone not found. Connect it with a cable and unlock it.")),
]


def explain_wda_error(e):
    """(a plain-language sentence, the setup step it points back to or None) for a failed start."""
    low = str(e).lower()
    for words, help, text in _CAUSES:
        if any(w in low for w in words):
            return T(*text), help
    return T(f"WebDriverAgent se nepodařilo spustit: {e}", f"Couldn't start WebDriverAgent: {e}"), None


# --- the running WebDriverAgent --------------------------------------------

class WdaSession:
    """A running WebDriverAgent: the tunnel, the XCUITest runner and the two port forwards. They all
    outlive start() as tasks on the shared loop, and only stop() takes them down."""

    def __init__(self, udid, bundle_id):
        self.udid = udid
        self.bundle_id = bundle_id
        self.url = None
        self._tunnel = None
        self._runner = None
        self._tasks = []

    async def _wait_for_wda(self, deadline):
        """Waits until WebDriverAgent answers on the phone, watching the runner: when XCUITest dies
        during startup its own error says far more than a timeout."""
        from pymobiledevice3 import usbmux
        from pymobiledevice3.exceptions import ConnectionFailedError
        while True:
            if self._runner.done():
                self._runner.result()                  # re-raises whatever killed the runner
                raise _WontLaunch(T("WebDriverAgent skončil dřív, než začal odpovídat.",
                                    "WebDriverAgent exited before it started answering."))
            if asyncio.get_running_loop().time() >= deadline:
                raise _WontLaunch(T(f"WebDriverAgent se neozval do {int(WDA_TIMEOUT)} s.",
                                    f"WebDriverAgent didn't answer within {int(WDA_TIMEOUT)} s."))
            dev = await usbmux.select_device(self.udid)
            if dev is None:
                raise Fatal(T("iPhone se během startu odpojil.", "The iPhone disconnected while starting up."),
                            help="pair")
            try:
                sock = await dev.connect(WDA_PORT)
            except ConnectionFailedError:
                await asyncio.sleep(0.2)
            else:
                sock.close()
                return

    async def _forward(self, port):
        """Exposes a phone port on the same localhost port, for Appium and stream.py."""
        from pymobiledevice3.tcp_forwarder import UsbmuxTcpForwarder
        ready = asyncio.Event()
        fw = UsbmuxTcpForwarder(serial=self.udid, dst_port=port, src_port=port, listening_event=ready)
        task = asyncio.create_task(fw.start())
        self._tasks.append(task)
        listening = asyncio.create_task(ready.wait())
        await asyncio.wait({task, listening}, timeout=30, return_when=asyncio.FIRST_COMPLETED)
        listening.cancel()
        if not ready.is_set():
            raise Fatal(T(f"Port {port} na tomhle Macu je obsazený. Ukonči druhou kopii IVory nebo Appia "
                          f"a spusť znovu.",
                          f"Port {port} on this Mac is taken. Quit the other copy of IVory or Appium "
                          f"and run again."))

    async def _astart(self):
        from pymobiledevice3.remote.userspace_tunnel import UserspaceRsdTunnel
        from pymobiledevice3.services.dvt.testmanaged.xcuitest import TestConfig, XCUITestService

        # remotepairing_fallback stays off, so a phone the userspace stack can't serve fails here with
        # a clear message instead of hanging.
        self._tunnel = UserspaceRsdTunnel(serial=self.udid, remotepairing_fallback=False)
        rsd = await self._tunnel.aopen()
        if not await _ainstalled(rsd, self.bundle_id):
            raise Fatal(T("WebDriverAgent není na iPhonu nainstalovaný.",
                          "WebDriverAgent isn't installed on the iPhone."))
        cfg = await TestConfig.create_for(rsd, runner_bundle_id=self.bundle_id)
        self._runner = asyncio.create_task(XCUITestService(rsd).run(cfg), name="ivory-wda")
        self._tasks.append(self._runner)
        await self._wait_for_wda(asyncio.get_running_loop().time() + WDA_TIMEOUT)
        await self._forward(WDA_PORT)
        await self._forward(MJPEG_PORT)

    async def _astop(self):
        for t in self._tasks:
            t.cancel()
        await asyncio.gather(*self._tasks, return_exceptions=True)
        self._tasks = []
        self._runner = None
        if self._tunnel is not None:
            try:
                await self._tunnel.aclose()
            except Exception:
                pass
            self._tunnel = None

    def start(self):
        """Starts WebDriverAgent and returns the URL to hand to Appium."""
        try:
            run(self._astart(), timeout=WDA_TIMEOUT + 90)
        except Fatal:
            self.stop()
            raise
        except Exception as e:
            self.stop()
            text, help = explain_wda_error(e)
            raise Fatal(text, help=help) from e
        self.url = f"http://127.0.0.1:{WDA_PORT}"
        return self.url

    def stop(self):
        try:
            run(self._astop(), timeout=30)
        except Exception:
            pass
        self.url = None


def ensure_wda(udid, apple_id, on_step=lambda _text: None):
    """Makes sure IVory's WebDriverAgent is on the phone and starts it. Returns (session, url).

    Signing is only redone when the runner is missing, or once when it won't launch: a free Apple ID's
    signature lasts 7 days, and an expired one just doesn't start.
    """
    if not apple_id:
        raise Fatal(T("Nejdřív se přihlas svým Apple ID v Nastavení → iPhone. IVory jím podepíše "
                      "pomocnou aplikaci, bez které iPhone ovládat nejde.",
                      "Sign in with your Apple ID under Settings → iPhone first. IVory signs the helper "
                      "app with it, and the iPhone can't be controlled without it."), help="signin")
    say = lambda _key, text: on_step(text)                                   # noqa: E731
    if not wda_installed(udid, apple_id):
        sign_and_install(udid, apple_id, say)
    session = WdaSession(udid, runner_id(udid, apple_id))
    on_step(T("Spouštím WebDriverAgent", "Starting WebDriverAgent"))
    try:
        return session, session.start()
    except _WontLaunch:
        on_step(T("Pomocná aplikace se nespustila – podepisuji ji znovu",
                  "The helper app didn't start – signing it again"))
        sign_and_install(udid, apple_id, say)
        session = WdaSession(udid, runner_id(udid, apple_id))
        return session, session.start()
