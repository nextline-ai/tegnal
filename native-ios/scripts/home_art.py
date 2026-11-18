#!/usr/bin/env python3
"""Draws the vector art the home scene travels through, as SVG image sets.

    python3 native-ios/scripts/home_art.py            # writes Assets.xcassets/Home/*.imageset
    python3 native-ios/scripts/home_art.py --sheet F  # also writes one contact sheet to F

Every piece is drawn from a fixed seed, so running it again gives the same files. Only
plain shapes and gradients are used: the asset catalog's SVG reader has no filters or masks.
"""

import json
import math
import random
import sys
from pathlib import Path

OUT = Path(__file__).resolve().parents[1] / "TEGNAL" / "Assets.xcassets" / "Home"
PIECES = {}


def f(value):
    return f"{value:.1f}".rstrip("0").rstrip(".")


def piece(name, width, height):
    def register(draw):
        PIECES[name] = (width, height, draw)
        return draw
    return register


class Art:
    """One SVG being drawn; gradient names carry the piece's name so pieces can share a sheet."""

    def __init__(self, name, seed=1):
        self.name, self.defs, self.body, self.count = name, [], [], 0
        self.random = random.Random(f"{name}:{seed}")

    def gradient(self, kind, stops, **box):
        self.count += 1
        ident = f"{self.name}{self.count}"
        attrs = " ".join(f'{key}="{f(value) if isinstance(value, (int, float)) else value}"' for key, value in box.items())
        inner = "".join(
            f'<stop offset="{f(offset)}" stop-color="{color}" stop-opacity="{f(alpha)}"/>' for offset, color, alpha in stops)
        self.defs.append(f'<{kind}Gradient id="{ident}" {attrs}>{inner}</{kind}Gradient>')
        return f"url(#{ident})"

    def linear(self, stops, x1=0, y1=0, x2=0, y2=1, user=False):
        box = dict(x1=x1, y1=y1, x2=x2, y2=y2)
        if user:
            box["gradientUnits"] = "userSpaceOnUse"
        return self.gradient("linear", stops, **box)

    def radial(self, stops, cx=0.5, cy=0.5, r=0.5):
        return self.gradient("radial", stops, cx=cx, cy=cy, r=r)

    def add(self, text):
        self.body.append(text)

    def path(self, d, fill="none", **attrs):
        extra = "".join(f' {key.replace("_", "-")}="{f(value) if isinstance(value, (int, float)) else value}"' for key, value in attrs.items())
        self.add(f'<path d="{d}" fill="{fill}"{extra}/>')

    def circle(self, x, y, r, fill, opacity=1):
        self.add(f'<circle cx="{f(x)}" cy="{f(y)}" r="{f(r)}" fill="{fill}" opacity="{f(opacity)}"/>')

    def ellipse(self, x, y, rx, ry, fill, opacity=1, turn=0):
        spin = f' transform="rotate({f(turn)} {f(x)} {f(y)})"' if turn else ""
        self.add(f'<ellipse cx="{f(x)}" cy="{f(y)}" rx="{f(rx)}" ry="{f(ry)}" fill="{fill}" opacity="{f(opacity)}"{spin}/>')

    def rect(self, x, y, w, h, fill, r=0, opacity=1, turn=0, **attrs):
        spin = f' transform="rotate({f(turn)} {f(x + w / 2)} {f(y + h / 2)})"' if turn else ""
        extra = "".join(f' {key.replace("_", "-")}="{f(value) if isinstance(value, (int, float)) else value}"' for key, value in attrs.items())
        self.add(f'<rect x="{f(x)}" y="{f(y)}" width="{f(w)}" height="{f(h)}" rx="{f(r)}" fill="{fill}" opacity="{f(opacity)}"{spin}{extra}/>')

    def polygon(self, points, fill, opacity=1, **attrs):
        d = "M" + " L".join(f"{f(x)} {f(y)}" for x, y in points) + " Z"
        self.path(d, fill, opacity=opacity, **attrs)


def polyline(points):
    return "M" + " L".join(f"{f(x)} {f(y)}" for x, y in points)


def curve(points, start="M"):
    """A smooth line through the points' midpoints."""
    d = f"{start}{f(points[0][0])} {f(points[0][1])}"
    for (x1, y1), (x2, y2) in zip(points[1:], points[2:]):
        d += f" Q{f(x1)} {f(y1)} {f((x1 + x2) / 2)} {f((y1 + y2) / 2)}"
    d += f" L{f(points[-1][0])} {f(points[-1][1])}"
    return d


