"""Driving the iPhone: the screen stream and the Bot that taps, swipes and types."""
import io
import json
import re
import socket
import threading
import time
from collections import deque
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import cv2
import numpy as np
from PIL import Image

from . import config as cfg
from .errors import Danger, StepError
from .output import log, short_err, T
from .calibration import cal_load
from .vision import find_text, Frame, img_diff, upper_text
from .screens import filter_key, multiselect_look, transfer_dialog


SAVER = ThreadPoolExecutor(max_workers=2)   # saving images doesn't block tapping


# --- Phone screen ---
class Stream:
    """Reads the WebDriverAgent MJPEG stream and keeps the latest frame."""

    def __init__(self, port):
        self.port = port
        self.lock = threading.Lock()
        self.jpeg, self.t, self.n = None, 0.0, 0
        self.stop_ev = threading.Event()
        if cfg.USE_STREAM:
            threading.Thread(target=self._run, daemon=True).start()

    def latest(self):
        with self.lock:
            return self.jpeg, self.t, self.n

    def fresh(self, age=0.6):
        return self.jpeg is not None and time.time() - self.t < age

    def _run(self):
        while not self.stop_ev.is_set():
            try:
                with socket.create_connection(("127.0.0.1", self.port), timeout=3) as s:
                    s.settimeout(5)
                    s.sendall(b"GET / HTTP/1.1\r\nHost: localhost\r\n\r\n")
                    buf = bytearray()
                    while not self.stop_ev.is_set():
                        chunk = s.recv(1 << 18)
                        if not chunk:
                            break
                        buf += chunk
                        self._frames(buf)
            except OSError:
                pass
            self.stop_ev.wait(1.0)

    def _frames(self, buf):
        while True:
            i = buf.find(b"\xff\xd8")
            if i < 0:
                if len(buf) > 1 << 16:
                    del buf[:-1024]
                return
            m = re.search(rb"Content-Length:\s*(\d+)", bytes(buf[max(0, i - 256):i]), re.I)
            if m:
                end = i + int(m.group(1))
                if len(buf) < end:
                    return
            else:
                j = buf.find(b"\xff\xd9", i + 2)
                if j < 0:
                    return
                end = j + 2
            frame = bytes(buf[i:end])
            del buf[:end]
            with self.lock:
                self.jpeg, self.t, self.n = frame, time.time(), self.n + 1


