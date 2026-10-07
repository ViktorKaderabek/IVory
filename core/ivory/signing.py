"""Signing WebDriverAgent with the user's own Apple ID through the bundled altsign-cli.

A development profile is only valid for the UDIDs it names, so the signature has to be made on the
user's Mac with the user's account – one made anywhere else would be refused by their phone.
"""
import hashlib
import os
import plistlib
import selectors
import shutil
import subprocess
import tempfile
import time
from pathlib import Path

from .errors import Fatal
from .output import T

_BUNDLED = Path(__file__).resolve().parent.parent.parent / "runtime"
LOGIN_TIMEOUT = 180        # seconds for the whole Apple sign-in, the user typing the code included
SIGN_TIMEOUT = 600


def _tool(name):
    """A file from the runtime/ shipped inside IVory.app (or of a clone). Never from anywhere writable
    like ~/.pogo: altsign-cli is handed the Apple ID password."""
    p = _BUNDLED / name
    return p if p.exists() else None


def _altsign():
    p = _tool("altsign-cli")
    return p if p and os.access(p, os.X_OK) else None


def wda_bundle_id(udid, apple_id):
    """The bundle id IVory signs WebDriverAgent under.

    App IDs are globally unique and the prebuilt runner's own was registered by someone else years
    ago ("App ID not available"), so ours is derived from the Apple ID and the UDID: stable between
    runs, so the same app is reinstalled instead of piling up, and never asked for by two users.
    """
    digest = hashlib.sha256(f"{apple_id.strip().lower()}|{udid}".encode()).hexdigest()[:10]
    return f"com.ivory.wda{digest}"


def runner_id(udid, apple_id):
    """The bundle id of the XCUITest runner app on the phone."""
    return wda_bundle_id(udid, apple_id) + ".xctrunner"


def _set_bundle_id(plist, value):
    with open(plist, "rb") as f:
        data = plistlib.load(f)
    data["CFBundleIdentifier"] = value
    with open(plist, "wb") as f:
        plistlib.dump(data, f, fmt=plistlib.FMT_BINARY)


def _answer_prompts(p, get_code):
    """Feeds altsign-cli the 2FA code when it asks for one and waits for it to finish.

    Read in raw chunks: "Enter code: " comes without a newline. Returns the exit code, or None when
    the user cancelled or Apple took too long.
    """
    deadline = time.monotonic() + LOGIN_TIMEOUT
    sel = selectors.DefaultSelector()
    sel.register(p.stdout, selectors.EVENT_READ)
    seen = b""
    while time.monotonic() < deadline:
        if not sel.select(timeout=1):
            continue
        chunk = os.read(p.stdout.fileno(), 4096)
        if not chunk:
            return p.wait(timeout=10)
        seen = (seen + chunk)[-4096:]
        if b"enter code" in seen.lower():
            seen = b""                     # a wrong code is asked for again
            code = get_code()
            if not code:
                return None
            p.stdin.write((code.strip() + "\n").encode())
            p.stdin.flush()
    return None


def login(apple_id, password, get_code):
    """Signs in to Apple and lets altsign-cli cache the session (about a year).

    The password and the code go to altsign-cli's stdin only, never into its arguments or a log.
    `get_code` is called when Apple asks for the six digits; returning None cancels.
    Returns (ok, why).
    """
    cli = _altsign()
    if not cli:
        raise Fatal(T("Chybí altsign-cli – přeinstaluj IVory.", "altsign-cli is missing – reinstall IVory."))
    p = subprocess.Popen([str(cli), "list", "--apple-id", apple_id],
                         stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    rc = None
    try:
        p.stdin.write((password + "\n").encode())
        p.stdin.flush()
        rc = _answer_prompts(p, get_code)
    except BrokenPipeError:
        rc = p.wait(timeout=10)
    finally:
        try:
            p.stdin.close()
        except OSError:
            pass
        if p.poll() is None:
            p.kill()
    if rc == 0:
        return True, ""
    if rc is None:
        return False, T("Přihlášení zrušeno.", "Sign-in cancelled.")
    return False, T("Apple přihlášení odmítl. Zkontroluj Apple ID a heslo.",
                    "Apple refused the sign-in. Check the Apple ID and the password.")


def _altsign_error(output):
    """The one line of altsign-cli's debug transcript worth showing."""
    for line in reversed(output.splitlines()):
        if "[Error]" in line or "Error Domain" in line:
            return line.split("] ", 1)[-1].strip()[:300]
    return ""


def sign_wda(udid, apple_id, out_dir):
    """Signs the bundled WebDriverAgent runner for this one phone into out_dir. Returns the .ipa."""
    cli, src = _altsign(), _tool("WebDriverAgentRunner.app")
    if not cli or not src:
        raise Fatal(T("Chybí podepisovací nástroje – přeinstaluj IVory.",
                      "The signing tools are missing – reinstall IVory."))
    base = wda_bundle_id(udid, apple_id)
    ipa = Path(out_dir) / "WebDriverAgentRunner-signed.ipa"
    stage = Path(tempfile.mkdtemp(prefix="ivory-wda-"))
    try:
        # A renamed copy is signed, the bundled runner itself is never touched.
        app = stage / "WebDriverAgentRunner.app"
        shutil.copytree(src, app, symlinks=True)
        _set_bundle_id(app / "Info.plist", base + ".xctrunner")
        _set_bundle_id(app / "PlugIns" / "WebDriverAgentRunner.xctest" / "Info.plist", base)
        r = subprocess.run([str(cli), "sign", "--udid", udid, "--app", str(app), "--output", str(ipa)],
                           capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=SIGN_TIMEOUT)
    finally:
        shutil.rmtree(stage, ignore_errors=True)
    if r.returncode == 2:
        raise Fatal(T("Přihlášení k Apple vypršelo. Přihlas se znovu v Nastavení → iPhone.",
                      "The Apple sign-in expired. Sign in again in Settings → iPhone."), help="signin")
    if "IVORY_CERT_LIMIT" in r.stdout + r.stderr:
        raise Fatal(T("Apple nevydal nový vývojářský certifikát: bezplatné Apple ID smí mít jen jeden a ten tvůj "
                      "vytvořil jiný program (Xcode, AltStore nebo Sideloadly). IVory cizí certifikát neruší, aby "
                      "aplikace podepsané jím fungovaly dál. Zruš ho v tom programu (v Xcode: Nastavení → Účty → "
                      "Spravovat certifikáty), nebo se v IVory přihlas jiným Apple ID.",
                      "Apple didn't issue a new development certificate: a free Apple ID may have only one, and yours "
                      "was made by another program (Xcode, AltStore or Sideloadly). IVory never revokes someone else's "
                      "certificate, so the apps it signed keep working. Revoke it in that program (in Xcode: Settings → "
                      "Accounts → Manage Certificates), or sign in to IVory with another Apple ID."), help="signin")
    if r.returncode != 0 or not ipa.is_file():
        why = _altsign_error(r.stdout + r.stderr)
        raise Fatal(T("Nepodařilo se podepsat WebDriverAgent. Zkontroluj, že je Apple ID přihlášené "
                      "v Nastavení → iPhone a že iPhone je připojený.",
                      "Couldn't sign WebDriverAgent. Check that the Apple ID is signed in under "
                      "Settings → iPhone and that the iPhone is connected.")
                    + (f"\n   ({why})" if why else ""))
    return ipa
