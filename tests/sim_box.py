"""Synthetic storage with scrolling: tests a pass over several screens, a large group,
imprecise scrolls (inertia), glitches and restarts. Checks that exactly the right Pokémon get tagged."""
import io, os, sys, time, random, tempfile, json
os.environ["POGO_NO_STREAM"] = "1"
from pathlib import Path
import numpy as np
from PIL import Image, ImageDraw, ImageFont
from support import S
import sim_navigation as SIM1

R = os.environ.get("POGO_SCREENS", os.path.expanduser("~/Desktop/pogo_runs/")).rstrip("/") + "/"
TMP = Path(tempfile.mkdtemp(prefix="pogo_sim_box_"))
S.CAL_FILE = TMP / "cal.json"; S.MEMORY_FILE = TMP / "memory.json"; S.OUT_DIR = TMP / "runs"
S.NAV_TIMEOUT = 60
S.TAG_NAME = "toREmove"   # the synthetic tag list uses this name
W, H = 1206, 2622
PITCH, ROW0 = 0.1665, 0.274
COLS = [0.18, 0.495, 0.81]
def F(size, bold=False):
    return ImageFont.truetype("/System/Library/Fonts/Supplemental/Arial Bold.ttf" if bold else "/System/Library/Fonts/Supplemental/Arial.ttf", size)

def rgb(path): return Image.open(R + path + ".png").convert("RGB")
def sprite(path, cx, cy): return rgb(path).crop((int((cx-0.11)*W), int((cy+0.02)*H), int((cx+0.11)*W), int((cy+0.095)*H)))
SPR = {"Tinkatink": sprite("20261002_161252/15_grid", 0.187, 0.274), "Charcadet": sprite("20261002_161252/15_grid", 0.819, 0.274),
       "Nacli": sprite("20261002_161252/15_grid", 0.502, 0.607), "Fidough": sprite("20261002_161252/15_grid", 0.187, 0.773),
       "Charmander": sprite("20261002_160212/22_grid", 0.49, 0.274), "Charizard": sprite("20261002_160212/22_grid", 0.49, 0.44),
       "Rattata": sprite("20261002_160212/22_grid", 0.49, 0.773), "Venusaur": sprite("20261002_161252/04_menu_pokemon_check_0", 0.178, 0.278),
       "Squirtle": sprite("20261002_161252/04_menu_pokemon_check_0", 0.494, 0.775), "Blastoise": sprite("20261002_161252/04_menu_pokemon_check_0", 0.808, 0.775)}
TYPES = {"Tinkatink": "FAIRY / STEEL", "Charcadet": "FIRE", "Nacli": "ROCK", "Fidough": "FAIRY", "Charmander": "FIRE", "Charizard": "FIRE / FLYING",
         "Rattata": "NORMAL", "Venusaur": "GRASS / POISON", "Squirtle": "WATER", "Blastoise": "WATER"}
HEADER = rgb("20261002_161252/15_grid").crop((0, 0, W, int(0.215 * H)))

def make_box(seed):
    rnd = random.Random(seed)
    spec = [("Venusaur", 1), ("Charmander", 4), ("Charizard", 5), ("Squirtle", 1), ("Blastoise", 2), ("Rattata", 3),
            ("Tinkatink", 14), ("Charcadet", 4), ("Nacli", 3), ("Fidough", 2)]
    mons, used = [], set()
    for sp, n in spec:
        for k in range(n):
            while True:
                cp = rnd.randint(100, 2500)
                if cp not in used: used.add(cp); break
            iv = tuple(rnd.randint(0, 15) for _ in range(3))
            name = sp if rnd.random() > 0.2 else f"Ma {rnd.randint(1000, 9999)}"
            mons.append({"id": len(mons), "sp": sp, "cp": cp, "iv": iv, "name": name, "tags": set()})
    # a twin with the same CP and name (ambiguous), with worse IVs
    r = [m for m in mons if m["sp"] == "Rattata"]
    r[1]["cp"], r[1]["name"], r[2]["name"] = r[2]["cp"], "Rattata", "Rattata"
    r[1]["iv"], r[2]["iv"] = (1, 2, 3), (2, 1, 3)
    r[0]["iv"] = (10, 10, 10)
    return mons

