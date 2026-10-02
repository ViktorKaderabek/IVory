"""Simulátor obou částí: duplicity -> Removable, pak celý box -> IV tagy (přes detail ≡ -> TAG)."""
import io, os, sys, time, random
os.environ["POGO_NO_STREAM"] = "1"
import numpy as np
from PIL import Image, ImageDraw
import sys as _sys
from pathlib import Path as _Path
_sys.path.insert(0, str(_Path(__file__).resolve().parents[1] / "core"))
_sys.path.insert(0, str(_Path(__file__).resolve().parent))
import pogo_bot as S
import sim2
from sim2 import F, W, H, draw_text_c, png, SPR, TYPES, COLS, ROW0, PITCH

S.NAV_TIMEOUT = 60
HEADER_ALL = Image.open(sim2.R + "20261002_161252/05_search_0.png").convert("RGB").crop((0, 0, W, int(0.215 * H)))
HEADER_DUP = sim2.HEADER
DETAIL = sim2.DETAIL
REAL = {k: Image.open(sim2.R + v + ".png").convert("RGB") for k, v in {
    "map": "20261002_161252/01_map", "menu": "20261002_161252/02_menu", "search": "20261002_161252/07_search_check_0",
    "sort_menu": "20261002_161252/11_sort_check_0", "dmenu": "20261002_161252/17_menu_cp487_check_0",
    "intro": "20261002_161252/20_appraise_cp487_check_0", "transfer": "20261002_161252/36_tag_button_check_0",
    "evolve": "20261002_155706/24_tap_zav_t"}.items()}
OTHER_TAGS = ["MEGA", "Evolve", "PowerUp"]

def make_mons(seed):
    rnd = random.Random(seed)
    spec = [("Venusaur", 1), ("Charmander", 3), ("Squirtle", 1), ("Blastoise", 1), ("Rattata", 2), ("Tinkatink", 1),
            ("Charcadet", 3), ("Nacli", 1), ("Fidough", 2)]
    mons, used = [], set()
    for sp, n in spec:
        for _ in range(n):
            while True:
                cp = rnd.randint(100, 2500)
                if cp not in used: used.add(cp); break
            iv = tuple(rnd.randint(4, 15) for _ in range(3))
            mons.append({"sp": sp, "cp": cp, "iv": iv, "name": sp, "tags": set()})
    # výchozí tagy: správný, špatný, dva IV tagy, jiný tag
    mons[0]["tags"] = {S.iv_tag(mons[0]["iv"])}                       # správně otagovaný -> přeskočit
    mons[4]["tags"] = {"MEGA"}                                          # jiný tag -> doplnit IV tag
    mons[5]["tags"] = {"100% Perfect", "70-0% Garbage"}                 # dva IV tagy -> opravit
    mons[13]["tags"] = {"PowerUp", "85-90% Great" if S.iv_tag(mons[13]["iv"]) != "85-90% Great" else "80-85% Good"}  # jeden špatný -> nechá být
    return mons

