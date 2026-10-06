"""Checks that look at colors instead of text: the map, the teal multi-select bar, the green TAG button,
the active row in the sort menu and the color swatches in the new-tag dialog."""
import cv2
import numpy as np

from .vision import crop_norm


def is_map(img):
    """Map = a red and white Poké Ball at the bottom center."""
    top = crop_norm(img, 0.45, 0.905, 0.55, 0.93).astype(int)
    bot = crop_norm(img, 0.45, 0.94, 0.55, 0.965).astype(int)
    if top.size == 0 or bot.size == 0:
        return False
    red = ((top[..., 0] > 180) & (top[..., 1] < 90) & (top[..., 2] < 90)).mean()
    white = ((bot[..., 0] > 225) & (bot[..., 1] > 225) & (bot[..., 2] > 225)).mean()
    return red > 0.25 and white > 0.3


def teal_top(img):
    """Dark teal bar at the top (multi-select)."""
    top = crop_norm(img, 0.25, 0.06, 0.95, 0.12).astype(int)
    return top.size > 0 and float(((top.sum(axis=2) < 420) & (top[..., 2] >= top[..., 0]) &
                                   (top[..., 1] >= top[..., 0])).mean()) > 0.9


def multiselect_look(img):
    """Multi-select by colors, for when OCR can't read the button texts: the teal bar at the top
    and the green TAG button at the bottom (100% and 98% on real screenshots, at most 47% and 31% elsewhere)."""
    btn = crop_norm(img, 0.2, 0.845, 0.8, 0.875).astype(int)
    return btn.size > 0 and teal_top(img) and \
        float(((btn[..., 1] > btn[..., 0] + 40) & (btn[..., 1] > btn[..., 2] + 5)).mean()) > 0.8


def sort_active(img, t):
    """The active sort option has an arrow to the right of its icon (light pixels); other rows have nothing there."""
    reg = crop_norm(img, 0.915, t["cy"] - 0.015, 0.975, t["cy"] + 0.015)
    return reg.size > 0 and (reg.min(axis=2) > 170).mean() > 0.02


def find_swatches(img, region=(0.02, 0.10, 0.98, 0.92)):
    """Color swatches in the new-tag dialog: at least 5 equally sized filled circles side by side
    (in one or more rows). Returns [{cx, cy, r, rgb}] row by row from the left (cx, cy, r as a fraction
    of the screen width/height), or []."""
    H, W = img.shape[:2]
    X0, Y0 = int(region[0] * W), int(region[1] * H)
    crop = img[Y0:int(region[3] * H), X0:int(region[2] * W)]
    if crop.size == 0:
        return []
    hsv = cv2.cvtColor(crop, cv2.COLOR_RGB2HSV)
    sat, val = hsv[..., 1].astype(np.int16), hsv[..., 2].astype(np.int16)
    # "anything that is not the light background": colored, dark, or mid gray (the gray swatch)
    mask = (((sat > 60) & (val > 50)) | (val < 120) | ((sat < 45) & (val >= 90) & (val <= 205))).astype(np.uint8)
    k = max(3, W // 200) | 1
    mask = cv2.morphologyEx(mask, cv2.MORPH_OPEN, np.ones((k, k), np.uint8))
    contours, _ = cv2.findContours(mask, cv2.RETR_LIST, cv2.CHAIN_APPROX_NONE)
    dmin, dmax = 0.035 * W, 0.17 * W
    cands = []
    for c in contours:
        area = cv2.contourArea(c)
        if area < np.pi * (dmin / 2) ** 2 * 0.6:
            continue
        (x, y), r = cv2.minEnclosingCircle(c)
        per = cv2.arcLength(c, True)
        if not dmin <= 2 * r <= dmax or per <= 0:
            continue
        if 4 * np.pi * area / per ** 2 < 0.78 or area / (np.pi * r * r) < 0.75:
            continue
        y0p, x0p = max(0, int(y - r)), max(0, int(x - r))
        pm = mask[y0p:int(y + r) + 1, x0p:int(x + r) + 1]
        pc = crop[y0p:int(y + r) + 1, x0p:int(x + r) + 1]
        yy, xx = np.ogrid[y0p:y0p + pm.shape[0], x0p:x0p + pm.shape[1]]
        d2 = (yy - y) ** 2 + (xx - x) ** 2
        if pm[d2 <= (0.6 * r) ** 2].mean() < 0.45:
            continue                       # hollow circle (the letter O, a ring): not a color swatch
        px = pc[d2 <= (0.75 * r) ** 2]
        px = px[px.min(axis=1) < 215]      # skip the white check mark / selection mark
        if len(px) < 10:
            continue
        cands.append({"x": x + X0, "y": y + Y0, "r": r, "rgb": tuple(int(v) for v in np.median(px, axis=0))})
    if len(cands) < 5:
        return []
    best = []
    for c in cands:                        # largest group of equally sized swatches
        grp = [d for d in cands if abs(d["r"] - c["r"]) <= 0.18 * c["r"]]
        if len(grp) > len(best):
            best = grp
    out = []
    for c in sorted(best, key=lambda c: c["r"]):   # concentric outlines of one swatch count once
        if all(np.hypot(c["x"] - o["x"], c["y"] - o["y"]) > o["r"] for o in out):
            out.append(c)
    if len(out) < 5:
        return []
    rmed = float(np.median([c["r"] for c in out]))
    rows = []
    for c in sorted(out, key=lambda c: c["y"]):
        if rows and abs(c["y"] - rows[-1][0]["y"]) < rmed:
            rows[-1].append(c)
        else:
            rows.append([c])
    flat = [c for row in rows if len(row) >= 2 for c in sorted(row, key=lambda c: c["x"])]
    if len(flat) < 5:
        return []
    return [{"cx": c["x"] / W, "cy": c["y"] / H, "r": c["r"] / W, "rgb": c["rgb"]} for c in flat]


def row_checked(img, t):
    """Is the row checked in the tag picker? The game draws a green check mark on the right of the row."""
    reg = crop_norm(img, 0.80, t["cy"] - 0.018, 0.98, t["cy"] + 0.018).astype(int)
    if reg.size == 0:
        return False
    r, g = reg[..., 0], reg[..., 1]
    return float(((g - r > 40) & (g > 120)).mean()) > 0.008
