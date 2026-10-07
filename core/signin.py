"""Signing in to Apple from Terminal (the app has its own screen for this).

IVory signs WebDriverAgent with the user's Apple ID, because a development profile is only valid for
the UDIDs it names – a signature made anywhere else would be refused by their phone. Run.sh calls
this once, when no Apple ID is configured yet.
"""
import getpass
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from ivory.errors import Fatal                      # noqa: E402
from ivory.output import load_language, T           # noqa: E402
from ivory.signing import login                     # noqa: E402

CONFIG = os.path.expanduser("~/.pogo/config.json")


def save_apple_id(apple_id):
    try:
        cfg = json.load(open(CONFIG))
    except (OSError, ValueError):
        cfg = {}
    cfg["apple_id"] = apple_id
    os.makedirs(os.path.dirname(CONFIG), exist_ok=True)
    with open(CONFIG + ".tmp", "w") as f:
        json.dump(cfg, f, indent=2, sort_keys=True, ensure_ascii=False)
    os.replace(CONFIG + ".tmp", CONFIG)


def main():
    load_language()
    print(T("""
  Přihlášení k Apple

  IVory podepíše tvým Apple ID pomocnou aplikaci, bez které iPhone ovládat nejde.
  Apple povolí ovládání jen zařízení, která patří k podepsanému účtu, takže to musí
  být tvůj účet. Stačí obyčejné Apple ID, placený vývojářský účet ne.

  Heslo jde rovnou Applu. IVory si ho neukládá – uloží se jen přihlášení, asi na rok.
""", """
  Sign in to Apple

  IVory signs the helper app the iPhone can't be controlled without with your Apple ID.
  Apple only allows control of devices that belong to the signing account, so it has to
  be yours. Any ordinary Apple ID will do; a paid developer account isn't needed.

  The password goes straight to Apple. IVory doesn't store it – only the sign-in is kept,
  for about a year.
"""))
    try:
        apple_id = input(T("  Apple ID (Enter přeskočí): ", "  Apple ID (Enter skips): ")).strip()
    except (EOFError, KeyboardInterrupt):
        return 1
    if not apple_id:
        print(T("  Přeskočeno. Bez přihlášení se iPhone ovládat nedá – přihlas se v aplikaci "
                "v Nastavení → iPhone.",
                "  Skipped. The iPhone can't be controlled without signing in – sign in in the app "
                "under Settings → iPhone."))
        return 0
    try:
        password = getpass.getpass(T("  Heslo (nezobrazuje se): ", "  Password (not shown): "))
    except (EOFError, KeyboardInterrupt):
        return 1

    def code():
        try:
            return input(T("  Kód z iPhonu (6 číslic): ", "  Code from the iPhone (6 digits): "))
        except (EOFError, KeyboardInterrupt):
            return None

    try:
        ok, why = login(apple_id, password, code)
    except Fatal as e:
        print(f"  ✖ {e}")
        return 1
    if not ok:
        print(f"  ✖ {why}")
        return 1
    save_apple_id(apple_id)
    print(T("  ✔ Přihlášeno.", "  ✔ Signed in."))
    return 0


if __name__ == "__main__":
    sys.exit(main())