class Phone:
    def __init__(self, mons, seed, glitch=0.0):
        self.mons = mons; self.rnd = random.Random(seed); self.glitch = glitch
        self.state = "map"; self.filtered = False; self.off = 0.0; self.sel = set(); self.cur = None
        self.list_off = 0.0; self.checked = set(); self.list_targets = []; self.list_return = "grid"
        self.typed = ""; self.taps = 0; self.bad = []; self.events = []; self.created = 0
        self.tag_names = OTHER_TAGS + [n for _, n in S.IV_TAGS]          # Removable zatím neexistuje
        class CE:
            def get_command(s, n): return ("POST", "/x")
            def add_command(s, *a): pass
        self.command_executor = CE()
    # --- seznam, který box ukazuje
    def shown(self):
        if not self.filtered: return list(range(len(self.mons)))
        cnt = {}
        for m in self.mons: cnt[m["sp"]] = cnt.get(m["sp"], 0) + 1
        return [i for i, m in enumerate(self.mons) if cnt[m["sp"]] >= 2]
    def max_off(self):
        rows = (len(self.shown()) + 2) // 3
        return max(0.0, ROW0 + (rows - 1) * PITCH - 0.70)
    # --- vykreslení
    def render_grid(self, multi=False):
        img = Image.new("RGB", (W, H), (238, 248, 238)); d = ImageDraw.Draw(img)
        if self.filtered and 0.2 < 0.235 - self.off < 1:
            draw_text_c(d, (0.55 * W, (0.235 - self.off) * H), "SHOW EVOLUTIONARY LINE", F(34, True), (40, 140, 150))
        for pos, i in enumerate(self.shown()):
            m = self.mons[i]; row, col = divmod(pos, 3); cy = ROW0 + row * PITCH - self.off; cx = COLS[col]
            if cy < 0.15 or cy > 1.05: continue
            if multi and i in self.sel:
                d.rectangle([int((cx - .155) * W), int((cy - .02) * H), int((cx + .155) * W), int((cy + .135) * H)], fill=(215, 240, 205))
            fcp, fnum = F(30), F(62); wn = d.textlength(str(m["cp"]), font=fnum); wc = d.textlength("CP", font=fcp)
            x0 = cx * W - (wn + wc + 4) / 2
            d.text((x0, cy * H - 6), "CP", font=fcp, fill=(110, 120, 120)); d.text((x0 + wc + 4, cy * H - 36), str(m["cp"]), font=fnum, fill=(60, 70, 70))
            img.paste(SPR[m["sp"]], (int((cx - 0.11) * W), int((cy + 0.02) * H)))
            draw_text_c(d, (cx * W, (cy + 0.105) * H), ("• " if m["tags"] else "") + m["name"], F(44, True), (50, 60, 60))
        img.paste(HEADER_DUP if self.filtered else HEADER_ALL, (0, 0))
        if multi:
            n = len(self.sel)
            d.rectangle([0, 0, W, int(0.15 * H)], fill=(40, 95, 110))
            draw_text_c(d, (0.81 * W, 0.098 * H), "SELECT ALL", F(40, True), (255, 255, 255)); draw_text_c(d, (0.107 * W, 0.117 * H), "X", F(50), (150, 230, 160))
            d.rounded_rectangle([int(.07 * W), int(.835 * H), int(.93 * W), int(.885 * H)], 60, fill=(100, 205, 160)); draw_text_c(d, (.5 * W, .86 * H), f"TAG ({n})", F(48, True), (255, 255, 255))
            d.rounded_rectangle([int(.07 * W), int(.912 * H), int(.93 * W), int(.962 * H)], 60, fill=(255, 255, 255), outline=(60, 200, 170), width=5); draw_text_c(d, (.5 * W, .937 * H), f"TRANSFER ({n})", F(44, True), (60, 190, 170))
        else:
            for cx in (0.5, 0.87):
                d.ellipse([int((cx - .045) * W), int(.91 * H), int((cx + .045) * W), int(.97 * H)], fill=(225, 245, 240), outline=(40, 120, 120), width=4)
            draw_text_c(d, (.5 * W, .94 * H), "X", F(50), (40, 120, 120)); draw_text_c(d, (.87 * W, .94 * H), "#", F(50), (40, 120, 120))
        return img
    def render_detail(self):
        m = self.mons[self.cur]
        img = sim2.render_detail({"cp": m["cp"], "name": m["name"], "sp": m["sp"]}); d = ImageDraw.Draw(img)
        d.rectangle([0, int(0.49 * H), W, int(0.53 * H)], fill=(255, 255, 255))
        x = 0.12
        for t in sorted(m["tags"]):
            w = d.textlength(t, font=F(40)) / W + 0.06
            d.rounded_rectangle([int(x * W), int(0.493 * H), int((x + w) * W), int(0.527 * H)], 40, fill=(90, 170, 230))
            d.text((int((x + 0.03) * W), int(0.497 * H)), t, font=F(40), fill=(255, 255, 255)); x += w + 0.02
        return img
    def list_rows(self):
        return self.tag_names + ["+ Add New Tag"]
    def row_y(self, k): return 0.30 + k * 0.058 - self.list_off
    def render_list(self):
        img = Image.new("RGB", (W, H), (250, 252, 250)); d = ImageDraw.Draw(img)
        for k, name in enumerate(self.list_rows()):
            y = self.row_y(k)
            if not 0.24 < y < 0.80: continue
            d.text((int(0.2 * W), int(y * H) - 28), name, font=F(50, name.startswith("+")), fill=(40, 150, 140) if name.startswith("+") else (60, 60, 60))
            if name in self.checked:
                d.ellipse([int(0.86 * W), int(y * H) - 28, int(0.86 * W) + 56, int(y * H) + 28], fill=(40, 180, 120))
        d.rectangle([0, 0, W, int(0.22 * H)], fill=(250, 252, 250))
        draw_text_c(d, (0.5 * W, 0.084 * H), f"TAG {len(self.list_targets)} POKÉMON", F(44), (90, 100, 100))
        d.rectangle([0, int(0.81 * H), W, H], fill=(250, 252, 250))
        d.rounded_rectangle([int(.3 * W), int(.835 * H), int(.7 * W), int(.885 * H)], 50, fill=(100, 205, 160)); draw_text_c(d, (.5 * W, .86 * H), "DONE", F(50, True), (255, 255, 255))
        d.ellipse([int(.455 * W), int(.91 * H), int(.545 * W), int(.97 * H)], fill=(225, 245, 240), outline=(40, 120, 120), width=4); draw_text_c(d, (.5 * W, .94 * H), "X", F(50), (40, 120, 120))
        return img
    def get_screenshot_as_png(self):
        st = self.state
        if st == "grid": return png(self.render_grid())
        if st == "multi": return png(self.render_grid(True))
        if st == "detail": return png(self.render_detail())
        if st == "bars": return png(sim2.render_bars(self.mons[self.cur]))
        if st == "taglist": return png(self.render_list())
        if st == "create":
            import sim3; return png(sim3.render_create(self.typed))
        return png(REAL[st])
    # --- ovládání
    def get_window_size(self): return {"width": 402, "height": 874}
    def update_settings(self, s): pass
    def query_app_state(self, b): return 4
    def is_locked(self): return False
    def activate_app(self, b): self.state = "map"
    def terminate_app(self, b): self.state, self.off, self.filtered = "map", 0, False; self.events.append("restart")
    def quit(self): pass
    def open_list(self, targets, ret):
        self.list_targets = list(targets); self.list_return = ret; self.list_off = 0.0
        common = set.intersection(*[self.mons[i]["tags"] for i in targets]) if targets else set()
        self.checked = set(common); self.initial = set(common); self.state = "taglist"
    def done_list(self):
        for i in self.list_targets:
            self.mons[i]["tags"] |= self.checked
            self.mons[i]["tags"] -= (self.initial - self.checked)
        self.state = self.list_return; self.sel = set()
    def execute(self, cmd, params=None):
        if cmd == "pogoKeys":
            txt = "".join(params["value"])
            if self.state == "create":
                if txt == "\n": self.finish_create()
                else: self.typed += txt
            return {"value": None}
        acts = params["actions"][0]["actions"]
        moves = [a for a in acts if a["type"] == "pointerMove"]
        held = any(a["type"] == "pause" and a.get("duration", 0) > 0 for a in acts)
        dy = moves[0]["y"] / 874 - moves[1]["y"] / 874
        if self.state == "grid":
            dy = dy * 3 if not held else dy - 0.01 * np.sign(dy) + self.rnd.uniform(-0.03, 0.03)
            self.off = float(min(self.max_off(), max(0.0, self.off + dy)))
        elif self.state == "taglist":
            mx = max(0.0, 0.30 + (len(self.list_rows()) - 1) * 0.058 - 0.78)
            self.list_off = float(min(mx, max(0.0, self.list_off + dy)))
        return {"value": None}
    def finish_create(self):
        if self.typed and self.typed not in self.tag_names:
            self.tag_names.append(self.typed); self.created += 1
        self.state, self.typed = "taglist", ""
    def cell_at(self, x, y):
        for pos, i in enumerate(self.shown()):
            row, col = divmod(pos, 3); cy = ROW0 + row * PITCH - self.off; cx = COLS[col]
            if abs(x - cx) < 0.15 and cy - 0.03 < y < cy + 0.14 and 0.215 < cy < 0.90: return i
        return None
    def execute_script(self, name, args):
        if name == "mobile: hideKeyboard":
            if self.state == "create": self.state = "taglist"
            return
        x, y = args["x"] / 402, args["y"] / 874; self.taps += 1
        hold = "touchAndHold" in name
        if self.rnd.random() < self.glitch:
            g = self.rnd.choice(["map", "restart"]); self.events.append(f"glitch:{g}@{self.state}")
            if g == "map": self.state, self.off, self.filtered = "map", 0, False
            else: self.terminate_app(None)
            return
        st = self.state; near = lambda cx, cy, dx, dy: abs(x - cx) < dx and abs(y - cy) < dy
        if st == "map" and near(.5, .935, .06, .035): self.state = "menu"
        elif st == "menu" and near(.22, .81, .09, .07): self.state, self.filtered, self.off = "grid", False, 0.0
        elif st == "search":
            if near(.62, .35, .08, .07): self.state, self.filtered, self.off = "grid", True, 0.0
            elif near(.105, .178, .05, .02): self.state = "grid"
        elif st == "sort_menu":
            if near(.87, .94, .08, .04) or near(.68, .61, .2, .02): self.state = "grid"
        elif st == "grid":
            if near(.87, .94, .06, .035): self.state = "sort_menu"
            elif near(.105, .178, .05, .02) or near(.915, .176, .05, .02):
                if self.filtered: self.filtered, self.off = False, 0.0
            elif near(.5, .178, .35, .025) and not self.filtered: self.state = "search"
            elif near(.5, .94, .05, .03): self.state, self.off, self.filtered = "map", 0.0, False
            else:
                i = self.cell_at(x, y)
                if i is not None:
                    if hold: self.state, self.sel = "multi", {i}
                    else: self.state, self.cur = "detail", i
        elif st == "detail":
            if near(.87, .94, .08, .04): self.state = "dmenu"
            elif near(.5, .94, .05, .03): self.state = "grid"
            elif near(.5, .80, .45, .04): self.bad.append("EVOLVE řádek"); self.state = "evolve"
        elif st == "dmenu":
            if near(.67, .771, .3, .025): self.state = "intro"
            elif near(.73, .61, .3, .025): self.open_list([self.cur], "detail")
            elif near(.66, .853, .3, .025): self.bad.append("TRANSFER v menu"); self.state = "transfer"
            elif near(.87, .94, .08, .04): self.state = "detail"
        elif st == "intro": self.state = "bars"
        elif st == "bars": self.state = "detail"
        elif st == "multi":
            if near(.5, .86, .43, .025): self.open_list(sorted(self.sel), "grid")
            elif near(.5, .937, .45, .025): self.bad.append("TRANSFER v multiselectu"); self.state = "transfer"
            elif near(.107, .117, .06, .03): self.state, self.sel = "grid", set()
            else:
                i = self.cell_at(x, y)
                if i is not None: self.sel ^= {i}
        elif st == "transfer":
            if near(.5, .643, .2, .025): self.state = "multi" if self.sel else "grid"
            elif near(.5, .566, .25, .03): self.bad.append("!!! POTVRZEN TRANSFER !!!")
        elif st == "taglist":
            if near(.5, .86, .2, .025): self.done_list(); return
            if near(.5, .94, .05, .03): self.state = self.list_return if self.list_return == "detail" else "multi"; return
            for k, nm in enumerate(self.list_rows()):
                if abs(y - self.row_y(k)) < 0.025 and 0.24 < self.row_y(k) < 0.80:
                    if nm.startswith("+"): self.state, self.typed = "create", ""
                    else: self.checked ^= {nm}
                    return
        elif st == "create":
            if abs(y - .55) < .03 and abs(x - .5) < .2: self.finish_create()
        elif st == "evolve":
            if near(.5, .662, .2, .025): self.state = "detail"

