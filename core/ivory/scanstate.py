"""A fast pass over one list, in progress: what has been read, what is still to do, and what the
app is told about it.

Fast mode goes about it like this:
 1) one pass through the list, scrolling only (order, CP, name, sprite)
 2) the first Pokémon is opened, then the appraisal, and the ▶ arrow (or a swipe) moves to the next
    one; the IV and tags of each are read without closing the detail screen
 3) the decisions are made in memory (worse duplicates, the right IV tag)
 4) the tags are set in bulk: everyone in the list who should get (or lose) the same tag is selected,
    and the tag is set for all of them at once
"""
from . import config as cfg
from .errors import NeedTop
from .output import emit, T
from .scroll import reopen_box


class FastState:
    """A fast pass over one list, in progress; it survives an error and a return to the storage."""

    def __init__(self):
        self.seq = None          # list cells in order
        self.recs = {}           # index -> Pokémon read from the detail screen
        self.scanned = False
        self.planned = False     # duplicates decided
        self.iv_planned = False
        self.pvp_planned = False
        self.rename_planned = False
        self.battle_planned = False
        self.weak_planned = False
        self.identified = False
        self.passes = []         # [(tag, remove?, indexes)]: bulk taggings still to do
        self.pass_fails = 0      # failed attempts at the current batch
        self.group_of = {}       # index -> group number (duplicates)
        self.upto = None         # how far to read (limit on duplicate groups)
        self.index_rec = {}      # index -> Rec (results for the summary)
        self.phantom = set()     # list cells that aren't in the game (doubled while scrolling)
        self.extra = []          # Pokémon read that are missing from the list
        self.scan_fail = {}      # index -> how many times reading from it failed
        self.skipped = set()     # Pokémon that repeatedly failed to open (most likely they are in the game)
        self.cache_hits = 0      # how many Pokémon were taken from memory (previous run) instead of being read


def emit_counts(bot, changed=None, delta=0):
    """The "Tags in your storage" panel: how many Pokémon have each tag (updated as it goes)."""
    emit("tagcounts", counts=bot.tag_counts, total=bot.box_total, changed=changed, delta=delta)


def count_tags(bot, st):
    """After reading the whole storage: the number of Pokémon in each known tag, as it is in the game now."""
    known = [cfg.TAG_NAME] + [n for _, n in cfg.IV_TAGS] + [lg["name"] for lg in cfg.PVP.values()] + cfg.battle_tags()
    bot.tag_counts = {n: 0 for n in known}
    for rec in st.recs.values():
        for n in rec.get("tags") or []:
            if n in bot.tag_counts:
                bot.tag_counts[n] += 1
    bot.box_total = len(st.seq)
    emit_counts(bot)


def require_top(bot):
    """The step needs the list from the top: if it isn't there, the storage is closed and opened again."""
    if not bot.fresh_list:
        reopen_box(bot)
        raise NeedTop(T("seznam potřebuju od začátku", "I need the list from the top"))
    bot.fresh_list = False
