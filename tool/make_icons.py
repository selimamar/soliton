"""Draw the Soliton "neural wave" logo and write every platform's app icon.

A wave threaded through the nodes of a small neural network: a network
learning a physical signal. Colours come from the light theme (slate
background, crimson nodes).

    source env.sh && uv run python tool/make_icons.py

Writes the iOS, macOS, Android (legacy and adaptive) and web icons in place,
plus a master SVG at assets/branding/neural_wave.svg. Icons of 64 px or less
use a bolder version without the network's edges, which vanish when small.
"""

import json
import math
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parent.parent

SLATE = (0x25, 0x2A, 0x31)
PAPER = (0xEC, 0xEE, 0xF0)
CRIMSON = (0xE4, 0x56, 0x6A)  # the site's #981B2B, lifted to read on slate
EDGE = tuple(round(0.6 * e + 0.4 * s) for e, s in zip((0x8A, 0x92, 0x9C), SLATE))

# Geometry in a unit box; the wave and the nodes share the same curve.
# Two periods of a sine, with a node on each crest and trough.
X0, X1, AMP = 0.04, 0.96, 0.2
PERIOD = (X1 - X0) / 2
NODES = [(X0 + PERIOD * k / 4, 0.5 - AMP if k % 4 == 1 else 0.5 + AMP) for k in (1, 3, 5, 7)]
EDGES = [(0, 2), (1, 3), (0, 3)]
STYLES = {
    "full": dict(wave=0.046, node=0.052, ring=0.016, edge=0.0125, edges=True),
    "small": dict(wave=0.075, node=0.075, ring=0.022, edge=0.0, edges=False),
}


def wave_y(x: float) -> float:
    return 0.5 - AMP * math.sin(2 * math.pi * (x - X0) / PERIOD)


def wave_points(n: int = 200) -> list[tuple[float, float]]:
    return [(X0 + (X1 - X0) * i / n, wave_y(X0 + (X1 - X0) * i / n)) for i in range(n + 1)]


def draw_mark(img, box, style, mono=None):
    """Draw the mark into `box` (x, y, size) of an RGBA image."""
    bx, by, bs = box
    st = STYLES[style]
    d = ImageDraw.Draw(img)
    p = lambda u, v: (bx + u * bs, by + v * bs)
    col = lambda c: mono or c
    if st["edges"]:
        for a, b in EDGES:
            d.line([p(*NODES[a]), p(*NODES[b])], fill=col(EDGE), width=round(st["edge"] * bs))
    # Stamp round dots densely along the curve: an even stroke with round
    # caps, which Pillow's polyline joins don't give.
    h = st["wave"] * bs / 2
    for u, v in wave_points(round(bs * 1.5)):
        x, y = p(u, v)
        d.ellipse([x - h, y - h, x + h, y + h], fill=col(PAPER))
    for u, v in NODES:
        x, y = p(u, v)
        r, ring = st["node"] * bs, st["ring"] * bs
        if mono is None:  # a ring in the background colour separates node and wave
            d.ellipse([x - r - ring, y - r - ring, x + r + ring, y + r + ring], fill=SLATE)
        d.ellipse([x - r, y - r, x + r, y + r], fill=col(CRIMSON))


