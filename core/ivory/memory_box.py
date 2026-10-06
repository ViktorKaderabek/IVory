"""The memory between runs: which Pokémon the bot already knows (so it doesn't read them again), and
what it writes back about the storage afterwards – for the next run and for the app."""
import difflib
import json
import time

import pokecalc

from . import config as cfg
from .vision import alnum
from .grid import names_ok
from .monrec import rename_values


CACHE_KEYS = ("cp", "name", "types", "hp", "candy", "iv", "have", "removable", "tags", "sid", "level", "t")


def same_name(a, b):
    """Grid name across two runs: OCR may differ by a letter, but not by species (Pidgey ≠ Pidgeot)."""
    a, b = alnum(a), alnum(b)
    if not a or not b:
        return False
    if a == b or names_ok(a, b):
        return True
    return min(len(a), len(b)) >= 6 and difflib.SequenceMatcher(None, a, b).ratio() >= 0.85


def from_memory(st, mem):
    """Repeat run: Pokémon the bot knows from last time (same CP and name in the list, and exactly one
    such entry in memory) are not read again – IV, types, HP and tags come from memory. The name is
    compared with both the grid name and the detail-screen name (it may have been missing from the grid
    last time). Returns the number of such Pokémon."""
    by_cp = {}
    for it in mem.box_items():
        if it.get("iv"):
            by_cp.setdefault(it.get("gcp"), []).append(it)
    hits = {}
    cp_count = {}
    for c in st.seq:
        cp_count[c["cp"]] = cp_count.get(c["cp"], 0) + 1
    for i, c in enumerate(st.seq):
        known = by_cp.get(c["cp"], [])
        cands = [it for it in known
                 if same_name(c["name"], it.get("gname") or "") or same_name(c["name"], it.get("name") or "")]
        if not cands and not alnum(c["name"]) and len(known) == 1 and cp_count[c["cp"]] == 1:
            cands = known              # OCR missed the name – this CP appears only once in the list and in memory
        if len(cands) == 1:
            hits[i] = cands[0]
    uses = {}
    for it in hits.values():
        uses[id(it)] = uses.get(id(it), 0) + 1
    n = 0
    for i, it in hits.items():
        if uses[id(it)] > 1 or i in st.recs:
            continue                   # two cells for one entry (same CP and name) – better read them
        rec = {k: it.get(k) for k in CACHE_KEYS}
        rec["iv"] = tuple(rec["iv"])
        rec["tags"] = list(rec.get("tags") or [])
        # Which of these are IV tags, and whether it has the TAG_NAME tag, by the current settings (tag
        # names may have changed since last time)
        ivnames = {n for _, n in cfg.IV_TAGS}
        rec["have"] = [t for t in rec["tags"] if t in ivnames]
        rec["removable"] = cfg.TAG_NAME in rec["tags"]
        rec["cached"] = True
        if not rec.get("sid"):
            rec.pop("sid", None)       # recognize the species again (neighbors in the list help)
            rec.pop("level", None)
        st.recs[i] = rec
        n += 1
    return n


def remember_box(st, mem, whole, complete=False):
    """Memory for the next run: what is known about each Pokémon now (IV, types, tags after tagging, name
    after renaming). Nothing is deleted by age – memory is reconciled with the storage:
    - whole = st is the whole storage. complete = it was also read in full (without memory), so whatever
      isn't in it isn't in the game – it gets deleted.
    - whole storage, read with memory: a Pokémon that wasn't in the list is deleted if it had the TAG_NAME
      tag (most likely transferred), or if it was missing for the second time in a row (grid OCR
      sometimes misses a cell).
    - only part of the storage (a list from a search): other entries are not affected.
    The comparison is with the memory from the start of the run, so saving repeatedly during one run
    duplicates nothing."""
    if mem is None or not st.seq:
        return
    now = time.time()
    items = []
    for i in sorted(st.recs):
        rec = st.recs[i]
        cell = st.seq[i] if i < len(st.seq) else None
        if cell is None or not rec.get("iv") or cell.get("cp") is None:
            continue
        it = {k: rec.get(k) for k in CACHE_KEYS}
        it["iv"] = list(rec["iv"])
        it["t"] = rec.get("t") or now
        # Grid name (it identifies the Pokémon next time); if OCR missed it, the detail-screen name
        it["gcp"], it["gname"] = cell["cp"], cell.get("name") or rec.get("name") or ""
        items.append(it)
    if not (whole and complete):
        by_cp, by_iv = {}, set()
        for it in items:
            by_cp.setdefault(it["gcp"], []).append(it["gname"])
            by_iv.add((it.get("cp"), tuple(it["iv"])))

        def superseded(old):
            if (old.get("cp"), tuple(old.get("iv") or ())) in by_iv:
                return True            # same Pokémon, just renamed in the meantime
            return any(same_name(g, old.get("gname") or "") for g in by_cp.get(old.get("gcp"), []))
        for old in mem.box_start:
            if superseded(old):
                continue
            if whole:
                misses = old.get("misses", 0) + 1
                if old.get("removable") or misses >= 2:
                    continue           # no longer in the game (transferred)
                old = dict(old, misses=misses)
            items.append(old)
    mem.set_box(items)


def save_box(st, mem):
    """For the app: an overview of the storage that was read (~/.pogo/last_box.json) – the number of
    Pokémon in an IV range and the sample names in the renaming settings."""
    out = []
    for i in sorted(st.recs):
        rec = st.recs[i]
        if not rec.get("iv"):
            continue
        name = rec.get("name") or ""
        out.append({"cp": rec["cp"], "name": name, "iv": list(rec["iv"]), "tags": rec.get("tags") or [],
                    "custom": not pokecalc.is_species_name(name) and not mem.renamed(rec["cp"], name),
                    "values": rename_values(rec)})
    try:
        tmp = cfg.BOX_FILE.with_name(cfg.BOX_FILE.name + ".tmp")
        tmp.write_text(json.dumps({"t": time.time(), "items": out}, ensure_ascii=False))
        tmp.replace(cfg.BOX_FILE)
    except OSError:
        pass