# --- Phone control ---
class Bot:
    def __init__(self, driver, run_dir):
        self.d = driver
        self.dir = run_dir
        self.stream = Stream(cfg.MJPEG_PORT)
        self.stream_misses = 0 if cfg.USE_STREAM else 99
        self.ring = deque(maxlen=cfg.RING)
        self._last = None
        self.need_sort = True
        self.fresh_list = False
        self.mode = "duplicit"            # "duplicit" = the typed search, "all" = the whole storage without a search,
        #                                   "cp" = search by CP (bot.query) for bulk tagging
        self.query = None                 # the search in "cp" mode (cp2260,cp2268,…)
        self.typed_query = None           # what the bot last typed into the Search field
        self.bars_frame = None            # the frame read_appraisal read the bars from
        self.bars_rec = None              # the Pokémon in that frame, if the quick confirmation already read it
        self.select_all_ok = True         # SELECT ALL in the search results (turned off when the count doesn't match)
        cal = cal_load().get("search") or {}
        # how the game shows the typed search in the Search field (learned on the first search)
        self.filter_key = cal.get("key") if cal.get("query") == cfg.SEARCH_QUERY else filter_key(cfg.SEARCH_QUERY)
        self.dumps = 0
        self.tags_checked = False         # setup: the tags from the settings exist in the game
        self.tag_checks = 0
        self.tag_attempts = {}            # how many times creating each tag was attempted
        self.broken_tags = set()          # tags that could not be created
        self.created_tags = []
        self.fast = cfg.FAST              # fast mode (the ▶ arrow in the appraisal, bulk tagging)
        self.tag_counts = {}              # "Tags in your storage" panel: tag -> number of Pokémon
        self.box_total = 0
        self.progress = 0                 # Pokémon read / tagged (for counting errors without progress)
        # how far the game scrolls the list per unit of finger drag (about 1.6× on iPhone), measured on every
        # scroll; the default guess errs high: scrolling too little is harmless, overshooting costs a correction
        self.scroll_gain = min(3.0, max(0.6, float(cal_load().get("scroll_gain", 1.5))))
        self.last_shift = None            # how far the list moved on the last scroll_by
        self.shown_count = None           # how many Pokémon the game shows in the storage header
        self.live_raw = None              # last frame from a screenshot (when the stream isn't running)
        self.refresh()
        if cfg.LIVE:
            threading.Thread(target=self._live_loop, daemon=True).start()

    def refresh(self):
        size = self.d.get_window_size()
        self.W, self.H = size["width"], size["height"]

    def _live_loop(self):
        """For the app: every half second, saves the latest screen frame to LIVE_FILE."""
        last = None
        while not self.stream.stop_ev.is_set():
            jpeg, t, _ = self.stream.latest()
            if jpeg is None or time.time() - t > 2.0:
                jpeg, t = self.live_raw or (None, None)
            if jpeg is not None and t != last:
                try:
                    tmp = cfg.LIVE_FILE.with_name(cfg.LIVE_FILE.name + ".tmp")
                    tmp.write_bytes(jpeg)
                    tmp.replace(cfg.LIVE_FILE)
                    last = t
                except OSError:
                    pass
            self.stream.stop_ev.wait(0.5)

    def streaming(self):
        return self.stream_misses < 3 or self.stream.fresh()

    def wait_stream(self, sec=6):
        end = time.time() + sec
        while cfg.USE_STREAM and time.time() < end:
            if self.stream.fresh():
                log(T("Obraz z iPhonu: video stream (rychlé)", "iPhone screen: video stream (fast)"))
                return True
            time.sleep(0.1)
        self.stream_misses = 99
        log(T("Obraz z iPhonu: video stream nejede, beru screenshoty (pomalejší, ale funguje)",
              "iPhone screen: the video stream isn't working, using screenshots (slower, but it works)"))
        return False

    # --- Screen ---
    def frame(self, after=None, timeout=2.0):
        """The latest frame; with after=, only a frame received after that time."""
        if self.streaming():
            end = time.time() + timeout
            while True:
                jpeg, t, n = self.stream.latest()
                now = time.time()
                if jpeg is not None and now - t < 0.6 and (after is None or t >= after):
                    self.stream_misses = 0
                    if self._last is not None and self._last[0] == n:
                        return self._last[1]
                    arr = cv2.imdecode(np.frombuffer(jpeg, np.uint8), cv2.IMREAD_COLOR)
                    if arr is not None:
                        fr = Frame(cv2.cvtColor(arr, cv2.COLOR_BGR2RGB), jpeg, t)
                        self._last = (n, fr)
                        return fr
                if now > end:
                    break
                time.sleep(0.01)
            self.stream_misses += 1
            if self.stream_misses == 3:
                log(T("   (video stream neposílá snímky, přepínám na screenshoty)",
                      "   (the video stream sends no frames, switching to screenshots)"))
        png = self.d.get_screenshot_as_png()
        img = np.array(Image.open(io.BytesIO(png)).convert("RGB"))
        fr = Frame(img, png, time.time())
        self.live_raw = (png, fr.t)
        return fr

    def remember(self, kind, label, fr, pt=None):
        self.ring.append((kind, label, fr.raw if fr is not None else None,
                          fr._tx if fr is not None else None, pt))

    def dump(self, name):
        """Saves the last few frames (black box) for diagnostics."""
        items = list(self.ring)
        self.ring.clear()
        self.dumps += 1
        d = self.dir / f"{name}_{self.dumps:02d}"

        def work():
            d.mkdir(parents=True, exist_ok=True)
            for k, (kind, label, raw, tx, pt) in enumerate(items):
                if raw is None:
                    continue
                img = cv2.imdecode(np.frombuffer(raw, np.uint8), cv2.IMREAD_COLOR)
                if img is None:
                    continue
                if pt:
                    h, w = img.shape[:2]
                    cv2.circle(img, (int(pt[0] * w), int(pt[1] * h)), max(12, w // 30), (0, 0, 255), 6)
                base = d / f"{k:02d}_{kind}_{re.sub(r'[^A-Za-z0-9_]+', '_', label)[:40]}"
                cv2.imwrite(f"{base}.jpg", img, [cv2.IMWRITE_JPEG_QUALITY, 80])
                if tx:
                    Path(f"{base}.json").write_text(json.dumps(tx, ensure_ascii=False, indent=1))

        SAVER.submit(work)
        return d

    # --- Touches ---
    def guard(self, x, y, label, fr=None, overlay=False):
        """Safety check before every touch: no TRANSFER/EVOLVE/... nearby.
        overlay=True: a floating button (X, ≡) lies over the detail screen rows, so for EVOLVE/POWER UP
        it is enough not to tap directly on their text."""
        max_age = 0.3 if self.streaming() else 2.5
        if fr is None or time.time() - fr.t > max_age:
            fr = self.frame()
        tx = fr.fast
        if transfer_dialog(tx) and label != "CANCEL":
            raise Danger(T("je otevřený dialog TRANSFER – kromě CANCEL nic neklikám",
                           "the TRANSFER dialog is open – tapping nothing but CANCEL"))
        if y > 0.89 and multiselect_look(fr.img):
            raise Danger(T(f"'{label}' na ({x:.2f}, {y:.2f}): ve výběru více Pokémonů je dole TRANSFER – NEKLIKÁM",
                           f"'{label}' at ({x:.2f}, {y:.2f}): multi-select has TRANSFER at the bottom – NOT TAPPING"))
        for t in tx:
            s = t["text"].strip()
            if not upper_text(s):
                continue
            u = s.upper()
            if cfg.DANGER_RE.match(u) and abs(t["cy"] - y) < cfg.DANGER_BAND:
                hit = True
            elif cfg.DANGER_ROW_RE.match(u):
                hit = (t["x0"] - 0.04 <= x <= t["x1"] + 0.04 and abs(t["cy"] - y) < 0.025) if overlay \
                    else abs(t["cy"] - y) < cfg.DANGER_BAND
            else:
                hit = False
            if hit:
                raise Danger(T(f"'{label}' na ({x:.2f}, {y:.2f}) je moc blízko tlačítka '{s}' – NEKLIKÁM",
                               f"'{label}' at ({x:.2f}, {y:.2f}) is too close to the '{s}' button – NOT TAPPING"))
        return fr

    def tap(self, x, y, label, fr=None, overlay=False):
        fr = self.guard(x, y, label, fr, overlay)
        self.remember("tap", label, fr, (x, y))
        log(T(f"   klepnutí: {label} ({x:.2f}, {y:.2f})", f"   tap: {label} ({x:.2f}, {y:.2f})"))
        self.d.execute_script("mobile: tap", {"x": int(x * self.W), "y": int(y * self.H)})
        return time.time()

    def long_press(self, x, y, label, fr=None, sec=cfg.LONG_PRESS_SEC):
        fr = self.guard(x, y, label, fr)
        self.remember("hold", label, fr, (x, y))
        log(T(f"   podržení {sec:.1f}s: {label} ({x:.2f}, {y:.2f})", f"   hold {sec:.1f}s: {label} ({x:.2f}, {y:.2f})"))
        self.d.execute_script("mobile: touchAndHold",
                              {"x": int(x * self.W), "y": int(y * self.H), "duration": sec})
        return time.time()

    def type_text(self, text):
        """Types text into the field that currently has the keyboard (WebDriverAgent /wda/keys)."""
        log(T(f"   psaní: {text!r}", f"   typing: {text!r}"))
        try:
            if self.d.command_executor.get_command("pogoKeys") is None:
                self.d.command_executor.add_command("pogoKeys", "POST", "/session/$sessionId/keys")
            self.d.execute("pogoKeys", {"value": list(text)})
        except Exception as e:
            log(T(f"   (psaní přes keys nešlo: {short_err(e)}, zkouším mobile: keys)",
                  f"   (typing via keys failed: {short_err(e)}, trying mobile: keys)"))
            self.d.execute_script("mobile: keys", {"keys": [text]})

    def drag(self, a, b, label, ms=400, hold=0.3, fr=None):
        """Finger drag; with hold, the finger pauses at the end so the list doesn't keep scrolling by inertia."""
        from selenium.webdriver.common.actions import interaction
        from selenium.webdriver.common.actions.action_builder import ActionBuilder
        from selenium.webdriver.common.actions.pointer_input import PointerInput

        fr = self.guard(a[0], a[1], label, fr)
        self.remember("drag", label, fr, a)
        log(T(f"   tažení: {label}", f"   drag: {label}"))
        finger = PointerInput(interaction.POINTER_TOUCH, "finger")
        ab = ActionBuilder(self.d, mouse=finger)
        finger.create_pointer_move(duration=0, x=int(a[0] * self.W), y=int(a[1] * self.H))
        finger.create_pointer_down(button=0)
        finger.create_pointer_move(duration=ms, x=int(b[0] * self.W), y=int(b[1] * self.H))
        if hold:
            finger.create_pause(hold)
        finger.create_pointer_up(button=0)
        ab.perform()
        return time.time()

    # --- Waiting for the result ---
    def wait_for(self, cond, timeout, after=None, label="kontrola"):
        """Reads new frames until cond(frame) returns something truthy (or time runs out)."""
        end = time.time() + timeout
        while True:
            fr = self.frame(after=after)
            res = cond(fr)
            if res or time.time() > end:
                self.remember("check", label, fr)
                return res, fr
            after = fr.t + 0.005

    def act(self, pt, label, cond, timeout=2.0, fr=None, tries=2, alts=(), overlay=False):
        """Taps and waits for the expected effect; if it doesn't come, tries again (possibly elsewhere)."""
        pts = [pt] + list(alts)
        for k in range(tries):
            p = pts[min(k, len(pts) - 1)]
            t0 = self.tap(p[0], p[1], label if k == 0 else f"{label} (znovu)", fr=fr, overlay=overlay)
            res, fr = self.wait_for(cond, timeout, after=t0 + cfg.FRAME_LAG, label=label)
            if res:
                return res, fr
        raise StepError(T(f"'{label}': klepnutí nemělo očekávaný efekt", f"'{label}': the tap had no effect"))

    def settle(self, fr, region=(0.0, 0.45, 1.0, 0.9), timeout=1.5, thr=1.5):
        """Waits until the screen stops moving in the given region (end of an animation)."""
        end = time.time() + timeout
        while time.time() < end:
            nxt = self.frame(after=fr.t + 0.005)
            if img_diff(fr.img, nxt.img, region) < thr:
                return nxt
            fr = nxt
        return fr

    def stable_text(self, patterns, exact=False, region=None, timeout=1.5):
        """Waits until the text stays in place (end of an animation)."""
        end = time.time() + timeout
        prev = fr = None
        while True:
            fr = self.frame(after=fr.t + 0.005 if fr else None)
            t = find_text(fr.texts, patterns, exact, region)
            if t and prev and abs(t["cx"] - prev["cx"]) < 0.005 and abs(t["cy"] - prev["cy"]) < 0.005:
                return t, fr
            if time.time() > end:
                return t, fr
            prev = t
