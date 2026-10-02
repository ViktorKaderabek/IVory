import io, json, os, time
os.environ["POGO_NO_STREAM"] = "1"
import numpy as np
from PIL import Image
import sys as _sys
from pathlib import Path as _Path
_sys.path.insert(0, str(_Path(__file__).resolve().parents[1] / "core"))
_sys.path.insert(0, str(_Path(__file__).resolve().parent))
import pogo_bot as S
R = os.environ.get("POGO_SCREENS", os.path.expanduser("~/Desktop/pogo_runs/")).rstrip("/") + "/"
def load(f, rescale=0.75):
    img = Image.open(R + f + ".png").convert("RGB")
    img = img.resize((int(img.width * rescale), int(img.height * rescale)), Image.LANCZOS)
    b = io.BytesIO(); img.save(b, "JPEG", quality=60)
    return S.Frame(np.array(img), b.getvalue(), time.time())

class FakeBot:  # jen pro guard
    def __init__(self, fr): self.fr = fr
    def streaming(self): return True
    def frame(self): return self.fr
guard = lambda fr, x, y, label="t": S.Bot.guard(FakeBot(fr), x, y, label, fr)
def try_guard(fr, x, y, label="t"):
    try: guard(fr, x, y, label); return "OK"
    except S.Danger as e: return "BLOK: " + str(e)[:70]

print("== pojistka")
ms = load("20261002_161252/34_vybrano_1")
print(" multiselect TAG count:", S.tag_count(ms.texts), "| tlačítko:", S.tag_button(ms.texts)["text"], round(S.tag_button(ms.texts)["cy"],3))
tb = S.tag_button(ms.texts)
for (x, y, l) in [(tb["cx"], tb["cy"], "TAG"), (0.12, 0.93, "stará záloha 0.93"), (0.5, 0.94, "X dole"), (0.5, 0.77+0.03, "výběr řádek 4"), (0.107, 0.117, "zrušit")]:
    print(f"  {l:20s}", try_guard(ms, x, y))
for f in ["20261002_161252/16_detail_cp487_check_0", "20261002_155706/23_tap_zav_t_appraisal"]:
    d = load(f)
    print(" detail:", f.split('/')[-1])
    for (x, y, l) in [(0.5, 0.80, "stará appraisal 0.80"), (0.5, 0.30, "P_NEUTRAL"), (0.87, 0.94, "menu ≡"), (0.5, 0.94, "X")]:
        print(f"  {l:20s}", try_guard(d, x, y))
td = load("20261002_161252/36_tag_button_check_0")
print(" transfer dialog: klasifikace", S.classify(td))
print("  tap CANCEL      ", try_guard(td, 0.5, 0.643, "CANCEL"))
print("  tap jiný        ", try_guard(td, 0.5, 0.30, "něco"))
ev = load("20261002_155706/24_tap_zav_t")
print(" evolve dialog: klasifikace", S.classify(ev), "| NO:", S.find_text(ev.texts, ["no","cancel"], exact=True)["cy"])
print("  tap YES         ", try_guard(ev, 0.5, 0.597, "x"))
print("  tap NO          ", try_guard(ev, 0.5, 0.662, "NO"))
dm = load("20261002_161252/17_menu_cp487_check_0")
ap = S.find_text(dm.texts, ["appraise"], exact=True)
print(" detail menu APPRAISE", round(ap["cy"],3), try_guard(dm, ap["cx"], ap["cy"]), "| ≡ zavřít", try_guard(dm, 0.87, 0.94))

print("\n== detail")
d = load("20261002_161252/16_detail_cp487_check_0")
print(" cp", S.detail_cp(d.texts), "jméno", S.detail_name(d.texts), "typy", S.detail_types(d.texts))

print("\n== mřížka a skupiny")
for f in ["20261002_161252/15_grid", "20261002_160212/22_grid", "20261002_161252/04_menu_pokemon_check_0", "20261002_161252/34_vybrano_1"]:
    fr = load(f)
    cells = S.with_details(S.complete_cells(fr.texts), fr)
    runs = S.make_runs(cells)
    print(f" {f.split('/')[-1]}: filtr={S.filter_key(S.search_bar_text(fr.texts))!r}")
    print("   ", " | ".join("+".join(f"{c['cp']}:{c['name'][:10]}" for c in r) for r in runs))

print("\n== bary")
for f in ["20261002_161252/21_bars_cp487", "20261002_161252/29_bars_cp482", "20261002_160212/31_bars_cp691", "20261002_160212/44_bars_cp553", "20261002_160212/57_bars_cp543", "20261002_160212/70_bars_cp416"]:
    for sc in (1.0, 0.75):
        fr = load(f, sc)
        labs = S.bar_labels(fr.texts)
        vals = tuple(S.read_bar(fr.img, l)[0] for l in labs) if labs else None
        print(f"  {f.split('/')[-1]:16s} scale {sc}: {vals}")

print("\n== mapa")
for f in ["20261002_161252/01_map", "20261002_161252/02_menu", "20261002_161252/15_grid"]:
    print(" ", f.split('/')[-1], S.is_map(load(f).img))
