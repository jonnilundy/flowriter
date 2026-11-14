#!/usr/bin/env python3
"""App icon concepts. Writes one 1024 SVG per concept to svg/ and a review sheet to
review.html. Needs fonttools (pip install fonttools). Run from the repo root:

    python3 design/app-icon/generate.py

Each SVG draws the icon shape and a lit rim itself, so it can be judged as it would sit in
a Dock. For a shipping .icon the system draws both: export the layers without them.
"""
import base64
import math
import pathlib
import subprocess
import tempfile

from fontTools.pens.boundsPen import BoundsPen
from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.transformPen import TransformPen
from fontTools.ttLib import TTFont

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parent.parent
S = 1024

# The app's own colours (Sources/FlowriterKit/Theme.swift). The icon adds no new hue.
NIGHT = "#181A1C"
BONE = "#D8D0C2"
BONE_BRIGHT = "#EEEAE0"
DUST = "#ABA398"
MARK = "#787166"
FLAME = "#ED954D"
LANTERN = "#EDCA70"
PAPER = "#F4F1EA"
INK = "#302A24"
INK_DEEP = "#1D1915"
EMBER = "#A35026"


# ---- colour: every blend and ramp is computed in OKLab, so a warm colour laid over the
# cool page keeps its chroma through the middle of the ramp (an sRGB blend goes grey there).

def _lin(c):
    c /= 255
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def _gam(c):
    c = min(1, max(0, c))
    return round(255 * (12.92 * c if c <= 0.0031308 else 1.055 * c ** (1 / 2.4) - 0.055))


def rgb(h):
    h = h.lstrip("#")
    return [int(h[i:i + 2], 16) for i in (0, 2, 4)]


def oklab(h):
    r, g, b = (_lin(c) for c in rgb(h))
    l = (0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b) ** (1 / 3)
    m = (0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b) ** (1 / 3)
    s = (0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b) ** (1 / 3)
    return (0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
            1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
            0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)