def wave(rng, x0, x1, y, amp, n=28):
    phases = [rng.uniform(0, math.tau) for _ in range(3)]
    points = []
    for i in range(n + 1):
        u = i / n * math.tau
        lift = math.sin(u + phases[0]) + 0.5 * math.sin(2.3 * u + phases[1]) + 0.25 * math.sin(4.7 * u + phases[2])
        points.append((x0 + (x1 - x0) * i / n, y + amp * lift / 1.75))
    return points


def sparkle(art, x, y, r, fill="#ffffff", opacity=1, pinch=0.1):
    k = r * pinch
    d = (f"M{f(x)} {f(y - r)} Q{f(x + k)} {f(y - k)} {f(x + r)} {f(y)} Q{f(x + k)} {f(y + k)} {f(x)} {f(y + r)} "
         f"Q{f(x - k)} {f(y + k)} {f(x - r)} {f(y)} Q{f(x - k)} {f(y - k)} {f(x)} {f(y - r)} Z")
    art.path(d, fill, opacity=opacity)


# MARK: - Sky

@piece("HomeSparkle", 160, 160)
def _(art):
    art.circle(80, 80, 80, art.radial([(0, "#ffffff", 0.75), (0.25, "#e9dcff", 0.32), (0.6, "#b9a0ff", 0.1), (1, "#b9a0ff", 0)]))
    sparkle(art, 80, 80, 74, art.radial([(0, "#ffffff", 1), (0.5, "#fff6e6", 1), (1, "#d9c8ff", 0.85)]), pinch=0.085)
    art.add('<g transform="rotate(45 80 80)">')
    sparkle(art, 80, 80, 30, "#ffffff", 0.85, pinch=0.12)
    art.add("</g>")
    art.circle(80, 80, 7, "#ffffff")


@piece("HomeStarfield", 400, 400)
def _(art):
    rng = art.random
    tints = ["#ffffff"] * 6 + ["#d9ccff", "#ffd9ec", "#fff0c9", "#bfe3ff"]
    for _ in range(120):
        size = rng.choice([0.5, 0.6, 0.7, 0.8, 1.0, 1.2, 1.6])
        art.circle(rng.uniform(4, 396), rng.uniform(4, 396), size, rng.choice(tints), rng.uniform(0.35, 1))
    for _ in range(7):
        x, y, r = rng.uniform(20, 380), rng.uniform(20, 380), rng.uniform(4, 8)
        art.circle(x, y, r * 1.6, art.radial([(0, "#ffffff", 0.35), (1, "#ffffff", 0)]))
        sparkle(art, x, y, r, rng.choice(tints), 0.95, pinch=0.12)


def streak_cloud(art, width, height, lit, shade, glow):
    """A flat cloud of long strokes, lit from underneath by the last light, as in the illustration."""
    rng = art.random
    rows = max(4, int(height / 13))
    body = art.linear([(0, shade, 0.9), (0.55, lit, 0.95), (1, glow, 0.95)])
    for row in range(rows):
        level = (row + 0.5) / rows
        y = height * (0.12 + 0.76 * level)
        reach = width * (0.42 + 0.5 * math.sin(math.pi * (0.15 + 0.8 * level)))
        for _ in range(rng.choice([1, 2, 2])):
            w = reach * rng.uniform(0.45, 1)
            h = height / rows * rng.uniform(0.75, 1.25)
            x = width / 2 - w / 2 + rng.uniform(-0.5, 0.5) * (width - w) * 0.8
            art.rect(x, y - h / 2, w, h, body, r=h / 2, opacity=rng.uniform(0.55, 0.92))
    for _ in range(rows):
        w = width * rng.uniform(0.12, 0.34)
        h = rng.uniform(2.5, 5)
        art.rect(rng.uniform(width * 0.1, width * 0.9 - w), height * rng.uniform(0.55, 0.9), w, h, glow, r=h / 2, opacity=rng.uniform(0.5, 0.9))
    for _ in range(3):
        w = width * rng.uniform(0.1, 0.22)
        art.rect(rng.uniform(width * 0.15, width * 0.85 - w), height * rng.uniform(0.1, 0.4), w, 2.5, "#ffffff", r=1.2, opacity=0.25)


