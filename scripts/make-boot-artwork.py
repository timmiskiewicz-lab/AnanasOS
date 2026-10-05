#!/usr/bin/env python3
"""Build AnanasOS images: yellow-gradient wordmark, wallpaper, login and GRUB."""

import argparse
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

TOP = (255, 246, 176)
BOTTOM = (232, 160, 32)
INK = (28, 16, 0, 255)
HINT = (240, 193, 74, 255)

FONT_CANDIDATES = [
    "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
    "/usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf",
    r"C:\Windows\Fonts\arialbd.ttf",
    r"C:\Windows\Fonts\segoeuib.ttf",
    r"C:\Windows\Fonts\arial.ttf",
]


def find_font():
    for candidate in FONT_CANDIDATES:
        if Path(candidate).is_file():
            return candidate
    raise SystemExit("No usable font found for the AnanasOS wordmark")


def load_font(size):
    return ImageFont.truetype(find_font(), size)


def trim_alpha(image, pad=0):
    image = image.convert("RGBA")
    bbox = image.getbbox()
    if not bbox:
        return image
    left = max(0, bbox[0] - pad)
    top = max(0, bbox[1] - pad)
    right = min(image.width, bbox[2] + pad)
    bottom = min(image.height, bbox[3] + pad)
    return image.crop((left, top, right, bottom))


def scale_width(image, width, nearest=False):
    width = max(1, int(width))
    height = max(1, round(image.height * width / image.width))
    resample = Image.Resampling.NEAREST if nearest else Image.Resampling.LANCZOS
    return image.resize((width, height), resample)


def wordmark(text, size, stroke=5):
    font = load_font(size)
    probe = ImageDraw.Draw(Image.new("L", (4, 4)))
    bbox = probe.textbbox((0, 0), text, font=font, stroke_width=stroke)
    pad = 6
    width = bbox[2] - bbox[0] + pad * 2
    height = bbox[3] - bbox[1] + pad * 2
    origin = (pad - bbox[0], pad - bbox[1])

    stroke_mask = Image.new("L", (width, height), 0)
    ImageDraw.Draw(stroke_mask).text(
        origin, text, font=font, fill=255, stroke_width=stroke, stroke_fill=255
    )
    fill_mask = Image.new("L", (width, height), 0)
    ImageDraw.Draw(fill_mask).text(origin, text, font=font, fill=255)

    image = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    outline = Image.new("RGBA", (width, height), INK)
    image.paste(outline, (0, 0), stroke_mask)

    gradient = Image.new("RGBA", (width, height))
    pixels = gradient.load()
    for y in range(height):
        blend = y / max(height - 1, 1)
        color = tuple(int(TOP[i] + (BOTTOM[i] - TOP[i]) * blend) for i in range(3))
        for x in range(width):
            pixels[x, y] = (*color, fill_mask.getpixel((x, y)))
    image.paste(gradient, (0, 0), gradient)
    return trim_alpha(image, pad=2)


def hint_line(text, size):
    font = load_font(size)
    probe = ImageDraw.Draw(Image.new("L", (4, 4)))
    bbox = probe.textbbox((0, 0), text, font=font, stroke_width=2)
    pad = 4
    width = bbox[2] - bbox[0] + pad * 2
    height = bbox[3] - bbox[1] + pad * 2
    origin = (pad - bbox[0], pad - bbox[1])
    image = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    draw.text(origin, text, font=font, fill=HINT, stroke_width=2, stroke_fill=INK)
    return trim_alpha(image, pad=1)


def paste_center(canvas, sprite, y):
    x = (canvas.width - sprite.width) // 2
    canvas.paste(sprite, (x, y), sprite)
    return y + sprite.height


def black_canvas(width, height):
    return Image.new("RGBA", (width, height), (0, 0, 0, 255))


def save_rgb(image, path):
    image.convert("RGB").save(path, "PNG", optimize=True)


def build(logo_path, out_dir):
    out_dir = Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    logo = trim_alpha(Image.open(logo_path).convert("RGBA"), pad=0)
    logo.save(out_dir / "logo-trimmed.png")
    scale_width(logo, 256, nearest=True).save(out_dir / "icon-256.png")

    title = wordmark("AnanasOS", 160, stroke=8)
    title.save(out_dir / "wordmark.png")

    plymouth_logo = scale_width(logo, 420, nearest=True)
    plymouth_logo.save(out_dir / "plymouth-logo.png")
    wordmark("AnanasOS", 92, stroke=5).save(out_dir / "plymouth-wordmark.png")

    wall_logo = scale_width(logo, 430, nearest=True)
    wall_word = scale_width(title, 760)
    wallpaper = black_canvas(1920, 1080)
    stack = wall_logo.height + 28 + wall_word.height
    y = (wallpaper.height - stack) // 2
    y = paste_center(wallpaper, wall_logo, y) + 28
    paste_center(wallpaper, wall_word, y)
    save_rgb(wallpaper, out_dir / "wallpaper.png")

    login_logo = scale_width(logo, 300, nearest=True)
    login_word = scale_width(title, 560)
    login = black_canvas(1920, 1080)
    y = paste_center(login, login_logo, 48) + 18
    paste_center(login, login_word, y)
    save_rgb(login, out_dir / "login.png")

    live = login.copy()
    hint = hint_line("Sesja live    użytkownik: ananas    hasło: ananas", 34)
    paste_center(live, hint, 1080 - hint.height - 36)
    save_rgb(live, out_dir / "login-live.png")

    grub_logo = scale_width(logo, 220, nearest=True)
    grub_word = scale_width(title, 460)
    grub = black_canvas(1920, 1080)
    y = paste_center(grub, grub_logo, 28) + 12
    paste_center(grub, grub_word, y)
    save_rgb(grub, out_dir / "grub-background.png")

    welcome = Image.new("RGBA", (title.width, title.height), (0, 0, 0, 0))
    welcome.paste(title, (0, 0), title)
    welcome.save(out_dir / "welcome-wordmark.png")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--logo", required=True)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()
    build(args.logo, args.out)


if __name__ == "__main__":
    main()