def run(seed=11, glitch=0.0, verbose=False):
    mons = make_mons(seed); init = [set(m["tags"]) for m in mons]
    phone = Phone(mons, seed, glitch)
    run_dir = sim2.TMP / f"run4_{seed}_{glitch}"; (run_dir / "iv").mkdir(parents=True, exist_ok=True)
    if not verbose: S.log = lambda msg="": None
    bot = S.Bot(phone, run_dir); book, book2 = S.Book(), S.Book(); mem = S.Memory(sim2.TMP / f"pamet4_{seed}_{glitch}.json")
    class A: max_groups = 0; fresh = False; only_iv = False; no_iv = False
    rep = S.Report(run_dir, 0); err = None; t0 = time.time()
    try: S.run(bot, book, book2, mem, A(), rep)
    except Exception as e: err = f"{type(e).__name__}: {e}"
    # očekávání
    ivnames = {n for _, n in S.IV_TAGS}
    by_sp = {}
    for i, m in enumerate(mons): by_sp.setdefault(m["sp"], []).append(i)
    exp_rem = set()
    for sp, idx in by_sp.items():
        if len(idx) < 2: continue
        best = max(idx, key=lambda i: (sum(mons[i]["iv"]), *mons[i]["iv"]))
        exp_rem |= {i for i in idx if i != best}
    bad_rem = sorted(i for i, m in enumerate(mons) if (S.TAG_NAME in m["tags"]) != (i in exp_rem))
    bad_iv = []
    for i, m in enumerate(mons):
        if i in exp_rem: continue
        had = init[i] & ivnames
        want = had if len(had) == 1 else {S.iv_tag(m["iv"])}
        if m["tags"] & ivnames != want: bad_iv.append((i, m["sp"], m["iv"], sorted(init[i]), sorted(m["tags"])))
    print(f"seed={seed} glitch={glitch}: chyba={err} | Removable špatně={bad_rem} | IV tagy špatně={bad_iv} | "
          f"tag založen {phone.created}x | nebezpečné={phone.bad} | klepnutí={phone.taps} | události={phone.events[:6]} | {time.time()-t0:.0f}s")

if __name__ == "__main__":
    run(11, 0.0, verbose="verbose" in sys.argv)