@piece("HomeCloudA", 380, 120)
def _(art):
    streak_cloud(art, 380, 120, "#8d74cf", "#5a4399", "#f2a9c6")


@piece("HomeCloudB", 300, 90)
def _(art):
    streak_cloud(art, 300, 90, "#a48be0", "#6d55ae", "#ffc4a8")


@piece("HomeCloudC", 340, 100)
def _(art):
    streak_cloud(art, 340, 100, "#c5b2f2", "#8a73cc", "#ffd9c2")


@piece("HomeCloudBank", 440, 250)
def _(art):
    rng = art.random
    for layer, (top, bottom, lift, alpha) in enumerate([("#b9a4f0", "#6a53b5", 34, 0.8), ("#e2d6ff", "#8f78d8", 12, 0.92), ("#fbf7ff", "#b3a0ee", -10, 1)]):
        level = 120 - lift + layer * 22
        # One gradient in the piece's own space, so the puffs and the mass under them shade as one cloud.
        # The underside thins out into the air, so the deck has no edge when it is passed from below.
        fill = art.linear([(0, top, alpha), (0.5, bottom, alpha), (0.8, bottom, alpha * 0.45), (1, bottom, 0)], 0, level - 60, 0, 250, user=True)
        x = -30
        while x < 470:
            r = rng.uniform(26, 54)
            art.circle(x, level + rng.uniform(-14, 14), r, fill)
            x += r * rng.uniform(0.9, 1.3)
        art.rect(-30, level, 500, 250 - level, fill)


@piece("HomeMoon", 240, 240)
def _(art):
    art.circle(120, 112, 120, art.radial([(0, "#d9c4ff", 0.26), (0.45, "#c2a8ff", 0.14), (0.75, "#a58cf0", 0.05), (1, "#a58cf0", 0)]))
    art.path("M150 62 A62 62 0 1 1 78 152 A50 50 0 1 0 150 62 Z", art.linear([(0, "#ffffff", 1), (1, "#ffe9b8", 1)], 0.2, 0, 0.8, 1))
    art.circle(160, 78, 2, "#ffffff", 0.8)


@piece("HomeShootingStar", 260, 110)
def _(art):
    tail = art.linear([(0, "#ffffff", 0), (0.7, "#d9ccff", 0.55), (1, "#ffffff", 1)], 16, 96, 236, 20, user=True)
    art.polygon([(16, 96), (236, 17.5), (238, 22.5)], tail)
    art.polygon([(96, 70), (236, 18.5), (237.5, 21.5)], "#ffffff", 0.7)
    art.circle(237, 20, 12, art.radial([(0, "#ffffff", 0.9), (1, "#ffffff", 0)]))
    sparkle(art, 237, 20, 8, "#ffffff", 1, pinch=0.14)


@piece("HomeConstellation", 240, 180)
def _(art):
    # A price tag drawn in stars: the thing learning mode teaches.
    outline = [(34, 92), (82, 42), (196, 34), (208, 132), (88, 146)]
    hole = (86, 94)
    for a, b in list(zip(outline, outline[1:] + outline[:1])) + [(outline[0], hole)]:
        art.path(polyline([a, b]), stroke="#e6dcff", stroke_width=1.1, stroke_opacity=0.5, stroke_linecap="round")
    for a, b in [((112, 78), (176, 72)), ((112, 104), (160, 104))]:
        art.path(polyline([a, b]), stroke="#e6dcff", stroke_width=1, stroke_opacity=0.28, stroke_linecap="round", stroke_dasharray="2 6")
    for index, (x, y) in enumerate(outline + [hole]):
        art.circle(x, y, 11, art.radial([(0, "#ffffff", 0.5), (1, "#ffffff", 0)]))
        sparkle(art, x, y, 7 if index % 2 else 5.5, "#ffffff", 1, pinch=0.16)


# MARK: - Underground

SOIL = ["#1e1430", "#261a40", "#2e1f4d", "#38275e", "#43306f"]


