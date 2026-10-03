"""Reading the three IV bars (attack, defense, HP) from the appraisal."""
import numpy as np

from . import config as cfg


def _bar_run(bar_row, gap):
    """The continuous run of the bar from its left end (gaps between segments up to `gap` px)."""
    xs = np.flatnonzero(bar_row)
    if xs.size == 0:
        return None
    breaks = np.flatnonzero(np.diff(xs) > gap)
    end = xs[breaks[0]] if breaks.size else xs[-1]
    return int(xs[0]), int(end)


def _measure_bar(img, label, y_end):
    """Finds the bar below a label (only down to y_end, so it doesn't reach the next bar).
    Returns (left, right, fill_end, row, pink) in pixels, or None."""
    H, W = img.shape[:2]
    x0 = max(0, int((label["x0"] - cfg.BAR_LEFT_PAD) * W))
    x1 = min(W, int((label["x0"] + cfg.BAR_MAX_W) * W))
    y0 = max(0, int((label["y1"] - 0.002) * H))
    y1 = min(H, int(y_end * H))
    region = img[y0:y1, x0:x1].astype(int)
    if region.size == 0:
        return None
    r, g, b = region[..., 0], region[..., 1], region[..., 2]
    fill = (r > cfg.FILL_MIN_R) & ((r - b) > cfg.FILL_MIN_RB)
    track = (np.abs(r - g) < 15) & (np.abs(g - b) < 15) & (r >= cfg.TRACK_MIN) & (r <= cfg.TRACK_MAX)
    bar = fill | track
    gap = max(3, int(cfg.BAR_GAP * W))
    best = None
    for row in range(region.shape[0]):
        run = _bar_run(bar[row], gap)
        if run is None or run[0] > 0.25 * region.shape[1]:
            continue
        if best is None or run[1] - run[0] > best[1] - best[0]:
            best = (run[0], run[1], row)
    if best is None or best[1] - best[0] < cfg.BAR_MIN_W * W:
        return None
    left, right, row = best
    # end of the fill: median over a few rows around the best one (against JPEG noise)
    ends, colors = [], []
    for rr in range(max(0, row - 2), min(region.shape[0], row + 3)):
        fx = np.flatnonzero(fill[rr, left:right + 1])
        if fx.size:
            ends.append(left + int(fx[-1]))
            colors.append(region[rr, left + fx].mean(axis=0))
    fill_end = int(np.median(ends)) if ends else None
    pink = False
    if colors:
        cr, cg, cb = np.mean(colors, axis=0)
        pink = cb > 105 and cg < 150      # pinkish red = 15, orange = less
    return x0 + left, x0 + right, None if fill_end is None else x0 + fill_end, y0 + row, pink


def read_bars(img, labels):
    """Measures the three IV bars (attack, defense, HP). Returns (ivs or None, debug)."""
    gaps = [labels[i + 1]["y0"] - labels[i]["y0"] for i in range(2)]
    pitch = sum(gaps) / 2
    ends = [labels[1]["y0"] - 0.002, labels[2]["y0"] - 0.002, labels[2]["y1"] + pitch * 0.6]
    bars = [_measure_bar(img, lab, ye) for lab, ye in zip(labels, ends)]
    if any(b is None for b in bars):
        return None, bars
    length = max(b[1] - b[0] for b in bars)      # all bars have the same length
    ivs = []
    for left, right, fill_end, row, pink in bars:
        if pink:
            iv = 15
        elif fill_end is None:
            iv = 0
        else:
            iv = min(14, round(15 * (fill_end - left + 1) / (length + 1)))
        ivs.append(int(max(0, iv)))
    return tuple(ivs), bars
