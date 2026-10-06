"""Measured Pokémon, the duplicate decisions and the memory kept between runs."""
import json
import time

from . import config as cfg
from .output import log, T
from .vision import alnum
from .grid import names_ok, sprite_sim


def decide(recs, keep_n=None):
    """Keeps the best by IV total (then attack, defense, HP) and marks the rest for removal.
    Never marks unmeasured ones."""
    keep_n = cfg.KEEP_N if keep_n is None else keep_n
    ok = sorted((r for r in recs if r.iv), key=lambda r: (sum(r.iv), *r.iv), reverse=True)
    for i, r in enumerate(ok):
        r.action = "keep" if i < keep_n else "remove"
    for r in recs:
        if not r.iv:
            r.action = None


def decide_group(group):
    """If a group mixes different types (another species / form), decides each type separately."""
    kinds = {tuple(r.types) for r in group if r.types}
    if len(kinds) <= 1:
        decide(group)
        return False
    for k in kinds:
        decide([r for r in group if r.types and tuple(r.types) == k])
    for r in group:
        if not r.types:
            r.action = "keep" if r.iv else None   # without a type, better keep it
    return True


# --- Pokémon records ---
class Rec:
    def __init__(self, cell, gid):
        self.cp, self.name, self.sig, self.sprite = cell["cp"], cell["name"], cell["sig"], cell["sprite"]
        self.gid = gid
        self.iv = self.types = self.action = None
        self.status = "new"          # new | done | failed | single
        self.fails = self.tag_fails = 0
        self.tagged = self.ambiguous = self.cached = False
        self.note = ""
        self.target, self.removed, self.had = None, [], False   # Part 2: IV tag, removed tags, already had it


class Book:
    def __init__(self):
        self.recs, self.next_gid, self.progress = [], 1, 0

    def new_gid(self):
        self.next_gid += 1
        return self.next_gid - 1

    def assign(self, cells):
        """Matches the cells to known records (same CP + name + sprite), keeping their order."""
        used = set()
        for c in cells:
            c["rec"] = None
            for r in self.recs:
                if id(r) not in used and r.cp == c["cp"] and names_ok(r.name, c["name"]) \
                        and sprite_sim(r.sprite, c["sprite"]) >= cfg.SAME_SPECIES_THR:
                    c["rec"] = r
                    used.add(id(r))
                    break

    def group(self, gid):
        return [r for r in self.recs if r.gid == gid]

    def groups(self):
        gids = {}
        for r in self.recs:
            gids.setdefault(r.gid, []).append(r)
        return {g: rs for g, rs in gids.items() if len(rs) >= 2}

    def groups_done(self):
        return sum(1 for rs in self.groups().values() if all(r.status != "new" for r in rs))

    def outstanding(self):
        return [r for r in self.recs if r.action == "remove" and not r.tagged
                and not r.ambiguous and r.tag_fails < 2]


class Memory:
    """Persistent memory between runs: what the bot knows about each Pokémon in the storage (IVs, types,
    tags, name) and who it tagged. The storage part is not cleared by age; after each run it is synced with
    what is in the game (see inventory.remember_box). Only the record of who got the TAG_NAME tag expires,
    after TAGGED_DAYS."""

    def __init__(self, path):
        self.path = path
        try:
            self.data = json.loads(path.read_text())
        except Exception:
            self.data = {}
        now = time.time()
        self.data["iv"] = {k: v for k, v in self.data.get("iv", {}).items() if isinstance(v, dict) and v.get("iv")}
        self.data["tagged"] = {k: v for k, v in self.data.get("tagged", {}).items()
                               if now - v < cfg.TAGGED_DAYS * 86400}
        self.data["box"] = [it for it in self.data.get("box", []) if isinstance(it, dict) and it.get("iv")]
        self.box_start = list(self.data["box"])    # memory at the start of the run (compared against it)

    def save(self):
        try:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            tmp = self.path.with_suffix(".tmp")
            tmp.write_text(json.dumps(self.data, default=lambda o: o.item() if hasattr(o, "item") else str(o)))
            tmp.replace(self.path)
        except OSError as e:
            log(T(f"   (paměť se nepodařilo uložit: {e})", f"   (couldn't save the memory: {e})"))

    def get_iv(self, sig):
        e = self.data["iv"].get(sig)
        return (tuple(e["iv"]), e.get("types")) if e else None

    def set_iv(self, sig, iv, types, save=True):
        if sig.split("|", 1)[1]:          # without a name, don't remember it
            self.data["iv"][sig] = {"iv": list(iv), "types": types, "t": time.time()}
            if save:
                self.save()

    def box_items(self):
        """Pokémon read in earlier runs: IVs, types, HP, tags and name as they last were in the game."""
        return self.data["box"]

    def set_box(self, items):
        """New memory contents; IVs by signature (slow mode) are kept only for the Pokémon in it."""
        self.data["box"] = items
        self.data["iv"] = {f"{it['gcp']}|{alnum(it.get('gname') or '')}": {"iv": it["iv"], "types": it.get("types"),
                                                                           "t": it.get("t")}
                           for it in items if alnum(it.get("gname") or "")}
        self.save()

    def is_tagged(self, cp, name):
        prefix = alnum(cfg.TAG_NAME) + "|"
        for k in self.data["tagged"]:
            if not k.startswith(prefix):
                continue                     # entry for another tag
            c, n = k[len(prefix):].split("|", 1)
            if c == str(cp) and n and names_ok(n, name):
                return True
        return False

    def set_tagged(self, cp, name):
        self.data["tagged"][f"{alnum(cfg.TAG_NAME)}|{cp}|{alnum(name)}"] = time.time()
        self.save()

    def renamed(self, cp, name):
        """Did the bot give this Pokémon its name? (then it isn't a custom nickname). The CP may have
        changed since the renaming (powered up), so the same name is enough."""
        n, done = alnum(name), self.data.setdefault("renamed", {})
        return bool(n) and (f"{cp}|{n}" in done or any(k.split("|", 1)[-1] == n for k in done))

    def set_renamed(self, cp, name):
        self.data.setdefault("renamed", {})[f"{cp}|{alnum(name)}"] = time.time()
        self.save()

    def refused_name(self, name):
        """Did the game refuse this nickname before ("inappropriate text")? Its filter judges the text, so
        it would refuse it again."""
        return alnum(name) in self.data.setdefault("refused", {})

    def set_refused_name(self, name):
        self.data.setdefault("refused", {})[alnum(name)] = time.time()
        self.save()
