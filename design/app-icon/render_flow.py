#!/usr/bin/env python3
"""Renders the Flowriter app icon: a line of handwriting that settles into a straight line
of text, with the lit caret at its end.

Every element is flat. Depth comes from layering only: the page, the line above it, the
caret above that. Each layer drops a soft shadow on what is under it, and where the line
crosses itself the later stroke lies over the earlier one. The caret is the one light: it
warms the page and the end of the line. Light is summed in linear RGB and converted to
sRGB once, at the end.

Needs numpy and Pillow. Run from the repo root:

    python3 design/app-icon/render_flow.py            # previews in design/app-icon/out/
    python3 design/app-icon/render_flow.py --install  # also writes Resources/AppIcon.*
"""
import math
import pathlib
import subprocess
import sys
import tempfile

import numpy as np
from PIL import Image

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parent.parent
W = 1024
SS = 3  # supersampling: shapes are rasterised at W * SS and box-filtered down
N = W * SS

# The app's dark theme (Sources/FlowriterKit/Theme.swift): background, heading, accent.
# The line and the caret's face are these exact values. Only shadow and glow move off them.
NIGHT, BONE_BRIGHT, FLAME = "#181A1C", "#EEEAE0", "#ED954D"

# Geometry, in 1024 units. The mark is drawn on a 668 baseline, then placed: moved by SHIFT
# and scaled by FIT about the centre, so its ink sits centred with even margins.
FIT, SHIFT = 0.93, (22.0, 14.0)
DRAWN_BASELINE = 668.0


def place(x, y):
    return (x + SHIFT[0] - W / 2) * FIT + W / 2, (y + SHIFT[1] - W / 2) * FIT + W / 2


STROKE = 54.0 * FIT
BASELINE = place(0, DRAWN_BASELINE)[1]
CARET = dict(w=56.0 * FIT, h=250.0 * FIT, r=14.0 * FIT, gap=62.0 * FIT, border=5.5 * FIT)


def lin(h):
    a = np.array([int(h[i:i + 2], 16) for i in (1, 3, 5)], np.float32) / 255
    return np.where(a <= 0.04045, a / 12.92, ((a + 0.055) / 1.055) ** 2.4).astype(np.float32)


def to_srgb(a):
    a = np.clip(a, 0, 1)
    return np.where(a <= 0.0031308, 12.92 * a, 1.055 * a ** (1 / 2.4) - 0.055)


def blur(a, sigma):
    pad = int(3 * sigma) + 1
    ap = np.pad(a, ((pad, pad), (pad, pad)) + ((0, 0),) * (a.ndim - 2), mode="edge")
    h, w = ap.shape[:2]
    g = np.exp(-2 * np.pi ** 2 * sigma ** 2 * (np.fft.rfftfreq(w)[None, :] ** 2 + np.fft.fftfreq(h)[:, None] ** 2))
    if a.ndim == 2:
        out = np.fft.irfft2(np.fft.rfft2(ap) * g, s=(h, w))
    else:
        out = np.stack([np.fft.irfft2(np.fft.rfft2(ap[..., c]) * g, s=(h, w)) for c in range(a.shape[2])], -1)
    return out[pad:-pad, pad:-pad].astype(np.float32)


