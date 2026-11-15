"""Puts the screens from capture_test.dart into phone and laptop frames.

    .venv/bin/python tool/showcase/frame.py

Reads build/showcase/raw/*.png, writes one transparent PNG to build/showcase/
(copied in docs/showcase/).
"""

from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parents[2]
RAW = ROOT / "build/showcase/raw"
OUT = ROOT / "build/showcase"
FONT = str(ROOT / "assets/fonts/Inter-SemiBold.ttf")
SS = 4  # supersampling for smooth mask edges


def rounded_mask(size, radius, box=None):
    """An antialiased rounded-rectangle mask of `size` (optionally only `box`)."""
    w, h = size
    big = Image.new("L", (w * SS, h * SS), 0)
    x0, y0, x1, y1 = box or (0, 0, w, h)
    ImageDraw.Draw(big).rounded_rectangle(
        (x0 * SS, y0 * SS, x1 * SS - 1, y1 * SS - 1), radius * SS, fill=255
    )
    return big.resize(size, Image.LANCZOS)


def shadow(img, blur, offset, opacity=0.35):
    """`img` on a larger transparent canvas with a soft shadow under it."""
    pad = blur * 3
    w, h = img.size
    out = Image.new("RGBA", (w + 2 * pad, h + 2 * pad + offset), (0, 0, 0, 0))
    alpha = img.getchannel("A").point(lambda a: int(a * opacity))
    sh = Image.new("RGBA", img.size, (0, 0, 0, 255))
    sh.putalpha(alpha)
    layer = Image.new("RGBA", out.size, (0, 0, 0, 0))
    layer.paste(sh, (pad, pad + offset), sh)
    out = Image.alpha_composite(out, layer.filter(ImageFilter.GaussianBlur(blur)))
    out.alpha_composite(img, (pad, pad))
    return out


def phone(screen_path, dark):
    screen = Image.open(screen_path).convert("RGBA")
    sw, sh = screen.size  # 1179 x 2556 (393 x 852 pt at 3x)
    bezel, r_screen = 36, 105
    W, H = sw + 2 * bezel, sh + 2 * bezel
    body = Image.new("RGBA", (W, H), (0, 0, 0, 0))

    # A plain black slab with an even bezel: no particular brand.
    body.paste(Image.new("RGBA", (W, H), (16, 16, 18, 255)), (0, 0),
               rounded_mask((W, H), r_screen + bezel))
    rim = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    ImageDraw.Draw(rim).rounded_rectangle((1, 1, W - 2, H - 2), r_screen + bezel - 1,
                                          outline=(60, 62, 68, 255), width=3)
    body.alpha_composite(rim)

    # Status bar, punch-hole camera and gesture bar drawn on the screen.
    s = screen.copy()
    d = ImageDraw.Draw(s)
    fg = (240, 240, 242, 255) if dark else (28, 28, 30, 255)
    font = ImageFont.truetype(FONT, 42)
    cy = 66
    d.text((72, cy), "12:30", font=font, fill=fg, anchor="lm")
    x = sw - 250
    # Wi-Fi: a filled wedge; signal: a filled triangle; battery: a bar.
    d.pieslice((x, cy - 22, x + 60, cy + 38), 225, 315, fill=fg)
    x += 78
    d.polygon([(x, cy + 18), (x + 40, cy + 18), (x + 40, cy - 22)], fill=fg)
    x += 62
    d.rounded_rectangle((x, cy - 14, x + 62, cy + 14), 7, outline=fg, width=4)
    d.rounded_rectangle((x + 7, cy - 7, x + 46, cy + 7), 3, fill=fg)
    d.rounded_rectangle((x + 65, cy - 6, x + 71, cy + 6), 2, fill=fg)
    d.ellipse((sw / 2 - 22, cy - 22, sw / 2 + 22, cy + 22), fill=(6, 6, 8, 255))
    d.rounded_rectangle((sw / 2 - 150, sh - 30, sw / 2 + 150, sh - 18), 6, fill=fg)

    body.paste(s, (bezel, bezel), rounded_mask((sw, sh), r_screen))
    return body


def laptop(screen_path, dark):
    screen = Image.open(screen_path).convert("RGBA")
    sw, sh = screen.size  # 2880 x 1800
    side, top, bottom = 64, 70, 64
    LW, LH = sw + 2 * side, sh + top + bottom
    base_h, overhang = 92, 190
    W, H = LW + 2 * overhang, LH + base_h
    img = Image.new("RGBA", (W, H), (0, 0, 0, 0))

    # Lid: aluminium edge, black glass bezel, camera.
    metal = (120, 123, 130, 255) if dark else (176, 179, 186, 255)
    lid = Image.new("RGBA", (LW, LH), (0, 0, 0, 0))
    lid.paste(Image.new("RGBA", (LW, LH), metal), (0, 0), rounded_mask((LW, LH), 64))
    lid.paste(Image.new("RGBA", (LW, LH), (14, 14, 16, 255)), (0, 0),
              rounded_mask((LW, LH), 58, (8, 8, LW - 8, LH)))
    ImageDraw.Draw(lid).ellipse((LW / 2 - 11, top / 2 - 11, LW / 2 + 11, top / 2 + 11),
                                fill=(40, 42, 48, 255))
    lid.paste(screen, (side, top), rounded_mask((sw, sh), 14))
    img.alpha_composite(lid, (overhang, 0))

    # Base: a slab, lighter on top, with the opening notch.
    base = Image.new("RGBA", (W * SS, base_h * SS), (0, 0, 0, 0))
    bd = ImageDraw.Draw(base)
    light = (206, 208, 214, 255) if not dark else (150, 153, 160, 255)
    shade = (150, 153, 160, 255) if not dark else (96, 99, 106, 255)
    bd.rounded_rectangle((0, 0, W * SS, base_h * SS), 46 * SS, fill=shade)
    bd.rectangle((0, 0, W * SS, 30 * SS), fill=light)
    nw = 520
    bd.rounded_rectangle(((W / 2 - nw / 2) * SS, -20 * SS, (W / 2 + nw / 2) * SS, 22 * SS),
                         20 * SS, fill=shade)
    img.alpha_composite(base.resize((W, base_h), Image.LANCZOS), (0, LH))
    return img


def fit(img, height):
    return img.resize((round(img.width * height / img.height), height), Image.LANCZOS)


def main():
    """The website image: a light laptop on a run's field plots, a dark phone
    in front on the runs list."""
    OUT.mkdir(parents=True, exist_ok=True)
    lap = shadow(laptop(RAW / "desktop-fields-light.png", dark=False), 70, 50)
    ph = shadow(phone(RAW / "phone-runs-dark.png", dark=True), 60, 40)
    ph = fit(ph, round(lap.height * 0.86))
    W = lap.width + ph.width // 2
    hero = Image.new("RGBA", (W, lap.height + 40), (0, 0, 0, 0))
    hero.alpha_composite(lap, (0, 0))
    hero.alpha_composite(ph, (W - ph.width, hero.height - ph.height))
    path = OUT / "soliton-laptop-phone.png"
    fit(hero, 1600).save(path, optimize=True)
    print(path)


if __name__ == "__main__":
    main()
