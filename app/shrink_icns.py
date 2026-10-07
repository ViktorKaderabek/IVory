#!/usr/bin/env python3
"""Losslessly shrinks an .icns in place.

iconutil writes the icon representations as lightly compressed PNGs. This
recompresses every one of them (an image stored twice, like ic08/ic13, only once),
which takes about a third off the file. The pixels are untouched.

Uses oxipng when it is installed (it also tries the PNG row filters), and falls
back to the standard library otherwise, so the build works without it.
"""
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import zlib

PNG_MAGIC = b"\x89PNG\r\n\x1a\n"


def _chunk(typ: bytes, data: bytes) -> bytes:
    return struct.pack(">I", len(data)) + typ + data + struct.pack(">I", zlib.crc32(typ + data))


def _shrink_png_stdlib(png: bytes) -> bytes:
    """Rebuild the PNG with its pixel stream recompressed at the highest zlib level."""
    out, idat, off = [PNG_MAGIC], b"", 8
    while off < len(png):
        (length,) = struct.unpack(">I", png[off:off + 4])
        typ, data = png[off + 4:off + 8], png[off + 8:off + 8 + length]
        off += 12 + length
        if typ == b"IDAT":          # collect, the stream can be split over several chunks
            idat += data
            continue
        if typ == b"IEND":
            out.append(_chunk(b"IDAT", zlib.compress(zlib.decompress(idat), 9)))
            out.append(_chunk(b"IEND", b""))
            break
        out.append(_chunk(typ, data))
    return b"".join(out)


def _shrink_png_oxipng(png: bytes) -> bytes:
    fd, tmp = tempfile.mkstemp(suffix=".png")
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(png)
        subprocess.run(["oxipng", "-o", "max", "--strip", "safe", "-q", tmp], check=True)
        with open(tmp, "rb") as f:
            return f.read()
    finally:
        os.unlink(tmp)


def shrink(path: str) -> tuple[int, int]:
    with open(path, "rb") as f:
        blob = f.read()
    if blob[:4] != b"icns":
        raise SystemExit(f"✖ {path} is not an .icns file")

    shrink_png = _shrink_png_oxipng if shutil.which("oxipng") else _shrink_png_stdlib
    parts, seen, off = [], {}, 8
    while off < len(blob):
        typ, length = struct.unpack(">4sI", blob[off:off + 8])
        if length < 8 or off + length > len(blob):
            raise SystemExit(f"✖ {path} is damaged (entry {typ!r})")
        body = blob[off + 8:off + length]
        off += length
        if body[:8] == PNG_MAGIC:
            if body in seen:
                body = seen[body]
            else:
                smaller = shrink_png(body)
                seen[body] = body = smaller if len(smaller) < len(body) else body
        parts.append(typ + struct.pack(">I", len(body) + 8) + body)

    packed = b"".join(parts)
    with open(path, "wb") as f:
        f.write(b"icns" + struct.pack(">I", len(packed) + 8) + packed)
    return len(blob), len(packed) + 8


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: shrink_icns.py <AppIcon.icns>")
    before, after = shrink(sys.argv[1])
    print(f"  ikona {before / 1024:.0f} kB → {after / 1024:.0f} kB "
          f"(−{100 - 100 * after / before:.0f} %)")
