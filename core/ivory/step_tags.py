"""The tagging steps: an IV tag for everyone, the PvP league tags, the Battle tags the app picked, and
the sweep that tags the weak Pokémon for transfer. Each of them decides from the storage already read
and then sets the tags in bulk."""
import pokecalc

from . import config as cfg
from .output import emit, log, pokemon_count, T
from .records import Rec
from .ivtags import iv_tag
from .batch_passes import run_passes
from .inventory import ensure_scanned
from .monrec import identify_all, species_of


def fast_iv(bot, book2, mem, args, report, st):
    """Part 2, fast: whole storage → IV and tags of all of them via the ▶ arrow → add the right IV tags in
    bulk (best first) and remove the ones that don't fit."""
    ensure_scanned(bot, st, mem)
    if not st.iv_planned:
        add = {n: [] for _, n in cfg.IV_TAGS}
        drop = {n: [] for _, n in cfg.IV_TAGS}
        st.index_rec = {}
        for i, cell in enumerate(st.seq):
            rec = st.recs.get(i) or {}
            r = Rec(cell, 0)
            st.index_rec[i] = r
            book2.recs.append(r)
            r.iv, r.types = rec.get("iv"), rec.get("types")
            r.cached = bool(rec.get("cached"))
            if rec.get("removable"):
                r.status, r.note = "skip", T(f"má tag {cfg.TAG_NAME} – přeskakuji", f"has the {cfg.TAG_NAME} tag – skipping")
                continue
            if not r.iv:
                r.status, r.note = "failed", T("IV se nepodařilo přečíst", "couldn't read the IV")
                continue
            mem.set_iv(r.sig, r.iv, r.types, save=False)
            have = [h for h in (rec.get("have") or []) if h in drop]   # only IV tags from the current settings
            r.target = iv_tag(r.iv)
            r.had = r.target in have
            r.removed = [h for h in have if h != r.target]
            # "done" only once the tag is really set (a bulk batch can fail)
            r.status = "done" if r.had and not r.removed else "pending"
            r.note = r.target + (T(" (už měl)", " (already had it)") if r.had and not r.removed else "") + \
                (T(f" (odebrat: {', '.join(r.removed)})", f" (remove: {', '.join(r.removed)})") if r.removed else "")
            if not r.had:
                add[r.target].append(i)
            for h in r.removed:
                drop[h].append(i)
        st.passes = [(n, False, add[n]) for _, n in cfg.IV_TAGS if add[n]] + \
                    [(n, True, drop[n]) for _, n in cfg.IV_TAGS if drop[n]]
        st.pending = {}
        for _, _, ix in st.passes:
            for i in ix:
                st.pending[i] = st.pending.get(i, 0) + 1
        st.iv_planned = True
        mem.save()
        if st.passes:
            log(T("\n   Plán hromadného tagování: ", "\n   Bulk tagging plan: ") + ", ".join(
                f"{'−' if rm else '+'}{n} ({len(ix)})" for n, rm, ix in st.passes))

    def done(tag, remove, idxs):
        book2.progress += 1
        for i in idxs:
            st.pending[i] -= 1
            if st.pending[i] == 0:          # all changes for this Pokémon are done
                st.index_rec[i].status = "done"
                report.show_iv(st.index_rec[i])
    run_passes(bot, st, done)
    for i, r in st.index_rec.items():
        if r.status == "pending":            # the batch with its tag failed even on the third try
            r.status, r.note = "failed", f"{r.note} – " + (
                T("ve hře nenalezen (CP se asi přečetlo špatně)", "not found in the game (probably a misread CP)")
                if st.seq[i].get("miss", 0) >= 2 else T("tag se nepodařilo nastavit", "couldn't set the tag"))
    for r in st.index_rec.values():          # the ones that needed nothing (already had it / skipped / error)
        if r.status != "done" or (r.had and not r.removed):
            report.show_iv(r)


