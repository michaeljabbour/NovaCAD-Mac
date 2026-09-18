#!/usr/bin/env python3
"""Generates NovaCAD's app icon (a 1024px master PNG) into the given path.

A dark CAD-canvas square with a blue 'N', faint grid, and a crosshair — evokes
the viewer's dark canvas and drafting tools. Pure Pillow; no external assets.
"""
import sys
from PIL import Image, ImageDraw, ImageFont

SIZE = 1024
out = sys.argv[1] if len(sys.argv) > 1 else "icon_1024.png"

img = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
d = ImageDraw.Draw(img)

# Rounded-rect background (AutoCAD-ish dark canvas).
margin = 40
radius = 190
d.rounded_rectangle([margin, margin, SIZE - margin, SIZE - margin],
                    radius=radius, fill=(33, 41, 48, 255))

# Faint grid.
grid = (255, 255, 255, 18)
step = 96
for x in range(margin + step, SIZE - margin, step):
    d.line([(x, margin + 8), (x, SIZE - margin - 8)], fill=grid, width=2)
for y in range(margin + step, SIZE - margin, step):
    d.line([(margin + 8, y), (SIZE - margin - 8, y)], fill=grid, width=2)

# Cyan crosshair through the centre.
cx = cy = SIZE // 2
cross = (64, 168, 255, 90)
d.line([(margin + 20, cy), (SIZE - margin - 20, cy)], fill=cross, width=3)
d.line([(cx, margin + 20), (cx, SIZE - margin - 20)], fill=cross, width=3)

# Big "N".
font = None
for path in [
    "/System/Library/Fonts/SFNSRounded.ttf",
    "/System/Library/Fonts/SFNS.ttf",
    "/System/Library/Fonts/Helvetica.ttc",
    "/Library/Fonts/Arial.ttf",
]:
    try:
        font = ImageFont.truetype(path, 620)
        break
    except Exception:
        continue
accent = (64, 168, 255, 255)
if font is not None:
    bbox = d.textbbox((0, 0), "N", font=font)
    w, h = bbox[2] - bbox[0], bbox[3] - bbox[1]
    d.text((cx - w / 2 - bbox[0], cy - h / 2 - bbox[1]), "N", font=font, fill=accent)
else:
    # Fallback: draw the strokes of an N by hand.
    lw = 90
    left, right = cx - 210, cx + 210
    top, bot = cy - 260, cy + 260
    d.line([(left, bot), (left, top)], fill=accent, width=lw)
    d.line([(left, top), (right, bot)], fill=accent, width=lw)
    d.line([(right, bot), (right, top)], fill=accent, width=lw)

# Red "measure tick" accent (nod to the markup tools).
d.line([(SIZE - margin - 250, SIZE - margin - 150),
        (SIZE - margin - 90, SIZE - margin - 150)], fill=(255, 60, 50, 230), width=14)

img.save(out)
print("wrote", out)
