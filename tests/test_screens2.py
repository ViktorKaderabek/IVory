import io, json, glob, os, sys, time
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
out = {}
for p in sorted(glob.glob(R + "2026100*/*.png")):
    f = p[len(R):-4]
    fr = load(f)
    st = S.classify(fr)
    out.setdefault(st, []).append(f.split("/")[-1])
for st, fs in out.items():
    print(f"{st:16s} {len(fs):3d}  {fs}")