def fast_pvp(bot, mem, args, report, st):
    """Part 3: IV rank for the PvP leagues → league tags in bulk (add where the rank fits, remove where it
    no longer does)."""
    ensure_scanned(bot, st, mem)
    leagues = [lg for lg in cfg.PVP if cfg.PVP[lg]["enabled"]]
    if not st.pvp_planned:
        identify_all(st)
        add = {lg: [] for lg in leagues}
        drop = {lg: [] for lg in leagues}
        st.pvp_index = {}
        unknown = 0
        for i in sorted(st.recs):
            rec = st.recs[i]
            if not rec.get("iv") or rec.get("removable"):
                continue
            sid, level = species_of(rec)
            if not sid:
                unknown += 1
                continue
            ranks = {lg: pokecalc.league_rank(sid, rec["iv"], lg) for lg in leagues}
            rec["ranks"] = {lg: (r[0] if r else None) for lg, r in ranks.items()}
            tags = set(rec.get("tags") or [])
            want = []
            for lg in leagues:
                name = cfg.PVP[lg]["name"]
                ok = rec["ranks"][lg] is not None and rec["ranks"][lg] <= cfg.PVP[lg]["max_rank"]
                if ok:
                    want.append(name)
                    if name not in tags:
                        add[lg].append(i)
                elif name in tags:
                    drop[lg].append(i)
            rk = "  ".join(f"{pokecalc.LEAGUE_LETTER[lg]}{rec['ranks'][lg] or '–'}" for lg in leagues)
            dex = pokecalc.SPECIES[sid]["dex"]
            ivs = "/".join(f"{v:02d}" for v in rec["iv"])
            log(f"   CP{rec['cp']:<5} #{dex:04d}  {ivs}  {rk}  -> {', '.join(n.split()[0] for n in want) or '–'}")
            emit("pvp", cp=rec["cp"], name=rec["name"], dex=dex, iv=list(rec["iv"]), ranks=rec["ranks"], tags=want)
            if want:
                st.pvp_index[i] = want
        if unknown:
            log(T(f"   (u {pokemon_count(unknown)} se nepodařilo poznat druh – PvP pořadí nejde spočítat)",
                  f"   (couldn't recognize the species of {pokemon_count(unknown)} – no PvP rank for them)"))
        st.passes = [(cfg.PVP[lg]["name"], False, add[lg]) for lg in leagues if add[lg]] + \
                    [(cfg.PVP[lg]["name"], True, drop[lg]) for lg in leagues if drop[lg]]
        st.pvp_planned = True
        if st.passes:
            log(T("\n   Plán PvP tagů: ", "\n   PvP tag plan: ") + ", ".join(f"{'−' if rm else '+'}{n} ({len(ix)})" for n, rm, ix in st.passes))

    def done(tag, remove, idxs):
        report.pvp_tagged += 0 if remove else len(idxs)
        emit("tagged", tag=tag, color=cfg.tag_color(tag), remove=remove,
             items=[{"cp": st.seq[i]["cp"], "name": st.seq[i]["name"]} for i in idxs])
    run_passes(bot, st, done)


def fast_battle(bot, mem, args, report, st):
    """Part 5: Battle tags in bulk. The app picks the Pokémon (the best raid attackers of each type, the chosen
    PvP teams) and writes them into config.json by CP and IVs; a picked Pokémon gets the tag, anyone else who has
    it loses it. Pokémon tagged for transfer are left alone."""
    ensure_scanned(bot, st, mem)
    if not st.battle_planned:
        identify_all(st)                        # the species, so a pick survives a power-up (CP changes, IVs don't)
        groups = cfg.BATTLE["tags"]
        add = {g["name"]: [] for g in groups}
        drop = {g["name"]: [] for g in groups}
        found = {g["name"]: set() for g in groups}
        for i in sorted(st.recs):
            rec = st.recs[i]
            if not rec.get("iv"):
                continue
            iv, sid = tuple(rec["iv"]), rec.get("sid")
            tags = set(rec.get("tags") or [])
            for g in groups:
                # the same species with the same IVs is the same Pokémon even after a power-up; without a known
                # species fall back to the CP the app saw
                picked = next((m for m in g["mons"] if m["iv"] == iv
                               and (m["sid"] == sid if m.get("sid") and sid else m["cp"] == rec.get("cp"))), None)
                if picked:
                    found[g["name"]].add(id(picked))
                if picked and g["name"] not in tags:
                    add[g["name"]].append(i)
                elif not picked and g["name"] in tags:
                    drop[g["name"]].append(i)
        for g in groups:
            gone = len([m for m in g["mons"] if id(m) not in found[g["name"]]])
            if gone:
                log(T(f"   {g['name']}: {pokemon_count(gone)} z výběru v úložišti už není (přenesení, vylepšení?)",
                      f"   {g['name']}: {pokemon_count(gone)} of the picks aren't in the storage any more (transferred, powered up?)"))
        st.passes = [(n, False, ix) for n, ix in add.items() if ix] + [(n, True, ix) for n, ix in drop.items() if ix]
        st.battle_planned = True
        if st.passes:
            log(T("\n   Plán Battle tagů: ", "\n   Battle tag plan: ") + ", ".join(f"{'−' if rm else '+'}{n} ({len(ix)})" for n, rm, ix in st.passes))
        else:
            log(T("   Battle tagy už sedí, není co měnit.", "   The Battle tags already fit, nothing to change."))

    def done(tag, remove, idxs):
        report.battle_tagged += 0 if remove else len(idxs)
        emit("tagged", tag=tag, color=cfg.tag_color(tag), remove=remove,
             items=[{"cp": st.seq[i]["cp"], "name": st.seq[i]["name"]} for i in idxs])
    run_passes(bot, st, done)