def from_oklab(L, a, b):
    l = (L + 0.3963377774 * a + 0.2158037573 * b) ** 3
    m = (L - 0.1055613458 * a - 0.0638541728 * b) ** 3
    s = (L - 0.0894841775 * a - 1.2914855480 * b) ** 3
    return "#%02X%02X%02X" % (
        _gam(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
        _gam(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
        _gam(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s))


def mix(a, b, t):
    A, B = oklab(a), oklab(b)
    return from_oklab(*(x + (y - x) * t for x, y in zip(A, B)))


def lch(h):
    L, a, b = oklab(h)
    return L, math.hypot(a, b), math.degrees(math.atan2(b, a)) % 360


def contrast(a, b):
    def lum(h):
        r, g, bl = (_lin(c) for c in rgb(h))
        return 0.2126 * r + 0.7152 * g + 0.0722 * bl
    hi, lo = sorted((lum(a), lum(b)), reverse=True)
    return (hi + 0.05) / (lo + 0.05)


def grad(id_, x1, y1, x2, y2, pts, sub=4):
    """A linear gradient through (offset, colour) points, with OKLab steps between them."""
    out = []
    for (o1, c1), (o2, c2) in zip(pts, pts[1:]):
        out += [(o1 + (o2 - o1) * i / sub, mix(c1, c2, i / sub)) for i in range(sub)]
    out.append(pts[-1])
    return (f'<linearGradient id="{id_}" gradientUnits="userSpaceOnUse" x1="{x1}" y1="{y1}" x2="{x2}" y2="{y2}">'
            + "".join(f'<stop offset="{o:.4f}" stop-color="{c}"/>' for o, c in out) + "</linearGradient>")


def vgrad(id_, y1, y2, *colors):
    return grad(id_, 0, y1, 0, y2, [(i / (len(colors) - 1), c) for i, c in enumerate(colors)])


def candlelight(id_, cx, cy, wide=0.19, tight=0.17, r=780):
    """The dark page lit from one point: a tight halo inside a wide one."""
    def at(t):
        base = mix("#1E2023", "#15171A", t)
        glow = wide * math.exp(-(t / 0.50) ** 2) + tight * math.exp(-(t / 0.17) ** 2)
        return mix(base, FLAME, glow)
    return (f'<radialGradient id="{id_}" gradientUnits="userSpaceOnUse" cx="{cx}" cy="{cy}" r="{r}">'
            + "".join(f'<stop offset="{i / 16:.4f}" stop-color="{at(i / 16)}"/>' for i in range(17))
            + "</radialGradient>")


FLAME_HOT = mix(LANTERN, "#FFFFFF", 0.25)
FLAME_TOP = mix(FLAME, LANTERN, 0.55)
FLAME_LOW = mix(FLAME, EMBER, 0.30)
FLAME_SIDE = mix(EMBER, INK_DEEP, 0.30)
BONE_SIDE = mix(DUST, NIGHT, 0.45)
FOCUS_FADE = 0.30


def flame_face(id_, y1, y2):
    return grad(id_, 0, y1, 0, y2, [(0, FLAME_HOT), (0.22, FLAME_TOP), (0.6, FLAME), (1, FLAME_LOW)])


# ---- shapes

def squircle(size=S, n=5.0, steps=200):
    h = size / 2
    pts = []
    for i in range(steps):
        a = 2 * math.pi * i / steps
        c, s = math.cos(a), math.sin(a)
        pts.append((h + h * math.copysign(abs(c) ** (2 / n), c), h + h * math.copysign(abs(s) ** (2 / n), s)))
    return "M" + " L".join(f"{x:.2f} {y:.2f}" for x, y in pts) + "Z"


SQ = squircle()


def rect(x, y, w, h, rx):
    return f'<rect x="{x:.1f}" y="{y:.1f}" width="{w:.1f}" height="{h:.1f}" rx="{rx:.1f}"/>'


_fonts = {}


def glyph(char, weight, em, cx, cy):
    """A Paper Mono glyph as a path in canvas pixels, its ink box centred on (cx, cy)."""
    if weight not in _fonts:
        _fonts[weight] = TTFont(ROOT / f"Resources/Fonts/PaperMono-{weight}.ttf")
    font = _fonts[weight]
    gs = font.getGlyphSet()
    name = font.getBestCmap()[ord(char)]
    bounds = BoundsPen(gs)
    gs[name].draw(bounds)
    s = em / font["head"].unitsPerEm
    x0, y0, x1, y1 = bounds.bounds
    pen = SVGPathPen(gs)
    gs[name].draw(TransformPen(pen, (s, 0, 0, -s, cx - (x0 + x1) / 2 * s, cy + (y0 + y1) / 2 * s)))
    return f'<path d="{pen.getCommands()}"/>', (x1 - x0) * s, (y1 - y0) * s


def glyph_and_caret(char, weight, em, cx, cy, gap, caret_w, tall=1.24):
    """A glyph and the caret after it, the pair centred on (cx, cy)."""
    _, w, h = glyph(char, weight, em, 0, 0)
    total = w + gap + caret_w
    path, _, _ = glyph(char, weight, em, cx - total / 2 + w / 2, cy)
    ch = h * tall
    return path, rect(cx + total / 2 - caret_w, cy - ch / 2, caret_w, ch, caret_w * 0.22), (cy - ch / 2, cy + ch / 2)


# ---- depth: one light from above. A raised shape gets a side wall, a lit top edge and a
# cast shadow. A lit shape also throws a bloom onto the ground.

class Icon:
    def __init__(self, p, light=False, wash=None):
        self.p, self.light, self.defs, self.body, self.n = p, light, [], [], 0
        self.wash = wash or ((0.55, 0.05) if light else (0.07, 0.20))

    def ground(self, fill_def, fill_id):
        self.defs.append(fill_def)
        self.body.append(f'<rect width="{S}" height="{S}" fill="url(#{fill_id})"/>')
        a, b = self.wash
        self.defs.append(
            f'<linearGradient id="{self.p}lit" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#fff" stop-opacity="{a}"/>'
            f'<stop offset="0.5" stop-color="#fff" stop-opacity="0"/><stop offset="0.5" stop-color="#000" stop-opacity="0"/>'
            f'<stop offset="1" stop-color="#000" stop-opacity="{b}"/></linearGradient>')
        self.body.append(f'<rect width="{S}" height="{S}" fill="url(#{self.p}lit)"/>')

    def define(self, el):
        self.n += 1
        sid = f"{self.p}s{self.n}"
        self.defs.append(el.replace(" ", f' id="{sid}" ', 1))
        self.defs.append(f'<clipPath id="{sid}c"><use href="#{sid}"/></clipPath>')
        return sid

    def add(self, markup):
        self.body.append(markup)

    def blur(self, n):
        return f"url(#{self.p}b{n})"

    def solid(self, el, top, side, depth=12, shadow=0.5, shadow_color="#000", glow=None, glow_opacity=0.7, edge=0.45):
        sid = self.define(el)
        if glow:
            self.add(f'<use href="#{sid}" fill="{glow}" opacity="{glow_opacity}" filter="{self.blur(44)}"/>')
        if shadow:
            self.add(f'<use href="#{sid}" fill="{shadow_color}" opacity="{shadow}" filter="{self.blur(18)}" transform="translate(0 {depth + 22})"/>')
        for i in range(depth, 0, -1):
            self.add(f'<use href="#{sid}" fill="{side}" transform="translate(0 {i})"/>')
        self.add(f'<use href="#{sid}" fill="{top}"/>')
        self.add(f'<g clip-path="url(#{sid}c)"><use href="#{sid}" fill="none" stroke="#fff" stroke-opacity="{edge}" '
                 f'stroke-width="8" transform="translate(0 4)"/></g>')
        return sid

    def sunk(self, el, fill, deep=1.0):
        """Cut into the surface: a shadow under the top lip, a lit lip below."""
        sid = self.define(el)
        self.add(f'<use href="#{sid}" fill="#fff" opacity="0.45" transform="translate(0 {5 * deep:.1f})"/>')
        self.add(f'<use href="#{sid}" fill="{fill}"/>')
        self.add(f'<g clip-path="url(#{sid}c)"><use href="#{sid}" fill="none" stroke="#000" stroke-opacity="{0.7 * deep:.2f}" '
                 f'stroke-width="{24 * deep:.0f}" filter="{self.blur(6)}" transform="translate(0 {11 * deep:.1f})"/></g>')

    def svg(self):
        blurs = "".join(
            f'<filter id="{self.p}b{n}" filterUnits="userSpaceOnUse" x="-200" y="-200" width="1424" height="1424">'
            f'<feGaussianBlur stdDeviation="{n}"/></filter>' for n in (6, 18, 44))
        top, bottom = (0.95, 0.14) if self.light else (0.36, 0.40)
        rim = (f'<linearGradient id="{self.p}rim" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#fff" stop-opacity="{top}"/>'
               f'<stop offset="0.32" stop-color="#fff" stop-opacity="0.05"/><stop offset="0.68" stop-color="#000" stop-opacity="0"/>'
               f'<stop offset="1" stop-color="#000" stop-opacity="{bottom}"/></linearGradient>')
        return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {S} {S}" width="{S}" height="{S}">'
                f'<defs><clipPath id="{self.p}sq"><path d="{SQ}"/></clipPath>{blurs}{rim}{"".join(self.defs)}</defs>'
                f'<g clip-path="url(#{self.p}sq)">{"".join(self.body)}'
                f'<path d="{SQ}" fill="none" stroke="url(#{self.p}rim)" stroke-width="12"/></g></svg>\n')


def night(icon, glow_at=None, wide=0.19, tight=0.17):
    p = icon.p
    if glow_at:
        icon.ground(candlelight(p + "g", *glow_at, wide=wide, tight=tight), p + "g")
    else:
        icon.ground(vgrad(p + "g", 0, S, "#1F2124", "#141618"), p + "g")


def paper(icon):
    icon.ground(vgrad(icon.p + "g", 0, S, "#F8F5EF", "#EBE6DC"), icon.p + "g")


# ---- the concepts

ROD = (468, 262, 88, 480, 22)


def caret_night(p):
    i = Icon(p)
    night(i, (512, 502))
    x, y, w, h, rx = ROD
    i.defs.append(flame_face(p + "f", y, y + h))
    i.solid(rect(*ROD), f"url(#{p}f)", FLAME_SIDE, depth=14, shadow=0.45, glow=FLAME, glow_opacity=0.8, edge=0.6)
    i.add(f'<rect x="{x + 16}" y="{y + 30}" width="13" height="{h * 0.5:.0f}" rx="6.5" fill="#fff" opacity="0.30" filter="{i.blur(6)}"/>')
    return i.svg()


def caret_paper(p):
    i = Icon(p, light=True)
    paper(i)
    x, y, w, h, rx = ROD
    i.defs.append(vgrad(p + "f", y, y + h, mix(EMBER, FLAME, 0.45), EMBER, mix(EMBER, INK_DEEP, 0.22)))
    i.solid(rect(*ROD), f"url(#{p}f)", mix(EMBER, INK_DEEP, 0.55), depth=14, shadow=0.34, shadow_color="#4A2410", edge=0.4)
    i.add(f'<rect x="{x + 16}" y="{y + 30}" width="13" height="{h * 0.5:.0f}" rx="6.5" fill="#fff" opacity="0.22" filter="{i.blur(6)}"/>')
    return i.svg()


def caret_ember(p):
    i = Icon(p, light=True, wash=(0.16, 0.10))
    i.ground(vgrad(p + "g", 0, S, mix(FLAME, LANTERN, 0.40), FLAME, mix(FLAME, EMBER, 0.34)), p + "g")
    x, y, w, h, rx = ROD
    i.defs.append(vgrad(p + "f", y, y + h, INK_DEEP, mix(INK_DEEP, INK, 0.8)))
    i.sunk(rect(*ROD), f"url(#{p}f)")
    return i.svg()


def focus_line(p):
    i = Icon(p)
    x, h = 204, 80
    caret = (x + 362 + 42, 398, 50, 228, 11)
    night(i, (caret[0] + 25, 512), wide=0.10, tight=0.12)
    faded = [mix(NIGHT, BONE, FOCUS_FADE + 0.06), mix(NIGHT, BONE, FOCUS_FADE - 0.04)]
    i.defs += [vgrad(p + "d1", 246, 326, *faded), vgrad(p + "d2", 698, 778, *faded),
               vgrad(p + "b", 472, 552, "#F7F4EC", BONE), flame_face(p + "f", caret[1], caret[1] + caret[3])]
    i.solid(rect(x, 286 - h / 2, 470, h, 16), f"url(#{p}d1)", mix(NIGHT, BONE, 0.10), depth=9, shadow=0.45, edge=0.16)
    i.solid(rect(x, 738 - h / 2, 596, h, 16), f"url(#{p}d2)", mix(NIGHT, BONE, 0.10), depth=9, shadow=0.45, edge=0.16)
    i.solid(rect(x, 512 - h / 2, 362, h, 16), f"url(#{p}b)", BONE_SIDE, depth=12, shadow=0.55, edge=0.8)
    i.solid(rect(*caret), f"url(#{p}f)", FLAME_SIDE, depth=12, shadow=0.4, glow=FLAME, glow_opacity=0.75, edge=0.6)
    return i.svg()


def heading_sheet(p):
    i = Icon(p)
    night(i)
    sx, sy, sw, sh = 214, 176, 596, 660
    i.defs.append(vgrad(p + "s", sy, sy + sh, "#FBF9F4", PAPER, "#E9E4DA"))
    i.solid(rect(sx, sy, sw, sh, 64), f"url(#{p}s)", "#B9B1A2", depth=14, shadow=0.7, edge=0.95)
    path, caret, (y1, y2) = glyph_and_caret("#", "SemiBold", 500, 512, sy + sh / 2, 46, 42)
    i.defs.append(vgrad(p + "h", y1, y2, mix(EMBER, FLAME, 0.25), EMBER, mix(EMBER, INK_DEEP, 0.15)))
    i.sunk(path, f"url(#{p}h)", deep=0.45)
    i.defs.append(vgrad(p + "c", y1, y2, INK, INK_DEEP))
    i.solid(caret, f"url(#{p}c)", "#0E0C0A", depth=6, shadow=0.35, shadow_color="#2A2018", edge=0.25)
    return i.svg()


def heading_night(p):
    i = Icon(p)
    path, caret, (y1, y2) = glyph_and_caret("#", "SemiBold", 660, 512, 506, 62, 56)
    night(i, (440, 506), wide=0.13, tight=0.05)
    i.defs += [flame_face(p + "h", y1 + 40, y2 - 20), vgrad(p + "c", y1, y2, "#F8F5EE", BONE)]
    i.solid(path, f"url(#{p}h)", FLAME_SIDE, depth=18, shadow=0.55, glow=FLAME, glow_opacity=0.38, edge=0.55)
    i.solid(caret, f"url(#{p}c)", BONE_SIDE, depth=18, shadow=0.55, edge=0.9)
    return i.svg()


def candle(p):
    i = Icon(p)
    cx, hw, ry, top, bot = 512, 62, 17, 508, 832
    tip, r = 204, 68
    fy = 398
    night(i, (cx, fy), wide=0.24, tight=0.24)
    flame = (f'<path d="M{cx} {tip} C{cx + 20} {tip + 66} {cx + r} {fy - 82} {cx + r} {fy} '
             f'A{r} {r} 0 0 1 {cx - r} {fy} C{cx - r} {fy - 82} {cx - 20} {tip + 66} {cx} {tip} Z"/>')
    body = f"M{cx - hw} {top} L{cx - hw} {bot} A{hw} {ry} 0 0 0 {cx + hw} {bot} L{cx + hw} {top} Z"
    i.defs += [
        grad(p + "w", cx - hw, 0, cx + hw, 0, [(0, "#A39B8F"), (0.30, "#F6F2E9"), (0.62, BONE), (1, "#7C756A")]),
        f'<linearGradient id="{p}wd" gradientUnits="userSpaceOnUse" x1="0" y1="{top}" x2="0" y2="{bot + ry}">'
        f'<stop offset="0" stop-color="{FLAME}" stop-opacity="0.30"/><stop offset="0.22" stop-color="{FLAME}" stop-opacity="0"/>'
        f'<stop offset="0.3" stop-color="#101214" stop-opacity="0"/><stop offset="1" stop-color="#101214" stop-opacity="0.72"/></linearGradient>',
        f'<radialGradient id="{p}f" gradientUnits="userSpaceOnUse" cx="{cx}" cy="{fy + 18}" r="190">'
        + "".join(f'<stop offset="{o}" stop-color="{c}"/>' for o, c in
                  [(0, mix(LANTERN, "#FFFFFF", 0.7)), (0.2, mix(LANTERN, "#FFFFFF", 0.35)), (0.42, LANTERN),
                   (0.7, mix(LANTERN, FLAME, 0.6)), (1, FLAME)])
        + "</radialGradient>",
    ]
    i.add(f'<ellipse cx="{cx}" cy="{bot + 20}" rx="170" ry="26" fill="#000" opacity="0.55" filter="{i.blur(18)}"/>')
    i.add(f'<path d="{body}" fill="url(#{p}w)"/><path d="{body}" fill="url(#{p}wd)"/>')
    i.add(f'<ellipse cx="{cx}" cy="{top}" rx="{hw}" ry="{ry}" fill="#FBF7EC"/>'
          f'<ellipse cx="{cx}" cy="{top + 1}" rx="{hw - 16}" ry="{ry - 6}" fill="{mix(LANTERN, BONE_BRIGHT, 0.45)}"/>')
    i.add(f'<rect x="{cx - 4}" y="{top - 36}" width="8" height="38" rx="4" fill="{INK_DEEP}"/>')
    fid = i.define(flame)
    i.add(f'<use href="#{fid}" fill="{FLAME}" opacity="0.85" filter="{i.blur(44)}"/>'
          f'<use href="#{fid}" fill="{LANTERN}" opacity="0.55" filter="{i.blur(18)}"/>'
          f'<use href="#{fid}" fill="url(#{p}f)"/>')
    return i.svg()


def flow(p):
    # Handwriting loops that settle into a straight line of text, with the caret at its end.
    i = Icon(p)
    base, x0, loops = 676, 150, 3
    v, d0, a0 = 24.0, 76.0, 370.0
    end = loops * 2 * math.pi
    pts = []
    for k in range(421):
        t = end * k / 420
        fade = 1 - (t / end) ** 2.4
        y = base - a0 * fade * (1 - math.cos(t)) / 2
        pts.append((x0 + v * t + d0 * fade * math.sin(t) + 0.22 * (base - y), y))
    line_end = 762
    d = "M" + " L".join(f"{x:.1f} {y:.1f}" for x, y in pts) + f" L{line_end} {base}"
    caret = (line_end + 58, base - 190, 52, 232, 11)
    night(i, (caret[0] + 26, base - 74), wide=0.10, tight=0.12)
    stroke = 'fill="none" stroke-linecap="round" stroke-linejoin="round"'
    i.defs += [f'<path id="{p}l" d="{d}" stroke-width="44"/>', vgrad(p + "lf", base - a0, base + 22, "#F8F5EE", BONE),
               flame_face(p + "f", caret[1], caret[1] + caret[3])]
    i.add(f'<use href="#{p}l" {stroke} stroke="#000" opacity="0.5" filter="{i.blur(18)}" transform="translate(0 30)"/>')
    for k in range(12, 0, -1):
        i.add(f'<use href="#{p}l" {stroke} stroke="{BONE_SIDE}" transform="translate(0 {k})"/>')
    i.add(f'<use href="#{p}l" {stroke} stroke="url(#{p}lf)"/>')
    i.add(f'<path d="{d}" {stroke} stroke="#fff" stroke-opacity="0.55" stroke-width="9" transform="translate(0 -13)" filter="{i.blur(6)}"/>')
    i.solid(rect(*caret), f"url(#{p}f)", FLAME_SIDE, depth=12, shadow=0.4, glow=FLAME, glow_opacity=0.75, edge=0.6)
    return i.svg()


def monogram(p):
    i = Icon(p)
    path, caret, (y1, y2) = glyph_and_caret("f", "SemiBold", 700, 512, 506, 66, 58)
    night(i, (622, 506), wide=0.13, tight=0.12)
    i.defs += [vgrad(p + "l", y1, y2, "#F8F5EE", BONE), flame_face(p + "f", y1, y2)]
    i.solid(path, f"url(#{p}l)", BONE_SIDE, depth=18, shadow=0.55, edge=0.9)
    i.solid(caret, f"url(#{p}f)", FLAME_SIDE, depth=18, shadow=0.45, glow=FLAME, glow_opacity=0.75, edge=0.6)
    return i.svg()


CONCEPTS = [
    # key, draw, number, name, ground, note, colour pairs to report
    ("caret-night", caret_night, "1", "Candle caret", "Night",
     "One caret, lit like a candle. It stands off the page and throws its own light. "
     "This is the app with nothing typed yet.",
     [("Caret on page", FLAME, NIGHT)]),
    ("caret-paper", caret_paper, "1", "Candle caret", "Paper",
     "The same bar on the light page. The caret takes the light theme's ember and casts a warm shadow.",
     [("Caret on page", EMBER, PAPER)]),
    ("caret-ember", caret_ember, "1", "Candle caret", "Ember",
     "The colours change places. The flame is the ground and the caret is cut into it in ink. "
     "The loudest of the set in a Dock.",
     [("Caret on ground", INK_DEEP, FLAME)]),
    ("focus-line", focus_line, "2", "Focus line", "Night",
     "Three raised lines of text. The line you are on is bright and has the lit caret. "
     "The lines above and below fall back into the page.",
     [("Bright line", BONE_BRIGHT, NIGHT), ("Faded line", mix(NIGHT, BONE, FOCUS_FADE), NIGHT), ("Caret", FLAME, NIGHT)]),
    ("heading-sheet", heading_sheet, "3", "First heading", "Paper on night",
     "A sheet of the light page lifted off the dark one, so both themes are in the icon. "
     "On it, a Markdown hash pressed into the paper and the caret after it.",
     [("Hash on sheet", EMBER, PAPER), ("Caret on sheet", INK_DEEP, PAPER), ("Sheet on ground", PAPER, NIGHT)]),
    ("heading-night", heading_night, "3", "First heading", "Night",
     "The hash alone, cast in flame with a bone caret. The moment before the title. "
     "It says literal Markdown without a word.",
     [("Hash on page", FLAME, NIGHT), ("Caret on page", BONE_BRIGHT, NIGHT)]),
    ("candle", candle, "4", "Candle", "Night",
     "The caret becomes the candle. A wax column, a flame and the warm light it throws. "
     "The most pictorial of the set and the closest to the palette's name.",
     [("Flame on page", FLAME, NIGHT), ("Candle on page", BONE_BRIGHT, NIGHT)]),
    ("flow", flow, "5", "Flow", "Night",
     "Handwriting loops that settle into one straight line of text, with the lit caret at the end. "
     "The only concept that draws the name.",
     [("Line on page", BONE_BRIGHT, NIGHT), ("Caret on page", FLAME, NIGHT)]),
    ("monogram", monogram, "6", "Monogram", "Night",
     "A Paper Mono f and a lit caret. It reads like a terminal prompt, in the spirit of "
     "Sublime Text and Ghostty.",
     [("Letter on page", BONE_BRIGHT, NIGHT), ("Caret on page", FLAME, NIGHT)]),
]

PALETTE = [
    ("Night", NIGHT, "the dark page"), ("Bone", BONE_BRIGHT, "headings"), ("Dust", DUST, "quiet text"),
    ("Flame", FLAME, "the caret, dark theme"), ("Lantern", LANTERN, "italic, dark theme"),
    ("Paper", PAPER, "the light page"), ("Ink", INK_DEEP, "headings, light theme"), ("Ember", EMBER, "the caret, light theme"),
]


def data_uri(mime, data):
    return f"data:{mime};base64," + base64.b64encode(data).decode()


def current_icon():
    with tempfile.TemporaryDirectory() as tmp:
        out = pathlib.Path(tmp) / "current.png"
        subprocess.run(["sips", "-Z", "384", str(ROOT / "Resources/AppIcon.icon/Assets/artwork.png"), "--out", str(out)],
                       check=True, capture_output=True)
        return data_uri("image/png", out.read_bytes())


def main():
    (HERE / "svg").mkdir(exist_ok=True)
    css_icons = []
    for n, (key, draw, *_rest) in enumerate(CONCEPTS):
        svg = draw(f"c{n}")
        (HERE / "svg" / f"{key}.svg").write_text(svg)
        css_icons.append(f'.i-{key}{{background-image:url("{data_uri("image/svg+xml", svg.encode())}")}}')
    mask = data_uri("image/svg+xml",
                    f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {S} {S}"><path d="{SQ}"/></svg>'.encode())
    css_icons.append(f'.i-current{{background-image:url("{current_icon()}");-webkit-mask:url("{mask}") center/100% 100%;mask:url("{mask}") center/100% 100%}}')
    font = data_uri("font/ttf", (ROOT / "Resources/Fonts/PaperMono-Regular.ttf").read_bytes())
    font_bold = data_uri("font/ttf", (ROOT / "Resources/Fonts/PaperMono-SemiBold.ttf").read_bytes())

    def icon(key, size):
        return f'<span class="shadow"><span class="icon i-{key}" style="width:{size}px;height:{size}px"></span></span>'

    cards = []
    for key, _draw, group, name, ground, note, pairs in CONCEPTS:
        rows = "".join(
            f'<li><span class="sw" style="background:{bg}"><span style="background:{fg}"></span></span>'
            f'<span>{label}</span><code>{fg}</code><b>{contrast(fg, bg):.1f}:1</b></li>'
            for label, fg, bg in pairs)
        ladder = "".join(f'<div>{icon(key, s)}<small>{s}</small></div>' for s in (128, 64, 32, 16))
        cards.append(f'''<article id="{key}">
<header><span class="num">{group}</span><h2>{name}</h2><span class="ground">{ground}</span></header>
<div class="stage">{icon(key, 256)}<div class="ladder">{ladder}</div></div>
<p>{note}</p><ul class="pairs">{rows}</ul><footer><code>svg/{key}.svg</code></footer></article>''')

    dock_keys = ["current"] + [c[0] for c in CONCEPTS]
    docks = "".join(
        f'<div class="dock {cls}"><div class="shelf">' + "".join(icon(k, 64) for k in dock_keys) + "</div></div>"
        for cls in ("dark", "dusk", "light"))

    swatches = "".join(
        f'<li><span style="background:{h}"></span><b>{n}</b><code>{h}</code>'
        f'<small>L {lch(h)[0]:.2f} · C {lch(h)[1]:.3f} · h {lch(h)[2]:.0f}°</small><small>{use}</small></li>'
        for n, h, use in PALETTE)

    html = f'''<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Flowriter icon concepts</title>
<style>
@font-face{{font-family:"Paper Mono";font-weight:400;src:url("{font}")}}
@font-face{{font-family:"Paper Mono";font-weight:600;src:url("{font_bold}")}}
:root{{--bg:#F4F1EA;--card:#FBF9F4;--text:#302A24;--head:#1D1915;--quiet:#6D6359;--mark:#978D7F;--line:rgba(48,42,36,.10);--accent:#A35026}}
@media (prefers-color-scheme:dark){{:root{{--bg:#181A1C;--card:#1E2023;--text:#D8D0C2;--head:#EEEAE0;--quiet:#ABA398;--mark:#787166;--line:rgba(216,208,194,.09);--accent:#ED954D}}}}
*{{box-sizing:border-box}}
body{{margin:0;background:var(--bg);color:var(--text);font:14px/1.75 "Paper Mono",ui-monospace,Menlo,monospace}}
main{{max-width:1180px;margin:0 auto;padding:56px 24px 96px}}
h1{{font-size:14px;font-weight:600;color:var(--head);margin:0}}
h1 i{{font-style:normal;color:var(--accent)}}
.lede{{max-width:66ch;color:var(--quiet);margin:8px 0 40px}}
h3{{font-size:14px;font-weight:600;color:var(--head);margin:56px 0 16px}}
h3 i{{font-style:normal;color:var(--accent)}}
.grid{{display:grid;grid-template-columns:repeat(auto-fill,minmax(340px,1fr));gap:20px}}
article{{background:var(--card);border:1px solid var(--line);border-radius:14px;padding:22px}}
article header{{display:flex;align-items:baseline;gap:10px;margin-bottom:20px}}
article h2{{font-size:14px;font-weight:600;color:var(--head);margin:0;flex:1}}
.num{{color:var(--accent);font-weight:600}}
.ground{{color:var(--mark)}}
.stage{{display:flex;align-items:flex-end;gap:22px;flex-wrap:wrap}}
.ladder{{display:flex;align-items:flex-end;gap:14px;flex-wrap:wrap}}
.ladder div{{display:flex;flex-direction:column;align-items:center;gap:6px}}
small{{color:var(--mark);font-size:11px;line-height:1.4}}
.shadow{{display:inline-block;line-height:0;filter:drop-shadow(0 1px 1px rgba(0,0,0,.25)) drop-shadow(0 6px 14px rgba(0,0,0,.22))}}
.icon{{display:inline-block;background-size:cover}}
article p{{margin:20px 0 14px;max-width:52ch}}
.pairs{{list-style:none;margin:0;padding:14px 0 0;border-top:1px solid var(--line);font-size:12px}}
.pairs li{{display:grid;grid-template-columns:22px 1fr auto 62px;gap:10px;align-items:center;color:var(--quiet)}}
.pairs b{{text-align:right;color:var(--head);font-weight:600}}
.sw{{width:22px;height:22px;border-radius:6px;display:grid;place-items:center;border:1px solid var(--line)}}
.sw span{{width:8px;height:8px;border-radius:2px}}
code{{font:inherit;color:var(--mark)}}
article footer{{margin-top:12px;font-size:12px}}
.dock{{padding:40px 24px 16px;border-radius:14px;margin-bottom:12px;display:flex;justify-content:center}}
.dock.light{{background:linear-gradient(160deg,#E9E4DA,#CBD3D2)}}
.dock.dusk{{background:linear-gradient(160deg,#5B6F8C,#C98B6B)}}
.dock.dark{{background:linear-gradient(160deg,#101113,#1F1E24)}}
.shelf{{display:flex;gap:12px;padding:10px 14px;border-radius:26px;background:rgba(255,255,255,.22);border:1px solid rgba(255,255,255,.25);flex-wrap:wrap;justify-content:center}}
.dock.dark .shelf{{background:rgba(255,255,255,.07);border-color:rgba(255,255,255,.12)}}
.palette{{list-style:none;margin:0;padding:0;display:grid;grid-template-columns:repeat(auto-fill,minmax(132px,1fr));gap:14px}}
.palette li{{display:flex;flex-direction:column}}
.palette span{{height:56px;border-radius:10px;border:1px solid var(--line);margin-bottom:8px}}
.palette b{{color:var(--head);font-weight:600}}
.notes{{max-width:66ch;color:var(--quiet);padding-left:2ch}}
.notes li::marker{{content:"– ";color:var(--accent)}}
{"".join(css_icons)}
</style></head><body><main>
<h1><i>#</i> Flowriter icon concepts</h1>
<p class="lede">Six ideas, nine drawings. Each one is lit from above: raised marks have a side wall, a lit top edge and a cast shadow, and anything in flame throws light on the page. Each one uses only the colours the app already has. The numbers under a drawing are WCAG contrast ratios of the flat colours.</p>
<div class="grid">{"".join(cards)}</div>
<h3><i>##</i> In a Dock</h3>
<p class="lede">The first icon is the current one. The rest follow in the order above, at 64 points, on a dark, a coloured and a light desktop.</p>
{docks}
<h3><i>##</i> Colour</h3>
<p class="lede">All eight colours come from Theme.swift. L, C and h are OKLCH lightness, chroma and hue.</p>
<ul class="palette">{swatches}</ul>
<ul class="notes">
<li>Every gradient and glow is blended in OKLab and written as stops. A flame colour laid over the cool page with plain opacity goes grey halfway. These keep their warmth.</li>
<li>The dark grounds stay around the app's page colour #181A1C and the paper grounds around #F4F1EA. Light and shade change lightness only. The hue does not move.</li>
<li>A flame face runs from {FLAME_HOT} at the top through {FLAME_TOP} and {FLAME} to {FLAME_LOW} at the foot. Its side wall is {FLAME_SIDE}. A bone face runs from #F8F5EE to {BONE}, with a {BONE_SIDE} wall.</li>
<li>Shadows on paper are tinted with ember, not black, so the cream stays clean.</li>
<li>All colours are sRGB, the same as the app.</li>
<li>The icon shape and its lit rim are drawn here to show the icon in place. In the shipped icon the system draws both.</li>
</ul>
</main></body></html>
'''
    (HERE / "review.html").write_text(html)
    print(f"wrote {len(CONCEPTS)} SVGs and review.html ({len(html) // 1024} KB)")


if __name__ == "__main__":
    main()