def expected(mons):
    exp = set()
    for sp in {m["sp"] for m in mons}:
        g = [m for m in mons if m["sp"] == sp]
        if len(g) < 2: continue
        best = max(g, key=lambda m: (sum(m["iv"]), *m["iv"]))
        for m in g:
            if m is best: continue
            amb = sum(1 for o in g if o["cp"] == m["cp"] and S.names_ok(o["name"], m["name"])) > 1
            if not amb: exp.add(m["id"])
    return exp

def draw_text_c(d, xy, text, f, fill):
    w = d.textlength(text, font=f); d.text((xy[0] - w / 2, xy[1] - f.size * 0.55), text, font=f, fill=fill)

def render_grid(mons, off, multi=False, sel=()):
    img = Image.new("RGB", (W, H), (238, 248, 238)); d = ImageDraw.Draw(img)
    y_evo = 0.235 - off
    if 0.2 < y_evo < 1: draw_text_c(d, (0.55 * W, y_evo * H), "SHOW EVOLUTIONARY LINE", F(34, True), (40, 140, 150))
    for m in mons:
        row, col = divmod(m["id"], 3)
        cy = ROW0 + row * PITCH - off; cx = COLS[col]
        if cy < 0.15 or cy > 1.05: continue
        if multi and m["id"] in sel:
            d.rectangle([int((cx - 0.155) * W), int((cy - 0.02) * H), int((cx + 0.155) * W), int((cy + 0.135) * H)], fill=(215, 240, 205))
        fcp, fnum = F(30), F(62)
        wn = d.textlength(str(m["cp"]), font=fnum); wc = d.textlength("CP", font=fcp)
        x0 = cx * W - (wn + wc + 4) / 2
        d.text((x0, cy * H - 6), "CP", font=fcp, fill=(110, 120, 120)); d.text((x0 + wc + 4, cy * H - 36), str(m["cp"]), font=fnum, fill=(60, 70, 70))
        img.paste(SPR[m["sp"]], (int((cx - 0.11) * W), int((cy + 0.02) * H)))
        nm = ("• " if m["tags"] else "") + m["name"]
        draw_text_c(d, (cx * W, (cy + 0.105) * H), nm, F(44, True), (50, 60, 60))
        d.line([int((cx - 0.07) * W), int((cy + 0.125) * H), int((cx + 0.07) * W), int((cy + 0.125) * H)], fill=(100, 220, 170), width=8)
    img.paste(HEADER, (0, 0))
    if multi:
        d.rectangle([0, 0, W, int(0.15 * H)], fill=(40, 95, 110))
        draw_text_c(d, (0.81 * W, 0.098 * H), "SELECT ALL", F(40, True), (255, 255, 255))
        draw_text_c(d, (0.107 * W, 0.117 * H), "X", F(50), (150, 230, 160))
        n = len(sel)
        d.rounded_rectangle([int(0.07 * W), int(0.835 * H), int(0.93 * W), int(0.885 * H)], 60, fill=(100, 205, 160))
        draw_text_c(d, (0.5 * W, 0.86 * H), f"TAG ({n})", F(48, True), (255, 255, 255))
        d.rounded_rectangle([int(0.07 * W), int(0.912 * H), int(0.93 * W), int(0.962 * H)], 60, fill=(255, 255, 255), outline=(60, 200, 170), width=5)
        draw_text_c(d, (0.5 * W, 0.937 * H), f"TRANSFER ({n})", F(44, True), (60, 190, 170))
    else:
        for cx in (0.5, 0.87):
            d.ellipse([int((cx - 0.045) * W), int(0.91 * H), int((cx + 0.045) * W), int(0.97 * H)], fill=(225, 245, 240), outline=(40, 120, 120), width=4)
        draw_text_c(d, (0.5 * W, 0.94 * H), "X", F(50), (40, 120, 120)); draw_text_c(d, (0.87 * W, 0.94 * H), "#", F(50), (40, 120, 120))
    return img

