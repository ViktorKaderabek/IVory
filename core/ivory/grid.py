"""The Pokémon grid in the storage: cells, sprites, names and groups of the same species."""
import difflib
import re

import cv2
import numpy as np

import pokecalc

from . import config as cfg
from .vision import alnum, cp_value, crop_norm, norm


PLAIN_NAME = re.compile(r"^[a-z][a-z'.\-]{2,}$")


def grid_cells(texts):
    """Storage cells found by their 'CP1234' texts (also when split into 'CP' + '1234'), row by row."""
    cells = []
    for t in texts:
        v = cp_value(t["text"])
        if v is not None:
            cells.append({"cx": t["cx"], "cy": t["cy"], "cp": v})
    nums = [t for t in texts if re.fullmatch(r"\d{2,5}", t["text"].strip())]
    for c in (t for t in texts if alnum(t["text"]) == "cp"):
        for n in nums:
            if abs(n["cy"] - c["cy"]) < 0.012 and -0.01 < n["x0"] - c["x1"] < 0.05:
                cells.append({"cx": (c["x0"] + n["x1"]) / 2, "cy": n["cy"], "cp": int(n["text"].strip())})
                break
    cells.sort(key=lambda c: c["cy"])
    rows, cur = [], []
    for c in cells:
        if cur and c["cy"] - cur[0]["cy"] > 0.03:
            rows.append(cur)
            cur = []
        cur.append(c)
    if cur:
        rows.append(cur)
    out = []
    for i, row in enumerate(rows):
        for c in sorted(row, key=lambda c: c["cx"]):
            c["row"] = i
            out.append(c)
    return out


def complete_cells(texts):
    return [c for c in grid_cells(texts) if cfg.GRID_TOP <= c["cy"] <= cfg.GRID_BOTTOM]


def sprite_of(img, cell):
    return crop_norm(img, cell["cx"] - cfg.SPRITE_HALF_W, cell["cy"] + cfg.SPRITE_TOP,
                     cell["cx"] + cfg.SPRITE_HALF_W, cell["cy"] + cfg.SPRITE_BOTTOM)


def _sim1(a, b):
    return float(cv2.matchTemplate(b, a[6:58, 6:58], cv2.TM_CCOEFF_NORMED).max())


def sprite_sim(a, b):
    """Sprite similarity 0-1; tolerates a shift of a few pixels."""
    if a is None or b is None or a.size == 0 or b.size == 0:
        return 0.0
    a = cv2.resize(a, (64, 64), interpolation=cv2.INTER_AREA).astype(np.float32)
    b = cv2.resize(b, (64, 64), interpolation=cv2.INTER_AREA).astype(np.float32)
    if a.std() < 2 or b.std() < 2:
        return 0.0
    return max(_sim1(a, b), _sim1(b, a))


def name_of(texts, cell):
    best, bd = None, 9.0
    for t in texts:
        dy = t["cy"] - cell["cy"]
        if cfg.NAME_DY[0] < dy < cfg.NAME_DY[1] and abs(t["cx"] - cell["cx"]) < 0.13 and cp_value(t["text"]) is None:
            d = abs(t["cx"] - cell["cx"])
            if d < bd:
                best, bd = t["text"], d
    return re.sub(r"^[^A-Za-zÀ-ž0-9]+", "", best).strip() if best else ""


def split_names(texts):
    """OCR merges the long nicknames of a whole grid row into one text ("• MAX 3159 L18 •MAX 1675 L7
    •MAX 3184L22" across the full width). Such a text is split into names at the tag dots, and each name gets
    a position from where it lies in the text; otherwise the middle cell would get the whole row and the
    outer ones nothing."""
    out = []
    for t in texts:
        s = t["text"]
        if t["x1"] - t["x0"] < 0.42 or s.count("•") < 1:
            out.append(t)
            continue
        parts = [(m.start(), m.group()) for m in re.finditer(r"[^•]+", s) if m.group().strip()]
        if len(parts) < 2:
            out.append(t)
            continue
        w = t["x1"] - t["x0"]
        for start, part in parts:
            a, b = start / len(s), (start + len(part)) / len(s)
            out.append(dict(t, text=part.strip(), x0=t["x0"] + a * w, x1=t["x0"] + b * w,
                            cx=t["x0"] + (a + b) / 2 * w))
    return out


def with_details(cells, fr):
    texts = split_names(fr.texts)
    for c in cells:
        c["name"] = name_of(texts, c)
        c["sprite"] = sprite_of(fr.img, c)
        c["sig"] = f"{c['cp']}|{alnum(c['name'])}"
    return cells


def names_ok(a, b):
    """The names don't rule each other out (one is missing, or they differ only by a tag mark at the start)."""
    a, b = alnum(a), alnum(b)
    if not a or not b or a == b:
        return True
    return abs(len(a) - len(b)) <= 2 and (a.endswith(b) or b.endswith(a))


def same_species(a, b):
    na, nb = norm(a["name"]), norm(b["name"])
    if PLAIN_NAME.match(na) and PLAIN_NAME.match(nb) and pokecalc.is_species_name(na) and \
            pokecalc.is_species_name(nb) and difflib.SequenceMatcher(None, na, nb).ratio() < 0.75:
        return False   # two different species names (a nickname like "Flower" doesn't decide this)
    return sprite_sim(a["sprite"], b["sprite"]) >= cfg.SAME_SPECIES_THR


def make_runs(cells):
    runs = []
    for c in cells:
        if runs and same_species(runs[-1][-1], c):
            runs[-1].append(c)
        else:
            runs.append([c])
    return runs