@piece("HomeGroundEdge", 400, 330)
def _(art):
    rng = art.random
    # Roots first, so the soil sits over where they begin.
    for _ in range(11):
        x, y, length = rng.uniform(10, 390), 96, rng.uniform(70, 215)
        points, drift = [(x, y)], rng.uniform(-0.5, 0.5)
        for step in range(1, 7):
            points.append((x + drift * step * 9 + rng.uniform(-9, 9), y + length * step / 6))
        width = rng.uniform(1.4, 3.8)
        art.path(curve(points), stroke=rng.choice(["#3a2859", "#46316c", "#2e2048"]), stroke_width=width, stroke_linecap="round", opacity=0.95)
        fork = points[rng.randint(2, 4)]
        art.path(curve([fork, (fork[0] + rng.uniform(-22, 22), fork[1] + 18), (fork[0] + rng.uniform(-34, 34), fork[1] + rng.uniform(34, 60))]),
                 stroke="#3a2859", stroke_width=width * 0.55, stroke_linecap="round", opacity=0.85)
    top = wave(rng, -10, 410, 30, 9)
    bottom = wave(rng, -10, 410, 118, 20)
    art.path(curve(top) + curve(list(reversed(bottom)), " L") + " Z", art.linear([(0, "#1e1430", 1), (0.5, "#2a1c46", 1), (1, "#33225a", 1)]))
    seam = wave(rng, -10, 410, 74, 10)
    art.path(curve(seam) + curve(list(reversed(bottom)), " L") + " Z", "#3d2a68", opacity=0.55)
    art.path(curve(seam), stroke="#6b52a8", stroke_width=1.2, stroke_opacity=0.5)
    for _ in range(26):
        art.ellipse(rng.uniform(0, 400), rng.uniform(48, 112), rng.uniform(1.5, 6), rng.uniform(1.2, 3.6),
                    rng.choice(["#5a4690", "#1a1029", "#4a3878", "#7460ad"]), rng.uniform(0.4, 0.9), rng.uniform(-30, 30))
    # Grass standing on the edge, the same dark as the foot of the illustration.
    for _ in range(64):
        x = rng.uniform(-5, 405)
        base = min(top, key=lambda p: abs(p[0] - x))[1] + 4
        height, lean, half = rng.uniform(10, 30), rng.uniform(-8, 8), rng.uniform(1, 2.2)
        art.path(f"M{f(x - half)} {f(base)} Q{f(x + lean * 0.3)} {f(base - height * 0.6)} {f(x + lean)} {f(base - height)} "
                 f"Q{f(x + lean * 0.4 + half)} {f(base - height * 0.5)} {f(x + half)} {f(base)} Z", "#1e1430")


def strata(art, relics):
    rng = art.random
    lines = [wave(rng, -10, 410, y, amp) for y, amp in [(26, 12), (84, 16), (140, 13), (196, 16), (244, 10)]]
    tones = ["#2a1c46", "#33225a", "#3b2968", "#2e1f50"]
    for index, tone in enumerate(tones):
        upper, lower = lines[index], lines[index + 1]
        art.path(curve(upper) + curve(list(reversed(lower)), " L") + " Z", art.linear([(0, tone, 1), (1, SOIL[1], 0.92)]))
        art.path(curve(upper), stroke="#8a72c8", stroke_width=1.2, stroke_opacity=0.36)
    for _ in range(44):
        art.ellipse(rng.uniform(0, 400), rng.uniform(34, 236), rng.uniform(1.2, 7), rng.uniform(1, 4),
                    rng.choice(["#5d4996", "#1b1130", "#4b3980", "#7d68b8"]), rng.uniform(0.35, 0.85), rng.uniform(-30, 30))
    # A vein of ore catching the light.
    y = rng.uniform(100, 170)
    vein = [(x, y + rng.uniform(-9, 9)) for x in range(-10, 420, 22)]
    art.path(polyline(vein), stroke=art.linear([(0, "#ffcf8a", 0), (0.3, "#ffcf8a", 0.8), (0.7, "#ff9ecb", 0.8), (1, "#ff9ecb", 0)], 0, 0, 1, 0),
             stroke_width=1.6, stroke_linejoin="round", opacity=0.75)
    for x, yy in vein[3:-3:3]:
        sparkle(art, x, yy, 3.2, "#fff1cf", 0.9, pinch=0.2)
    if relics:
        # An ammonite and a fish, long buried.
        cx, cy = 96, 166
        spiral = [(cx + (2 + 2.6 * t) * math.cos(t * 0.9), cy + (2 + 2.6 * t) * math.sin(t * 0.9)) for t in [i * 0.35 for i in range(34)]]
        art.path(curve(spiral), stroke="#9a86cf", stroke_width=2.2, stroke_linecap="round", opacity=0.7)
        for t in range(6, 33, 3):
            a = t * 0.35 * 0.9
            r1, r2 = 2 + 2.6 * t * 0.35 - 4, 2 + 2.6 * t * 0.35 + 1
            art.path(polyline([(cx + r1 * math.cos(a), cy + r1 * math.sin(a)), (cx + r2 * math.cos(a), cy + r2 * math.sin(a))]),
                     stroke="#9a86cf", stroke_width=1, opacity=0.5)
        fx, fy = 286, 76
        art.add(f'<g transform="rotate(-12 {fx} {fy})" opacity="0.62">')
        art.path(polyline([(fx - 34, fy), (fx + 30, fy)]), stroke="#a592d8", stroke_width=1.6, stroke_linecap="round")
        for k in range(-3, 4):
            reach = 11 - abs(k) * 1.8
            art.path(polyline([(fx + k * 8, fy - reach), (fx + k * 8 - 3, fy), (fx + k * 8, fy + reach)]), stroke="#a592d8", stroke_width=1.1, stroke_linecap="round")
        art.polygon([(fx - 34, fy), (fx - 47, fy - 9), (fx - 47, fy + 9)], "#a592d8")
        art.polygon([(fx + 30, fy - 7), (fx + 44, fy), (fx + 30, fy + 7)], "#a592d8")
        art.add("</g>")