DETAIL = rgb("20261002_161252/16_detail_cp487_check_0")
def render_detail(m):
    img = DETAIL.copy(); d = ImageDraw.Draw(img)
    bg = img.getpixel((int(0.3 * W), int(0.072 * H)))
    d.rectangle([int(0.3 * W), int(0.04 * H), int(0.66 * W), int(0.105 * H)], fill=bg)
    draw_text_c(d, (0.47 * W, 0.072 * H), f"CP{m['cp']}", F(90), (255, 255, 255))
    d.rectangle([int(0.2 * W), int(0.40 * H), int(0.8 * W), int(0.445 * H)], fill=(255, 255, 255))
    draw_text_c(d, (0.5 * W, 0.422 * H), m["name"], F(66, True), (60, 70, 70))
    d.rectangle([int(0.3 * W), int(0.555 * H), int(0.72 * W), int(0.582 * H)], fill=(255, 255, 255))
    draw_text_c(d, (0.5 * W, 0.568 * H), TYPES[m["sp"]], F(34), (110, 120, 120))
    return img

BARS_BASE = rgb("20261002_160212/32_tap_appraisal_zavrit_cp691_0")
def bar_geom():
    a = np.array(BARS_BASE); b = io.BytesIO(); BARS_BASE.save(b, "PNG")
    fr = S.Frame(a, b.getvalue(), 0); labs = S.bar_labels(fr.texts); _, bars = S.read_bars(a, labs)
    geo = []
    for left, right, fe, row, pink in bars:
        xm = left + 10
        isbar = lambda y: not (a[y, xm] > 245).all()
        top = row; bot = row
        while isbar(top - 1): top -= 1
        while isbar(bot + 1): bot += 1
        seps = [x for x in range(left, right) if (a[row, x] > 245).all()]
        geo.append((left, right, top, bot, seps))
    return geo
GEO = bar_geom()
def render_bars(m):
    a = np.array(BARS_BASE).copy()
    for (left, right, top, bot, seps), iv in zip(GEO, m["iv"]):
        a[top:bot + 1, left:right + 1] = (226, 226, 226)
        fe = left + int((right - left) * iv / 15)
        a[top:bot + 1, left:fe + 1] = (224, 128, 134) if iv == 15 else (243, 168, 79)
        for x in seps: a[top:bot + 1, x] = (255, 255, 255)
    return Image.fromarray(a)

def png(img): b = io.BytesIO(); img.save(b, "PNG"); return b.getvalue()

