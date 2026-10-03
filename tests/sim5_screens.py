"""Kontrola simulátoru sim5: každou nakreslenou obrazovku pošle botovi a vypíše, jak ji poznal.
Uloží i obrázky do dočasné složky (na prohlédnutí)."""
import sys, numpy as np
import sim5
from sim5 import S, Phone, make_mons

mons = make_mons(3)
p = Phone(mons, existing_tags=[("Mega", "orange"), ("100% Perfect", "purple"), ("Removable", "red")])
p.cur = 1
cases = {"map": {}, "menu": {}, "grid": {}, "search": {"kb": True}, "sort_menu": {}, "detail": {}, "intro": {},
         "bars": {}, "dmenu": {}, "multi": {"sel": {0, 1}}, "taglist": {"list_targets": [1]},
         "create": {"kb": False}, "create_kb": {"kb": True, "typed": "95-99% Insane"},
         "grid_filtered": {"filtered": True, "query": sim5.QUERY}}
out = sim5.TMP / "screens"; out.mkdir(exist_ok=True)
for name, attrs in cases.items():
    for k, v in attrs.items():
        setattr(p, k, v)
    p.state = name.replace("_kb", "").replace("_filtered", "")
    raw = p.get_screenshot_as_png()
    from PIL import Image
    import io
    img = np.array(Image.open(io.BytesIO(raw)).convert("RGB"))
    fr = S.Frame(img, raw, 0)
    st = S.classify(fr)
    extra = ""
    if name.startswith("grid"):
        extra = f" cells={len(S.complete_cells(fr.texts))} filtr={S.filter_key(S.search_bar_text(fr.texts))!r}"
    if name == "bars":
        labs = S.bar_labels(fr.texts)
        extra = f" iv={S.read_bars(fr.img, labs)[0] if labs else None} pravda={mons[1]['iv']}"
    if name.startswith("create"):
        sw = S.find_swatches(fr.img)
        extra = f" koleček={len(sw)} barvy={[S.nearest_swatch(sw, c)['cx'].__round__(2) for c in S.TAG_PALETTE] if sw else None}"
    if name == "detail":
        extra = f" cp={S.detail_cp(fr.texts)} jméno={S.detail_name(fr.texts)} typy={S.detail_types(fr.texts)}"
    if name == "sort_menu":
        t = S.find_text(fr.texts, ["number"], exact=True)
        extra = f" NUMBER aktivní={S.sort_active(fr.img, t) if t else None}"
    if name == "search":
        extra = f" klávesnice={S.keyboard_on(fr.texts)}"
    Image.fromarray(img).save(out / f"{name}.jpg")
    print(f"{name:14s} -> {st:16s}{extra}")
for k, v in [("filtered", False), ("query", "")]:
    setattr(p, k, v)
print("obrázky:", out)
