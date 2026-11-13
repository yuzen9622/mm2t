"""Regenerates background.png and background@2x.png (needs Pillow; run: python3 make_background.py).

The window is 660x400 points. The icon centres in settings.py, (180,170) and (480,170), line up
with the arrow drawn here, so change both together.
"""
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

W, H = 660, 400
CREAM, ORANGE, INK = "#F6F5F1", "#F0700F", "#1C1C1E"
FONT = "/System/Library/Fonts/STHeiti Medium.ttc"
out = Path(__file__).parent

for scale, name in ((1, "background.png"), (2, "background@2x.png")):
    def s(v):
        return round(v * scale)

    img = Image.new("RGB", (s(W), s(H)), CREAM)
    d = ImageDraw.Draw(img)

    # Arrow between the two icons, centred on y = 170.
    y, x0, x1, head = 170, 268, 392, 22
    shaft_end = x1 - head + 4
    d.line([(s(x0), s(y)), (s(shaft_end), s(y))], fill=ORANGE, width=s(7))
    d.polygon([(s(x1), s(y)), (s(x1 - head), s(y - 15)), (s(x1 - head), s(y + 15))], fill=ORANGE)
    d.ellipse([s(x0 - 3.5), s(y - 3.5), s(x0 + 3.5), s(y + 3.5)], fill=ORANGE)  # round the tail

    font = ImageFont.truetype(FONT, s(20))
    text = "拖入 Applications 以安裝"
    width = d.textlength(text, font=font)
    d.text(((s(W) - width) / 2, s(318)), text, font=font, fill=INK)

    img.save(out / name, dpi=(72 * scale, 72 * scale))
