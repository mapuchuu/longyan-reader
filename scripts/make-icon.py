#!/usr/bin/env python3
"""Makes Resources/AppIcon.icns from Resources/longyan-mark.png: the mark in ink on a warm
paper squircle, laid out on Apple's macOS icon grid (an 824 pt body on a 1024 pt canvas,
with its drop shadow). Needs Pillow; run it only when the mark or the colours change.

    python3 scripts/make-icon.py
"""
import os, shutil, subprocess, tempfile
from PIL import Image, ImageChops, ImageDraw, ImageFilter

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
PAPER_TOP, PAPER_BOTTOM = (250, 247, 241), (236, 229, 217)
INK = (28, 28, 30)


def master(n=1024):
    mark = Image.open(os.path.join(ROOT, "Resources/longyan-mark.png")).convert("RGBA")
    # The mark is black on white: its darkness is the shape.
    shape = ImageChops.multiply(ImageChops.invert(mark.convert("L")), mark.split()[3])
    shape = shape.crop(shape.getbbox())

    body, radius = round(n * 824 / 1024), round(n * 185 / 1024)
    inset = (n - body) // 2
    squircle = Image.new("L", (n, n), 0)
    ImageDraw.Draw(squircle).rounded_rectangle((inset, inset, inset + body, inset + body), radius=radius, fill=255)

    icon = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    shadow = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    shadow.putalpha(squircle.point(lambda v: int(v * 0.30)))
    icon.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(n * 14 / 1024)), (0, round(n * 10 / 1024)))

    gradient = Image.new("RGBA", (1, n))
    for y in range(n):
        t = y / (n - 1)
        gradient.putpixel((0, y), tuple(round(PAPER_TOP[i] * (1 - t) + PAPER_BOTTOM[i] * t) for i in range(3)) + (255,))
    paper = gradient.resize((n, n))
    paper.putalpha(squircle)
    icon.alpha_composite(paper)

    w = round(body * 0.62)
    h = round(shape.height * w / shape.width)
    ink = Image.new("RGBA", (w, h), INK + (255,))
    ink.putalpha(shape.resize((w, h), Image.LANCZOS))
    icon.alpha_composite(ink, ((n - w) // 2, (n - h) // 2))
    return icon


def main():
    big = master(1024)
    tmp = tempfile.mkdtemp()
    iconset = os.path.join(tmp, "AppIcon.iconset")
    os.mkdir(iconset)
    for size in (16, 32, 128, 256, 512):
        big.resize((size, size), Image.LANCZOS).save(os.path.join(iconset, f"icon_{size}x{size}.png"))
        big.resize((size * 2, size * 2), Image.LANCZOS).save(os.path.join(iconset, f"icon_{size}x{size}@2x.png"))
    out = os.path.join(ROOT, "Resources/AppIcon.icns")
    subprocess.run(["iconutil", "-c", "icns", iconset, "-o", out], check=True)
    shutil.rmtree(tmp)
    print("wrote", os.path.relpath(out, ROOT))


if __name__ == "__main__":
    main()
