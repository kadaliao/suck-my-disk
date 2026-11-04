#!/usr/bin/env python3
"""Generates App/AppIcon.icon: a tapered spiral ribbon, split into the app's
category colors, curling into the center like space being sucked down a drain.

    python3 scripts/make-icon.py                 # writes App/AppIcon.icon
    python3 scripts/make-icon.py --preview DIR   # also renders PNGs with ictool
"""
import json
import math
import os
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "App", "AppIcon.icon")
ICTOOL = "/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"

SIZE = 1024
CX, CY = SIZE / 2, SIZE / 2

# Outside in: projects, media, dev caches, models, app data.
COLORS = ["#0A84FF", "#FF375F", "#FF9F0A", "#BF5AF2", "#30B0C7"]

# Spiral shape.
TURNS = 2.1           # how far the ribbon curls in
R_OUT = 372           # radius of the ribbon's center line at the outer end
R_IN = 10             # where it ends
R_POW = 1.25          # shape of the radius curve (>1 crowds the inner turns)
WIDTH_OUT = 140       # ribbon width at the outer end
WIDTH_IN = 6
W_POW = 1.1           # shape of the width taper
START_ANGLE = 250     # degrees, where the outer end sits (0 = right, counterclockwise)
GAP = 0.085           # gap between segments, as a fraction of the local width
# Segment boundaries along the ribbon (0 = outer end, 1 = center).
SPLITS = [0.0, 0.17, 0.34, 0.52, 0.72, 1.0]
FIT = 730             # size of the drawing's bounding box on the 1024 canvas
MASS_CENTER = 0.5     # 0 = center the bounding box, 1 = center the visual mass


def center(t):
    """Point on the center line; t runs from the outer end (0) to the center (1)."""
    r = R_OUT + (R_IN - R_OUT) * (t ** R_POW)
    a = math.radians(START_ANGLE) - t * TURNS * 2 * math.pi
    return CX + r * math.cos(a), CY - r * math.sin(a)


def width(t):
    return WIDTH_OUT + (WIDTH_IN - WIDTH_OUT) * (t ** W_POW)


def normal(t, eps=1e-4):
    x0, y0 = center(max(0.0, t - eps))
    x1, y1 = center(min(1.0, t + eps))
    dx, dy = x1 - x0, y1 - y0
    length = math.hypot(dx, dy) or 1.0
    return -dy / length, dx / length


def ribbon(t0, t1, cap_start=False, steps=220):
    """Closed outline of the ribbon between t0 and t1."""
    left, right = [], []
    n = max(8, int(steps * (t1 - t0)))
    for i in range(n + 1):
        t = t0 + (t1 - t0) * i / n
        x, y = center(t)
        nx, ny = normal(t)
        h = width(t) / 2
        left.append((x + nx * h, y + ny * h))
        right.append((x - nx * h, y - ny * h))
    pts = left + right[::-1]
    if cap_start:
        # Round cap at the outer end: half circle from the right edge back to the left edge.
        x, y = center(t0)
        nx, ny = normal(t0)
        h = width(t0) / 2
        a0 = math.atan2(-ny, -nx)
        for i in range(1, 32):
            a = a0 - math.pi * i / 32
            pts.append((x + h * math.cos(a), y + h * math.sin(a)))
    return pts


def path_d(pts):
    return "M" + " L".join(f"{x:.2f},{y:.2f}" for x, y in pts) + " Z"


def centroid(polys):
    """Area-weighted center of the filled shapes (shoelace formula)."""
    A = cx = cy = 0.0
    for poly in polys:
        for (x0, y0), (x1, y1) in zip(poly, poly[1:] + poly[:1]):
            c = x0 * y1 - x1 * y0
            A += c
            cx += (x0 + x1) * c
            cy += (y0 + y1) * c
    return cx / (3 * A), cy / (3 * A)


