"""Values the bot learns on the phone and keeps between runs, such as how the game shows the typed search
and the scroll gain (~/.pogo/calibration.json)."""
import json

from . import config as cfg


def cal_load():
    try:
        return json.loads(cfg.CAL_FILE.read_text())
    except Exception:
        return {}


def cal_set(key, val):
    d = cal_load()
    d[key] = val
    cfg.CAL_FILE.parent.mkdir(parents=True, exist_ok=True)
    cfg.CAL_FILE.write_text(json.dumps(d, indent=1))