def fast_weak(bot, mem, args, report, st):
    """Part 6: everyone under WEAK["max_iv"] % gets the tag for transferring. It runs last, so the PvP and Battle
    tags set earlier in this run already protect their Pokémon. The tag is only added, never taken off: the
    duplicates step and the user put it on for their own reasons."""
    ensure_scanned(bot, st, mem)
    if not st.weak_planned:
        identify_all(st)
        limit = cfg.WEAK["max_iv"]
        protected = set(cfg.PVP[lg]["name"] for lg in cfg.PVP) | set(cfg.battle_tags())
        keep_tag = cfg.WEAK["keep_tag"]
        best = {}                                   # species -> the best IV sum in the storage
        if cfg.WEAK["keep_best"]:
            for rec in st.recs.values():
                sid = (rec.get("sid") or "").split("_")[0]
                if sid and rec.get("iv"):
                    best[sid] = max(best.get(sid, -1), sum(rec["iv"]))
        add, kept = [], {}

        def skip(why):
            kept[why] = kept.get(why, 0) + 1

        for i in sorted(st.recs):
            rec = st.recs[i]
            if not rec.get("iv"):
                continue
            pct = round(sum(rec["iv"]) * 100 / 45)
            if pct >= limit:
                continue
            tags = set(rec.get("tags") or [])
            if cfg.TAG_NAME in tags:
                continue                            # already tagged (duplicates, or by hand)
            sid = rec.get("sid")
            sp_tags = set(pokecalc.SPECIES[sid]["tags"]) if sid in pokecalc.SPECIES else set()
            if cfg.WEAK["keep_legendary"] and "legendary" in sp_tags:
                skip(T("legendární", "legendary"))
            elif cfg.WEAK["keep_mythical"] and "mythical" in sp_tags:
                skip(T("mýtičtí", "mythical"))
            elif cfg.WEAK["keep_ultra_beast"] and "ultrabeast" in sp_tags:
                skip(T("ultra beasts", "ultra beasts"))
            elif cfg.WEAK["keep_regional"] and sp_tags & {"regional", "alolan", "galarian", "hisuian", "paldean"}:
                skip(T("regionální formy", "regional forms"))
            elif cfg.WEAK["keep_battle"] and tags & protected:
                skip(T("PvP a Battle tagy", "PvP and Battle tags"))
            elif keep_tag and keep_tag in tags:
                skip(keep_tag)
            elif cfg.WEAK["keep_best"] and sid and best.get((sid or "").split("_")[0]) == sum(rec["iv"]):
                skip(T("nejlepší svého druhu", "the best of its species"))
            else:
                add.append(i)
                log(f"   CP{rec['cp']:<5} {pct:>3} %  {rec['name']}  -> {cfg.TAG_NAME}")
        st.passes = [(cfg.TAG_NAME, False, add)] if add else []
        st.weak_planned = True
        if kept:
            log(T("   Chráněné (netagují se): ", "   Protected (left alone): ")
                + ", ".join(f"{n} {v}×" for n, v in sorted(kept.items())))
        log(T(f"\n   Pod {limit} % IV: {pokemon_count(len(add))} dostane tag {cfg.TAG_NAME}.",
              f"\n   Under {limit}% IV: {pokemon_count(len(add))} will get the {cfg.TAG_NAME} tag."))

    def done(tag, remove, idxs):
        report.weak_tagged += len(idxs)
        emit("tagged", tag=tag, color=cfg.tag_color(tag), remove=remove,
             items=[{"cp": st.seq[i]["cp"], "name": st.seq[i]["name"]} for i in idxs])
    run_passes(bot, st, done)
