#!/usr/bin/env python3
"""Regenerate apple-touch-icon.png - the iOS home-screen icon for the dashboard.

Pure stdlib on purpose: this box has no PIL and no ImageMagick, and the repo's whole
premise is that nothing needs installing to rebuild what it ships. The icon is committed
as a PNG, so this script only runs when the artwork changes.

Design: three ascending gold candlesticks on the dashboard's dark navy, matching the
page's --accent (#d9ad57) and dark --surface. iOS applies its own squircle mask, so the
background is full-bleed and the artwork stays inside the middle ~70%.

    python3 tools/make-icon.py            # writes apple-touch-icon.png at the repo root
"""

import os
import struct
import zlib

SIZE = 180          # apple-touch-icon.png: 180x180 is what iOS asks for at @3x
SS = 4              # supersample factor; the box-downsample at the end is the antialiasing

BG_TOP = (26, 34, 49)        # #1a2231
BG_BOTTOM = (13, 18, 27)     # #0d121b
CANDLE_LOW = (196, 154, 74)  # #c49a4a - leftmost, dimmest
CANDLE_MID = (217, 173, 87)  # #d9ad57 - the page's --accent
CANDLE_HIGH = (240, 196, 118)  # #f0c476 - rightmost, brightest: reads as "rising"
BASELINE = (217, 173, 87)

# (centre x, wick top, wick bottom, body top, body bottom, colour) in final-pixel space
CANDLES = [
    (54, 96, 146, 106, 140, CANDLE_LOW),
    (90, 66, 124, 76, 116, CANDLE_MID),
    (126, 34, 102, 44, 94, CANDLE_HIGH),
]
BODY_W = 22
WICK_W = 4


def new_canvas():
    """Full-bleed vertical gradient, rendered straight onto the supersampled grid."""
    n = SIZE * SS
    buf = bytearray(n * n * 3)
    for y in range(n):
        t = y / (n - 1)
        row = bytes(
            round(BG_TOP[c] + (BG_BOTTOM[c] - BG_TOP[c]) * t) for c in range(3)
        ) * n
        buf[y * n * 3:(y + 1) * n * 3] = row
    return buf


def blend(buf, idx, color, alpha):
    if alpha >= 1.0:
        buf[idx:idx + 3] = bytes(color)
        return
    for c in range(3):
        buf[idx + c] = round(buf[idx + c] * (1 - alpha) + color[c] * alpha)


def rounded_rect(buf, x0, y0, x1, y1, radius, color, alpha=1.0):
    """Fill a rounded rectangle given in final-pixel coordinates.

    Edges land on the supersampled grid and get their smoothing from the downsample,
    so this only needs a hard inside/outside test per sample.
    """
    n = SIZE * SS
    for py in range(max(0, int(y0 * SS)), min(n, int(y1 * SS) + 1)):
        sy = (py + 0.5) / SS
        if sy < y0 or sy > y1:
            continue
        for px in range(max(0, int(x0 * SS)), min(n, int(x1 * SS) + 1)):
            sx = (px + 0.5) / SS
            if sx < x0 or sx > x1:
                continue
            # corner test: only the arcs need distance maths, the straight edges are free
            cx = min(max(sx, x0 + radius), x1 - radius)
            cy = min(max(sy, y0 + radius), y1 - radius)
            dx, dy = sx - cx, sy - cy
            if dx * dx + dy * dy > radius * radius:
                continue
            blend(buf, (py * n + px) * 3, color, alpha)


def downsample(buf):
    """Box filter SSxSS back to SIZExSIZE. This is what makes the edges smooth."""
    n = SIZE * SS
    out = bytearray(SIZE * SIZE * 3)
    area = SS * SS
    for y in range(SIZE):
        for x in range(SIZE):
            totals = [0, 0, 0]
            for sy in range(y * SS, y * SS + SS):
                base = (sy * n + x * SS) * 3
                for sx in range(SS):
                    i = base + sx * 3
                    totals[0] += buf[i]
                    totals[1] += buf[i + 1]
                    totals[2] += buf[i + 2]
            o = (y * SIZE + x) * 3
            out[o] = totals[0] // area
            out[o + 1] = totals[1] // area
            out[o + 2] = totals[2] // area
    return out


def write_png(path, pixels):
    """Minimal 8-bit truecolour PNG writer (filter 0 on every row)."""
    raw = b"".join(
        b"\x00" + bytes(pixels[y * SIZE * 3:(y + 1) * SIZE * 3]) for y in range(SIZE)
    )

    def chunk(tag, data):
        return (
            struct.pack(">I", len(data))
            + tag
            + data
            + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
        )

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", SIZE, SIZE, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(raw, 9))
    png += chunk(b"IEND", b"")
    with open(path, "wb") as fh:
        fh.write(png)


def main():
    buf = new_canvas()
    # a faint rule under the candles: gives the chart a floor without competing with it
    rounded_rect(buf, 30, 151, 150, 153, 1, BASELINE, alpha=0.32)
    for cx, wick_top, wick_bottom, body_top, body_bottom, color in CANDLES:
        rounded_rect(buf, cx - WICK_W / 2, wick_top, cx + WICK_W / 2, wick_bottom, WICK_W / 2, color)
        rounded_rect(buf, cx - BODY_W / 2, body_top, cx + BODY_W / 2, body_bottom, 4, color)

    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    out = os.path.join(root, "apple-touch-icon.png")
    write_png(out, downsample(buf))
    print("wrote %s (%dx%d, %d bytes)" % (out, SIZE, SIZE, os.path.getsize(out)))


if __name__ == "__main__":
    main()
