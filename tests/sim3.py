"""Test zakládání tagu: v seznamu tag není -> Add New Tag -> Enter tag name -> psaní -> Done -> vybrat."""
import io, os, sys, time, random
os.environ["POGO_NO_STREAM"] = "1"
from PIL import Image, ImageDraw
import sys as _sys
from pathlib import Path as _Path
_sys.path.insert(0, str(_Path(__file__).resolve().parents[1] / "core"))
_sys.path.insert(0, str(_Path(__file__).resolve().parent))
import pogo_bot as S
import sim2
from sim2 import F, W, H, draw_text_c, png

BASE_LIST = Image.open(sim2.R + "20261002_160212/82_tag_pick_cp691.png").convert("RGB")
SEARCH = Image.open(sim2.R + "20261002_161252/07_search_check_0.png").convert("RGB")

def render_taglist(has_tag, checked):
    img = BASE_LIST.copy(); d = ImageDraw.Draw(img)
    for y in (0.742, 0.80):
        d.rectangle([int(0.12 * W), int((y - 0.025) * H), int(0.95 * W), int((y + 0.025) * H)], fill=(255, 255, 255))
    if has_tag:
        d.text((int(0.235 * W), int(0.742 * H) - 30), S.TAG_NAME, fill=(60, 60, 60), font=F(52))
        if checked:
            d.ellipse([int(0.86 * W), int(0.742 * H) - 30, int(0.86 * W) + 60, int(0.742 * H) + 30], fill=(40, 180, 120))
    d.text((int(0.235 * W), int(0.80 * H) - 30), "+ Add New Tag", fill=(40, 150, 140), font=F(52, True))
    return img

def render_create(typed):
    img = SEARCH.copy(); d = ImageDraw.Draw(img)
    d.rectangle([0, int(0.12 * H), W, int(0.64 * H)], fill=(245, 250, 245))
    d.rounded_rectangle([int(0.1 * W), int(0.37 * H), int(0.9 * W), int(0.43 * H)], 30, outline=(120, 120, 120), width=4, fill=(255, 255, 255))
    draw_text_c(d, (0.5 * W, 0.40 * H), typed or "Enter tag name", F(50), (60, 60, 60) if typed else (160, 160, 160))
    d.rounded_rectangle([int(0.3 * W), int(0.52 * H), int(0.7 * W), int(0.58 * H)], 40, fill=(100, 205, 160))
    draw_text_c(d, (0.5 * W, 0.55 * H), "DONE", F(50, True), (255, 255, 255))
    return img

class CmdExec:
    def get_command(self, n): return ("POST", "/x")
    def add_command(self, *a): pass

class Phone3(sim2.Phone):
    def __init__(self, *a, **k):
        super().__init__(*a, **k)
        self.tag_exists = False; self.typed = ""; self.command_executor = CmdExec(); self.created = 0
    def get_screenshot_as_png(self):
        if self.state == "taglist": return png(render_taglist(self.tag_exists, self.checked))
        if self.state == "create": return png(render_create(self.typed))
        return super().get_screenshot_as_png()
    def execute(self, cmd, params=None):
        if cmd == "pogoKeys":
            txt = "".join(params["value"])
            if self.state == "create":
                if txt == "\n": self.finish_create()
                else: self.typed += txt
            return {"value": None}
        return super().execute(cmd, params)
    def finish_create(self):
        if self.typed:
            self.tag_exists = True; self.created += 1
        self.state, self.typed = "taglist", ""
    def execute_script(self, name, args):
        if self.state == "taglist" and "tap" in name:
            x, y = args["x"] / 402, args["y"] / 874
            if abs(y - 0.80) < 0.025 and abs(x - 0.4) < 0.35:
                self.taps += 1; self.state = "create"; return
            if abs(y - 0.742) < 0.025 and not self.tag_exists:
                self.taps += 1; return
        if self.state == "create" and "tap" in name:
            x, y = args["x"] / 402, args["y"] / 874; self.taps += 1
            if abs(y - 0.55) < 0.03 and abs(x - 0.5) < 0.2: self.finish_create()
            return
        if name == "mobile: hideKeyboard":
            if self.state == "create": self.state = "taglist"
            return
        return super().execute_script(name, args)

def run(seed=5):
    mons = sim2.make_box(seed)[:9]          # menší box: Venusaur, 4x Charmander, 4x Charizard
    for i, m in enumerate(mons): m["id"] = i
    phone = Phone3(mons, seed, 0.0, 0.02)
    run_dir = sim2.TMP / f"run3_{seed}"; (run_dir / "iv").mkdir(parents=True, exist_ok=True)
    bot = S.Bot(phone, run_dir); book = S.Book(); mem = S.Memory(sim2.TMP / f"pamet3_{seed}.json")
    class A: max_groups = 0; fresh = False
    err = None
    try: S.run(bot, book, mem, A(), S.Report(run_dir, 0))
    except Exception as e: err = f"{type(e).__name__}: {e}"
    exp = sim2.expected(mons); tagged = {m["id"] for m in mons if m["tags"]}
    print(f"chyba={err} | tag založen {phone.created}x | otagováno={sorted(tagged)} čekáno={sorted(exp)} | nebezpečné={phone.bad} | klepnutí={phone.taps}")

if __name__ == "__main__":
    run()