class Phone:
    def __init__(self, mons, seed, glitch_rate=0.0, inertia=0.03):
        self.mons = mons; self.rnd = random.Random(seed); self.glitch = glitch_rate; self.inertia = inertia
        self.state = "map"; self.off = 0.0; self.sel = set(); self.cur = None; self.checked = False
        self.filtered = False; self.sorted = False; self.taps = 0; self.bad = []; self.events = []
        rows = (len(mons) + 2) // 3
        self.max_off = max(0.0, ROW0 + (rows - 1) * PITCH - 0.70)
        self._cache = {}
    def get_window_size(self): return {"width": 402, "height": 874}
    def update_settings(self, s): pass
    def query_app_state(self, b): return 4
    def is_locked(self): return False
    def activate_app(self, b): self.state = "map"
    def terminate_app(self, b): self.state = "map"; self.off = 0; self.events.append("restart")
    def quit(self): pass
    def get_screenshot_as_png(self):
        st = self.state
        key = (st, round(self.off, 4), tuple(sorted(self.sel)), self.cur, self.checked, tuple(len(m["tags"]) for m in self.mons))
        if key in self._cache: return self._cache[key]
        if st == "grid": out = png(render_grid(self.mons, self.off))
        elif st == "multi": out = png(render_grid(self.mons, self.off, True, self.sel))
        elif st == "detail": out = png(render_detail(self.mons[self.cur]))
        elif st == "bars": out = png(render_bars(self.mons[self.cur]))
        elif st == "dmenu": out = SIM1.SCREENS["dmenu_487"]
        elif st == "intro": out = SIM1.SCREENS["intro_487"]
        elif st == "taglist": out = SIM1.SCREENS["taglist_on" if self.checked else "taglist"]
        else: out = SIM1.SCREENS[st]
        if len(self._cache) > 300: self._cache.clear()
        self._cache[key] = out
        return out
    def cell_at(self, x, y):
        for m in self.mons:
            row, col = divmod(m["id"], 3); cy = ROW0 + row * PITCH - self.off; cx = COLS[col]
            if abs(x - cx) < 0.15 and cy - 0.03 < y < cy + 0.14 and 0.215 < cy < 0.90: return m
        return None
    def maybe_glitch(self):
        if self.rnd.random() < self.glitch:
            opts = ["map", "restart"] + (["evolve"] if self.state == "detail" else []) + (["transfer"] if self.state == "multi" else [])
            g = self.rnd.choice(opts); self.events.append(f"glitch:{g}@{self.state}")
            if g == "map": self.state, self.off, self.filtered = "map", 0, False
            elif g == "restart": self.terminate_app(None); self.filtered = False
            elif g == "evolve": self.state = "evolve"
            elif g == "transfer": self.state = "transfer"
            return True
        return False
    def execute(self, cmd, params=None):
        acts = params["actions"][0]["actions"]
        moves = [a for a in acts if a["type"] == "pointerMove"]
        held = any(a["type"] == "pause" and a.get("duration", 0) > 0 for a in acts)
        y0, y1 = moves[0]["y"] / 874, moves[1]["y"] / 874
        if self.state == "grid":
            dy = (y0 - y1)
            if held: dy = dy - 0.01 * np.sign(dy) + self.rnd.uniform(-self.inertia, self.inertia)
            else: dy *= 3
            self.off = float(min(self.max_off, max(0.0, self.off + dy)))
        elif self.state == "taglist":
            pass
        return {"value": None}
    def execute_script(self, name, args):
        x, y = args["x"] / 402, args["y"] / 874; self.taps += 1
        hold = "touchAndHold" in name
        if self.maybe_glitch(): return
        st = self.state
        near = lambda cx, cy, dx, dy: abs(x - cx) < dx and abs(y - cy) < dy
        if st == "map" and near(0.5, 0.935, 0.06, 0.035): self.state = "menu"
        elif st == "menu":
            if near(0.22, 0.81, 0.09, 0.07): self.state = "box_unf"
        elif st == "box_unf":
            if near(0.5, 0.18, 0.35, 0.025): self.state = "search"
            elif near(0.5, 0.94, 0.05, 0.03): self.state = "map"
        elif st == "search":
            if near(0.62, 0.35, 0.08, 0.07): self.state, self.off, self.filtered = "grid", 0.0, True
        elif st == "sort_menu":
            if near(0.68, 0.61, 0.2, 0.02): self.state, self.sorted = "grid", True
            elif near(0.87, 0.94, 0.08, 0.04): self.state = "grid"
        elif st == "grid":
            if near(0.87, 0.94, 0.06, 0.035): self.state = "sort_menu"
            elif near(0.105, 0.178, 0.05, 0.02): self.state, self.filtered = "box_unf", False
            elif near(0.5, 0.94, 0.05, 0.03): self.state, self.off = "map", 0.0
            else:
                m = self.cell_at(x, y)
                if m is not None:
                    if hold: self.state, self.sel = "multi", {m["id"]}
                    else: self.state, self.cur = "detail", m["id"]
        elif st == "detail":
            if near(0.87, 0.94, 0.08, 0.04): self.state = "dmenu"
            elif near(0.5, 0.94, 0.05, 0.03): self.state = "grid"
            elif near(0.5, 0.80, 0.45, 0.04): self.bad.append("EVOLVE row"); self.state = "evolve"
        elif st == "dmenu":
            if near(0.67, 0.771, 0.3, 0.025): self.state = "intro"
            elif near(0.66, 0.853, 0.3, 0.025): self.bad.append("TRANSFER in menu"); self.state = "transfer"
            elif near(0.87, 0.94, 0.08, 0.04): self.state = "detail"
        elif st == "intro": self.state = "bars"
        elif st == "bars": self.state = "detail"
        elif st == "multi":
            if near(0.5, 0.86, 0.43, 0.025): self.state, self.checked = "taglist", False
            elif near(0.5, 0.937, 0.45, 0.025): self.bad.append("TRANSFER in multiselect"); self.state = "transfer"
            elif near(0.107, 0.117, 0.06, 0.03): self.state, self.sel = "grid", set()
            else:
                m = self.cell_at(x, y)
                if m is not None: self.sel ^= {m["id"]}
        elif st == "transfer":
            if near(0.5, 0.643, 0.2, 0.025): self.state = "multi" if self.sel else "grid"
            elif near(0.5, 0.566, 0.25, 0.03): self.bad.append("!!! TRANSFER CONFIRMED !!!")
        elif st == "taglist":
            if near(0.3, 0.742, 0.3, 0.025): self.checked = not self.checked
            elif near(0.5, 0.86, 0.2, 0.025):
                if self.checked:
                    for i in self.sel: self.mons[i]["tags"].add("toREmove")
                self.state, self.sel = "grid", set()
            elif near(0.5, 0.94, 0.05, 0.03): self.state = "multi"
        elif st == "evolve":
            if near(0.5, 0.662, 0.2, 0.025): self.state = "detail"
            elif near(0.5, 0.597, 0.2, 0.03): self.bad.append("!!! EVOLVE CONFIRMED !!!")

