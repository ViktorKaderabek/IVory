"""One Pokémon as the bot read it, worked out from what the detail screen showed: which species and
level it is, what the app shows about it while reading, and the chip values for the name template.

The species doesn't always follow from CP and HP alone (a nickname hides the name), so `identify_all`
decides the leftovers from the neighbours: the storage is sorted by Pokédex number, so a Pokémon's
number lies between its neighbours' numbers.
"""
import pokecalc

from .ivtags import iv_tag


def species_of(rec):
    """Species and level of a Pokémon (computed once and stored in the record)."""
    if "sid" not in rec:
        rec["sid"], rec["level"] = (None, None)
        if rec.get("iv") and rec.get("cp"):
            rec["sid"], rec["level"] = pokecalc.identify(rec.get("name"), rec.get("types"), rec["cp"], rec.get("hp"),
                                                         rec["iv"], rec.get("candy"))
    return rec["sid"], rec["level"]
def live_mon(rec):
    """What the app shows in "Now reading" about the Pokémon the bot just read: besides CP, name and IV
    also the species (the app draws its picture from the dex number), level, types and the IV tag it is
    going to get. The species is identified the same way identify_all does it first; when CP and HP fit
    several species it stays None until the neighbors decide, and the app then shows no picture."""
    sid, level = species_of(rec)
    sp = pokecalc.SPECIES.get(sid or "")
    iv = rec.get("iv")
    return {"cp": rec.get("cp"), "name": rec.get("name"), "iv": list(iv) if iv else None,
            "sid": sid, "dex": sp["dex"] if sp else None, "level": level,
            "types": rec.get("types") or [], "hp": rec.get("hp"),
            "pct": round(sum(iv) * 100 / 45) if iv else None,
            "tag": iv_tag(iv) if iv else None, "have": rec.get("have") or []}
def identify_all(st):
    """Species of every Pokémon. Where CP and HP fit several species (a nickname), the neighbors decide:
    the storage is sorted by Pokédex number, so a Pokémon's number lies between its neighbors' numbers."""
    if st.identified:
        return
    order = sorted(st.recs)
    for i in order:
        species_of(st.recs[i])
    dex = {i: pokecalc.SPECIES[st.recs[i]["sid"]]["dex"] for i in order if st.recs[i].get("sid")}
    for i in order:
        rec = st.recs[i]
        if rec.get("sid") or not rec.get("iv") or not rec.get("cp"):
            continue
        lo = max((d for j, d in dex.items() if j < i), default=1)
        hi = min((d for j, d in dex.items() if j > i), default=99999)
        rec["sid"], rec["level"] = pokecalc.identify(rec.get("name"), rec.get("types"), rec["cp"], rec.get("hp"),
                                                     rec["iv"], rec.get("candy"), dex_range=(lo, hi))
    st.identified = True
def rename_values(rec):
    """Name template chip values for a Pokémon (only the IV ones when the species is unknown)."""
    iv = rec["iv"]
    sid, level = species_of(rec)
    if sid:
        return pokecalc.chip_values(pokecalc.info(sid, iv, level, rec["cp"]), iv)
    return pokecalc.iv_values(iv)
