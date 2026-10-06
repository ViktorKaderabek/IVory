"""Running the bulk taggings a step planned: each pass is one tag and the list of Pokémon that should
get or lose it, split into searches of at most SEARCH_BATCH CPs."""
from . import config as cfg
from .errors import Fatal, NeedTop, StepError, TagCreated
from .output import emit, log, pokemon_count, T
from .scanstate import emit_counts
from .batch import tag_batch


def note_tag(rec, tag, remove):
    """After bulk tagging: updates the Pokémon's record to match the game now (memory for the next run)."""
    if rec is None:
        return
    rec["tags"] = [t for t in (rec.get("tags") or []) if t != tag] + ([] if remove else [tag])
    if tag in {n for _, n in cfg.IV_TAGS}:
        rec["have"] = [t for t in (rec.get("have") or []) if t != tag] + ([] if remove else [tag])
    if tag == cfg.TAG_NAME:
        rec["removable"] = not remove


def run_passes(bot, st, on_done):
    """Runs the remaining bulk taggings (st.passes); after each batch calls on_done(tag, remove, indexes).
    Tags in st.seq (with the search st.tag_base) or, when the duplicates step took its data from a fully
    read storage, in st.tag_full.seq through the index mapping st.tag_map. Pokémon the game can't find
    by CP are skipped and the run goes on."""
    full, fwd = getattr(st, "tag_full", None), getattr(st, "tag_map", None)
    back = {j: i for i, j in fwd.items()} if full is not None else None
    cell = (lambda i: full.seq[fwd[i]]) if full is not None else (lambda i: st.seq[i])
    while st.passes:
        tag, remove, idxs = st.passes[0]
        if full is not None:
            idxs = [i for i in idxs if i in fwd]
        if not idxs:
            st.passes.pop(0)
            continue
        try:
            if full is not None:
                done, gone = tag_batch(bot, full.seq, [fwd[i] for i in idxs], tag, remove)
                done, gone = [back[j] for j in done], [back[j] for j in gone]
            else:
                done, gone = tag_batch(bot, st.seq, idxs, tag, remove, getattr(st, "tag_base", None))
        except (Fatal, TagCreated, NeedTop):
            raise
        except StepError:
            st.pass_fails += 1
            if st.pass_fails >= 3:      # these Pokémon can't be selected – skip them so the run doesn't stall
                log(T(f"   ✖ tag {tag} se u {pokemon_count(len(idxs))} nepodařilo nastavit, vynechávám je",
                      f"   ✖ couldn't set tag {tag} for {pokemon_count(len(idxs))}, skipping them"))
                emit("problem", text=T(f"Tag {tag} se u {pokemon_count(len(idxs))} nepodařilo nastavit – "
                                       f"zkontroluj je ručně.",
                                       f"Couldn't set tag {tag} for {pokemon_count(len(idxs))} – check them yourself."))
                st.passes.pop(0)
                st.pass_fails = 0
                continue
            raise
        st.pass_fails = 0
        bot.progress += len(done)
        if tag in bot.tag_counts or not remove:
            bot.tag_counts[tag] = max(0, bot.tag_counts.get(tag, 0) + (-len(done) if remove else len(done)))
            emit_counts(bot, tag, -len(done) if remove else len(done))
        on_done(tag, remove, done)
        for i in done:
            note_tag(full.recs.get(fwd[i]) if full is not None else st.recs.get(i), tag, remove)
        if gone:
            cps = ", ".join(f"CP{cell(i)['cp']}" for i in gone)
            log(T(f"   ✖ tag {tag} vynechávám u {cps} – hledání podle CP je ve hře nenašlo (CP se nejspíš přečetlo špatně)",
                  f"   ✖ skipping tag {tag} for {cps} – the CP search didn't find them in the game (probably a misread CP)"))
            new = [i for i in gone if not cell(i).get("miss_noted")]
            for i in new:
                cell(i)["miss_noted"] = True
            if new:
                emit("problem", text=T(f"{pokemon_count(len(new))} se ve hře nepodařilo najít podle CP (nejspíš "
                                       f"špatně přečtené CP) – zkontroluj je ručně.",
                                       f"Couldn't find {pokemon_count(len(new))} in the game by CP (probably a misread "
                                       f"CP) – check them yourself."))
        skip = set(done) | set(gone)
        st.passes[0] = (tag, remove, [i for i in idxs if i not in skip])
