"""The run report: group and IV lines for the log and the app, the result files and the summary."""
import json
import time

from . import config as cfg
from .output import emit, log, T
from .vision import norm
from .grid import PLAIN_NAME


def iv_pct(iv):
    return round(sum(iv) * 100 / 45) if iv else None


def species_title(group):
    names = [r.name for r in group if PLAIN_NAME.match(norm(r.name))] or [r.name for r in group]
    return max(set(names), key=names.count) if names else "?"


class Report:
    def __init__(self, run_dir, max_groups):
        self.dir, self.max = run_dir, max_groups
        self.t0 = time.time()
        self.shown, self.sent = {}, {}
        self.measured = 0
        self.pvp_tagged = 0
        self.renamed = 0
        self.battle_tagged = 0
        self.weak_tagged = 0

    def limit_reached(self, book):
        return bool(self.max) and book.groups_done() >= self.max

    def show(self, book, gid, quiet=False):
        """A group of the same Pokémon: each one's IVs and what the bot will do with it.
        quiet = only the event for the app."""
        group = book.group(gid)
        lines = []
        for r in group:
            ivs = "/".join(f"{v:>2}" for v in r.iv) if r.iv else " ?/ ?/ ?"
            pct = f"{sum(r.iv) / 45:4.0%}" if r.iv else "   ?"
            act = {"keep": T("nechat", "keep"), "remove": f"tag {cfg.TAG_NAME}"}.get(
                r.action, T("nezměřeno", "not measured") if r.status == "failed" else "?")
            flags = (T(" ✔ označeno", " ✔ tagged") if r.tagged else "") + \
                (T(" (IV z paměti)", " (IV from memory)") if r.cached else "") + \
                (T(" (stejné CP i jméno – nejde rozlišit, neoznačuji)", " (same CP and name – can't tell apart, not tagging)")
                 if r.ambiguous and r.action == "remove" else "")
            lines.append(f"   CP{r.cp:<5} {ivs}  {pct}  -> {act}{flags}")
        title = species_title(group)
        text = T(f"\n── Skupina: {title} ({len(group)}×)\n", f"\n── Group: {title} ({len(group)}×)\n") + "\n".join(lines)
        if not quiet and self.shown.get(gid) != text:
            self.shown[gid] = text
            log(text)
        payload = {"id": gid, "title": title, "tag": cfg.TAG_NAME, "color": cfg.TAG_COLOR, "items": [{
            "cp": r.cp, "name": r.name, "iv": list(r.iv) if r.iv else None, "pct": iv_pct(r.iv),
            "action": r.action, "tagged": r.tagged, "cached": r.cached, "failed": r.status == "failed",
            "ambiguous": r.ambiguous} for r in group]}
        key = json.dumps(payload, sort_keys=True)
        if self.sent.get(gid) != key:
            self.sent[gid] = key
            emit("group", **payload)

    def show_iv(self, r):
        """Part 2: one Pokémon and its IV tag."""
        ivs = "/".join(f"{v:>2}" for v in r.iv) if r.iv else " ?/ ?/ ?"
        pct = f"{sum(r.iv) / 45:4.0%}" if r.iv else "   ?"
        log(f"   CP{r.cp:<5} {r.name[:16]:16s} {ivs} {pct}  -> {r.note}" + (T(" (IV z paměti)", " (IV from memory)") if r.cached else ""))
        emit("iv", cp=r.cp, name=r.name, iv=list(r.iv) if r.iv else None, pct=iv_pct(r.iv), status=r.status,
             tag=r.target, color=cfg.tag_color(r.target) if r.target else None, had=r.had, removed=r.removed,
             note=r.note, cached=r.cached)

    def save_iv(self, book2):
        if book2.recs:
            out = [{"cp": r.cp, "name": r.name, "iv": list(r.iv) if r.iv else None, "status": r.status,
                    "tag": r.target, "note": r.note} for r in book2.recs]
            (self.dir / "result_iv_tagy.json").write_text(json.dumps(out, ensure_ascii=False, indent=1))

    def summary_iv(self, book2):
        if not book2.recs:
            return {}
        log(T("\n------ 2. část: IV tagy ------", "\n------ Part 2: IV tags ------"))
        done = [r for r in book2.recs if r.status == "done"]
        per_tag = []
        for _, name in cfg.IV_TAGS:
            n = sum(1 for r in done if r.target == name)
            if n:
                log(f"   {name:16s} {n}×")
                per_tag.append({"name": name, "color": cfg.tag_color(name), "count": n})
        out = {"seen": len(book2.recs), "tagged": sum(1 for r in done if not r.had),
               "had": sum(1 for r in done if r.had), "skipped": sum(r.status == "skip" for r in book2.recs),
               "failed": sum(r.status in ("failed", "pending") for r in book2.recs), "per_tag": per_tag}
        log(T(f"Prošlo: {out['seen']}, nově otagováno: {out['tagged']}, tag už měli: {out['had']}, "
              f"přeskočeno: {out['skipped']}, nepovedlo se: {out['failed']}",
              f"Checked: {out['seen']}, newly tagged: {out['tagged']}, already tagged: {out['had']}, "
              f"skipped: {out['skipped']}, failed: {out['failed']}"))
        return out

    def save(self, book):
        out = [{"group": r.gid, "cp": r.cp, "name": r.name, "iv": list(r.iv) if r.iv else None,
                "types": r.types, "action": r.action, "tagged": r.tagged, "status": r.status,
                "from_memory": r.cached, "ambiguous": r.ambiguous}
               for r in book.recs if r.status != "single"]
        (self.dir / "result.json").write_text(json.dumps(out, ensure_ascii=False, indent=1))

    def summary(self, book):
        dt = time.time() - self.t0
        recs = [r for r in book.recs if r.status != "single"]
        rem = [r for r in recs if r.action == "remove"]
        left = [r for r in rem if not r.tagged]
        out = {"minutes": round(dt / 60, 1), "groups": len(book.groups()), "pokemon": len(recs),
               "measured": self.measured, "cached": sum(r.cached for r in recs),
               "failed": sum(r.status == "failed" for r in recs), "removable": sum(r.tagged for r in rem),
               "removable_total": len(rem), "left": [f"{r.name} CP{r.cp}" for r in left]}
        log(T("\n================ SHRNUTÍ ================", "\n================ SUMMARY ================"))
        if recs:
            log(T(f"Skupin stejných Pokémonů: {out['groups']}, Pokémonů v nich: {out['pokemon']}",
                  f"Groups of the same Pokémon: {out['groups']}, Pokémon in them: {out['pokemon']}"))
            log(T(f"Změřeno teď: {out['measured']}, z paměti: {out['cached']}, nepodařilo se změřit: {out['failed']}",
                  f"Measured now: {out['measured']}, from memory: {out['cached']}, couldn't measure: {out['failed']}"))
            log(T(f"Tag {cfg.TAG_NAME} dostalo: {out['removable']} z {out['removable_total']}",
                  f"Got the {cfg.TAG_NAME} tag: {out['removable']} of {out['removable_total']}"))
            if left:
                log(T("Bez tagu zůstali (zkontroluj ručně): ", "Left without the tag (check them yourself): ") +
                    ", ".join(out["left"]))
        log(T(f"Čas: {dt / 60:.1f} min", f"Time: {dt / 60:.1f} min") +
            (T(f", {dt / self.measured:.1f} s na změřeného Pokémona", f", {dt / self.measured:.1f} s per measured Pokémon")
             if self.measured else ""))
        return out
