"""What the app's setup guide asks the iPhone, and its install step.

The guide is Swift, but everything beyond listing the phone goes through pymobiledevice3, so the guide
calls this with the Python that scripts/run.sh --prepare set up:

  python setup.py check UDID              {"paired", "devmode"} as one JSON line
  python setup.py reveal UDID             makes the Developer Mode switch appear in Settings
  python setup.py install UDID APPLE_ID   signs the helper app and installs it, with "@@" events

The Apple ID password never comes here: signing uses the session altsign-cli cached at sign-in.
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from ivory import config as cfg                     # noqa: E402
from ivory import phone                             # noqa: E402
from ivory.errors import Fatal                      # noqa: E402
from ivory.output import emit, load_language, T     # noqa: E402
from ivory.wda import explain_wda_error, sign_and_install  # noqa: E402


def _say(**data):
    print(json.dumps(data, ensure_ascii=False), flush=True)


def check(udid):
    ok = phone.paired(udid)
    _say(paired=ok, devmode=phone.developer_mode_status(udid) if ok else None)


def install(udid, apple_id):
    try:
        sign_and_install(udid, apple_id, on_step=lambda key, _text: emit("setup", id=key, state="start"))
    except Fatal as e:
        emit("setup", state="fail", text=str(e))
        return 1
    except Exception as e:                              # pymobiledevice3 raises its own types
        emit("setup", state="fail", text=explain_wda_error(e)[0])
        return 1
    emit("setup", id="phone", state="done")
    return 0


def main(argv):
    load_language()
    cfg.EVENTS = True
    command, args = (argv[0], argv[1:]) if argv else ("", [])
    if command == "check" and len(args) == 1:
        check(args[0])
    elif command == "reveal" and len(args) == 1:
        _say(ok=phone.reveal_developer_mode(args[0]))
    elif command == "install" and len(args) == 2:
        return install(*args)
    else:
        print(T("Použití: setup.py check|reveal UDID  /  setup.py install UDID APPLE_ID",
                "Usage: setup.py check|reveal UDID  /  setup.py install UDID APPLE_ID"), file=sys.stderr)
        return 64
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
