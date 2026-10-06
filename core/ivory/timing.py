"""Where a run spends its time: named spans the bot measures while it reads the storage.

The bot wraps the parts of the reading cycle in `span("name")`; `report()` then says how much of the
wall-clock each part took. Only for the log and the app's speed panel – nothing here steers a run.
"""
import time
from contextlib import contextmanager

from .output import T


SPANS = {}        # name -> [total seconds, how many times]


def reset():
    SPANS.clear()


@contextmanager
def span(name):
    t0 = time.time()
    try:
        yield
    finally:
        add(name, time.time() - t0)


def add(name, sec):
    e = SPANS.setdefault(name, [0.0, 0])
    e[0] += sec
    e[1] += 1


def report(total=None, n=None):
    """The measured spans, longest first: [(name, seconds, count, seconds per Pokémon)]."""
    out = [(name, sec, hits, sec / n if n else None) for name, (sec, hits) in SPANS.items()]
    out.sort(key=lambda r: -r[1])
    if total is not None:
        rest = total - sum(r[1] for r in out)
        if rest > 0.05:
            out.append((T("ostatní", "the rest"), rest, 0, rest / n if n else None))
    return out


def line(total, n):
    """One log line with the breakdown per Pokémon."""
    parts = [f"{name} {sec / n:.2f}" for name, sec, _, _ in report(total, n) if sec / n >= 0.01]
    return " · ".join(parts)