@piece("HomeStrataA", 400, 270)
def _(art):
    strata(art, False)


@piece("HomeStrataB", 400, 270)
def _(art):
    strata(art, True)


@piece("HomeCrystals", 240, 300)
def _(art):
    rng = art.random
    art.ellipse(96, 160, 130, 130, art.radial([(0, "#9b7bff", 0.5), (0.45, "#7c5cff", 0.18), (1, "#7c5cff", 0)]))
    shards = []
    for index in range(9):
        angle = math.radians(-78 + index * 15 + rng.uniform(-6, 6))
        shards.append((rng.uniform(-6, 30), 188 + index * 9 + rng.uniform(-8, 8), angle, rng.uniform(70, 190) * (0.65 + 0.35 * math.cos(angle + 0.5)), rng.uniform(15, 30)))
    for bx, by, angle, length, width in sorted(shards, key=lambda s: -s[3]):
        ux, uy, nx, ny = math.cos(angle), math.sin(angle), -math.sin(angle), math.cos(angle)
        neck = 0.76
        left, right = (bx - nx * width / 2, by - ny * width / 2), (bx + nx * width / 2, by + ny * width / 2)
        mid = (bx + ux * length * neck, by + uy * length * neck)
        shoulder_left, shoulder_right = (mid[0] - nx * width / 2, mid[1] - ny * width / 2), (mid[0] + nx * width / 2, mid[1] + ny * width / 2)
        tip = (bx + ux * length, by + uy * length)
        tint = rng.choice([("#cbb8ff", "#8465f0", "#5a3fc0"), ("#e3d4ff", "#9a7dff", "#6748d1"), ("#ffc9e6", "#c58cf5", "#7a52d6")])
        light = art.linear([(0, "#3a2670", 1), (0.35, tint[1], 1), (1, tint[0], 1)], bx, by, tip[0], tip[1], user=True)
        dark = art.linear([(0, "#2b1b57", 1), (0.4, tint[2], 1), (1, tint[1], 1)], bx, by, tip[0], tip[1], user=True)
        art.polygon([left, (bx, by), mid, tip, shoulder_left], light)
        art.polygon([(bx, by), right, shoulder_right, tip, mid], dark)
        art.polygon([shoulder_left, mid, tip], "#ffffff", 0.42)
        art.path(polyline([(bx, by), mid, tip]), stroke="#ffffff", stroke_width=0.9, stroke_opacity=0.5)
    # The rock the crystals grow from.
    art.polygon([(-20, 120), (6, 138), (14, 162), (34, 178), (30, 206), (46, 226), (36, 252), (44, 276), (18, 292), (-20, 300)],
                art.linear([(0, "#0d0819", 1), (1, "#2b1c4a", 1)], 0, 0, 1, 0), stroke="#5a45a0", stroke_width=1.2, stroke_opacity=0.5)
    for _ in range(9):
        x, y = rng.uniform(40, 220), rng.uniform(20, 260)
        sparkle(art, x, y, rng.uniform(2, 5), "#ffffff", rng.uniform(0.5, 0.95), pinch=0.18)