class Args: max_groups = 0; fresh = False; only_iv = False; no_iv = True

def run(seed=1, glitch=0.0, inertia=0.03, verbose=False):
    mons = make_box(seed); phone = Phone(mons, seed, glitch, inertia)
    run_dir = TMP / f"run_{seed}_{glitch}"; (run_dir / "iv").mkdir(parents=True, exist_ok=True)
    if not verbose: S.log = lambda msg="": None
    bot = S.Bot(phone, run_dir); book = S.Book(); mem = S.Memory(TMP / f"memory_{seed}_{glitch}.json")
    rep = S.Report(run_dir, 0); t0 = time.time(); err = None
    try: S.run(bot, book, S.Book(), mem, Args(), rep)
    except Exception as e: err = f"{type(e).__name__}: {e}"
    tagged = {m["id"] for m in mons if m["tags"]}; exp = expected(mons)
    ivs_ok = all(any(tuple(r.iv) == m["iv"] for m in mons if m["cp"] == r.cp and S.names_ok(m["name"], r.name)) for r in book.recs if r.iv)
    print(f"seed={seed} glitch={glitch} inertia={inertia}: error={err} | dangerous={phone.bad} | "
          f"tagged={len(tagged)} expected={len(exp)} diff: extra={sorted(tagged-exp)} missing={sorted(exp-tagged)} | "
          f"IVs correct={ivs_ok} | taps={phone.taps} | events={phone.events[:8]} | {time.time()-t0:.0f}s")
    return phone, book

if __name__ == "__main__":
    args = sys.argv[1:]
    if "verbose" in args:
        run(1, 0.0, 0.03, verbose=True)
    else:
        for seed, glitch, inertia in [(1, 0.0, 0.0), (2, 0.0, 0.04), (3, 0.03, 0.04), (4, 0.06, 0.05)]:
            run(seed, glitch, inertia)
