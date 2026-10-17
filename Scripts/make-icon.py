#!/usr/bin/env python3
"""Turns the logo artwork (an icon tile on a black backdrop) into Assets/AppIcon.icns.

Finds the tile by brightness, places it on Apple's 1024 px icon grid (824 px tile, 100 px margin),
and cuts the black backdrop away along the tile's own outline.
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

# Mask traced from the artwork itself: the tile is lighter than the black backdrop all the way to
# its rim, so threshold it, fill any interior holes, pull the edge in to drop the dark fringe, and
# soften one pixel for anti-aliasing.
# A black border around the crop joins all of the backdrop into one ring the fill can reach.
PAD = 12
padded = Image.new("L", (TILE + 2 * PAD, TILE + 2 * PAD), 0)
padded.paste(tile.convert("L"), (PAD, PAD))
holes = padded.point(lambda v: 255 if v > 16 else 0)
ImageDraw.floodfill(holes, (0, 0), 128)                 # backdrop → 128
mask = holes.point(lambda v: 0 if v == 128 else 255)    # everything else is tile
mask = mask.filter(ImageFilter.MinFilter(5))            # erode ~2 px
mask = mask.filter(ImageFilter.GaussianBlur(1.0)).crop((PAD, PAD, PAD + TILE, PAD + TILE))
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
