"""Synthetic phone: draws every game screen itself (needs no game screenshots).

Tests a whole run: the way into the storage, typing the search, sorting, checking the tags at the start
(missing tags are created in the color from the settings), duplicates -> Removable tag, the whole storage -> IV tags.
The new-tag dialog comes in variants (the keyboard opens by itself / Enter creates the tag right away /
colors in two rows / the new tag gets checked by itself), so the bot does not depend on one form of the dialog.
The real_phone scenario behaves like a real iPhone: after a drag the list moves 1.6× further than the finger,
the storage is bigger (legendaries with close CP), the CP in the appraisal is sometimes unreadable, and on the
last Pokémon a tap where the ▶ arrow would be closes the appraisal.

  python sim_synthetic.py                 # all scenarios
  python sim_synthetic.py verbose         # one scenario with the bot's log
  python sim_synthetic.py real_phone ...  # only the named scenarios
"""
import io, itertools, os, re, sys, time, random, tempfile
os.environ["POGO_NO_STREAM"] = "1"
from pathlib import Path
import numpy as np
from PIL import Image, ImageDraw, ImageFont
from support import S
import pokecalc as PC

TMP = Path(tempfile.mkdtemp(prefix="pogo_sim_synthetic_"))
S.CAL_FILE = TMP / "cal.json"; S.MEMORY_FILE = TMP / "memory.json"; S.OUT_DIR = TMP / "runs"
S.BOX_FILE = TMP / "last_box.json"; S.LIVE_FILE = TMP / "live.jpg"
S.NAV_TIMEOUT = 60

W, H = 904, 1966                      # like the iPhone video stream (75 %)
PT_W, PT_H = 402, 874                 # window size in points (for taps)
ROW0, PITCH, COLS = 0.274, 0.1665, [0.18, 0.495, 0.81]
GAME_COLORS = {"blue": (66, 135, 230), "green": (82, 186, 106), "purple": (152, 101, 220), "yellow": (243, 196, 58),
               "red": (226, 76, 80), "orange": (242, 145, 60), "gray": (150, 154, 160), "black": (48, 48, 52)}
COLOR_ORDER = ["blue", "green", "purple", "yellow", "red", "orange", "gray", "black"]
QUERY = "count & !legendary & !ultra beasts"

_fonts = {}
def F(size, bold=False):
    key = (size, bold)
    if key not in _fonts:
        _fonts[key] = ImageFont.truetype("/System/Library/Fonts/Supplemental/Arial Bold.ttf" if bold
                                         else "/System/Library/Fonts/Supplemental/Arial.ttf", int(size * W / 1206))
    return _fonts[key]

def text_c(d, x, y, s, f, fill):
    w = d.textlength(s, font=f)
    d.text((x * W - w / 2, y * H - f.size * 0.55), s, font=f, fill=fill)

def text_l(d, x, y, s, f, fill):
    d.text((x * W, y * H - f.size * 0.55), s, font=f, fill=fill)

def png(img):
    b = io.BytesIO(); img.save(b, "JPEG", quality=88); return b.getvalue()

