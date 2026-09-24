"""Generuje ikony Androida Dynomic Diag (wariant B: białe logo na czerwieni + znacznik diagnozy).

Uruchom: python3 tool/make_icons.py (wymaga Pillow).
"""
from PIL import Image, ImageDraw
import math, os

RED = (0xE5, 0x1C, 0x1C, 255)
WHITE = (255, 255, 255, 255)
RES = "android/app/src/main/res"
SS = 4  # nadpróbkowanie


def draw_mark(d, cx, cy, k, badge_fill=RED, badge=True):
    """Znak Dynomic w układzie 40x40 (środek 0,0) przeskalowany o k pikseli na jednostkę."""
    w = 3.2 * k
    r = 17 * k
    d.ellipse([cx - r - w / 2, cy - r - w / 2, cx + r + w / 2, cy + r + w / 2], outline=WHITE, width=round(w))
    pts = [(-11, 2), (-6, 2), (-2, -7), (3, 8), (7, -2), (11, -2)]
    pts = [(cx + x * k, cy + y * k) for x, y in pts]
    d.line(pts, fill=WHITE, width=round(w), joint="curve")
    for x, y in (pts[0], pts[-1]):  # zaokrąglone końce
        d.ellipse([x - w / 2, y - w / 2, x + w / 2, y + w / 2], fill=WHITE)
    if badge:
        bx, by, br = cx + 12 * k, cy + 12 * k, 6.5 * k
        bw = 2.4 * k
        d.ellipse([bx - br - bw / 2, by - br - bw / 2, bx + br + bw / 2, by + br + bw / 2], fill=WHITE)
        d.ellipse([bx - br + bw / 2, by - br + bw / 2, bx + br - bw / 2, by + br - bw / 2], fill=badge_fill)
        ck = [(bx - 2.7 * k, by), (bx - 0.8 * k, by + 1.9 * k), (bx + 2.8 * k, by - 1.9 * k)]
        d.line(ck, fill=WHITE, width=round(1.8 * k), joint="curve")


def render(size, fn):
    big = Image.new("RGBA", (size * SS, size * SS), (0, 0, 0, 0))
    fn(ImageDraw.Draw(big), size * SS)
    return big.resize((size, size), Image.LANCZOS)


def legacy(d, s):
    d.rounded_rectangle([0, 0, s - 1, s - 1], radius=s * 0.22, fill=RED)
    draw_mark(d, s / 2, s / 2, s / 108 * 1.55)


def legacy_round(d, s):
    d.ellipse([0, 0, s - 1, s - 1], fill=RED)
    draw_mark(d, s / 2, s / 2, s / 108 * 1.45)


def foreground(d, s):
    # Strefa bezpieczna ikony adaptacyjnej: koło o średnicy 66 z 108 dp
    draw_mark(d, s / 2, s / 2, s / 108 * 1.15)


def monochrome(d, s):
    draw_mark(d, s / 2, s / 2, s / 108 * 1.15, badge_fill=(0, 0, 0, 0))


densities = {"mdpi": 1, "hdpi": 1.5, "xhdpi": 2, "xxhdpi": 3, "xxxhdpi": 4}
for name, f in densities.items():
    folder = f"{RES}/mipmap-{name}"
    os.makedirs(folder, exist_ok=True)
    render(round(48 * f), legacy).save(f"{folder}/ic_launcher.png")
    render(round(48 * f), legacy_round).save(f"{folder}/ic_launcher_round.png")
    render(round(108 * f), foreground).save(f"{folder}/ic_launcher_foreground.png")
    render(round(108 * f), monochrome).save(f"{folder}/ic_launcher_monochrome.png")

os.makedirs(f"{RES}/mipmap-anydpi-v26", exist_ok=True)
adaptive = """<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@color/ic_launcher_background"/>
    <foreground android:drawable="@mipmap/ic_launcher_foreground"/>
    <monochrome android:drawable="@mipmap/ic_launcher_monochrome"/>
</adaptive-icon>
"""
for n in ("ic_launcher.xml", "ic_launcher_round.xml"):
    open(f"{RES}/mipmap-anydpi-v26/{n}", "w").write(adaptive)
open(f"{RES}/values/ic_launcher_background.xml", "w").write(
    '<?xml version="1.0" encoding="utf-8"?>\n<resources>\n    <color name="ic_launcher_background">#E51C1C</color>\n</resources>\n')

# Podgląd do dokumentacji / sprawdzenia
render(512, legacy).save("tool/icon_preview.png")
print("ok")
