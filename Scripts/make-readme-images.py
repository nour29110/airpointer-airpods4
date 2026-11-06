#!/usr/bin/env python3
"""Make the README's images from the case renders and the app's own previews.

Needs Pillow and ffmpeg. Run this from the project folder after a build:

AirPointer.app/Contents/MacOS/AirPointer --check-home --preview-directory /tmp/previews
python3 Scripts/make-readme-images.py /tmp/previews
"""
import math
import subprocess
import sys
import tempfile
from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter, ImageFont

root = Path(__file__).resolve().parent.parent
assets = root / 'Assets'
out = assets / 'Readme'
previews = Path(sys.argv[1])
stage = (28, 28, 30, 255)


def font(size, weight):
    face = ImageFont.truetype('/System/Library/Fonts/SFNS.ttf', size)
    # San Francisco's axes: width, optical size, grade, weight.
    face.set_variation_by_axes([100, max(17, size), 400, weight])
    return face


def rounded(size, radius, fill=255):
    mask = Image.new('L', (size[0] * 2, size[1] * 2), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, size[0] * 2 - 1, size[1] * 2 - 1), radius * 2, fill=fill)
    return mask.resize(size, Image.LANCZOS)


def banner(size, radius=36):
    image = Image.new('RGBA', size, (0, 0, 0, 0))
    image.paste(stage, (0, 0), rounded(size, radius))
    return image


def place(canvas, image, x, y, radius=24):
    """A window on the stage: rounded corners and a soft shadow."""
    w, h = image.size
    shadow = Image.new('L', canvas.size, 0)
    shadow.paste(rounded((w, h), radius, 150), (x, y + 14))
    canvas.paste((0, 0, 0, 255), (0, 0), shadow.filter(ImageFilter.GaussianBlur(24)))
    canvas.paste(image.convert('RGB'), (x, y), rounded((w, h), radius))


def fit(name, width, crop_height=None):
    image = Image.open(previews / f'{name}.png').convert('RGBA')
    if crop_height:
        image = image.crop((0, 0, image.width, crop_height))
    return image.resize((width, round(image.height * width / image.width)), Image.LANCZOS)


def icon():
    with tempfile.TemporaryDirectory() as folder:
        png = Path(folder) / 'icon.png'
        subprocess.run(['sips', '-s', 'format', 'png', str(assets / 'AppIcon.icns'), '--out', str(png)], check=True, capture_output=True)
        Image.open(png).convert('RGBA').resize((256, 256), Image.LANCZOS).save(out / 'icon.png', optimize=True)


def screens():
    canvas = banner((2000, 960), 48)
    place(canvas, fit('pointer-running', 660, 1040), 90, 90)
    place(canvas, fit('menu-bar', 560), 800, 82)
    # The notch's "Pointing" panel, without the desktop around it.
    notch = Image.open(previews / 'notch-steps.png').convert('RGBA')
    place(canvas, notch.crop((80, 2578, 797, 2978)).resize((500, 279), Image.LANCZOS), 1420, 340, 34)
    canvas.save(out / 'screens.png', optimize=True)


def setup():
    names = ['setup-allow', 'setup-connect', 'setup-calibrate', 'setup-tap']
    canvas = banner((2000, 600), 48)
    for index, name in enumerate(names):
        place(canvas, fit(name, 440), 60 + index * 480, 56, 14)
    canvas.save(out / 'setup.png', optimize=True)


def connect_animation():
    size = (1200, 560)
    title, detail = font(40, 650), font(26, 400)
    lid = [Image.open(path).convert('RGBA').resize((400, 400), Image.LANCZOS) for path in sorted((assets / 'CaseLid').glob('lid-*.png'))]
    front = Image.open(assets / 'CaseFront.png').convert('RGBA').resize((400, 400), Image.LANCZOS)

    def frame(art, heading, words, pips, live=False):
        image = banner(size)
        image.alpha_composite(art, ((size[0] - 400) // 2, 16))
        draw = ImageDraw.Draw(image)
        for index in range(3):
            x = size[0] // 2 - 75 + index * 54
            draw.rounded_rectangle((x, 410, x + 42, 415), 3, fill=(245, 245, 247, 255) if index < pips else (90, 90, 94, 255))
        width = draw.textlength(heading, font=title) + (34 if live else 0)
        x = (size[0] - width) / 2
        if live:
            draw.ellipse((x, 448, x + 20, 468), fill=(240, 74, 56, 255))
            x += 34
        draw.text((x, 432), heading, font=title, fill=(245, 245, 247, 255))
        draw.text((size[0] / 2, 500), words, font=detail, fill=(170, 170, 176, 255), anchor='ma')
        return image

    frames = [frame(lid[0], 'Open the lid', 'Keep both AirPods inside.', 1)] * 12
    frames += [frame(art, 'Close the lid', 'AirPointer goes on by itself.', 2) for art in lid for _ in range(2)]
    frames += [frame(lid[-1], 'Close the lid', 'AirPointer goes on by itself.', 2)] * 8
    for step in range(18):
        t = step / 17
        turn = (1 - math.cos(t * math.pi)) / 2
        art = lid[-1].rotate(-90 * turn, Image.BICUBIC)
        frames.append(frame(Image.blend(art, front, max(0, turn - 0.75) * 4), 'Turn it upright', 'A quarter turn clockwise.', 3))
    frames += [frame(front, 'Pointing', 'Aim with the case. Tap its front to click.', 3, True)] * 28

    with tempfile.TemporaryDirectory() as folder:
        for index, image in enumerate(frames):
            image.save(Path(folder) / f'{index:03}.png')
        subprocess.run(['ffmpeg', '-y', '-loglevel', 'error', '-framerate', '15', '-i', f'{folder}/%03d.png', '-filter_complex',
                        '[0:v]scale=880:-1:flags=lanczos,split[a][b];[a]palettegen=reserve_transparent=1:stats_mode=full[p];[b][p]paletteuse=dither=bayer:bayer_scale=4:alpha_threshold=128',
                        '-loop', '0', str(out / 'connect.gif')], check=True)


out.mkdir(exist_ok=True)
icon()
screens()
setup()
connect_animation()
