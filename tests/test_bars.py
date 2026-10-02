import io, os, time, glob
os.environ["POGO_NO_STREAM"] = "1"
import numpy as np
from PIL import Image
import sys as _sys
from pathlib import Path as _Path
_sys.path.insert(0, str(_Path(__file__).resolve().parents[1] / "core"))
_sys.path.insert(0, str(_Path(__file__).resolve().parent))
import pogo_bot as S
R = os.environ.get("POGO_SCREENS", os.path.expanduser("~/Desktop/pogo_runs/")).rstrip("/") + "/"
truth = {"487": (14,15,15), "482": (14,15,12), "691": (15,14,13), "553": (15,13,14), "543": (11,15,15), "416": (15,13,15)}
cases = [("20261002_155706/09_tap_zav_t_appraisal","487"),("20261002_155706/12_tap_zav_t_appraisal","487"),
         ("20261002_155706/21_tap_zav_t_appraisal","482"),("20261002_160212/32_tap_appraisal_zavrit_cp691_0","691"),
         ("20261002_160212/45_tap_appraisal_zavrit_cp553_0","553"),("20261002_160212/58_tap_appraisal_zavrit_cp543_0","543"),
         ("20261002_160212/71_tap_appraisal_zavrit_cp416_0","416"),
         # debug snímky s nakreslenými čarami (jen orientačně)
         ("20261002_161252/21_bars_cp487","487"),("20261002_161252/29_bars_cp482","482"),("20261002_160212/31_bars_cp691","691"),
         ("20261002_160212/44_bars_cp553","553"),("20261002_160212/57_bars_cp543","543"),("20261002_160212/70_bars_cp416","416")]
def load(f, sc, q=60):
    img = Image.open(R + f + ".png").convert("RGB")
    if sc != 1.0: img = img.resize((int(img.width*sc), int(img.height*sc)), Image.LANCZOS)
    b = io.BytesIO(); img.save(b, "JPEG", quality=q)
    return S.Frame(np.array(img), b.getvalue(), time.time())
bad = 0
for f, cp in cases:
    res = []
    for sc, q in ((1.0, 95), (0.75, 60), (0.75, 40), (0.5, 60)):
        fr = load(f, sc, q)
        labs = S.bar_labels(fr.texts)
        vals = S.read_bars(fr.img, labs)[0] if labs else "bez popisků"
        ok = vals == truth[cp]
        bad += (not ok) and "bars" not in f
        res.append(f"{sc}/q{q}: {vals}{'' if ok else ' ✗'}")
    print(f"CP{cp} {f.split('/')[-1][:28]:28s} pravda {truth[cp]}  " + "  ".join(res))
print("chyb na čistých snímcích:", bad)