def fit(polys):
    """Scales the drawing to FIT pixels across and centers it: halfway between
    its bounding box and its visual mass, so the long tail doesn't pull it off."""
    xs = [x for poly in polys for x, _ in poly]
    ys = [y for poly in polys for _, y in poly]
    w, h = max(xs) - min(xs), max(ys) - min(ys)
    k = FIT / max(w, h)
    mx, my = centroid(polys)
    bx, by = (max(xs) + min(xs)) / 2, (max(ys) + min(ys)) / 2
    cx, cy = bx + (mx - bx) * MASS_CENTER, by + (my - by) * MASS_CENTER
    return [[(CX + (x - cx) * k, CY + (y - cy) * k) for x, y in poly] for poly in polys]


def speed(t):
    """Center-line length per unit t."""
    a, b = max(0.0, t - 1e-3), min(1.0, t + 1e-3)
    x0, y0 = center(a)
    x1, y1 = center(b)
    return math.hypot(x1 - x0, y1 - y0) / (b - a)


def segment_bounds():
    out = []
    for k in range(len(COLORS)):
        a, b = SPLITS[k], SPLITS[k + 1]
        if a > 0:
            a += (GAP * width(a) / 2) / speed(a)
        if b < 1:
            b -= (GAP * width(b) / 2) / speed(b)
        out.append((a, b))
    return out


def svg(paths):
    body = "\n".join(f'  <path d="{d}" fill="{c}"/>' for d, c in paths)
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{SIZE}" height="{SIZE}" '
            f'viewBox="0 0 {SIZE} {SIZE}">\n{body}\n</svg>\n')


def build():
    if os.path.exists(OUT):
        shutil.rmtree(OUT)
    os.makedirs(os.path.join(OUT, "Assets"))
    layers = []
    polys = fit([ribbon(a, b, cap_start=(k == 0)) for k, (a, b) in enumerate(segment_bounds())])
    for k, poly in enumerate(polys):
        name = f"segment-{k + 1}"
        d = path_d(poly)
        with open(os.path.join(OUT, "Assets", name + ".svg"), "w") as f:
            f.write(svg([(d, COLORS[k])]))
        layers.append({"image-name": name + ".svg", "name": name})
    doc = {
        "fill-specializations": [
            {"value": {"linear-gradient": ["srgb:1.00000,1.00000,1.00000,1.00000",
                                           "srgb:0.90196,0.91373,0.92941,1.00000"]}},
            {"appearance": "dark",
             "value": {"linear-gradient": ["srgb:0.20392,0.21176,0.23137,1.00000",
                                           "srgb:0.07843,0.08235,0.09412,1.00000"]}},
        ],
        "groups": [
            {
                "layers": layers,
                "shadow": {"kind": "layer-color", "opacity": 0.5},
                "translucency": {"enabled": True, "value": 0.25},
                "specular": True,
            }
        ],
        "supported-platforms": {"squares": ["macOS"]},
    }
    with open(os.path.join(OUT, "icon.json"), "w") as f:
        json.dump(doc, f, indent=2)
        f.write("\n")


def preview(dest):
    os.makedirs(dest, exist_ok=True)
    jobs = [("light-1024", "Default", 1024), ("dark-1024", "Dark", 1024),
            ("light-64", "Default", 64), ("light-32", "Default", 32), ("light-16", "Default", 16),
            ("dark-32", "Dark", 32)]
    for name, rendition, px in jobs:
        out = os.path.join(dest, f"{name}.png")
        subprocess.run([ICTOOL, OUT, "--export-image", "--output-file", out, "--platform", "macOS",
                        "--rendition", rendition, "--width", str(px), "--height", str(px), "--scale", "1"],
                       check=True, stdout=subprocess.DEVNULL)
        print(out)


if __name__ == "__main__":
    # Experiments: --set NAME=VALUE overrides a constant, --out DIR writes elsewhere.
    args = sys.argv[1:]
    while "--set" in args:
        i = args.index("--set")
        k, v = args[i + 1].split("=", 1)
        globals()[k] = json.loads(v)
        del args[i:i + 2]
    if "--out" in args:
        i = args.index("--out")
        OUT = args[i + 1]
        del args[i:i + 2]
    sys.argv = [sys.argv[0]] + args
    build()
    if "--preview" in sys.argv:
        i = sys.argv.index("--preview")
        dest = sys.argv[i + 1] if i + 1 < len(sys.argv) else os.path.join(ROOT, "build", "icon-preview")
        preview(dest)
