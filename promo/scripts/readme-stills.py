#!/usr/bin/env python3
"""Frames captured app screenshots for the README: rounded window, soft shadow, paper ground.

Usage:
  readme-stills.py window <screenshot.png> <out.png>
  readme-stills.py capsule <prompt.jpg> <countdown.jpg> <out.png>
"""
import sys

from PIL import Image, ImageChops, ImageDraw, ImageFilter

PAPER = (246, 245, 241)
WIDTH = 2400


def rounded(img, radius):
    mask = Image.new('L', img.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, img.size[0] - 1, img.size[1] - 1], radius, fill=255)
    out = img.convert('RGBA')
    out.putalpha(ImageChops.multiply(out.getchannel('A'), mask))
    return out


def shadowed(canvas, card, x, y, blur=60, dy=34, alpha=48):
    shadow = Image.new('RGBA', canvas.size, (0, 0, 0, 0))
    a = card.getchannel('A').point(lambda v: v * alpha // 255)
    tint = Image.new('RGBA', card.size, (60, 40, 20, 0))
    tint.putalpha(a)
    shadow.paste(tint, (x, y + dy), tint)
    shadow = shadow.filter(ImageFilter.GaussianBlur(blur))
    canvas.alpha_composite(shadow)
    canvas.alpha_composite(card, (x, y))


def window(src, out):
    shot = Image.open(src).convert('RGB')
    w = WIDTH - 240
    h = round(shot.size[1] * w / shot.size[0])
    card = rounded(shot.resize((w, h), Image.LANCZOS), 26)
    canvas = Image.new('RGBA', (WIDTH, h + 260), PAPER + (255,))
    shadowed(canvas, card, 120, 100)
    canvas.convert('RGB').save(out, optimize=True)


def capsule(prompt, countdown, out):
    """The notch capsule in two states, each hanging from the top edge of a screen strip."""
    strip_w, strip_h, gap = WIDTH - 240, 300, 70
    canvas = Image.new('RGBA', (WIDTH, 120 * 2 + strip_h * 2 + gap), PAPER + (255,))
    for i, src in enumerate((prompt, countdown)):
        frame = Image.open(src).convert('RGB')
        frame = frame.crop((0, 0, frame.size[0], 200))
        scale = 1.55
        frame = frame.resize((round(frame.size[0] * scale), round(frame.size[1] * scale)), Image.LANCZOS)
        strip = Image.new('RGB', (strip_w, strip_h), (233, 230, 223))
        bar = Image.new('RGB', (strip_w, 56), (226, 222, 214))
        strip.paste(bar, (0, 0))
        # the capture's white ground disappears under multiply, leaving the black capsule
        x = (strip_w - frame.size[0]) // 2
        region = strip.crop((x, 0, x + frame.size[0], frame.size[1]))
        strip.paste(ImageChops.multiply(region, frame), (x, 0))
        card = rounded(strip, 26)
        shadowed(canvas, card, 120, 120 + i * (strip_h + gap), blur=40, dy=20, alpha=40)
    canvas.convert('RGB').save(out, optimize=True)


if __name__ == '__main__':
    kind = sys.argv[1]
    if kind == 'window':
        window(sys.argv[2], sys.argv[3])
    else:
        capsule(sys.argv[2], sys.argv[3], sys.argv[4])
