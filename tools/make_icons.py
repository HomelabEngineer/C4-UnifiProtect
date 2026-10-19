#!/usr/bin/env python3
"""Draw original Composer icons for every driver (Pillow only, no vendor logos).

    python3 tools/make_icons.py
Writes drivers/<driver>/www/icons/device_sm.png (16x16), device_lg.png (32x32)
and device_300.png (documentation header).
"""
import os

from PIL import Image, ImageDraw

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
SS = 8
TOP = (24, 132, 226)
BOTTOM = (12, 60, 128)
GLYPH = (240, 244, 248, 255)


def tile(size):
    n = size * SS
    img = Image.new("RGBA", (n, n))
    px = img.load()
    for y in range(n):
        t = y / max(1, n - 1)
        c = tuple(int(TOP[i] + (BOTTOM[i] - TOP[i]) * t) for i in range(3)) + (255,)
        for x in range(n):
            px[x, y] = c
    mask = Image.new("L", (n, n), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, n - 1, n - 1], radius=int(n * 0.22), fill=255)
    out = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    out.paste(img, (0, 0), mask)
    return out


def glyph_master(d, n):
    # stacked NVR with a shield badge
    w = n * 0.56
    x0 = (n - w) / 2
    for i in range(3):
        y = n * (0.26 + i * 0.17)
        d.rounded_rectangle([x0, y, x0 + w, y + n * 0.12], radius=n * 0.03, fill=GLYPH)
        d.ellipse([x0 + w * 0.8, y + n * 0.035, x0 + w * 0.8 + n * 0.05, y + n * 0.085], fill=(24, 132, 226, 255))


def glyph_camera(d, n):
    d.rounded_rectangle([n * 0.18, n * 0.32, n * 0.68, n * 0.68], radius=n * 0.06, fill=GLYPH)
    d.polygon([(n * 0.68, n * 0.44), (n * 0.84, n * 0.34), (n * 0.84, n * 0.66), (n * 0.68, n * 0.56)], fill=GLYPH)
    d.ellipse([n * 0.31, n * 0.39, n * 0.53, n * 0.61], fill=(12, 60, 128, 255))


def glyph_entry(d, n):
    d.rectangle([n * 0.3, n * 0.18, n * 0.62, n * 0.84], outline=GLYPH, width=int(n * 0.06))
    d.polygon([(n * 0.3, n * 0.18), (n * 0.56, n * 0.26), (n * 0.56, n * 0.9), (n * 0.3, n * 0.84)], fill=GLYPH)
    d.ellipse([n * 0.48, n * 0.5, n * 0.53, n * 0.55], fill=(12, 60, 128, 255))
    d.rectangle([n * 0.7, n * 0.4, n * 0.78, n * 0.62], fill=GLYPH)


def glyph_motion(d, n):
    c = (n * 0.3, n * 0.5)
    d.ellipse([c[0] - n * 0.07, c[1] - n * 0.07, c[0] + n * 0.07, c[1] + n * 0.07], fill=GLYPH)
    for r in (0.2, 0.33, 0.46):
        d.arc([c[0] - n * r, c[1] - n * r, c[0] + n * r, c[1] + n * r], start=-50, end=50, fill=GLYPH, width=int(n * 0.06))


def glyph_environmental(d, n):
    d.rounded_rectangle([n * 0.25, n * 0.16, n * 0.37, n * 0.66], radius=n * 0.06, fill=GLYPH)
    d.ellipse([n * 0.19, n * 0.6, n * 0.43, n * 0.84], fill=GLYPH)
    d.polygon([(n * 0.66, n * 0.2), (n * 0.52, n * 0.5), (n * 0.8, n * 0.5)], fill=GLYPH)
    d.ellipse([n * 0.52, n * 0.38, n * 0.8, n * 0.66], fill=GLYPH)


def glyph_smoke(d, n):
    d.ellipse([n * 0.18, n * 0.18, n * 0.82, n * 0.82], outline=GLYPH, width=int(n * 0.07))
    d.ellipse([n * 0.38, n * 0.38, n * 0.62, n * 0.62], fill=GLYPH)
    for i in range(6):
        import math
        a = i * math.pi / 3
        x, y = n * 0.5 + math.cos(a) * n * 0.2, n * 0.5 + math.sin(a) * n * 0.2
        d.ellipse([x - n * 0.025, y - n * 0.025, x + n * 0.025, y + n * 0.025], fill=GLYPH)


def glyph_siren(d, n):
    d.pieslice([n * 0.24, n * 0.22, n * 0.76, n * 0.74], start=180, end=360, fill=GLYPH)
    d.rectangle([n * 0.24, n * 0.48, n * 0.76, n * 0.66], fill=GLYPH)
    d.rectangle([n * 0.18, n * 0.68, n * 0.82, n * 0.78], fill=GLYPH)
    d.line([n * 0.5, n * 0.06, n * 0.5, n * 0.16], fill=GLYPH, width=int(n * 0.05))
    d.line([n * 0.14, n * 0.2, n * 0.22, n * 0.27], fill=GLYPH, width=int(n * 0.05))
    d.line([n * 0.86, n * 0.2, n * 0.78, n * 0.27], fill=GLYPH, width=int(n * 0.05))


GLYPHS = {
    "unifi_protect": glyph_master,
    "unifi_protect_camera": glyph_camera,
    "unifi_protect_entry": glyph_entry,
    "unifi_protect_motion": glyph_motion,
    "unifi_protect_environmental": glyph_environmental,
    "unifi_protect_smoke_co": glyph_smoke,
    "unifi_protect_siren": glyph_siren,
}


def render(fn, size):
    img = tile(size)
    fn(ImageDraw.Draw(img), size * SS)
    return img.resize((size, size), Image.LANCZOS)


def main():
    for folder, fn in GLYPHS.items():
        out = os.path.join(ROOT, "drivers", folder, "www", "icons")
        os.makedirs(out, exist_ok=True)
        render(fn, 16).save(os.path.join(out, "device_sm.png"))
        render(fn, 32).save(os.path.join(out, "device_lg.png"))
        render(fn, 300).save(os.path.join(out, "device_300.png"))
    print("icons written")


if __name__ == "__main__":
    main()
