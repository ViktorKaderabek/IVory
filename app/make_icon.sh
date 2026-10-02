#!/bin/bash
# Nakreslí ikonu aplikace (mřížka „inventáře“ se zvýrazněnou buňkou) a převede ji na AppIcon.icns.
# Potřebuje Python s Pillow (bere ~/.pogo/venv, které připraví scripts/run.sh).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PY="$HOME/.pogo/venv/bin/python"
[ -x "$PY" ] || PY="python3"
TMP="$(mktemp -d)"
ICONSET="$TMP/AppIcon.iconset"
mkdir -p "$ICONSET"

"$PY" - "$ICONSET" <<'EOF'
import sys
from PIL import Image, ImageDraw

out = sys.argv[1]
S = 1024
img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
# pozadí: zaoblený čtverec s gradientem (tyrkysová -> modrá)
grad = Image.new("RGBA", (S, S))
gd = ImageDraw.Draw(grad)
for y in range(S):
    t = y / S
    gd.line([(0, y), (S, y)], fill=(int(24 + 20 * t), int(178 - 70 * t), int(170 + 60 * t), 255))
mask = Image.new("L", (S, S), 0)
ImageDraw.Draw(mask).rounded_rectangle([90, 90, S - 90, S - 90], radius=190, fill=255)
img.paste(grad, (0, 0), mask)
d = ImageDraw.Draw(img)
# mřížka 3x3 „boxu“
cell, gap = 176, 44
x0 = (S - (3 * cell + 2 * gap)) // 2
for r in range(3):
    for c in range(3):
        x, y = x0 + c * (cell + gap), x0 + r * (cell + gap)
        if (r, c) == (1, 1):
            d.rounded_rectangle([x, y, x + cell, y + cell], radius=40, fill=(255, 214, 92, 255))
            # zatržítko
            d.line([(x + 44, y + 92), (x + 78, y + 126), (x + 136, y + 56)], fill=(40, 60, 70, 255), width=22,
                   joint="curve")
        else:
            d.rounded_rectangle([x, y, x + cell, y + cell], radius=40, fill=(255, 255, 255, 215))
for size in (16, 32, 64, 128, 256, 512):
    img.resize((size, size), Image.LANCZOS).save(f"{out}/icon_{size}x{size}.png")
    img.resize((size * 2, size * 2), Image.LANCZOS).save(f"{out}/icon_{size}x{size}@2x.png")
EOF

iconutil -c icns "$ICONSET" -o "$ROOT/app/AppIcon.icns"
rm -rf "$TMP"
echo "✔ Ikona: app/AppIcon.icns"
