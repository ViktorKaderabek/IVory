"""Simulátor telefonu ze skutečných screenshotů – testuje navigaci, měření, tagování a zotavení."""
import io, os, sys, time, tempfile, json
os.environ["POGO_NO_STREAM"] = "1"
from pathlib import Path
import numpy as np
from PIL import Image, ImageDraw, ImageFont
import sys as _sys
from pathlib import Path as _Path
_sys.path.insert(0, str(_Path(__file__).resolve().parents[1] / "core"))
_sys.path.insert(0, str(_Path(__file__).resolve().parent))
import pogo_bot as S

R = os.environ.get("POGO_SCREENS", os.path.expanduser("~/Desktop/pogo_runs/")).rstrip("/") + "/"
TMP = Path(tempfile.mkdtemp(prefix="pogo_sim_"))
S.CAL_FILE = TMP / "cal.json"; S.MEMORY_FILE = TMP / "pamet.json"; S.OUT_DIR = TMP / "runs"
S.NAV_TIMEOUT = 40
S.TAG_NAME = "toREmove"   # syntetický seznam tagů má tenhle název

def png(path): return open(R + path + ".png", "rb").read()

def tag_list_img(checked):
    img = Image.open(R + "20261002_160212/82_tag_pick_cp691.png").convert("RGB")
    W, H = img.size; d = ImageDraw.Draw(img)
    y = int(0.742 * H)
    d.rectangle([int(0.12*W), y - 45, int(0.75*W), y + 45], fill=(255, 255, 255))
    f = ImageFont.truetype("/System/Library/Fonts/Supplemental/Arial.ttf", 52)
    d.text((int(0.235*W), y - 30), "toREmove", fill=(60, 60, 60), font=f)
    if checked:
        d.ellipse([int(0.86*W), y - 30, int(0.86*W) + 60, y + 30], fill=(40, 180, 120))
    b = io.BytesIO(); img.save(b, "PNG"); return b.getvalue()

SCREENS = {
    "map": png("20261002_161252/01_map"), "menu": png("20261002_161252/02_menu"),
    "box_unf": png("20261002_161252/05_search_0"), "box_tags": png("20261002_160212/01_map"),
    "search": png("20261002_161252/07_search_check_0"), "box_unsorted": png("20261002_161252/10_saved_search_check_0"),
    "sort_menu": png("20261002_161252/11_sort_check_0"), "box": png("20261002_161252/15_grid"),
    "detail_487": png("20261002_161252/16_detail_cp487_check_0"), "detail_482": png("20261002_161252/24_detail_cp482_check_0"),
    "dmenu_487": png("20261002_161252/17_menu_cp487_check_0"), "dmenu_482": png("20261002_161252/25_menu_cp482_check_0"),
    "intro_487": png("20261002_161252/20_appraise_cp487_check_0"), "intro_482": png("20261002_161252/28_appraise_cp482_check_0"),
    "bars_487": png("20261002_155706/09_tap_zav_t_appraisal"), "bars_482": png("20261002_155706/21_tap_zav_t_appraisal"),
    "multi": png("20261002_161252/34_vybrano_1"), "transfer": png("20261002_161252/36_tag_button_check_0"),
    "taglist": tag_list_img(False), "taglist_on": tag_list_img(True), "evolve": png("20261002_155706/24_tap_zav_t"),
}

