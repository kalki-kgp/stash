#!/usr/bin/env python3
"""Turns the logo artwork (an icon tile on a black backdrop) into Assets/AppIcon.icns.

Finds the tile by brightness, places it on Apple's 1024 px icon grid (824 px tile, 100 px margin),
and cuts the black backdrop away with an anti-aliased superellipse matching the tile's corners.
Usage: Scripts/make-icon.py <artwork.png>
"""
import os, subprocess, sys, tempfile
from PIL import Image, ImageChops, ImageDraw, ImageFilter

src = Image.open(sys.argv[1]).convert("RGB")
root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")

# The tile is dark grey, the backdrop near-black: threshold, then take the bounding box.
gray = src.convert("L").point(lambda v: 255 if v > 14 else 0).filter(ImageFilter.MedianFilter(5))
box = gray.getbbox()
tile = src.crop(box)
side = max(tile.size)
square = Image.new("RGB", (side, side), (0, 0, 0))
square.paste(tile, ((side - tile.width) // 2, (side - tile.height) // 2))

TILE, CANVAS, SS = 824, 1024, 4
tile = square.resize((TILE, TILE), Image.LANCZOS)

# Superellipse mask (n = 5 approximates Apple's continuous-corner squircle), supersampled for AA.
n, big = 5.0, TILE * SS
mask = Image.new("L", (big, big), 0)
draw = ImageDraw.Draw(mask)
r = big / 2
for y in range(big):
    dy = abs((y + 0.5 - r) / r)
    if dy >= 1:
        continue
    dx = (1 - dy ** n) ** (1 / n)
    draw.line([(r - dx * r, y), (r + dx * r - 1, y)], fill=255)
mask = mask.resize((TILE, TILE), Image.LANCZOS)

icon = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
off = (CANVAS - TILE) // 2
rgba = tile.convert("RGBA")
rgba.putalpha(mask)
icon.paste(rgba, (off, off), rgba)
os.makedirs(os.path.join(root, "Assets"), exist_ok=True)
icon.save(os.path.join(root, "Assets/AppIcon-1024.png"))

with tempfile.TemporaryDirectory() as tmp:
    iconset = os.path.join(tmp, "AppIcon.iconset")
    os.makedirs(iconset)
    for size in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            px = size * scale
            name = f"icon_{size}x{size}{'@2x' if scale == 2 else ''}.png"
            icon.resize((px, px), Image.LANCZOS).save(os.path.join(iconset, name))
    subprocess.run(["iconutil", "-c", "icns", iconset, "-o", os.path.join(root, "Assets/AppIcon.icns")], check=True)
print("tile box", box, "→ Assets/AppIcon.icns")
