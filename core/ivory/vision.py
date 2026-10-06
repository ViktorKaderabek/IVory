"""Text recognition (Apple Vision) and basic helpers for finding text and comparing images."""
import re
import unicodedata

import cv2
import numpy as np


HOMOGLYPHS = str.maketrans("сСрРоОеЕаАхХ", "cCpPoOeEaAxX")   # OCR sometimes returns Cyrillic letters
CP_RE = re.compile(r"^cp?(\d{2,5})$")              # OCR sometimes drops the P ("c1272")


def norm(s):
    s = unicodedata.normalize("NFKD", (s or "").translate(HOMOGLYPHS))
    return "".join(c for c in s if not unicodedata.combining(c)).lower().strip()


def alnum(s):
    return re.sub(r"[^a-z0-9]", "", norm(s))


# --- OCR (Apple Vision) ---
def ocr(data, fast=False):
    import Vision
    from Foundation import NSData

    ns = NSData.dataWithBytes_length_(data, len(data))
    handler = Vision.VNImageRequestHandler.alloc().initWithData_options_(ns, None)
    req = Vision.VNRecognizeTextRequest.alloc().init()
    req.setRecognitionLevel_(Vision.VNRequestTextRecognitionLevelFast if fast
                             else Vision.VNRequestTextRecognitionLevelAccurate)
    req.setUsesLanguageCorrection_(False)
    ok, err = handler.performRequests_error_([req], None)
    if not ok:
        raise RuntimeError(f"OCR selhalo: {err}")
    out = []
    for obs in req.results() or []:
        cands = obs.topCandidates_(1)
        if not cands:
            continue
        bb = obs.boundingBox()  # normalized, origin at the BOTTOM left
        x, y = bb.origin.x, bb.origin.y
        w, h = bb.size.width, bb.size.height
        out.append({
            "text": str(cands[0].string()),
            "cx": x + w / 2, "cy": 1 - (y + h / 2),
            "x0": x, "x1": x + w, "y0": 1 - (y + h), "y1": 1 - y,
        })
    return out


class Frame:
    """One screen frame; OCR runs only when it is needed (and only once)."""

    def __init__(self, img, raw, t):
        self.img, self.raw, self.t = img, raw, t
        self._tx = self._fast = None

    @property
    def texts(self):
        if self._tx is None:
            self._tx = ocr(self.raw)
        return self._tx

    @property
    def fast(self):
        if self._tx is not None:
            return self._tx
        if self._fast is not None:
            return self._fast
        self._fast = ocr(self.raw, fast=True)
        return self._fast

    def rough(self):
        """The same frame, but whatever asks for its text gets the fast OCR (21 ms instead of 100).
        Used to poll for a change – what the bot then acts on is always read with the accurate one."""
        return RoughFrame(self)


class RoughFrame:
    """A Frame whose `texts` are the fast OCR. Everything else (the image, the time) is the frame's."""

    def __init__(self, frame):
        self.frame = frame

    @property
    def texts(self):
        return self.frame.fast

    @property
    def fast(self):
        return self.frame.fast

    def __getattr__(self, name):
        return getattr(self.frame, name)


def in_region(t, region):
    return region is None or (region[0] <= t["cx"] <= region[2] and region[1] <= t["cy"] <= region[3])


def find_all(texts, patterns, exact=False, region=None):
    pats = [norm(p) for p in patterns]
    out = []
    for t in texts:
        if not in_region(t, region):
            continue
        n = norm(t["text"])
        if any((n == p) if exact else (p in n) for p in pats):
            out.append(t)
    return out


def find_text(texts, patterns, exact=False, region=None):
    r = find_all(texts, patterns, exact, region)
    return r[0] if r else None


def find_re(texts, rx, region=None):
    for t in texts:
        if in_region(t, region) and rx.search(norm(t["text"])):
            return t
    return None


def upper_text(s):
    letters = [c for c in s if c.isalpha()]
    return bool(letters) and sum(c.isupper() for c in letters) >= 0.8 * len(letters)


# --- Storage grid and image comparison ---
def cp_value(text):
    m = CP_RE.match(re.sub(r"\s", "", norm(text)))
    return int(m.group(1)) if m else None


def crop_norm(img, x0, y0, x1, y1):
    H, W = img.shape[:2]
    return img[max(0, int(y0 * H)):min(H, int(y1 * H)),
               max(0, int(x0 * W)):min(W, int(x1 * W))]


def img_diff(a, b, region=(0.0, 0.2, 1.0, 0.8)):
    ca, cb = crop_norm(a, *region), crop_norm(b, *region)
    if ca.size == 0 or ca.shape != cb.shape:
        return 99.0
    ga = cv2.resize(cv2.cvtColor(ca, cv2.COLOR_RGB2GRAY), (64, 140), interpolation=cv2.INTER_AREA)
    gb = cv2.resize(cv2.cvtColor(cb, cv2.COLOR_RGB2GRAY), (64, 140), interpolation=cv2.INTER_AREA)
    return float(np.abs(ga.astype(int) - gb.astype(int)).mean())


def changed_frac(a, b):
    if a.size == 0 or a.shape != b.shape:
        return 1.0
    return float((np.abs(a.astype(int) - b.astype(int)).max(axis=2) > 40).mean())