def render(size, shape="square", scale=0.82, style=None, background=True, mono=None):
    """Render one icon.

    shape: "square" (full bleed, the OS masks it), "rounded" (rounded square
    filling the canvas) or "macos" (rounded square on the macOS icon grid
    with a soft shadow). scale: the mark's width as a fraction of the body.
    """
    style = style or ("small" if size <= 64 else "full")
    ss = max(4, 2048 // size)
    n = size * ss
    img = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    if shape == "macos":
        body = round(n * 824 / 1024)
        off = (n - body) // 2
        radius = body * 0.2237
        shadow = Image.new("RGBA", (n, n), (0, 0, 0, 0))
        ImageDraw.Draw(shadow).rounded_rectangle(
            [off, off + n * 0.012, off + body, off + body + n * 0.012], radius, fill=(0, 0, 0, 90)
        )
        img = Image.alpha_composite(img, shadow.filter(ImageFilter.GaussianBlur(n * 0.014)))
    else:
        body, off = n, 0
        radius = n * 0.225 if shape == "rounded" else 0
    if background:
        ImageDraw.Draw(img).rounded_rectangle([off, off, off + body - 1, off + body - 1], radius, fill=SLATE)
    ms = body * scale
    draw_mark(img, (off + (body - ms) / 2, off + (body - ms) / 2, ms), style, mono)
    return img.resize((size, size), Image.LANCZOS)


def save(img, path, opaque=False):
    path.parent.mkdir(parents=True, exist_ok=True)
    (img.convert("RGB") if opaque else img).save(path, optimize=True)
    print("wrote", path.relative_to(ROOT))


def appiconset(folder, **kw):
    contents = json.loads((folder / "Contents.json").read_text())
    for entry in contents["images"]:
        if "filename" not in entry:
            continue
        px = round(float(entry["size"].split("x")[0]) * int(entry["scale"].rstrip("x")))
        yield px, folder / entry["filename"]


def write_svg(path):
    st = STYLES["full"]
    s = 1024
    q = lambda u: f"{u * s:.1f}"
    edges = "".join(
        f'<line x1="{q(NODES[a][0])}" y1="{q(NODES[a][1])}" x2="{q(NODES[b][0])}" y2="{q(NODES[b][1])}"/>'
        for a, b in EDGES
    )
    wave = " L".join(f"{q(u)} {q(v)}" for u, v in wave_points(80))
    nodes = "".join(
        f'<circle cx="{q(u)}" cy="{q(v)}" r="{st["node"] * s:.1f}" stroke="#252A31" '
        f'stroke-width="{2 * st["ring"] * s:.1f}" paint-order="stroke"/>'
        for u, v in NODES
    )
    hexc = lambda c: "#%02X%02X%02X" % c
    svg = (
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {s} {s}">\n'
        f'<rect width="{s}" height="{s}" rx="{0.225 * s:.0f}" fill="#252A31"/>\n'
        f'<g transform="translate({s * 0.09:.1f} {s * 0.09:.1f}) scale(0.82)">\n'
        f'<g stroke="{hexc(EDGE)}" stroke-width="{st["edge"] * s:.1f}">{edges}</g>\n'
        f'<path d="M{wave}" fill="none" stroke="#ECEEF0" stroke-width="{st["wave"] * s:.1f}" '
        f'stroke-linecap="round" stroke-linejoin="round"/>\n'
        f'<g fill="{hexc(CRIMSON)}">{nodes}</g>\n</g>\n</svg>\n'
    )
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(svg)
    print("wrote", path.relative_to(ROOT))


def main():
    write_svg(ROOT / "assets/branding/neural_wave.svg")
    save(render(1024, "rounded"), ROOT / "assets/branding/neural_wave.png")
    # Beside the runs list title: 24 pt at up to 3x, in the bold small style.
    save(render(72, "rounded", style="small"), ROOT / "assets/branding/app_mark.png")

    # iOS masks the corners itself and rejects transparency.
    for px, path in appiconset(ROOT / "ios/Runner/Assets.xcassets/AppIcon.appiconset"):
        save(render(px), path, opaque=True)

    for px, path in appiconset(ROOT / "macos/Runner/Assets.xcassets/AppIcon.appiconset"):
        save(render(px, "macos", scale=0.78), path)

    res = ROOT / "android/app/src/main/res"
    for dpi, factor in {"mdpi": 1, "hdpi": 1.5, "xhdpi": 2, "xxhdpi": 3, "xxxhdpi": 4}.items():
        save(render(round(48 * factor), "rounded", scale=0.78), res / f"mipmap-{dpi}/ic_launcher.png")
        # Adaptive layers are 108 dp; the launcher shows the centre 72 dp
        # and may crop to a 66 dp circle.
        fg = round(108 * factor)
        save(render(fg, scale=0.56, style="full", background=False), res / f"mipmap-{dpi}/ic_launcher_foreground.png")
        save(
            render(fg, scale=0.56, style="small", background=False, mono=(255, 255, 255)),
            res / f"mipmap-{dpi}/ic_launcher_monochrome.png",
        )

    web = ROOT / "web"
    save(render(32, "rounded"), web / "favicon.png")
    save(render(192, "rounded"), web / "icons/Icon-192.png")
    save(render(512, "rounded"), web / "icons/Icon-512.png")
    # Maskable icons may be cropped to the central 80% circle.
    save(render(192, scale=0.64), web / "icons/Icon-maskable-192.png", opaque=True)
    save(render(512, scale=0.64), web / "icons/Icon-maskable-512.png", opaque=True)


if __name__ == "__main__":
    main()
