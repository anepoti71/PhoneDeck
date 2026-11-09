"""Builds the app icon from a square artwork on a flat dark background.

    build/python/bin/python3 -I scripts/make-icon.py [Resources/AppIcon-source.png]

Steps:
1. the background is removed by flood-filling the near-black area from the four corners, so dark
   colours inside the artwork stay opaque;
2. the artwork is fitted to the macOS icon grid: an 824 px body centred on a 1024 px canvas, with
   a soft drop shadow like the system icons;
3. every size macOS uses (Dock, Finder, notifications, Cmd-Tab, Spotlight…) goes into
   build/AppIcon.iconset, then `iconutil` packs Resources/AppIcon.icns.

Also writes Resources/AppIcon.png (1024 px) for the README.
"""

import shutil
import subprocess
import sys
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
SOURCE = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "Resources" / "AppIcon-source.png"
CANVAS, BODY = 1024, 824          # Apple macOS icon grid
BG_THRESHOLD = 30                 # how far from the corner colour still counts as background
MAGENTA = (255, 0, 255)

ICONSET_SIZES = [  # (file name, pixels)
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]


def cut_out(src: Image.Image) -> Image.Image:
    """RGBA artwork cropped to its shape, background transparent with an anti-aliased edge."""
    rgb = src.convert("RGB")
    w, h = rgb.size
    filled = rgb.copy()
    for corner in [(0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1)]:
        if filled.getpixel(corner) != MAGENTA:
            ImageDraw.floodfill(filled, corner, MAGENTA, thresh=BG_THRESHOLD)
    # 255 where the artwork is, 0 on the background
    diff = ImageChops.difference(filled, Image.new("RGB", (w, h), MAGENTA)).convert("L")
    mask = diff.point(lambda v: 255 if v > 0 else 0)
    # Drop the 1 px dark rim the flood fill leaves, then soften the edge.
    mask = mask.filter(ImageFilter.MinFilter(3)).filter(ImageFilter.GaussianBlur(0.8))
    art = rgb.convert("RGBA")
    art.putalpha(mask)
    return art.crop(mask.getbbox())


def compose(art: Image.Image) -> Image.Image:
    """Artwork on the 1024 px grid with a soft shadow."""
    scale = BODY / max(art.size)
    body = art.resize((round(art.width * scale), round(art.height * scale)), Image.LANCZOS)
    canvas = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    x = (CANVAS - body.width) // 2
    y = (CANVAS - body.height) // 2

    shadow_alpha = body.getchannel("A").point(lambda v: v * 0.35)
    shadow = Image.new("RGBA", body.size, (0, 0, 0, 0))
    shadow.putalpha(shadow_alpha)
    layer = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    layer.paste(shadow, (x, y + 12), shadow)
    canvas = Image.alpha_composite(canvas, layer.filter(ImageFilter.GaussianBlur(14)))

    canvas.alpha_composite(body, (x, y))
    return canvas


def main() -> int:
    if not SOURCE.is_file():
        print(f"Immagine sorgente non trovata: {SOURCE}", file=sys.stderr)
        return 1
    icon = compose(cut_out(Image.open(SOURCE)))

    iconset = ROOT / "build" / "AppIcon.iconset"
    shutil.rmtree(iconset, ignore_errors=True)
    iconset.mkdir(parents=True)
    for name, px in ICONSET_SIZES:
        img = icon if px == CANVAS else icon.resize((px, px), Image.LANCZOS)
        if px <= 32:
            img = img.filter(ImageFilter.UnsharpMask(radius=0.6, percent=60, threshold=0))
        img.save(iconset / name)
    icon.save(ROOT / "Resources" / "AppIcon.png")

    out = ROOT / "Resources" / "AppIcon.icns"
    subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(out)], check=True)
    print(f"Creato {out.relative_to(ROOT)} ({out.stat().st_size // 1024} KB) e Resources/AppIcon.png")
    return 0


if __name__ == "__main__":
    sys.exit(main())