@piece("HomeLantern", 240, 330)
def _(art):
    cx, cy = 120, 200
    art.circle(cx, cy, 120, art.radial([(0, "#ffd58f", 0.6), (0.3, "#ffb866", 0.26), (0.7, "#ff9a5a", 0.07), (1, "#ff9a5a", 0)]))
    art.path(polyline([(cx, 0), (cx, cy - 46)]), stroke="#3b2b5c", stroke_width=2)
    for y in range(8, int(cy - 50), 12):
        art.ellipse(cx, y, 2.6, 4.2, "none", 1)
    art.polygon([(cx - 9, cy - 46), (cx + 9, cy - 46), (cx + 21, cy - 32), (cx - 21, cy - 32)], "#2b1d45")
    art.rect(cx - 5, cy - 53, 10, 8, "#2b1d45", r=3)
    art.rect(cx - 18, cy - 32, 36, 58, art.radial([(0, "#fffbe6", 1), (0.5, "#ffd88a", 1), (1, "#f08f4a", 1)], 0.5, 0.55, 0.62), r=7)
    for x in (cx - 18, cx - 0.9, cx + 16.2):
        art.rect(x, cy - 32, 1.8, 58, "#2b1d45")
    art.rect(cx - 18, cy - 5, 36, 1.6, "#2b1d45", opacity=0.8)
    art.polygon([(cx - 21, cy + 26), (cx + 21, cy + 26), (cx + 12, cy + 36), (cx - 12, cy + 36)], "#2b1d45")
    art.path(polyline([(cx, cy + 36), (cx, cy + 58)]), stroke="#c9774a", stroke_width=1.6)
    art.polygon([(cx - 4, cy + 56), (cx + 4, cy + 56), (cx + 2, cy + 74), (cx - 2, cy + 74)], "#e89a5c")
    art.ellipse(cx, cy - 2, 7, 13, "#ffffff", 0.75)


@piece("HomeRockSide", 220, 760)
def _(art):
    rng = art.random

    def wall(reach, jag, step):
        # An outcrop: it swells out of the cave wall and sinks back into it, so no edge of the drawing shows.
        points, y = [(-20, 0)], 0
        while y < 760:
            swell = math.sin(math.pi * y / 760) ** 0.7
            bulge = math.sin(y / 120 + 1.3) * 26 + math.sin(y / 47) * 12
            points.append((max(-20, (reach + bulge + rng.uniform(-jag, jag)) * swell - 20 * (1 - swell)), y))
            y += rng.uniform(step * 0.6, step * 1.4)
        return points + [(-20, 760)]

    back = wall(150, 20, 34)
    art.polygon(back, art.linear([(0, "#150d27", 1), (1, "#2a1c48", 1)], 0, 0, 1, 0))
    art.path(polyline(back[1:-1]), stroke="#6d57b0", stroke_width=1.4, stroke_opacity=0.42, stroke_linejoin="round")
    front = wall(92, 24, 44)
    art.polygon(front, art.linear([(0, "#07040f", 1), (1, "#170f2a", 1)], 0, 0, 1, 0))
    art.path(polyline(front[1:-1]), stroke="#4a3a80", stroke_width=1.2, stroke_opacity=0.5, stroke_linejoin="round")
    for _ in range(7):
        y = rng.uniform(180, 580)
        x = rng.uniform(60, 110)
        art.polygon([(x - 7, y), (x + 9, y - 3), (x + 4, y + 10)], "#3a2b68", 0.7)


@piece("HomeGems", 400, 400)
def _(art):
    # Specks of ore and small stones in the dark between the layers.
    rng = art.random
    for _ in range(46):
        art.circle(rng.uniform(4, 396), rng.uniform(4, 396), rng.choice([0.6, 0.8, 1, 1.3]), rng.choice(["#b9a0ff", "#ffcf8a", "#ff9ecb", "#8a72c8", "#6ef0d6"]), rng.uniform(0.25, 0.8))
    for _ in range(30):
        art.ellipse(rng.uniform(0, 400), rng.uniform(0, 400), rng.uniform(2, 9), rng.uniform(1.5, 5), rng.choice(["#2a1c46", "#33225a", "#241839", "#3b2968"]), rng.uniform(0.5, 0.9), rng.uniform(-40, 40))
    for _ in range(7):
        x, y, r = rng.uniform(20, 380), rng.uniform(20, 380), rng.uniform(3.5, 7)
        tint = rng.choice([("#cbb8ff", "#7c5cff"), ("#ffd9a0", "#ff9a5a"), ("#bafff0", "#3fc7b4")])
        art.circle(x, y, r * 2.4, art.radial([(0, tint[1], 0.35), (1, tint[1], 0)]))
        art.polygon([(x, y - r), (x + r * 0.7, y), (x, y + r), (x - r * 0.7, y)], tint[1])
        art.polygon([(x, y - r), (x + r * 0.7, y), (x, y)], tint[0])