def down(a, k=SS):
    h, w = a.shape[:2]
    return a.reshape(h // k, k, w // k, k, *a.shape[2:]).mean((1, 3)).astype(np.float32)


def up(a, k=SS):
    return a.repeat(k, 0).repeat(k, 1)


def shift(a, dx, dy, fill=0):
    out = np.full_like(a, fill)
    h, w = a.shape[:2]
    ys, yd = (slice(0, h - dy), slice(dy, h)) if dy >= 0 else (slice(-dy, h), slice(0, h + dy))
    xs, xd = (slice(0, w - dx), slice(dx, w)) if dx >= 0 else (slice(-dx, w), slice(0, w + dx))
    out[yd, xd] = a[ys, xs]
    return out


def centreline():
    """Three loops, each calmer than the last, then the straight line. 1024 units."""
    x0, loops = 112.0, 3
    v, d0, a0 = 26.5, 104.0, 384.0
    end = loops * 2 * math.pi
    pts = []
    for k in range(1921):
        t = end * k / 1920
        fade = 1 - (t / end) ** 2.4
        y = DRAWN_BASELINE - a0 * fade * (1 - math.cos(t)) / 2
        ease = 64 * (t / end) ** 3  # the last hump runs out longer, so it meets the line in a soft curve
        pts.append((x0 + v * t + ease + d0 * fade * math.sin(t) + 0.22 * (DRAWN_BASELINE - y), y))
    line_end = 762.0
    last = pts[-1][0]
    pts += [(last + (line_end - last) * k / 24, DRAWN_BASELINE) for k in range(1, 25)]
    return np.array([place(x, y) for x, y in pts]), place(line_end, 0)[0]


def stroke(P):
    """Rasterise the line. Returns, per pixel, how far along the line it is (-1 off the line),
    and the places where the line crosses itself as (earlier, later) distances along it.
    Where two parts of the line overlap, the later part owns the pixel: it lies on top."""
    r = STROKE / 2 * SS
    A, seg = P[:-1], P[1:] - P[:-1]
    ln = np.hypot(seg[:, 0], seg[:, 1])
    s = np.concatenate([[0], np.cumsum(ln)])
    crossings = []
    for i in range(len(A) - 40):
        j = np.arange(i + 40, len(A))
        qp = A[j] - A[i]
        den = seg[i, 0] * seg[j, 1] - seg[i, 1] * seg[j, 0]
        with np.errstate(divide="ignore", invalid="ignore"):
            t = (qp[:, 0] * seg[j, 1] - qp[:, 1] * seg[j, 0]) / den
            u = (qp[:, 0] * seg[i, 1] - qp[:, 1] * seg[i, 0]) / den
        hit = (den != 0) & (t >= 0) & (t < 1) & (u >= 0) & (u < 1)
        crossings += [(s[i] + tt * ln[i], s[jj] + uu * ln[jj]) for jj, tt, uu in zip(j[hit], t[hit], u[hit])]

    along = np.full((N, N), -1.0, np.float32)
    for i in range(len(A)):
        if ln[i] == 0:
            continue
        (ax, ay), (bx, by), (dx, dy) = A[i], P[i + 1], seg[i]
        x0, x1 = max(0, int(min(ax, bx) - r - 2)), min(N, int(max(ax, bx) + r + 3))
        y0, y1 = max(0, int(min(ay, by) - r - 2)), min(N, int(max(ay, by) + r + 3))
        X = (np.arange(x0, x1, dtype=np.float32) + 0.5)[None, :]
        Y = (np.arange(y0, y1, dtype=np.float32) + 0.5)[:, None]
        u = np.clip(((X - ax) * dx + (Y - ay) * dy) / (ln[i] ** 2), 0, 1)
        d2 = (X - (ax + u * dx)) ** 2 + (Y - (ay + u * dy)) ** 2
        here = s[i] + u * ln[i]
        sub = (slice(y0, y1), slice(x0, x1))
        upd = (d2 < r * r) & (here > along[sub])
        along[sub][upd] = here[upd]
    return along, crossings


def caret_box(line_end):
    c = CARET
    return line_end + c["gap"], BASELINE + STROKE / 2 + 18 * FIT - c["h"], c["w"], c["h"]


def caret_alpha(box):
    x, y, w, h = (v * SS for v in box)
    rad = CARET["r"] * SS
    X = (np.arange(N, dtype=np.float32) + 0.5)[None, :]
    Y = (np.arange(N, dtype=np.float32) + 0.5)[:, None]
    qx, qy = np.abs(X - (x + w / 2)) - (w / 2 - rad), np.abs(Y - (y + h / 2)) - (h / 2 - rad)
    sdf = np.hypot(np.maximum(qx, 0), np.maximum(qy, 0)) + np.minimum(np.maximum(qx, qy), 0) - rad
    # coverage, and a border band: 1 at the edge, falling to 0 a border's width inside
    border = np.clip(1 + sdf / (CARET["border"] * SS), 0, 1) * (sdf < 0)
    return np.clip(0.5 - sdf, 0, 1).astype(np.float32), border.astype(np.float32)


def caret_distance(box, X, Y):
    """Distance from each point to the caret's centre axis."""
    x, y, w, h = box
    return np.hypot(X - (x + w / 2), Y - np.clip(Y, y + w / 2, y + h - w / 2))


def edges(mask, layer=None, gap=0.0):
    """Thin bands just inside a flat shape's upper and lower edges: where the light catches
    it and where it turns away. With `layer`, an edge also counts where a part of the shape
    lies over a part that is far behind it."""
    def band(dx, dy):
        beyond = shift(mask, dx, dy)
        edge = mask & ~beyond
        if layer is not None:
            edge |= mask & beyond & (layer - shift(layer, dx, dy, fill=-1) > gap)
        return edge.astype(np.float32)
    return band(2, 5), band(-2, -5)


def render():
    P, line_end = centreline()
    box = caret_box(line_end)
    along, crossings = stroke(P * SS)
    on_line = along >= 0
    c_alpha, c_border = caret_alpha(box)
    cov1, ca1 = down(on_line.astype(np.float32)), down(c_alpha)
    flame = lin(FLAME)

    x1 = (np.arange(W, dtype=np.float32) + 0.5)[None, :]
    y1 = (np.arange(W, dtype=np.float32) + 0.5)[:, None]
    X = (np.arange(N, dtype=np.float32) + 0.5)[None, :] / SS
    Y = (np.arange(N, dtype=np.float32) + 0.5)[:, None] / SS

    # --- layer 1, the page: lighter at the top, with the caret's light pooled on it
    pool = np.exp(-(((x1 - 0.40 * W) / (0.70 * W)) ** 2 + ((y1 - 0.12 * W) / (0.62 * W)) ** 2))
    ground = lin(NIGHT)[None, None, :] * (0.66 + 0.80 * pool)[..., None]
    d = caret_distance(box, x1, y1)
    glow = 0.046 * np.exp(-(d / 280) ** 2) + 0.15 * np.exp(-(d / 104) ** 2) + 0.20 * np.exp(-(d / 44) ** 2)
    ground += glow[..., None] * flame[None, None, :]
    # the line's shadow: a wide soft one and a close one, both straight down
    under_line = 0.50 * blur(shift(cov1, 0, 20), 16) + 0.40 * blur(shift(cov1, 0, 6), 4.5)
    under_caret = 0.34 * blur(shift(ca1, 0, 12), 10)
    ground *= (1 - np.clip(under_line + under_caret, 0, 0.9))[..., None]
    img = up(ground)

    # --- layer 2, the line: the app's own white, flat. Only its very end takes a little of the caret's warmth.
    reach = 0.15 / (1 + (caret_distance(box, X, Y) / 60) ** 2)
    fill = lin(BONE_BRIGHT)[None, None, :] * (1 + reach[..., None] * (flame * 1.55 - 0.42))
    shade = np.ones((N, N), np.float32)
    span = 4.2 * STROKE * SS
    for earlier, later in crossings:
        if later - earlier < 2 * span:  # a pinch in one stroke, not one stroke over another
            continue
        # the upper stroke near the crossing, fading out along its length so its shadow has no end
        over = np.clip(1.6 * (1 - np.abs(along - later) / span), 0, 1) * on_line
        cast = 0.55 * blur(shift(down(over), 0, 9), 7) + 0.45 * blur(shift(down(over), 0, 3), 2.5)
        under = on_line & (np.abs(along - earlier) < 1.5 * span)
        shade = np.where(under, shade * (1 - 0.46 * np.clip(up(cast), 0, 1)), shade)
    lit, turned = edges(on_line, along, gap=6 * STROKE * SS)
    fill = fill * shade[..., None] + 0.10 * lit[..., None]
    fill *= (1 - 0.10 * turned)[..., None]
    img = np.where(on_line[..., None], fill, img)

    # --- layer 3, the caret: the app's own orange, flat, with a light border in the app's
    # white so it holds the eye. The border is a little stronger at the top.
    bx, by, bw, bh = box
    rim = (c_border ** 1.2 * (0.72 - 0.20 * np.clip((Y - by) / bh, 0, 1)))[..., None] * np.ones_like(X)[..., None]
    body = flame[None, None, :] * (1 - rim) + lin(BONE_BRIGHT)[None, None, :] * rim
    a = c_alpha[..., None]

    # The caret's bloom falls on the page and the line. The caret itself goes on last, so
    # its face stays the exact theme colour.
    out = down(img)
    light = down(flame[None, None, :] * a)
    out += blur(light, 6) * 0.10 + blur(light, 26) * 0.20 + blur(light, 80) * 0.17
    peak = np.maximum(out.max(-1, keepdims=True), 1e-6)
    out = np.where(peak > 1, out / peak, out)
    return np.clip(out * (1 - ca1[..., None]) + down(body * a), 0, 1)


def to_image(linear, alpha=None, seed=7):
    rng = np.random.default_rng(seed)
    dither = (rng.random(linear.shape[:2]) - rng.random(linear.shape[:2]))[..., None] / 255
    rgb = np.clip(to_srgb(linear) + dither, 0, 1)
    if alpha is None:
        return Image.fromarray((rgb * 255 + 0.5).astype(np.uint8))
    return Image.fromarray((np.dstack([rgb, np.clip(alpha, 0, 1)]) * 255 + 0.5).astype(np.uint8))


def squircle(size, inset=0.0, n=5.0):
    """Coverage of the icon shape and the distance inside its edge, on a size x size canvas."""
    half = size / 2 - inset
    c = (np.arange(size, dtype=np.float32) + 0.5 - size / 2) / half
    f = (np.abs(c)[None, :] ** n + np.abs(c)[:, None] ** n) ** (1 / n)
    inside = (1 - f) * half
    return np.clip(inside + 0.5, 0, 1), inside


def framed(linear, inset=0):
    """The artwork in the icon shape with a lit rim, as the system would show it."""
    size = linear.shape[0]
    if inset:
        inner = size - 2 * inset
        scaled = np.stack([np.asarray(Image.fromarray(linear[..., c]).resize((inner, inner), Image.LANCZOS)) for c in range(3)], -1)
        linear = np.zeros_like(linear)
        linear[inset:inset + inner, inset:inset + inner] = scaled
    alpha, inside = squircle(size, inset)
    y = (np.arange(size, dtype=np.float32)[:, None] - inset) / (size - 2 * inset)
    edge = np.clip(1 - inside / (size * 0.0045), 0, 1) * alpha
    lit = linear + (edge * np.clip(1 - y / 0.36, 0, 1) * 0.30)[..., None]
    lit *= (1 - edge * np.clip((y - 0.62) / 0.38, 0, 1) * 0.45)[..., None]
    return lit, alpha


def with_shadow(linear, alpha):
    """A framed icon over transparency with the soft drop shadow of a macOS icon."""
    shadow = blur(shift(alpha, 0, 10), 10) * 0.30
    out_a = alpha + shadow * (1 - alpha)
    return linear * (alpha / np.maximum(out_a, 1e-6))[..., None], out_a


def main():
    out_dir = HERE / "out"
    out_dir.mkdir(exist_ok=True)
    art = render()
    to_image(art).save(out_dir / "flow-artwork.png")
    full, alpha = framed(art)
    icon = to_image(full, alpha)
    icon.save(out_dir / "flow-preview.png")

    ladder = Image.new("RGB", (1040, 300), (30, 31, 34))
    x = 24
    for s in (256, 128, 64, 32, 16):
        small = icon.resize((s, s), Image.LANCZOS)
        ladder.paste(small, (x, 280 - s), small)
        x += s + 28
    for s in (64, 32, 16):  # the same three magnified, to judge the small sizes
        small = icon.resize((s, s), Image.LANCZOS).resize((s * 3, s * 3), Image.NEAREST)
        ladder.paste(small, (x, 280 - s * 3), small)
        x += s * 3 + 28
    ladder.save(out_dir / "flow-sizes.png")
    for name, (x, y, w) in {"loops": (130, 250, 440), "caret": (560, 380, 440)}.items():
        icon.crop((x, y, x + w, y + w)).resize((880, 880), Image.LANCZOS).save(out_dir / f"flow-detail-{name}.png")

    if "--install" in sys.argv:
        to_image(art).save(ROOT / "Resources/AppIcon.icon/Assets/artwork.png")
        master = to_image(*with_shadow(*framed(art, inset=100)))
        with tempfile.TemporaryDirectory() as tmp:
            iconset = pathlib.Path(tmp) / "AppIcon.iconset"
            iconset.mkdir()
            for pt in (16, 32, 128, 256, 512):
                master.resize((pt, pt), Image.LANCZOS).save(iconset / f"icon_{pt}x{pt}.png")
                master.resize((pt * 2, pt * 2), Image.LANCZOS).save(iconset / f"icon_{pt}x{pt}@2x.png")
            subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(ROOT / "Resources/AppIcon.icns")], check=True)
        print("installed Resources/AppIcon.icon/Assets/artwork.png and Resources/AppIcon.icns")
    print("wrote", out_dir)


if __name__ == "__main__":
    main()