class Fake:
    def __init__(self, start, glitches=()):
        self.state = start; self.prev = None; self.log = []; self.fails = []; self.tagged = []
        self.glitches = list(glitches)   # (po kolika klepnutích, nový stav) – simulace popupu/pádu
        self.taps = 0
    def get_window_size(self): return {"width": 402, "height": 874}
    def get_screenshot_as_png(self): return SCREENS[self.state]
    def update_settings(self, s): pass
    def query_app_state(self, b): return 4
    def is_locked(self): return False
    def activate_app(self, b): self.state = "map"
    def terminate_app(self, b): self.state = "map"
    def quit(self): pass
    def execute(self, cmd, params=None): self.log.append(("drag",)); return {"value": None}
    def go(self, s): self.prev, self.state = self.state, s
    def execute_script(self, name, args):
        x, y = args["x"] / 402, args["y"] / 874
        self.taps += 1
        st = self.state
        self.log.append((name.split()[-1], st, round(x, 3), round(y, 3)))
        for g in list(self.glitches):
            if self.taps == g[0]:
                self.glitches.remove(g); self.go(g[1]); return
        hold = "touchAndHold" in name
        near = lambda cx, cy, dx, dy: abs(x - cx) < dx and abs(y - cy) < dy
        if st == "map" and near(0.5, 0.935, 0.06, 0.035): self.go("menu")
        elif st == "menu":
            if near(0.22, 0.81, 0.09, 0.07): self.go("box_unf")
            elif near(0.5, 0.93, 0.06, 0.04): self.go("map")
        elif st == "box_unf":
            if near(0.5, 0.18, 0.35, 0.025): self.go("search")
            elif near(0.19, 0.09, 0.08, 0.03): self.go("box_tags")
            elif near(0.5, 0.94, 0.05, 0.03): self.go("map")
        elif st == "box_tags":
            if near(0.5, 0.09, 0.1, 0.04): self.go("box_unf")
        elif st == "search":
            if near(0.62, 0.35, 0.08, 0.07): self.go("box" if getattr(self, "sorted", False) else "box_unsorted")
        elif st in ("box_unsorted", "box"):
            if near(0.87, 0.94, 0.08, 0.04): self.prev2 = st; self.go("sort_menu")
            elif near(0.105, 0.178, 0.05, 0.02): self.go("box_unf")
            elif near(0.5, 0.94, 0.05, 0.03): self.go("map")
            elif st == "box" and near(0.18, 0.32, 0.12, 0.06): self.go("multi" if hold else "detail_487")
            elif st == "box" and near(0.49, 0.32, 0.12, 0.06): self.go("multi" if hold else "detail_482")
        elif st == "sort_menu":
            if near(0.68, 0.61, 0.2, 0.02): self.sorted = True; self.go("box")
            elif near(0.87, 0.94, 0.08, 0.04): self.go(getattr(self, "prev2", "box"))
        elif st.startswith("detail_"):
            k = st.split("_")[1]
            if near(0.87, 0.94, 0.08, 0.04): self.go("dmenu_" + k)
            elif near(0.5, 0.94, 0.05, 0.03): self.go("box")
            elif near(0.5, 0.80, 0.45, 0.04): self.fails.append("EVOLVE ŘÁDEK!"); self.go("evolve")
        elif st.startswith("dmenu_"):
            k = st.split("_")[1]
            if near(0.67, 0.771, 0.3, 0.025): self.go("intro_" + k)
            elif near(0.66, 0.853, 0.3, 0.025): self.fails.append("TRANSFER v menu!"); self.go("transfer")
            elif near(0.87, 0.94, 0.08, 0.04): self.go("detail_" + k)
        elif st.startswith("intro_"): self.go("bars_" + st.split("_")[1])
        elif st.startswith("bars_"): self.go("detail_" + st.split("_")[1])
        elif st == "multi":
            if near(0.5, 0.86, 0.4, 0.025): self.go("taglist")
            elif near(0.5, 0.937, 0.45, 0.03): self.fails.append("TRANSFER v multiselectu!"); self.go("transfer")
            elif near(0.107, 0.117, 0.06, 0.03): self.go("box")
        elif st == "transfer":
            if near(0.5, 0.643, 0.2, 0.025): self.go("multi" if self.prev == "multi" else "box")
            elif near(0.5, 0.566, 0.25, 0.03): self.fails.append("POTVRZEN TRANSFER!!!")
        elif st in ("taglist", "taglist_on"):
            if near(0.3, 0.742, 0.3, 0.025): self.go("taglist_on" if st == "taglist" else "taglist")
            elif near(0.5, 0.86, 0.2, 0.025):
                if st == "taglist_on": self.tagged.append("482")
                self.go("box")
            elif near(0.5, 0.94, 0.05, 0.03): self.go("multi")
        elif st == "evolve":
            if near(0.5, 0.662, 0.2, 0.025): self.go("detail_482")
            elif near(0.5, 0.597, 0.2, 0.03): self.fails.append("EVOLVE POTVRZEN!!!")

def make_bot(fake):
    run_dir = TMP / f"run_{time.time():.0f}"; (run_dir / "iv").mkdir(parents=True, exist_ok=True)
    return S.Bot(fake, run_dir)

class Args: max_groups = 1; fresh = False; only_iv = False; no_iv = True

def scenario(name, start, glitches=(), full=False, limit=1):
    fake = Fake(start, glitches)
    bot = make_bot(fake)
    t0 = time.time()
    print(f"\n######## {name} (start: {start})")
    try:
        if full:
            book, mem = S.Book(), S.Memory(S.MEMORY_FILE)
            args = Args(); args.max_groups = limit
            rep = S.Report(bot.dir, limit)
            S.run(bot, book, S.Book(), mem, args, rep)
            rep.summary(book)
        else:
            S.ensure_box(bot)
    except Exception as e:
        print("VÝJIMKA:", type(e).__name__, e)
    print(f"=> konec ve stavu {fake.state}, klepnutí {fake.taps}, chyby simulátoru {fake.fails}, otagováno {fake.tagged}, {time.time()-t0:.1f}s")
    return fake

if __name__ == "__main__":
    which = sys.argv[1:] or ["nav"]
    if "nav" in which:
        for st in ["map", "menu", "box_tags", "detail_487", "dmenu_482", "bars_487", "transfer", "evolve", "taglist", "multi", "sort_menu", "search"]:
            scenario("navigace do boxu", st)
    if "full" in which:
        scenario("celý průchod s tagem", "map", full=True)
    if "glitch" in which:
        scenario("pád do mapy uprostřed měření", "map", glitches=[(12, "map")], full=True)
        scenario("transfer dialog uprostřed tagování", "map", glitches=[(22, "transfer")], full=True)

if __name__ == "__main__" and "rerun" in sys.argv[1:]:
    scenario("druhý běh – IV z paměti, bez znovu-tagování", "map", full=True)
