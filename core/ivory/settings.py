"""The settings the app writes into ~/.pogo/config.json, applied over the defaults in config.py."""
import json

from . import config as cfg
from .output import log, T
from .vision import alnum


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
    cfg.APPLE_ID = str(c.get("apple_id") or "").strip()
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
    # Battle tags; a name the other steps manage is left out (the battle step would take it off everyone else)
    taken = {alnum(cfg.TAG_NAME)} | {alnum(n) for _, n in cfg.IV_TAGS} | {alnum(lg["name"]) for lg in cfg.PVP.values()}
    battle = []
    for t in (c.get("battle") or {}).get("tags") or []:
        name = str((t or {}).get("name") or "").strip()
        if not name or alnum(name) in taken:
            continue
        taken.add(alnum(name))
        mons = [{"cp": int(m["cp"]), "iv": tuple(int(v) for v in m["iv"]), "sid": str(m.get("sid") or "")}
                for m in t.get("mons") or []
                if isinstance(m, dict) and m.get("cp") and isinstance(m.get("iv"), list) and len(m["iv"]) == 3]
        battle.append({"name": name, "color": cfg.color_name(t.get("color"), "gray"), "mons": mons})
    cfg.BATTLE["tags"] = battle
    wk = c.get("weak") or {}
    cfg.WEAK["max_iv"] = max(0, min(100, int(wk.get("max_iv", cfg.WEAK["max_iv"]))))
    for k in ("keep_legendary", "keep_mythical", "keep_ultra_beast", "keep_regional", "keep_best", "keep_battle"):
        if k in wk:
            cfg.WEAK[k] = bool(wk[k])
    cfg.WEAK["keep_tag"] = str(wk.get("keep_tag") or "").strip()
    cfg.MAX_GROUPS = int(c.get("max_groups", cfg.MAX_GROUPS))