@piece("HomeMushrooms", 170, 120)
def _(art):
    art.ellipse(85, 78, 85, 44, art.radial([(0, "#6ef0d6", 0.42), (0.5, "#6ef0d6", 0.14), (1, "#6ef0d6", 0)]))
    for x, base, height, cap in [(52, 104, 34, 20), (86, 108, 52, 27), (118, 104, 26, 15), (30, 108, 16, 10)]:
        art.path(f"M{f(x - 3)} {f(base)} Q{f(x - 1)} {f(base - height * 0.5)} {f(x - 2)} {f(base - height)} L{f(x + 2)} {f(base - height)} Q{f(x + 2)} {f(base - height * 0.5)} {f(x + 3)} {f(base)} Z", "#d7fff5", opacity=0.9)
        top = base - height
        art.path(f"M{f(x - cap)} {f(top + 3)} Q{f(x - cap * 0.9)} {f(top - cap * 0.9)} {f(x)} {f(top - cap * 0.95)} Q{f(x + cap * 0.9)} {f(top - cap * 0.9)} {f(x + cap)} {f(top + 3)} Q{f(x)} {f(top + 8)} {f(x - cap)} {f(top + 3)} Z",
                 art.linear([(0, "#c9fff2", 1), (0.5, "#5fe6cf", 1), (1, "#2f9fb0", 1)]))
        art.circle(x - cap * 0.3, top - cap * 0.45, cap * 0.13, "#ffffff", 0.9)
        art.circle(x + cap * 0.35, top - cap * 0.25, cap * 0.09, "#ffffff", 0.75)
    for x, y in [(20, 60), (140, 52), (100, 30), (66, 44), (150, 86)]:
        art.circle(x, y, 1.6, "#bafff0", 0.85)


@piece("HomeRelicFrame", 150, 130)
def _(art):
    art.add('<g transform="rotate(-9 75 65)">')
    art.rect(24, 22, 102, 86, art.linear([(0, "#e5c07a", 1), (1, "#9a6b3a", 1)], 0, 0, 1, 1), r=4)
    art.rect(33, 31, 84, 68, "#2a1c46", r=2)
    art.rect(36, 34, 78, 62, art.linear([(0, "#3b2a7a", 1), (0.6, "#b98ad0", 1), (1, "#ffcf9a", 1)]), r=1)
    art.circle(94, 52, 6, "#fff3d0", 0.95)
    art.path("M36 96 L58 70 L72 84 L90 62 L114 96 Z", "#231739", opacity=0.9)
    art.path(polyline([(24, 22), (126, 22)]), stroke="#fff1cf", stroke_width=1.2, stroke_opacity=0.7)
    art.add("</g>")


@piece("HomeRelicBooks", 150, 120)
def _(art):
    for index, (x, y, w, h, cover, turn) in enumerate([(22, 78, 104, 20, "#7c5cff", 2), (30, 57, 92, 20, "#ff8aa8", -3), (26, 36, 98, 20, "#3fc7b4", 4)]):
        art.add(f'<g transform="rotate({turn} 75 60)">')
        art.rect(x, y, w, h, cover, r=3)
        art.rect(x + 5, y + 3, w - 8, h - 6, "#fff6e3", r=1)
        art.rect(x, y, 12, h, cover, r=3)
        art.rect(x + 12, y + 3, 1.2, h - 6, "#000000", opacity=0.18)
        for line in range(3):
            art.rect(x + 20, y + 6 + line * 3.4, w - 34, 0.9, "#b9a6d8", opacity=0.6)
        art.add("</g>")