def make_sprite(species):
    """A simple species image: a few colored shapes seeded by the name (different for each species)."""
    rnd = random.Random(species)
    w, h = int(0.22 * W), int(0.075 * H)
    img = Image.new("RGB", (w, h), (238, 248, 238)); d = ImageDraw.Draw(img)
    for _ in range(5):
        c = tuple(rnd.randint(30, 230) for _ in range(3))
        x0, y0 = rnd.randint(0, w - 30), rnd.randint(0, h - 20)
        x1, y1 = rnd.randint(x0 + 15, min(w, x0 + w // 2)), rnd.randint(y0 + 10, min(h, y0 + h // 1))
        (d.ellipse if rnd.random() < 0.5 else d.rectangle)([x0, y0, x1, y1], fill=c)
    return img

SPECIES = {"Charmander": "FIRE", "Charizard": "FIRE / FLYING", "Squirtle": "WATER", "Rattata": "NORMAL",
           "Pidgey": "NORMAL / FLYING", "Machop": "FIGHTING", "Geodude": "ROCK / GROUND", "Eevee": "NORMAL",
           "Dratini": "DRAGON", "Mewtwo": "PSYCHIC", "Chikorita": "GRASS", "Larvitar": "ROCK / GROUND",
           "Kyogre": "WATER", "Groudon": "GROUND", "Dialga": "STEEL / DRAGON", "Palkia": "WATER / DRAGON"}
SPR = {sp: make_sprite(sp) for sp in SPECIES}


def keyboard(d, ret="return"):
    d.rectangle([0, int(0.62 * H), W, H], fill=(208, 211, 217))
    for row, (y, keys) in enumerate([(0.67, "QWERTYUIOP"), (0.74, "ASDFGHJKL"), (0.81, "ZXCVBNM")]):
        x0 = 0.05 + row * 0.045
        for i, k in enumerate(keys):
            x = x0 + i * 0.0935
            d.rounded_rectangle([int((x - 0.04) * W), int((y - 0.028) * H), int((x + 0.04) * W), int((y + 0.028) * H)],
                                10, fill=(255, 255, 255))
            text_c(d, x, y, k, F(52), (20, 20, 20))
    text_c(d, 0.12, 0.89, "123", F(44), (20, 20, 20))
    d.rounded_rectangle([int(0.25 * W), int(0.865 * H), int(0.72 * W), int(0.915 * H)], 10, fill=(255, 255, 255))
    text_c(d, 0.485, 0.89, "space", F(40), (20, 20, 20))
    d.rounded_rectangle([int(0.75 * W), int(0.865 * H), int(0.97 * W), int(0.915 * H)], 10, fill=(170, 175, 185))
    text_c(d, 0.86, 0.89, ret, F(40), (20, 20, 20))


class Phone:
    def __init__(self, mons, seed=1, glitch=0.0, kb_auto=False, return_submits=False, two_rows=False,
                 auto_check=False, existing_tags=(), nav=True, swipe_closes=False, gain=1.0, cp_flaky=0.0,
                 select_all=False, multi_fling=0.0, big=0, select_all_search=True, ghost=0, done_stuck=0,
                 check_delay=0.0, twins_rev=False, ok_needed=False, refuse=()):
        self.twins_rev = twins_rev                            # search results reverse Pokémon of the same species and CP
        self.mons = mons; self.rnd = random.Random(seed); self.glitch = glitch
        self.gain = gain                                      # the list moves gain× further than the finger (iPhone ~1.6)
        self.cp_flaky = cp_flaky                              # how often the CP is unreadable in the appraisal
        self.select_all = select_all                          # older game version: SELECT ALL in multiselect
        self.select_all_search = select_all_search            # SELECT ALL in search results
        self.multi_fling = multi_fling                        # how often a scroll in multiselect overshoots
        self.kb_auto, self.return_submits, self.two_rows, self.auto_check = kb_auto, return_submits, two_rows, auto_check
        self.nav = nav                                        # can the appraisal move on to the next one (▶ / swipe)?
        self.swipe_closes = swipe_closes                      # no ▶ arrow, and a swipe closes the appraisal
        self.ghost, self.ghost_idx = ghost, None              # Pokémon whose CP the bot misreads (1 = in a batch, 2 = alone)
        self.done_stuck = done_stuck                          # DONE saves the tags, but the tag picker stays open
        self.check_delay = check_delay                        # check marks in the tag picker appear only after a moment
        self.ok_needed = ok_needed                            # like the game: Enter only hides the keyboard, OK saves the name
        self.refuse = set(refuse)                             # names the game refuses ("inappropriate text")
        self.refusals = []; self.refused_shown = False
        self.list_opened = 0.0
        self.state = "map"; self.filtered = False; self.query = ""; self.off = 0.0; self.sel = set(); self.cur = None
        self.sorted = False; self.kb = False; self.typed = ""
        self.list_off = 0.0; self.checked = set(); self.initial = set(); self.list_targets = []; self.list_return = "grid"
        self.tags = {n: c for n, c in existing_tags}              # name -> color (tags in the game)
        self.created = []; self.queries = []; self.taps = 0; self.bad = []; self.events = []; self.renamed = []
        self.appraisals = 0; self.nexts = 0                    # times the appraisal was opened / the ▶ arrow tapped
        self.hide_chips = set()                                # tag chips that OCR "misses" on the detail screen
        self.mixed = set(); self.touched = set()               # multi-Pokémon selection: only some have the tag ("Mixed")
        self.dlg_color = "blue"
        class CE:
            def get_command(s, n): return ("POST", "/x")
            def add_command(s, *a): pass
        self.command_executor = CE()

    # ------------------------------------------------------------ what the storage shows
    def shown(self):
        """What the storage shows: everything without a search, otherwise filtered like the game does.
        All groups separated by & must match; within a group one of the comma-separated options is enough;
        ! = does not match. cpN = exact CP, count = the species is in the storage at least 2× (duplicates);
        other words (legendary, ultra beasts) select nothing in the simulation."""
        if not self.filtered:
            return list(range(len(self.mons)))
        cnt = {}
        for m in self.mons: cnt[m["sp"]] = cnt.get(m["sp"], 0) + 1
        def term(m, t):
            neg = t.startswith("!"); t = t.lstrip("!").strip()
            if re.fullmatch(r"cp\d+", t): v = m["cp"] == int(t[2:])
            elif t == "count": v = cnt[m["sp"]] >= 2
            else: v = False
            return v != neg
        groups = [[t.strip().lower() for t in g.split(",") if t.strip()] for g in self.query.split("&")]
        out = [i for i, m in enumerate(self.mons) if all(any(term(m, t) for t in g) for g in groups if g)]
        if self.twins_rev:                 # the game keeps no order for equal number + CP: reversed in the results
            key = lambda i: (self.mons[i]["sp"], self.mons[i]["cp"])
            out = [i for _, grp in itertools.groupby(out, key) for i in reversed(list(grp))]
        return out

    def max_off(self):
        rows = (len(self.shown()) + 2) // 3
        return max(0.0, ROW0 + (rows - 1) * PITCH - 0.70)

    def list_rows(self):
        return sorted(self.tags) + ["+ Add New Tag"]

    def row_y(self, k): return 0.30 + k * 0.058 - self.list_off

    # ------------------------------------------------------------ drawing
    def header(self, d, bar_text=None, active=False):
        d.rectangle([0, 0, W, int(0.215 * H)], fill=(250, 252, 250))
        text_c(d, 0.32, 0.066, "POKÉMON", F(40, True), (60, 70, 70))
        if self.filtered:
            # during a search, a magnifier and the result count "(12)" sit under POKÉMON, like in the game
            cx, cy, r = 0.30, 0.093, 0.011
            d.ellipse([int((cx - r) * W), int((cy - 0.006) * H), int((cx + r) * W), int((cy + 0.006) * H)],
                      outline=(120, 130, 130), width=4)
            d.line([int((cx + r * 0.6) * W), int((cy + 0.004) * H), int((cx + r * 1.6) * W), int((cy + 0.010) * H)],
                   fill=(120, 130, 130), width=5)
            text_l(d, cx + 0.025, cy, f"({len(self.shown())})", F(30), (120, 130, 130))
        else:
            text_c(d, 0.32, 0.093, f"{len(self.mons)}/725", F(30), (120, 130, 130))
        text_c(d, 0.74, 0.066, "EGGS", F(40, True), (150, 160, 160))
        text_c(d, 0.74, 0.093, "9/12", F(30), (150, 160, 160))
        d.rounded_rectangle([int(0.08 * W), int(0.155 * H), int(0.95 * W), int(0.2 * H)], 40, fill=(232, 240, 236))
        if bar_text:
            s = bar_text
            f = F(42)
            while d.textlength(s, font=f) > 0.66 * W and len(s) > 4:
                s = s[:-2]
            if s != bar_text:
                s = s.rstrip() + "…"
            text_l(d, 0.17, 0.178, s, f, (50, 60, 60))
            text_c(d, 0.105, 0.178, "<", F(48, True), (60, 120, 120))
            text_c(d, 0.915, 0.176, "×", F(48), (100, 110, 110))
        elif active:
            d.line([int(0.17 * W), int(0.163 * H), int(0.17 * W), int(0.193 * H)], fill=(60, 60, 60), width=3)
        else:
            text_c(d, 0.52, 0.178, "Search", F(42), (140, 150, 150))

    def render_grid(self, multi=False):
        img = Image.new("RGB", (W, H), (238, 248, 238)); d = ImageDraw.Draw(img)
        for pos, i in enumerate(self.shown()):
            m = self.mons[i]; row, col = divmod(pos, 3); cy = ROW0 + row * PITCH - self.off; cx = COLS[col]
            if cy < 0.15 or cy > 1.05: continue
            if multi and i in self.sel:
                d.rectangle([int((cx - .155) * W), int((cy - .02) * H), int((cx + .155) * W), int((cy + .135) * H)], fill=(215, 240, 205))
            fcp, fnum = F(30), F(62); wn = d.textlength(str(m["cp"]), font=fnum); wc = d.textlength("CP", font=fcp)
            x0 = cx * W - (wn + wc + 4) / 2
            d.text((x0, cy * H - fcp.size * 0.2), "CP", font=fcp, fill=(110, 120, 120))
            d.text((x0 + wc + 4, cy * H - fnum.size * 0.6), str(m["cp"]), font=fnum, fill=(60, 70, 70))
            img.paste(SPR[m["sp"]], (int((cx - 0.11) * W), int((cy + 0.02) * H)))
            text_c(d, cx, cy + 0.105, ("• " if m["tags"] else "") + m["name"], F(44, True), (50, 60, 60))
        self.header(d, self.query if self.filtered else None)
        if multi:
            n = len(self.sel)
            d.rectangle([0, 0, W, int(0.15 * H)], fill=(40, 95, 110))
            if self.select_all or (self.filtered and self.select_all_search):
                text_c(d, 0.81, 0.098, "SELECT ALL", F(40, True), (255, 255, 255))
            text_c(d, 0.107, 0.117, "X", F(50), (150, 230, 160))
            d.rounded_rectangle([int(.07 * W), int(.835 * H), int(.93 * W), int(.885 * H)], 60, fill=(100, 205, 160)); text_c(d, .5, .86, f"TAG ({n})", F(48, True), (255, 255, 255))
            # new game version: TRANSFER is grayed out (0 for selected legendaries), so OCR may not read it
            d.rounded_rectangle([int(.07 * W), int(.912 * H), int(.93 * W), int(.962 * H)], 60, fill=(222, 232, 228)); text_c(d, .5, .937, f"TRANSFER ({n})", F(44, True), (196, 206, 204))
        else:
            for cx in (0.5, 0.87):
                d.ellipse([int((cx - .045) * W), int(.91 * H), int((cx + .045) * W), int(.97 * H)], fill=(225, 245, 240), outline=(40, 120, 120), width=4)
            text_c(d, .5, .94, "X", F(50), (40, 120, 120)); text_c(d, .87, .94, "#", F(50), (40, 120, 120))
        return img

    def render_search(self):
        img = Image.new("RGB", (W, H), (250, 252, 250)); d = ImageDraw.Draw(img)
        self.header(d, None, active=True)
        if self.typed:
            d.rectangle([int(0.15 * W), int(0.158 * H), int(0.93 * W), int(0.198 * H)], fill=(232, 240, 236))
            s, f = self.typed, F(42)
            while d.textlength(s, font=f) > 0.7 * W and len(s) > 4:
                s = s[1:]                                   # while typing, the end of the text is visible
            text_l(d, 0.17, 0.178, s, f, (50, 60, 60))
            text_c(d, 0.105, 0.178, "<", F(48, True), (60, 120, 120))
        text_l(d, 0.08, 0.26, "Recent searches", F(40, True), (60, 70, 70))
        text_l(d, 0.08, 0.31, "shiny", F(40), (90, 100, 100))
        text_l(d, 0.08, 0.40, "Recommended", F(40, True), (60, 70, 70))
        text_l(d, 0.08, 0.45, "See More", F(40), (40, 150, 140))
        if self.kb:
            keyboard(d, "search")
        return img

    def render_sort(self):
        img = Image.new("RGB", (W, H), (32, 70, 80)); d = ImageDraw.Draw(img)
        for k, opt in enumerate(["RECENT", "FAVORITE", "NUMBER", "HP", "NAME", "COMBAT POWER"]):
            y = 0.47 + k * 0.07
            text_c(d, 0.68, y, opt, F(46, True), (255, 255, 255))
            if (opt == "NUMBER") == self.sorted:
                if opt == "NUMBER" or (opt == "RECENT" and not self.sorted):
                    d.polygon([(int(0.93 * W), int((y - 0.01) * H)), (int(0.96 * W), int(y * H)), (int(0.93 * W), int((y + 0.01) * H))], fill=(255, 255, 255))
        d.ellipse([int(.825 * W), int(.91 * H), int(.915 * W), int(.97 * H)], fill=(225, 245, 240)); text_c(d, .87, .94, "X", F(50), (40, 120, 120))
        return img

    def render_detail(self, bubble=None, bars=False):
        m = self.mons[self.cur]
        img = Image.new("RGB", (W, H), (255, 255, 255)); d = ImageDraw.Draw(img)
        d.rectangle([0, 0, W, int(0.36 * H)], fill=(120, 190, 210))
        if not (bars and self.cp_flaky and self.rnd.random() < self.cp_flaky):    # the appraisal dims the CP
            text_c(d, 0.47, 0.072, f"CP{m['cp']}", F(90), (255, 255, 255))
        img.paste(SPR[m["sp"]].resize((int(0.44 * W), int(0.15 * H))), (int(0.28 * W), int(0.17 * H)))
        text_c(d, 0.5, 0.422, m["name"], F(66, True), (60, 70, 70))
        x = 0.12
        for t in sorted(m["tags"]):
            if t in self.hide_chips:
                continue
            w = d.textlength(t, font=F(36)) / W + 0.06
            d.rounded_rectangle([int(x * W), int(0.493 * H), int((x + w) * W), int(0.527 * H)], 40, fill=GAME_COLORS.get(self.tags.get(t, "blue"), (90, 170, 230)))
            d.text((int((x + 0.03) * W), int(0.497 * H)), t, font=F(36), fill=(255, 255, 255)); x += w + 0.02
        text_c(d, 0.5, 0.568, SPECIES[m["sp"]], F(34), (110, 120, 120))
        text_c(d, 0.5, 0.62, f"{m['hp']} / {m['hp']} HP", F(40), (90, 100, 100))
        if not bubble and not bars:
            text_c(d, 0.3, 0.70, "STARDUST", F(36), (120, 130, 130))
            d.rounded_rectangle([int(.1 * W), int(.73 * H), int(.9 * W), int(.77 * H)], 40, fill=(100, 205, 160)); text_c(d, .5, .75, "POWER UP", F(44, True), (255, 255, 255))
            d.rounded_rectangle([int(.1 * W), int(.78 * H), int(.9 * W), int(.82 * H)], 40, fill=(100, 205, 160)); text_c(d, .5, .80, "EVOLVE", F(44, True), (255, 255, 255))
            for cx, s in ((0.5, "X"), (0.87, "≡")):
                d.ellipse([int((cx - .045) * W), int(.91 * H), int((cx + .045) * W), int(.97 * H)], fill=(225, 245, 240), outline=(40, 120, 120), width=4)
                text_c(d, cx, .94, s, F(50), (40, 120, 120))
        else:
            text_c(d, 0.3, 0.70, "STARDUST", F(36), (120, 130, 130))
        if bubble:
            d.rectangle([0, int(0.83 * H), W, H], fill=(245, 250, 248))
            text_l(d, 0.06, 0.87, "Overall, your Pokémon is a wonder!", F(40), (50, 60, 60))
            text_l(d, 0.06, 0.91, "Let me analyze its stats in detail.", F(40), (50, 60, 60))
        if bars:
            d.rectangle([0, int(0.72 * H), W, H], fill=(250, 250, 250))
            for k, (lab, iv) in enumerate(zip(["Attack", "Defense", "HP"], m["iv"])):
                y = 0.775 + k * 0.05
                text_l(d, 0.08, y, lab, F(36, True), (70, 80, 80))
                top, bot = int((y + 0.016) * H), int((y + 0.026) * H)
                left, right = int(0.08 * W), int(0.44 * W)
                d.rectangle([left, top, right, bot], fill=(226, 226, 226))
                if iv:
                    d.rectangle([left, top, left + int((right - left) * iv / 15), bot], fill=(224, 128, 134) if iv == 15 else (243, 168, 79))
            text_c(d, 0.03, 0.835, "◀", F(40), (90, 100, 100)); text_c(d, 0.975, 0.835, "▶", F(40), (90, 100, 100))
        return img

    def render_dmenu(self):
        img = Image.new("RGB", (W, H), (40, 52, 58)); d = ImageDraw.Draw(img)
        for y, s in ((0.45, "FAVORITE"), (0.61, "TAG"), (0.69, "ITEM"), (0.771, "APPRAISE"), (0.853, "TRANSFER")):
            text_c(d, 0.70, y, s, F(46, True), (255, 255, 255))
        d.ellipse([int(.825 * W), int(.91 * H), int(.915 * W), int(.97 * H)], fill=(225, 245, 240)); text_c(d, .87, .94, "X", F(50), (40, 120, 120))
        return img

    def render_list(self, dim=False):
        img = Image.new("RGB", (W, H), (250, 252, 250)); d = ImageDraw.Draw(img)
        for k, name in enumerate(self.list_rows()):
            y = self.row_y(k)
            if not 0.24 < y < 0.80: continue
            if name.startswith("+"):
                text_l(d, 0.2, y, name, F(50, True), (40, 150, 140))
                continue
            c = GAME_COLORS[self.tags[name]]
            d.ellipse([int(0.08 * W), int((y - 0.012) * H), int(0.08 * W) + int(0.024 * H), int((y + 0.012) * H)], fill=c)
            text_l(d, 0.2, y, name, F(50), (60, 60, 60))
            box = [int(0.86 * W), int((y - 0.014) * H), int(0.86 * W) + int(0.028 * H), int((y + 0.014) * H)]
            if name in self.checked and time.time() - self.list_opened >= self.check_delay:
                d.ellipse(box, fill=(40, 180, 120))
            elif name in self.mixed:
                text_l(d, 0.74, y, "Mixed", F(44), (150, 155, 155))
            else: d.ellipse(box, outline=(170, 175, 175), width=4)
        d.rectangle([0, 0, W, int(0.22 * H)], fill=(250, 252, 250))
        text_c(d, 0.5, 0.084, f"TAG {len(self.list_targets)} POKÉMON", F(44), (90, 100, 100))
        d.rectangle([0, int(0.81 * H), W, H], fill=(250, 252, 250))
        d.rounded_rectangle([int(.3 * W), int(.835 * H), int(.7 * W), int(.885 * H)], 50, fill=(100, 205, 160)); text_c(d, .5, .86, "DONE", F(50, True), (255, 255, 255))
        d.ellipse([int(.455 * W), int(.91 * H), int(.545 * W), int(.97 * H)], fill=(225, 245, 240), outline=(40, 120, 120), width=4); text_c(d, .5, .94, "X", F(50), (40, 120, 120))
        if dim:
            img = Image.blend(img, Image.new("RGB", (W, H), (30, 30, 30)), 0.55)
        return img

    def swatch_pos(self):
        if self.two_rows:
            return [(0.24 + (i % 4) * 0.17, 0.48 + (i // 4) * 0.065) for i in range(8)]
        return [(0.14 + i * 0.103, 0.50) for i in range(8)]

    def render_create(self):
        img = self.render_list(dim=True); d = ImageDraw.Draw(img)
        d.rounded_rectangle([int(0.06 * W), int(0.25 * H), int(0.94 * W), int(0.70 * H)], 40, fill=(255, 255, 255))
        text_c(d, 0.5, 0.29, "NEW TAG", F(48, True), (60, 70, 70))
        d.rounded_rectangle([int(0.12 * W), int(0.35 * H), int(0.88 * W), int(0.41 * H)], 30, outline=(150, 160, 160), width=4, fill=(255, 255, 255))
        text_c(d, 0.5, 0.38, self.typed or "Enter tag name", F(46), (60, 60, 60) if self.typed else (165, 170, 170))
        r = int(0.04 * W)
        for (x, y), cname in zip(self.swatch_pos(), COLOR_ORDER):
            cx, cy = int(x * W), int(y * H)
            if cname == self.dlg_color:
                d.ellipse([cx - r - 9, cy - r - 9, cx + r + 9, cy + r + 9], outline=GAME_COLORS[cname], width=5)
            d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=GAME_COLORS[cname])
        d.rounded_rectangle([int(.3 * W), int(.61 * H), int(.7 * W), int(.66 * H)], 50, fill=(100, 205, 160)); text_c(d, .5, .635, "DONE", F(50, True), (255, 255, 255))
        if self.kb:
            keyboard(d, "done")
        return img

    def get_screenshot_as_png(self):
        st = self.state
        if st == "map":
            img = Image.new("RGB", (W, H), (120, 190, 120)); d = ImageDraw.Draw(img)
            for k in range(6): d.line([(0, k * 300), (W, k * 300 + 200)], fill=(230, 230, 200), width=30)
            cx, cy, r = W // 2, int(0.935 * H), int(0.07 * W)
            d.pieslice([cx - r, cy - r, cx + r, cy + r], 180, 360, fill=(222, 40, 40)); d.pieslice([cx - r, cy - r, cx + r, cy + r], 0, 180, fill=(250, 250, 250))
            return png(img)
        if st == "menu":
            img = Image.new("RGB", (W, H), (200, 240, 200)); d = ImageDraw.Draw(img)
            for x, y, s in ((0.23, 0.55, "POKÉDEX"), (0.77, 0.55, "BATTLE"), (0.5, 0.66, "SHOP"), (0.22, 0.78, "POKÉMON"), (0.77, 0.78, "ITEMS")):
                text_c(d, x, y, s, F(40, True), (60, 90, 90))
                d.ellipse([int((x - 0.06) * W), int((y + 0.025) * H), int((x + 0.06) * W), int((y + 0.08) * H)], outline=(60, 90, 90), width=4)
            return png(img)
        if st == "grid": return png(self.render_grid())
        if st == "multi": return png(self.render_grid(True))
        if st == "search": return png(self.render_search())
        if st == "sort_menu": return png(self.render_sort())
        if st == "detail": return png(self.render_detail())
        if st == "intro": return png(self.render_detail(bubble=True))
        if st == "bars": return png(self.render_detail(bars=True))
        if st == "dmenu": return png(self.render_dmenu())
        if st == "rename":                                    # the game's Set Nickname dialog
            img = self.render_detail(); d = ImageDraw.Draw(img)
            d.rounded_rectangle([int(0.03 * W), int(0.34 * H), int(0.97 * W), int(0.66 * H)], 30, fill=(255, 255, 255), outline=(150, 160, 160), width=3)
            text_c(d, 0.5, 0.38, "Set Nickname", F(40), (90, 100, 100))
            d.rounded_rectangle([int(0.12 * W), int(0.42 * H), int(0.88 * W), int(0.47 * H)], 30, outline=(80, 190, 190), width=3)
            text_c(d, 0.5, 0.445, self.typed or " ", F(48), (40, 40, 40))
            if self.refused_shown:
                text_c(d, 0.5, 0.50, "This name contains inappropriate text.", F(34), (90, 100, 100))
            d.rounded_rectangle([int(0.12 * W), int(0.515 * H), int(0.88 * W), int(0.565 * H)], 40, fill=(120, 210, 160))
            text_c(d, 0.5, 0.54, "OK", F(44, True), (255, 255, 255))
            text_c(d, 0.5, 0.61, "CANCEL", F(40, True), (60, 170, 150))
            if self.kb:
                keyboard(d, "done")
            return png(img)
        if st == "taglist": return png(self.render_list())
        if st == "create": return png(self.render_create())
        raise RuntimeError(st)

    # ------------------------------------------------------------ controls
    def get_window_size(self): return {"width": PT_W, "height": PT_H}

    @property
    def switch_to(self):
        phone = self
        class Active:
            def clear(self_):
                if phone.state == "rename": phone.typed = ""
        class SwitchTo:
            active_element = Active()
        return SwitchTo()
    def update_settings(self, s): pass
    def query_app_state(self, b): return 4
    def is_locked(self): return False
    def activate_app(self, b): self.state = "map"
    def terminate_app(self, b):
        self.state, self.off, self.filtered, self.kb, self.typed = "map", 0, False, False, ""
        self.sorted = False; self.events.append("restart")
    def quit(self): pass

    def open_list(self, targets, ret):
        self.list_targets = list(targets); self.list_return = ret; self.list_off = 0.0
        common = set.intersection(*[self.mons[i]["tags"] for i in targets]) if targets else set()
        union = set.union(*[self.mons[i]["tags"] for i in targets]) if targets else set()
        self.checked = set(common); self.initial = set(common); self.state = "taglist"
        self.mixed = (union - common) if len(targets) > 1 else set(); self.touched = set()
        self.list_opened = time.time()

    def done_list(self):
        # like the game: checked tags go to everyone; anything switched off by a tap (also from "Mixed")
        # is removed from everyone; untouched "Mixed" stays as it is
        off = {nm for nm in self.touched if nm not in self.checked and nm not in self.mixed}
        for i in self.list_targets:
            self.mons[i]["tags"] |= self.checked
            self.mons[i]["tags"] -= (self.initial - self.checked) | off
        if self.done_stuck and self.list_return == "grid" and self.checked - self.initial:
            # the tags were saved, but the tag picker stays open: the bot treats it as an error and repeats
            # the batch; the selected Pokémon already have the tag, so the repeat must not uncheck it
            self.done_stuck -= 1
            self.initial = set(self.checked)
            self.events.append("DONE saved, but the screen is stuck")
            return
        self.state = self.list_return; self.sel = set()

    def make_ghost(self, q):
        """A Pokémon whose CP the bot misread: in the game it has a different CP than the bot typed into the search.
        ghost=1: a Pokémon in the middle of a batch (some results are missing), ghost=2: the only Pokémon
        in the search (nothing is found)."""
        m = re.match(r"^(cp\d+(?:,cp\d+)*)(?:&|$)", q)
        if not m:
            return
        cps = {int(x) for x in re.findall(r"\d+", m.group(1))}
        cand = [i for i, mon in enumerate(self.mons) if mon["cp"] in cps]
        if (self.ghost == 1 and len(cand) < 3) or (self.ghost == 2 and len(cps) != 1) or not cand:
            return
        i = cand[len(cand) // 2]
        used = {mon["cp"] for mon in self.mons}
        new = self.mons[i]["cp"] + 1
        while new in used:
            new += 1
        self.events.append(f"CP{self.mons[i]['cp']} is CP{new} in the game")
        self.mons[i]["cp"], self.ghost_idx = new, i

    def finish_create(self):
        name = self.typed.strip()
        if name:
            if name in self.tags: self.bad.append(f"duplicate tag {name}")
            self.tags[name] = self.dlg_color; self.created.append((name, self.dlg_color))
            if self.auto_check: self.checked.add(name)
        self.state, self.typed, self.kb = "taglist", "", False

    def submit_name(self):
        name = self.typed.strip()
        if name in self.refuse:                               # the dialog stays open with the game's message
            self.refusals.append(name); self.refused_shown, self.kb = True, False
            return
        if name:
            self.mons[self.cur]["name"] = name[:12]; self.renamed.append(name)
        self.state, self.typed, self.kb, self.refused_shown = "detail", "", False, False

    def keys(self, txt):
        if self.state == "rename":
            for ch in txt:
                if ch == "\n":
                    if self.ok_needed: self.kb = False
                    else: self.submit_name()
                    return
                elif ch == "\b": self.typed = self.typed[:-1]
                else: self.typed += ch
            return
        if self.state == "search" and self.kb:
            for ch in txt:
                if ch == "\n":
                    q = self.typed.strip(); self.queries.append(q)
                    if self.ghost and self.ghost_idx is None:
                        self.make_ghost(q)
                    self.kb = False
                    if q: self.state, self.filtered, self.query, self.off = "grid", True, q, 0.0
                elif ch == "\b": self.typed = self.typed[:-1]
                else: self.typed += ch
        elif self.state == "create" and self.kb:
            for ch in txt:
                if ch == "\n":
                    if self.return_submits: self.finish_create(); return
                    self.kb = False
                elif ch == "\b": self.typed = self.typed[:-1]
                else: self.typed += ch

    def execute(self, cmd, params=None):
        if cmd == "pogoKeys":
            self.keys("".join(params["value"])); return {"value": None}
        acts = params["actions"][0]["actions"]
        moves = [a for a in acts if a["type"] == "pointerMove"]
        held = any(a["type"] == "pause" and a.get("duration", 0) > 0 for a in acts)
        dy = moves[0]["y"] / PT_H - moves[1]["y"] / PT_H
        dx = moves[1]["x"] / PT_W - moves[0]["x"] / PT_W
        if self.state in ("bars", "detail") and dx < -0.3 and abs(dy) < 0.1:
            if self.next_mon() and self.swipe_closes:
                self.state = "detail"
            return {"value": None}
        if self.state == "grid" and dy < -0.2 and self.off == 0 and not held:
            # like the real game: a quick downward swipe at the top of the list closes the storage
            self.state, self.filtered, self.query = "map", False, ""
            self.events.append("storage closed by swiping down")
            return {"value": None}
        if self.state in ("grid", "multi"):
            dy = dy * 3 if not held else dy * self.gain - 0.01 * np.sign(dy) + self.rnd.uniform(-0.03, 0.03)
            if self.state == "multi" and self.multi_fling and self.rnd.random() < self.multi_fling:
                dy += 0.7 * np.sign(dy)                       # the scroll overshot by several rows
                self.events.append("multiselect overshot")
            self.off = float(min(self.max_off(), max(0.0, self.off + dy)))
        elif self.state == "taglist":
            mx = max(0.0, 0.30 + (len(self.list_rows()) - 1) * 0.058 - 0.78)
            self.list_off = float(min(mx, max(0.0, self.list_off + dy)))
        return {"value": None}

    def next_mon(self):
        order = self.shown()
        k = order.index(self.cur)
        if self.nav and k + 1 < len(order):
            self.cur = order[k + 1]
            return True
        return False

    def cell_at(self, x, y):
        for pos, i in enumerate(self.shown()):
            row, col = divmod(pos, 3); cy = ROW0 + row * PITCH - self.off; cx = COLS[col]
            if abs(x - cx) < 0.15 and cy - 0.03 < y < cy + 0.14 and 0.215 < cy < 0.90: return i
        return None

    def execute_script(self, name, args):
        if name == "mobile: hideKeyboard":
            self.kb = False; return
        if name == "mobile: keys":
            self.keys("".join(args["keys"])); return
        x, y = args["x"] / PT_W, args["y"] / PT_H; self.taps += 1
        hold = "touchAndHold" in name
        if self.glitch and self.rnd.random() < self.glitch and self.state in ("grid", "detail", "multi"):
            g = self.rnd.choice(["map", "restart"]); self.events.append(f"glitch:{g}@{self.state}")
            if g == "map": self.state, self.off, self.filtered = "map", 0, False
            else: self.terminate_app(None)
            return
        st = self.state; near = lambda cx, cy, dx, dy: abs(x - cx) < dx and abs(y - cy) < dy
        if st == "map" and near(.5, .935, .06, .035): self.state = "menu"
        elif st == "menu" and near(.22, .81, .09, .07): self.state, self.filtered, self.off = "grid", False, 0.0
        elif st == "search":
            if self.kb and y > 0.62: return                       # the keyboard isn't tapped: typing goes through keys()
            if near(.105, .178, .05, .02): self.state, self.kb, self.typed = "grid", False, ""
            elif near(.5, .178, .4, .025): self.kb = True
        elif st == "sort_menu":
            if near(.68, .61, .2, .02): self.state, self.sorted = "grid", True
            elif near(.87, .94, .08, .04): self.state = "grid"
        elif st == "grid":
            if near(.87, .94, .06, .035): self.state = "sort_menu"
            elif near(.105, .178, .05, .02) or near(.915, .176, .05, .02):
                if self.filtered: self.filtered, self.off, self.query = False, 0.0, ""
            elif near(.5, .178, .35, .025) and not self.filtered: self.state, self.kb, self.typed = "search", True, ""
            elif near(.5, .94, .05, .03): self.state, self.off, self.filtered = "map", 0.0, False
            else:
                i = self.cell_at(x, y)
                if i is not None:
                    if hold: self.state, self.sel = "multi", {i}
                    else: self.state, self.cur = "detail", i
        elif st == "rename":
            if self.kb and y > 0.62:
                self.bad.append("keyboard tapped in the Set Nickname dialog"); return   # it would type into the name
            if near(.5, .54, .38, .025): self.submit_name()
            elif near(.5, .61, .2, .02): self.state, self.typed, self.kb, self.refused_shown = "detail", "", False, False
            # like the game: a tap outside the dialog does nothing
        elif st == "detail":
            if near(.5, .422, .3, .025): self.state, self.typed, self.kb = "rename", self.mons[self.cur]["name"], True; return
            if near(.87, .94, .08, .04): self.state = "dmenu"
            elif near(.5, .94, .05, .03): self.state = "grid"
            elif near(.5, .80, .45, .025): self.bad.append("EVOLVE row")
            elif near(.5, .75, .45, .02): self.bad.append("POWER UP row")
        elif st == "dmenu":
            if near(.70, .771, .3, .025): self.state = "intro"; self.appraisals += 1
            elif near(.70, .61, .3, .025): self.open_list([self.cur], "detail")
            elif near(.70, .853, .3, .025): self.bad.append("TRANSFER in menu")
            elif near(.87, .94, .08, .04): self.state = "detail"
        elif st == "intro": self.state = "bars"
        elif st == "bars":
            if x > 0.93 and 0.72 < y < 0.92:                            # the ▶ arrow
                self.nexts += 1
                if not self.swipe_closes and not self.next_mon():
                    self.state = "detail"                               # last one: no arrow, the tap closes it
            elif x < 0.07 and 0.72 < y < 0.92: pass                     # the ◀ arrow
            else: self.state = "detail"
        elif st == "multi":
            if near(.5, .86, .43, .025): self.open_list(sorted(self.sel), "grid")
            elif near(.5, .937, .45, .025): self.bad.append("TRANSFER in multiselect")
            elif near(.107, .117, .06, .03): self.state, self.sel = "grid", set()
            elif near(.81, .098, .15, .025) and (self.select_all or (self.filtered and self.select_all_search)):
                self.sel = set(self.shown()); self.events.append("select all")
            else:
                i = self.cell_at(x, y)
                if i is not None: self.sel ^= {i}
        elif st == "taglist":
            if near(.5, .86, .2, .025): self.done_list(); return
            if near(.5, .94, .05, .03):
                self.state = self.list_return if self.list_return == "detail" else "multi"; return
            for k, nm in enumerate(self.list_rows()):
                if abs(y - self.row_y(k)) < 0.025 and 0.24 < self.row_y(k) < 0.80:
                    if nm.startswith("+"):
                        self.state, self.typed, self.kb, self.dlg_color = "create", "", self.kb_auto, "blue"
                    elif nm in self.mixed:
                        self.mixed.discard(nm); self.touched.add(nm)      # "Mixed" → nothing (like the game)
                    else:
                        self.checked ^= {nm}; self.touched.add(nm)
                    return
        elif st == "create":
            if self.kb and y > 0.62: return
            if not (0.06 < x < 0.94 and 0.25 < y < 0.70):
                self.state, self.typed, self.kb = "taglist", "", False      # a tap outside the dialog = cancel
                self.events.append("dialog cancelled")
                return
            for (sx, sy), cname in zip(self.swatch_pos(), COLOR_ORDER):
                if abs(x - sx) < 0.045 and abs(y - sy) < 0.022:
                    self.dlg_color = cname; self.kb = False; return
            if near(.5, .38, .38, .03): self.kb = True
            elif near(.5, .635, .2, .025) and self.typed: self.finish_create()


def merging_ocr(orig):
    """OCR like on a real iPhone: merges the long nicknames of neighboring cells in the same row (with the tag dot)
    into one text ("• MAX 2992 L15 •MAX 3619 L20"), as happens after renaming with a template."""
    def ocr(data, fast=False):
        out = orig(data, fast)
        names = sorted((t for t in out if t["text"].lstrip().startswith("•") and len(t["text"]) >= 10
                        and t["cy"] > 0.215), key=lambda t: (round(t["cy"], 2), t["cx"]))
        used, merged = set(), []
        for a, b in zip(names, names[1:]):
            if id(a) in used or abs(a["cy"] - b["cy"]) > 0.01 or b["x0"] - a["x1"] > 0.08:
                continue
            used |= {id(a), id(b)}
            merged.append(dict(a, text=f"{a['text']} {b['text']}", x1=b["x1"], cx=(a["x0"] + b["x1"]) / 2))
        return [t for t in out if id(t) not in used] + merged
    return ocr


CP_QUERY = re.compile(r"^cp\d+(,cp\d+)*(&(.+))?$")


def query_ok(q):
    """A search the bot may type: SEARCH_QUERY, or a list of CPs (optionally & SEARCH_QUERY)."""
    m = CP_QUERY.match(q)
    return q == QUERY or bool(m and (m.group(3) is None or m.group(3) == QUERY))


def fill_stats(m):
    """CP and HP computed from the species' real stats, IVs and level, like in the game."""
    st = PC.SPECIES[m["sp"].lower()]["stats"]
    m["cp"] = PC.cp_of(st, m["iv"], PC._cpm_at(m["level"]))
    m["hp"] = max(10, int((st[2] + m["iv"][2]) * PC._cpm_at(m["level"])))


def make_mons(seed, big=0):
    rnd = random.Random(seed)
    # ordered by Pokédex number: the bot sorts the storage by number
    spec = [("Charmander", 3), ("Squirtle", 1), ("Pidgey", 3), ("Rattata", 2), ("Machop", 1), ("Geodude", 2), ("Eevee", 1)]
    mons = []
    for sp, n in spec:
        for _ in range(n):
            iv = tuple(rnd.randint(3, 15) for _ in range(3))
            mons.append({"sp": sp, "iv": iv, "level": rnd.randint(16, 60) / 2, "name": sp, "tags": set()})
    mons[1]["iv"] = (15, 15, 15)                      # 100 %
    mons[6]["tags"] = {"Mega"}                        # another tag: add the IV tag
    mons[3]["iv"] = (5, 6, 7)
    mons[3]["tags"] = {"95-99% Insane"}               # wrong IV tag: remove it and add the right one
    mons[12]["tags"] = {"100% Perfect", "70-0% Garbage"}   # two IV tags: keep only the right one
    mons[9]["iv"] = (0, 15, 14)                       # Machop: good PvP IVs
    mons[10]["name"] = "Kytka"                        # custom nickname: do not rename
    mons[10]["iv"] = (13, 14, 13)
    mons[7]["iv"] = (14, 13, 13)                      # 89 %: rename
    if big:                                           # bigger storage: legendaries with close CP (as in reality)
        extra = [("Dratini", 3), ("Mewtwo", 6), ("Chikorita", 2), ("Larvitar", 3), ("Kyogre", 9), ("Groudon", 8),
                 ("Dialga", 6), ("Palkia", 6)]
        for sp, n in extra:
            for _ in range(n):
                iv = tuple(rnd.randint(10, 15) for _ in range(3))
                lvl = 20 if sp in ("Mewtwo", "Kyogre", "Groudon", "Dialga", "Palkia") else rnd.randint(16, 60) / 2
                mons.append({"sp": sp, "iv": iv, "level": lvl, "name": sp, "tags": set()})
    for m in mons:
        fill_stats(m)
    return mons


DEFAULT_IV_TAGS, DEFAULT_TEMPLATE, DEFAULT_WEAK = list(S.IV_TAGS), list(S.RENAME["template"] or []), dict(S.WEAK)


class Args:
    max_groups = 0; fresh = False; only_iv = False; no_iv = False
    steps = {"duplicates", "iv", "pvp", "rename"}


def run(name, seed=3, verbose=False, only_iv=False, fast=True, steps=None, inject=False, **variant):
    rerun = variant.pop("rerun", False)       # a second run with the same memory (and one newly caught Eevee)
    mixed = variant.pop("mixed", False)       # some have Master League "since yesterday" and the bot cannot see its chip
    merge = variant.pop("merge_names", False) # OCR merges long names of neighboring cells (like the iPhone)
    max_reads = variant.pop("max_reads", None)    # the second run may read at most this many Pokémon (appraisal + ▶)
    refuse_first = variant.pop("refuse_first", False)   # the game refuses the name of the first Pokémon to rename
    battle = variant.pop("battle", None)      # Battle tags: [(name, color, picked indexes, indexes that already have it)]
    weak = variant.pop("weak", None)          # weak Pokémon: the max_iv %, or a dict of settings
    old_min = S.RENAME["min"]
    S.RENAME["min"] = variant.pop("rename_min", old_min)
    if variant.get("template"):
        S.RENAME["template"] = variant.pop("template")
    mons = make_mons(seed, variant.get("big", 0)); init = [set(m["tags"]) for m in mons]
    if variant.get("twins_rev"):              # two Kyogre with the same CP (and different IVs and HP) right after each other
        k = next(i for i, m in enumerate(mons) if m["sp"] == "Kyogre")
        for j, iv in ((k, (12, 12, 15)), (k + 1, (12, 13, 14))):
            mons[j].update(iv=iv, level=20); fill_stats(mons[j])
        assert mons[k]["cp"] == mons[k + 1]["cp"] and mons[k]["hp"] != mons[k + 1]["hp"]
    existing = [("Mega", "orange"), ("100% Perfect", "purple"), ("95-99% Insane", "blue"),
                ("70-0% Garbage", "black")]                         # the other tags are missing in the game
    if mixed:
        existing.append(("Master League", "purple"))
    for n, c, _, had in battle or []:
        if had:                                  # a tag already in the game, on Pokémon the app no longer picks
            existing.append((n, c))
            for i in had:
                mons[i]["tags"].add(n); init[i].add(n)
    S.BATTLE = {"tags": [{"name": n, "color": c, "mons": [{"cp": mons[i]["cp"], "iv": tuple(mons[i]["iv"])} for i in idx]}
                         for n, c, idx, _ in battle or []]}
    if weak is not None:
        S.WEAK = dict(DEFAULT_WEAK, **(weak if isinstance(weak, dict) else {"max_iv": weak}))
    phone = Phone(mons, seed, existing_tags=existing, **variant)
    refused = None
    if refuse_first:
        tpl = S.RENAME["template"] or PC.DEFAULT_TEMPLATE
        i = next(i for i, m in enumerate(mons) if S.RENAME["min"] <= round(sum(m["iv"]) * 100 / 45) <= S.RENAME["max"] and i != 10)
        m = mons[i]
        refused = PC.render_name(tpl, PC.chip_values(PC.info(m["sp"].lower(), m["iv"], m["level"], m["cp"]), m["iv"]))
        phone.refuse = {refused}
    run_dir = TMP / f"run_{name}"; (run_dir / "iv").mkdir(parents=True, exist_ok=True)
    S.SEARCH_QUERY = QUERY
    S.RECHECK_TAGGED = True                  # as in the author's settings: recheck tagged ones too
    for lg, mx in (("great", 1500), ("ultra", 1500), ("master", 300)):   # higher limits so there is something to tag
        S.PVP[lg]["max_rank"] = mx
    if mixed:
        wants = [i for i, m in enumerate(mons)
                 if (PC.league_rank(m["sp"].lower(), m["iv"], "master") or (9999,))[0] <= S.PVP["master"]["max_rank"]]
        for i in wants[::2]:                          # every second one already has it: the selection will be "Mixed"
            mons[i]["tags"].add("Master League"); init[i].add("Master League")
        phone.hide_chips = {"Master League"}
    log = S.log
    if not verbose:
        S.log = lambda msg="": None
    S.MEMORY_FILE = TMP / f"memory_{name}.json"
    bot = S.Bot(phone, run_dir); bot.udid = "SIM"; bot.fast = fast
    book, book2, mem = S.Book(), S.Book(), S.Memory(S.MEMORY_FILE)
    rep = S.Report(run_dir, 0); err = None; t0 = time.time()
    orig_scan, orig_ocr = S.grid_scan, S.ocr
    if merge:
        S.ocr = merging_ocr(orig_ocr)
    if inject:
        def grid_scan_bad(bot):
            # the scrolled list with a duplicated cell and a cell with a nonsense CP (like on a real phone)
            seq = orig_scan(bot)
            if len(seq) > 30:
                seq.insert(9, dict(seq[8]))
                seq.insert(21, dict(seq[20], cp=99999))
                seq.insert(len(seq) - 1, dict(seq[-1]))
            return seq
        S.grid_scan = grid_scan_bad
    first = second = None
    try:
        args = Args()
        args.steps = set(steps or (["iv"] if only_iv else Args.steps))
        S.run(bot, book, book2, mem, args, rep)
        if rerun:
            first = (time.time() - t0, phone.appraisals, phone.nexts)
            if rerun == "config":
                # the settings change between runs: different IV tag limits and a different name template
                S.IV_TAGS = [(100, "100% Perfect"), (95, "95-99% Insane"), (91, "90-95% Amazing"),
                             (86, "85-90% Great"), (81, "80-85% Good"), (70, "70-80% Mid"), (0, "70-0% Garbage")]
                S.RENAME["template"] = [{"k": "iv"}, {"k": "space"}, {"k": "short"}]
            else:
                # a newly caught Eevee appears between runs: a new duplicate and a new Pokémon to read
                new = {"sp": "Eevee", "iv": (15, 14, 13), "level": 21.0, "name": "Eevee", "tags": set()}
                fill_stats(new)
                k = max(i for i, m in enumerate(mons) if m["sp"] == "Eevee") + 1
                mons.insert(k, new); init.insert(k, set())
            phone.state, phone.filtered, phone.query, phone.off, phone.kb, phone.typed = "map", False, "", 0.0, False, ""
            a0, n0, t1 = phone.appraisals, phone.nexts, time.time()
            bot = S.Bot(phone, run_dir); bot.udid = "SIM"; bot.fast = fast
            book, book2, mem = S.Book(), S.Book(), S.Memory(S.MEMORY_FILE)
            rep = S.Report(run_dir, 0)
            S.run(bot, book, book2, mem, args, rep)
            second = (time.time() - t1, phone.appraisals - a0, phone.nexts - n0)
    except Exception as e:
        err = f"{type(e).__name__}: {e}"
    finally:
        S.log = log
        S.grid_scan, S.ocr = orig_scan, orig_ocr
    template = S.RENAME["template"] or PC.DEFAULT_TEMPLATE      # the template in effect at the end
    # --- expectations
    ghost = {phone.ghost_idx} if phone.ghost_idx is not None else set()
    ivnames = {n for _, n in S.IV_TAGS}
    by_sp = {}
    for i, m in enumerate(mons): by_sp.setdefault(m["sp"], []).append(i)
    exp_rem = set()
    st_used = set(steps or (["iv"] if only_iv else Args.steps))
    for idx in (by_sp.values() if "duplicates" in st_used else []):
        if len(idx) < 2: continue
        best = max(idx, key=lambda i: (sum(mons[i]["iv"]), *mons[i]["iv"]))
        exp_rem |= {i for i in idx if i != best}
    lgnames = {lg["name"] for lg in S.PVP.values()}
    btnames = {n for n, _, _, _ in battle or []}
    # who the weak step should tag: under the IV limit and not protected
    want_weak = set()
    if "weak" in st_used:
        best = {}
        for m in mons:
            best[m["sp"]] = max(best.get(m["sp"], -1), sum(m["iv"]))
        for i, m in enumerate(mons):
            if i in ghost or round(sum(m["iv"]) * 100 / 45) >= S.WEAK["max_iv"]:
                continue
            sp_tags = set((PC.SPECIES.get(m["sp"].lower()) or {}).get("tags") or [])
            if S.WEAK["keep_legendary"] and "legendary" in sp_tags: continue
            if S.WEAK["keep_mythical"] and "mythical" in sp_tags: continue
            if S.WEAK["keep_ultra_beast"] and "ultrabeast" in sp_tags: continue
            if S.WEAK["keep_regional"] and sp_tags & {"regional", "alolan", "galarian", "hisuian", "paldean"}: continue
            if S.WEAK["keep_battle"] and m["tags"] & (lgnames | btnames): continue
            if S.WEAK["keep_tag"] and S.WEAK["keep_tag"] in m["tags"]: continue
            if S.WEAK["keep_best"] and best[m["sp"]] == sum(m["iv"]): continue
            want_weak.add(i)
    exp_rem |= want_weak                     # the weak step adds the same tag and never takes it off
    bad_rem = sorted(i for i, m in enumerate(mons) if (S.TAG_NAME in m["tags"]) != (i in exp_rem) and i not in ghost)
    bad_iv = [(i, m["sp"], m["iv"], sorted(m["tags"])) for i, m in enumerate(mons)
              if "iv" in st_used and i not in exp_rem and i not in ghost and m["tags"] & ivnames != {S.iv_tag(m["iv"])}]
    bad_pvp, bad_name, bad_battle = [], [], []
    for i, m in enumerate(mons):
        if i in exp_rem or i in ghost:
            continue
        sid = m["sp"].lower()
        if "battle" in st_used:
            want = {n for n, _, idx, _ in battle or [] if i in idx}
            if m["tags"] & btnames != want:
                bad_battle.append((i, m["sp"], sorted(m["tags"] & btnames), sorted(want)))
        if "pvp" in st_used:
            want = {S.PVP[lg]["name"] for lg in S.PVP if (PC.league_rank(sid, m["iv"], lg) or (9999,))[0] <= S.PVP[lg]["max_rank"]}
            if m["tags"] & lgnames != want:
                bad_pvp.append((i, m["sp"], m["iv"], sorted(m["tags"] & lgnames), sorted(want)))
        if "rename" in st_used:
            pct = round(sum(m["iv"]) * 100 / 45)
            want = m["sp"] if m["sp"] != "" else ""
            if S.RENAME["min"] <= pct <= S.RENAME["max"] and i != 10:
                want = PC.render_name(template, PC.chip_values(PC.info(sid, m["iv"], m["level"], m["cp"]), m["iv"]))
            elif i == 10:
                want = "Kytka"
            if want == refused:
                want = m["sp"]                   # the game refused the name: the Pokémon keeps its own
            if m["name"] != want:
                bad_name.append((i, m["sp"], m["iv"], m["name"], want))
    other_lost = [i for i, m in enumerate(mons) if (init[i] - ivnames - lgnames - btnames - {S.TAG_NAME}) - m["tags"]]
    # a picture for the app for every Pokémon in the memory, and none for others (the saving runs in the background)
    want_cards = {S.card_key(it["cp"], it["iv"]) for it in S.Memory(S.MEMORY_FILE).box_items() if it.get("cp")}
    cdir, cards = S.cards_dir(S.MEMORY_FILE), set()
    for _ in range(40):
        cards = {f[:-4] for f in os.listdir(cdir) if f.endswith(".jpg") and not f.endswith(("_icon.jpg", ".tmp.jpg"))} \
            if cdir.exists() else set()
        if cards == want_cards:
            break
        time.sleep(0.1)
    bad_cards = sorted(cards ^ want_cards)
    wanted = ([S.TAG_NAME] if "duplicates" in st_used else []) + \
        ([n for _, n in S.IV_TAGS] if "iv" in st_used else []) + (sorted(lgnames) if "pvp" in st_used else []) + \
        (sorted(btnames) if "battle" in st_used else [])
    missing = [n for n in wanted if n not in phone.tags]
    wrong_color = [(n, c, S.tag_color(n)) for n, c in phone.created if c != S.tag_color(n)]
    ok = not err and not bad_rem and not bad_iv and not other_lost and not missing and not wrong_color \
        and not bad_pvp and not bad_name and not bad_battle and not phone.bad and not bad_cards \
        and ("duplicates" not in st_used or phone.queries) and all(query_ok(q) for q in phone.queries) \
        and (not variant.get("ghost") or ghost) and not phone.done_stuck \
        and (not rerun or (second is not None and second[1] <= 3)) \
        and (max_reads is None or (second is not None and second[1] + second[2] <= max_reads)) \
        and (not refused or (phone.refusals == [refused] and S.Memory(S.MEMORY_FILE).refused_name(refused)))
    print(f"{'OK ' if ok else 'FAIL'} {name:28s} error={err} | Removable wrong={bad_rem} | IV wrong={bad_iv} | "
          f"PvP wrong={bad_pvp} | names wrong={bad_name} | {f'Battle wrong={bad_battle} | ' if battle else ''}"
          f"renamed={phone.renamed} | "
          f"{f'refused={phone.refusals} | ' if refused else ''}"
          f"cards={len(cards)}{f' wrong={bad_cards[:4]}' if bad_cards else ''} | "
          f"other tags lost={other_lost} | missing tags={missing} | wrong color={wrong_color} | "
          f"created={len(phone.created)} | searches={len(phone.queries)}× | dangerous={phone.bad} | "
          f"taps={phone.taps} | events={phone.events[:5]} | {time.time() - t0:.0f}s" +
          (f" | run 1 {first[0]:.0f}s, appraisal {first[1]}×, ▶ {first[2]}× | run 2 {second[0]:.0f}s, "
           f"appraisal {second[1]}×, ▶ {second[2]}×" if first and second else ""), flush=True)
    S.IV_TAGS, S.RENAME["template"] = list(DEFAULT_IV_TAGS), list(DEFAULT_TEMPLATE)   # later scenarios start from the defaults
    S.BATTLE = {"tags": []}
    S.WEAK = dict(DEFAULT_WEAK)
    S.RENAME["min"] = old_min
    return ok


SCENARIOS = {
    "basic": dict(),
    "keyboard_auto": dict(kb_auto=True),
    "enter_creates_tag": dict(return_submits=True),
    "colors_in_two_rows": dict(two_rows=True),
    "new_tag_auto_checked": dict(auto_check=True),
    "only_iv_tags": dict(only_iv=True),
    "pvp_and_rename": dict(steps=["pvp", "rename"]),
    "slow_mode": dict(fast=False),
    "no_next_in_appraisal": dict(nav=False),
    "swipe_closes_appraisal": dict(swipe_closes=True),
    "glitches": dict(glitch=0.04),
    "only_duplicates": dict(steps=["duplicates"]),
    "no_select_all": dict(big=1, select_all_search=False, steps=["iv", "pvp"]),
    "real_phone": dict(gain=1.6, big=1, cp_flaky=0.15, steps=["iv", "pvp", "rename"]),
    "real_phone_all_steps": dict(gain=1.6, big=1, cp_flaky=0.15),
    "duplicated_list": dict(big=1, inject=True, steps=["iv"]),
    "multiselect_overshoots": dict(gain=1.6, big=1, multi_fling=0.3, steps=["iv"]),
    "cp_missing_in_batch": dict(big=1, ghost=1),
    "search_finds_nothing": dict(big=1, ghost=2),
    "already_tagged": dict(big=1, done_stuck=1, check_delay=0.6, steps=["iv", "pvp"]),
    "rerun": dict(big=1, rerun=True),
    "rerun_real_phone": dict(gain=1.6, big=1, cp_flaky=0.15, rerun=True),
    # renaming to long names ("MAX 3351 L15") that OCR merges in the grid; the second run must recognize them from memory
    "rerun_long_names": dict(gain=1.6, big=1, cp_flaky=0.15, rerun=True, merge_names=True, rename_min=0,
                             max_reads=4,
                             template=[{"k": "text", "v": "MAX"}, {"k": "space"}, {"k": "cpMax"},
                                       {"k": "space"}, {"k": "lvl"}]),
    "settings_changed": dict(big=1, rerun="config"),
    # the game refuses one name ("inappropriate text"): CANCEL, no second try, and the next run doesn't try it again;
    # Enter only hides the keyboard and OK saves the name, like in the game
    "name_refused": dict(rerun=True, steps=["rename"], ok_needed=True, refuse_first=True,
                         template=[{"k": "text", "v": "MAX"}, {"k": "space"}, {"k": "cpMax"},
                                   {"k": "space"}, {"k": "lvl"}]),
    "mixed_tags": dict(big=1, mixed=True, steps=["pvp"]),
    # two Kyogre with the same CP that the search shows in reverse order; each name must go to the right one
    # Battle tags from the app's picks: "Raid" already in the game on two Pokémon that are no longer picked (it must
    # come off them), "GL tým" missing (created in its color)
    "battle_tags": dict(big=1, steps=["battle"], battle=[("Raid", "red", [9, 1, 4], [5, 12]), ("GL tým", "green", [7, 3], [])]),
    "battle_all_steps": dict(big=1, steps=["duplicates", "iv", "pvp", "rename", "battle"],
                             battle=[("Raid", "red", [9, 1, 4], [5]), ("GL tým", "green", [7], [])]),
    # weak Pokémon: everyone under the IV limit gets the transfer tag, but the protections keep the rare ones
    "weak_pokemon": dict(big=1, steps=["weak"], weak=80),
    "weak_with_duplicates": dict(big=1, steps=["duplicates", "iv", "weak"], weak=75),
    # every protection off: even legendaries under the limit get tagged
    "weak_no_keeps": dict(big=1, steps=["weak"],
                          weak=dict(max_iv=80, keep_legendary=False, keep_mythical=False, keep_ultra_beast=False,
                                    keep_regional=False, keep_best=False, keep_battle=False)),
    "twins_same_cp": dict(big=1, twins_rev=True, steps=["iv", "rename"],
                          template=[{"k": "text", "v": "MAX"}, {"k": "space"}, {"k": "cpMax"},
                                    {"k": "space"}, {"k": "lvl"}]),
}

if __name__ == "__main__":
    if "verbose" in sys.argv:
        run("verbose", verbose=True)
    else:
        only = [a for a in sys.argv[1:] if a in SCENARIOS]
        results = [run(n, **SCENARIOS[n]) for n in (only or SCENARIOS)]
        print(f"\n{sum(results)}/{len(results)} scenarios passed")
        sys.exit(0 if all(results) else 1)
