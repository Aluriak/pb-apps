#!/usr/bin/env python3
"""Draws the icons of the apps into icons/: <id>.bmp and <id>_f.bmp (focused, inverted).

The reader shows apps declared in view.json with these: BMP, 128 x 128 pixels at most.
Needs Pillow: pip install pillow
"""

from pathlib import Path

from PIL import Image, ImageDraw, ImageOps

SIZE = 120
LINE = 6
OUT = Path(__file__).resolve().parent.parent / "icons"


def canvas():
    image = Image.new("L", (SIZE, SIZE), 255)
    return image, ImageDraw.Draw(image)


def opds_connector(draw):
    # An open book with an arrow coming down into it
    draw.line([(14, 52), (60, 64), (106, 52)], fill=0, width=LINE)
    draw.line([(14, 52), (14, 100), (60, 112), (106, 100), (106, 52)], fill=0, width=LINE, joint="curve")
    draw.line([(60, 64), (60, 112)], fill=0, width=LINE)
    draw.line([(60, 8), (60, 44)], fill=0, width=LINE)
    draw.polygon([(44, 32), (76, 32), (60, 50)], fill=0)


def reading_stats(draw):
    # A bar chart on a base line
    draw.line([(12, 104), (108, 104)], fill=0, width=LINE)
    for x, top in ((22, 70), (50, 38), (78, 54)):
        draw.rectangle([(x, top), (x + 20, 98)], fill=0)
    draw.line([(18, 30), (40, 18), (62, 26), (100, 10)], fill=0, width=4)


def app_manager(draw):
    # Four app tiles, the last one being added
    for x, y in ((14, 14), (66, 14), (14, 66)):
        draw.rounded_rectangle([(x, y), (x + 40, y + 40)], radius=8, outline=0, width=LINE)
    draw.line([(86, 66), (86, 106)], fill=0, width=LINE)
    draw.line([(66, 86), (106, 86)], fill=0, width=LINE)


ICONS = {
    "opds-connector": opds_connector,
    "reading-stats": reading_stats,
    "app-manager": app_manager,
}


def main():
    OUT.mkdir(exist_ok=True)
    for app_id, draw_icon in ICONS.items():
        image, draw = canvas()
        draw_icon(draw)
        image.convert("RGB").save(OUT / f"{app_id}.bmp")
        ImageOps.invert(image).convert("RGB").save(OUT / f"{app_id}_f.bmp")
        print(f"icons/{app_id}.bmp, icons/{app_id}_f.bmp")


if __name__ == "__main__":
    main()