@piece("HomeCeiling", 400, 210)
def _(art):
    # The roof of the last chamber: the ground's far edge, with the library in the open space under it.
    rng = art.random

    def hang(x, length, width, fill, rim):
        tip = (x + rng.uniform(-3, 3), 62 + length)
        left, right = (x - width / 2, 58), (x + width / 2, 58)
        art.path(f"M{f(left[0])} {f(left[1])} Q{f(x - width * 0.22)} {f(62 + length * 0.45)} {f(tip[0])} {f(tip[1])} "
                 f"Q{f(x + width * 0.22)} {f(62 + length * 0.45)} {f(right[0])} {f(right[1])} Z", fill)
        art.path(f"M{f(x + width * 0.18)} {f(64)} Q{f(x + width * 0.12)} {f(62 + length * 0.5)} {f(tip[0])} {f(tip[1])}",
                 stroke=rim, stroke_width=1.1, stroke_opacity=0.5, stroke_linecap="round")

    back = art.linear([(0, "#1a1130", 1), (1, "#2a1c48", 1)])
    for _ in range(11):
        hang(rng.uniform(0, 400), rng.uniform(26, 78), rng.uniform(18, 36), back, "#6d57b0")
    # Small crystals in the roof, lit from inside.
    tints = [("#cbb8ff", "#7c5cff"), ("#bafff0", "#3fc7b4"), ("#ffc9e6", "#c58cf5"), ("#cbb8ff", "#7c5cff")]
    for x, tint in zip((64, 152, 250, 338), tints):
        x += rng.uniform(-14, 14)
        length = rng.uniform(26, 44)
        art.ellipse(x, 74 + length * 0.5, 30, 34, art.radial([(0, tint[1], 0.4), (1, tint[1], 0)]))
        art.polygon([(x - 6, 62), (x + 6, 62), (x + 5, 62 + length * 0.7), (x, 62 + length), (x - 5, 62 + length * 0.7)], tint[1])
        art.polygon([(x - 6, 62), (x, 62), (x, 62 + length), (x - 5, 62 + length * 0.7)], tint[0])
    under = wave(rng, -10, 410, 66, 9)
    art.path(f"M-10 0 L410 0 " + curve(list(reversed(under)), "L") + " Z", art.linear([(0, "#0d0716", 1), (0.55, "#130b22", 1), (1, "#1c1232", 1)]))
    art.path(curve(under), stroke="#6d57b0", stroke_width=1.3, stroke_opacity=0.5)
    front = art.linear([(0, "#130b22", 1), (1, "#211639", 1)])
    for _ in range(9):
        hang(rng.uniform(0, 400), rng.uniform(40, 128), rng.uniform(20, 42), front, "#8a72c8")
    for _ in range(18):
        art.ellipse(rng.uniform(0, 400), rng.uniform(8, 56), rng.uniform(2, 8), rng.uniform(1.5, 4), rng.choice(["#241839", "#2e1f4d", "#1a1029"]), rng.uniform(0.5, 0.9), rng.uniform(-30, 30))


def write(sheet=None):
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / "Contents.json").write_text(json.dumps({"info": {"author": "xcode", "version": 1}}, indent=2) + "\n")
    sheet_body, sheet_defs, x, y, row = [], [], 20, 20, 0
    for name, (width, height, draw) in PIECES.items():
        art = Art(name)
        draw(art)
        text = (f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}">'
                f'<defs>{"".join(art.defs)}</defs>{"".join(art.body)}</svg>\n')
        folder = OUT / f"{name}.imageset"
        folder.mkdir(exist_ok=True)
        (folder / f"{name}.svg").write_text(text)
        (folder / "Contents.json").write_text(json.dumps({
            "images": [{"filename": f"{name}.svg", "idiom": "universal"}],
            "info": {"author": "xcode", "version": 1},
            "properties": {"preserves-vector-representation": True},
        }, indent=2) + "\n")
        if x + width > 1500:
            x, y, row = 20, y + row + 20, 0
        sheet_defs += art.defs
        sheet_body.append(f'<g transform="translate({x} {y})">{"".join(art.body)}</g>')
        x, row = x + width + 20, max(row, height)
    if sheet:
        total = y + row + 20
        Path(sheet).write_text(f'<svg xmlns="http://www.w3.org/2000/svg" width="1520" height="{total}" viewBox="0 0 1520 {total}">'
                               f'<defs>{"".join(sheet_defs)}</defs><rect width="1520" height="{total}" fill="#160e2a"/>{"".join(sheet_body)}</svg>')
    print(f"{len(PIECES)} pieces written to {OUT}")


if __name__ == "__main__":
    write(sys.argv[2] if len(sys.argv) > 2 and sys.argv[1] == "--sheet" else None)
