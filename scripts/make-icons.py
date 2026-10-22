#!/usr/bin/env python3
"""Draws the icons of the apps into icons/: <id>.bmp and <id>_f.bmp (focused).

Same look as the reader's own icons: thin black outlines with rounded ends on white, in a
square of 122 pixels (the reader takes up to 128). The focused icon has a thicker line.
Drawn four times larger, then scaled down, for smooth lines.
Needs Pillow: pip install pillow
"""

from pathlib import Path

from PIL import Image, ImageDraw

SIZE = 122
SCALE = 4
OUT = Path(__file__).resolve().parent.parent / "icons"


class Pen:
    """Draws on the large canvas with coordinates of the final icon"""

    def __init__(self, draw, width):
        self.draw = draw
        self.width = round(width * SCALE)

    def _p(self, points):
        return [(x * SCALE, y * SCALE) for x, y in points]

    def line(self, *points):
        pts = self._p(points)
        self.draw.line(pts, fill=0, width=self.width, joint="curve")
        # Rounded ends, like the reader's icons
        r = self.width / 2
        for x, y in (pts[0], pts[-1]):
            self.draw.ellipse([(x - r, y - r), (x + r, y + r)], fill=0)

    def box(self, x0, y0, x1, y1, radius):
        self.draw.rounded_rectangle(self._p([(x0, y0), (x1, y1)]), radius=radius * SCALE, outline=0, width=self.width)


def opds_connector(pen):
    # An open book, an arrow coming down into it
    pen.line((22, 58), (40, 52), (61, 58))
    pen.line((61, 58), (82, 52), (100, 58))
    pen.line((22, 58), (22, 96), (40, 91), (61, 97), (82, 91), (100, 96), (100, 58))
    pen.line((61, 58), (61, 97))
    pen.line((61, 20), (61, 44))
    pen.line((51, 35), (61, 45), (71, 35))


def reading_stats(pen):
    # Three bars on a base line, a trend line above them
    pen.line((22, 98), (100, 98))
    pen.box(30, 70, 44, 98, 3)
    pen.box(54, 54, 68, 98, 3)
    pen.box(78, 62, 92, 98, 3)
    pen.line((28, 46), (48, 32), (66, 40), (94, 22))


def app_manager(pen):
    # Like the reader's "Applications" icon, the last tile being added
    pen.box(26, 26, 55, 55, 6)
    pen.box(67, 26, 96, 55, 6)
    pen.box(26, 67, 55, 96, 6)
    pen.line((81.5, 69), (81.5, 94))
    pen.line((69, 81.5), (94, 81.5))


ICONS = {
    "opds-connector": opds_connector,
    "reading-stats": reading_stats,
    "app-manager": app_manager,
}


def render(draw_icon, width):
    image = Image.new("L", (SIZE * SCALE, SIZE * SCALE), 255)
    draw_icon(Pen(ImageDraw.Draw(image), width))
    return image.resize((SIZE, SIZE), Image.LANCZOS).convert("RGB")


def main():
    OUT.mkdir(exist_ok=True)
    for app_id, draw_icon in ICONS.items():
        render(draw_icon, 3.5).save(OUT / f"{app_id}.bmp")
        render(draw_icon, 5.5).save(OUT / f"{app_id}_f.bmp")
        print(f"icons/{app_id}.bmp, icons/{app_id}_f.bmp")


if __name__ == "__main__":
    main()
