# Shared Fate 3D style study: the mage as "pixel-textured low poly".
#
# Low-poly geometry wrapped in one small pixel-art atlas (nearest filtering,
# a 25-colour palette taken from SoulArt.MAGE_* and Soul.COLOR_MAGE). Every
# texel is drawn by this file: robe folds, trim, the face, hair and the staff
# runes are texture, not geometry. A 1 cm inverted hull gives the sprites'
# dark outline. The rig is the WP11 mage contract plus hidden leg bones that
# plant the boots and four robe bones through which the knees and heels push
# the hem (smooth weights on the skirt, rigid elsewhere).
# Design notes and numbers: docs/style-study/mage_pixel.md.
#
# Command line (deterministic):
#     blender --background --factory-startup --python tools/blender/mage_styles/mage_pixel.py -- --root <repo>
#       [--blend <file>]   where to save the viewable .blend (default: <main checkout>/blender/mage_pixel.blend)
#       [--no-renders]     skip the preview renders
#       [--no-blend]       skip saving the .blend
#
# Writes
#     assets/3d/models/styles/mage_pixel.glb         model, rig, idle / walk / cast, atlas embedded
#     assets/3d/models/styles/mage_pixel_atlas.png   the atlas, for inspection
#     assets/3d/previews/styles/mage_pixel_*.png     front, side, back, walk, cast, iso, iso_pixelated
#
# Conventions (docs/3d-port-contracts.md section 10, docs/deviations/wp11.md):
# Blender +Z up, feet on z = 0, the mage faces +Y (glTF / Godot -Z after
# export_yup), right hand at +X. `Staff` has its origin at the grip and its
# shaft along local +Z (Godot +Y). Bones are rolled so local X is +X: a
# positive local-X rotation swings a hanging limb forward and tips an upright
# bone backward.

import bpy
import math
import os
import struct
import sys
import time
import zlib
from mathutils import Vector, Matrix, Euler

T_START = time.time()


def _options():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    opts = {"root": globals().get("SF_ROOT"), "blend": None, "renders": True, "save_blend": True}
    i = 0
    while i < len(argv):
        a = argv[i]
        if a in ("--root", "--blend"):
            opts[a[2:]] = argv[i + 1]
            i += 2
        elif a == "--no-renders":
            opts["renders"] = False
            i += 1
        elif a == "--no-blend":
            opts["save_blend"] = False
            i += 1
        else:
            raise SystemExit("mage_pixel.py: unknown argument %r" % a)
    return opts


OPTS = _options()
STYLE_DIR = globals().get("SF_STYLE_DIR") or os.path.dirname(os.path.abspath(__file__))
SF_DIR = os.path.dirname(STYLE_DIR)
SF_ROOT = os.path.abspath(OPTS["root"] or os.path.join(SF_DIR, os.pardir, os.pardir))
exec(open(os.path.join(SF_DIR, "sf_assets_common.py"), encoding="utf-8").read())

MODEL_DIR = os.path.join(SF_ROOT, "assets", "3d", "models", "styles")
PREVIEW_DIR = os.path.join(SF_ROOT, "assets", "3d", "previews", "styles")


def _main_checkout(root):
    """A worktree lives at <main>/.claude/worktrees/<name>; the .blend goes to <main>."""
    parts = os.path.normpath(root).split(os.sep)
    for i in range(len(parts) - 1):
        if parts[i] == ".claude" and parts[i + 1] == "worktrees":
            return os.sep.join(parts[:i])
    return root


BLEND_PATH = os.path.abspath(OPTS["blend"] or os.path.join(_main_checkout(SF_ROOT), "blender", "mage_pixel.blend"))

# --------------------------------------------------------------------------
# style constants
# --------------------------------------------------------------------------

DENSITY = 32.0        # texels per metre on every surface (2 screen px per texel in the game camera)
OUTLINE_W = 0.010     # inverted-hull outline, metres
ATLAS_WIDTH = 128
PAD = 1               # texels of edge extrusion around every region

ANIM_FPS = 60
IDLE_FRAMES, WALK_FRAMES, CAST_FRAMES = 120, 60, 60
WALK_PREVIEW_FRAME = 18   # phase 0.30: both feet planted, widest stride
CAST_PREVIEW_FRAME = 38   # t = 0.63 s, the thrust
TAU = 2.0 * math.pi

# Palette: SoulArt.MAGE_* and Soul.COLOR_MAGE (sRGB, as 8-bit hex) plus the
# shades the 2D placeholder does not need. Nothing outside this list is drawn.
PALETTE = [
    ("OUTLINE", "#120F14"),  # SoulArt.OUTLINE
    ("ROBE_D2", "#28173F"),
    ("ROBE_D", "#3D2461"),   # MAGE_ROBE_DARK
    ("ROBE", "#5C388C"),     # MAGE_ROBE
    ("ROBE_L", "#7A52AE"),
    ("TRIM", "#9E7AD1"),     # MAGE_ROBE_TRIM
    ("HOOD", "#4D2E7A"),     # MAGE_HAT
    ("HOOD_L", "#664299"),   # MAGE_HAT_LIGHT
    ("SHADOW", "#2E1F38"),   # MAGE_EYE: eyes and the shadow under the hood
    ("GREY_D", "#45454F"),
    ("GREY", "#6E6E78"),     # the WP1 mage grey
    ("GREY_L", "#9494A0"),
    ("GOLD_D", "#9A7630"),
    ("GOLD", "#D9B352"),     # MAGE_BAND
    ("GOLD_L", "#FFEB8C"),   # MAGE_STAR
    ("SKIN_D", "#B39A88"),
    ("SKIN", "#DBC2AD"),     # MAGE_SKIN
    ("HAIR_D", "#9898A6"),
    ("HAIR", "#C7C7D1"),     # MAGE_HAIR
    ("WOOD_D", "#4F4A59"),
    ("WOOD", "#6E6878"),     # near the WP1 staff grey
    ("WOOD_L", "#8E889A"),
    ("CRYS_D", "#8C66CC"),
    ("CRYS", "#CC9EFF"),     # Soul.COLOR_MAGE
    ("CRYS_L", "#F0E4FF"),
]
PAL_INDEX = {k: i for i, (k, _) in enumerate(PALETTE)}
PAL_RGB = {k: tuple(int(h[i:i + 2], 16) for i in (1, 3, 5)) for k, h in PALETTE}

MAT_ATLAS, MAT_GLOW, MAT_OUTLINE = 0, 1, 2

BAYER4 = ((0, 8, 2, 10), (12, 4, 14, 6), (3, 11, 1, 9), (15, 7, 13, 5))


def dith(x, y, level):
    """Ordered 4x4 dither: True on `level` (0..1) of the texels."""
    return BAYER4[y % 4][x % 4] < level * 16.0


def hsh(*vals):
    """Deterministic hash of small integers -> [0, 1)."""
    h = 2166136261
    for v in vals:
        h = ((h ^ (int(v) & 0xFFFFFFFF)) * 16777619) & 0xFFFFFFFF
    h ^= h >> 13
    h = (h * 0x5BD1E995) & 0xFFFFFFFF
    return (h ^ (h >> 15)) / 4294967296.0


# --------------------------------------------------------------------------
# atlas regions: every part owns a rectangle sized from its surface at DENSITY
# --------------------------------------------------------------------------

class Region:
    def __init__(self, name, w, h, paint, meta):
        self.name, self.w, self.h, self.paint, self.meta = name, int(w), int(h), paint, meta
        self.x = self.y = None


REGIONS = {}


def region(name, w, h, paint, **meta):
    """Register a region once; parts on both sides share it (same size)."""
    r = REGIONS.get(name)
    if r is None:
        r = REGIONS[name] = Region(name, w, h, paint, meta)
    elif (r.w, r.h) != (int(w), int(h)):
        raise RuntimeError("region %s reused with size %sx%s, was %sx%s" % (name, w, h, r.w, r.h))
    return r


def swatch_uv(key):
    return ("SW", PAL_INDEX[key] + 0.5, 0.5)


def pack_regions():
    """Skyline bottom-left packing into ATLAS_WIDTH columns; height is a power of two."""
    sky = [0] * ATLAS_WIDTH
    for r in sorted(REGIONS.values(), key=lambda r: (-r.h, -r.w, r.name)):
        w, h = r.w + 2 * PAD, r.h + 2 * PAD
        best = None
        for x in range(0, ATLAS_WIDTH - w + 1):
            y = max(sky[x:x + w])
            if best is None or y < best[1]:
                best = (x, y)
        x, y = best
        for i in range(x, x + w):
            sky[i] = y + h
        r.x, r.y = x + PAD, y + PAD
    used = max(sky)
    height = 16
    while height < used:
        height *= 2
    return ATLAS_WIDTH, height


class Painter:
    """Draws palette keys into one region of the atlas canvas (local coordinates)."""

    def __init__(self, canvas, reg):
        self.c, self.r = canvas, reg

    def put(self, x, y, key):
        if key is not None and 0 <= x < self.r.w and 0 <= y < self.r.h:
            self.c[self.r.y + y][self.r.x + x] = key

    def fill(self, key):
        for y in range(self.r.h):
            for x in range(self.r.w):
                self.put(x, y, key)


def lathe_phi(reg, col):
    """Angle (radians, 0 = front, + toward +X) at the centre of texel column `col`."""
    m = reg.meta
    if m["mirror"]:
        return (col + 0.5) / reg.w * math.pi
    return -math.pi + (col + 0.5) / reg.w * TAU


def lathe_z(reg, row):
    """Profile height at the centre of texel row `row`."""
    prof = reg.meta["prof"]
    v = row + 0.5
    for (v0, z0), (v1, z1) in zip(prof, prof[1:]):
        if v0 <= v <= v1 and v1 > v0:
            return z0 + (z1 - z0) * (v - v0) / (v1 - v0)
    return prof[-1][1] if v > prof[-1][0] else prof[0][1]


def nearest_row(reg, z):
    return min(range(reg.h), key=lambda row: abs(lathe_z(reg, row) - z))


# --------------------------------------------------------------------------
# mesh builder: vertices with bone weights, faces with atlas UVs
# --------------------------------------------------------------------------

def newell(pts):
    n = Vector((0.0, 0.0, 0.0))
    for a, b in zip(pts, pts[1:] + pts[:1]):
        n.x += (a.y - b.y) * (a.z + b.z)
        n.y += (a.z - b.z) * (a.x + b.x)
        n.z += (a.x - b.x) * (a.y + b.y)
    return n


class Builder:
    def __init__(self):
        self.co, self.wt, self.faces, self.hulls = [], [], [], []

    def vert(self, p, weights):
        w = weights(p) if callable(weights) else ({weights: 1.0} if weights else {})
        self.co.append(Vector(p))
        self.wt.append(w)
        return len(self.co) - 1

    def face(self, idx, uvs, mat, hint=None):
        idx, uvs = list(idx), list(uvs)
        if hint is not None and newell([self.co[i] for i in idx]).dot(hint) < 0.0:
            idx.reverse()
            uvs.reverse()
        self.faces.append([idx, uvs, mat])

    def outline(self, start):
        """Give faces[start:] an inverted hull (built at the end)."""
        self.hulls.append((start, len(self.faces)))

    def build_hulls(self):
        for start, end in self.hulls:
            part = self.faces[start:end]
            normals = {}
            for idx, _, _ in part:
                n = newell([self.co[i] for i in idx])
                for i in idx:
                    normals[i] = normals.get(i, Vector((0.0, 0.0, 0.0))) + n
            remap = {}
            for i in sorted(normals):
                n = normals[i].normalized() if normals[i].length > 1e-9 else Vector((0, 0, 1))
                remap[i] = len(self.co)
                p = self.co[i] + n * OUTLINE_W
                if self.co[i].z >= 0.0 > p.z:
                    p.z = self.co[i].z          # the soles' outline stays on the floor
                self.co.append(p)
                self.wt.append(dict(self.wt[i]))
            for idx, _, _ in part:
                hull = [remap[i] for i in reversed(idx)]
                self.faces.append([hull, [swatch_uv("OUTLINE")] * len(hull), MAT_OUTLINE])

    def tri_count(self):
        return sum(len(f[0]) - 2 for f in self.faces)


def frame_along(origin, direction, front):
    """Local frame at `origin` whose +Z runs along `direction` and +Y toward `front`."""
    z = Vector(direction).normalized()
    y = Vector(front)
    y = (y - z * y.dot(z)).normalized()
    x = y.cross(z)
    m = Matrix((x, y, z)).transposed().to_4x4()
    m.translation = Vector(origin)
    return m


def lathe(b, reg_name, paint, rings, seg, weights, mirror=False, frame=None, apex=None,
          apex_first=False, v_rows=None, width=None, cap0=None, cap1=None, mat=MAT_ATLAS,
          outline=True):
    """Surface of revolution. `rings` are (z, rx, ry, cy) in the local frame
    (z along the axis, y toward the front), in texture order: the first ring is
    texel row 0. Columns follow the angle; `mirror` maps both halves onto one
    half-width strip (front centre at column 0, back centre at the right edge).
    Otherwise the seam is the back vertex and the front centre falls on the
    column boundary W / 2 (use an odd `seg` so a face, not an edge, is in front).
    `apex` = (z, cy) closes the surface to a point; `cap0` / `cap1` close ring 0
    / the last ring with a flat fan in one palette colour."""
    frame = frame if frame is not None else Matrix.Identity(4)
    if mirror and seg % 2:
        raise RuntimeError("%s: a mirrored lathe needs an even segment count" % reg_name)
    pts = [(z, (rx + ry) * 0.5, cy) for z, rx, ry, cy in rings]
    if apex is not None:
        ap = (apex[0], 0.0, apex[1])
        pts = [ap] + pts if apex_first else pts + [ap]
    if v_rows is None:
        acc = [0.0]
        for p, q in zip(pts, pts[1:]):
            acc.append(acc[-1] + math.sqrt(sum((q[i] - p[i]) ** 2 for i in range(3))))
        h = max(1, int(round(acc[-1] * DENSITY)))
        v_rows = [a / acc[-1] * h for a in acc]
    if len(v_rows) != len(pts):
        raise RuntimeError("%s: %d v rows for %d profile points" % (reg_name, len(v_rows), len(pts)))
    if width is None:
        circ = max(math.pi * (rx + ry) for _, rx, ry, _ in rings)
        width = max(2, int(round(circ * DENSITY / (2.0 if mirror else 1.0))))
        width += width % 2
    reg = region(reg_name, width, int(round(v_rows[-1])), paint, mirror=mirror,
                 prof=[(v, p[0]) for v, p in zip(v_rows, pts)])
    W = reg.w
    ring_v = v_rows[1:] if (apex is not None and apex_first) else v_rows[:len(rings)]
    phis = [-math.pi + j * TAU / seg for j in range(seg)]

    def u_of(j):
        if mirror:
            return abs(-math.pi + j * TAU / seg) / math.pi * W
        return j / float(seg) * W

    ids = []
    for z, rx, ry, cy in rings:
        ids.append([b.vert(frame @ Vector((rx * math.sin(p), cy + ry * math.cos(p), z)), weights)
                    for p in phis])
    raw = []   # (idx, uvs), all wound the same way round the surface
    score = 0.0   # orientation from the radial direction of the side quads, applied to all
    for i in range(len(rings) - 1):
        axis = frame @ Vector((0.0, (rings[i][3] + rings[i + 1][3]) * 0.5,
                               (rings[i][0] + rings[i + 1][0]) * 0.5))
        for j in range(seg):
            jn = (j + 1) % seg
            idx = [ids[i][j], ids[i][jn], ids[i + 1][jn], ids[i + 1][j]]
            pts3 = [b.co[k] for k in idx]
            score += newell(pts3).dot(sum(pts3, Vector()) / 4.0 - axis)
            raw.append((idx, [(reg_name, u_of(j), ring_v[i]), (reg_name, u_of(j + 1), ring_v[i]),
                              (reg_name, u_of(j + 1), ring_v[i + 1]), (reg_name, u_of(j), ring_v[i + 1])]))
    if apex is not None:
        za, cya = apex
        a = b.vert(frame @ Vector((0.0, cya, za)), weights)
        va = v_rows[0] if apex_first else v_rows[-1]
        ring = ids[0] if apex_first else ids[-1]
        rv = ring_v[0] if apex_first else ring_v[-1]
        for j in range(seg):
            jn = (j + 1) % seg
            um = (u_of(j) + u_of(j + 1)) * 0.5
            if apex_first:
                raw.append(([a, ring[jn], ring[j]],
                            [(reg_name, um, va), (reg_name, u_of(j + 1), rv), (reg_name, u_of(j), rv)]))
            else:
                raw.append(([ring[j], ring[jn], a],
                            [(reg_name, u_of(j), rv), (reg_name, u_of(j + 1), rv), (reg_name, um, va)]))
    for key, first in ((cap0, True), (cap1, False)):
        if key is None:
            continue
        z, rx, ry, cy = rings[0] if first else rings[-1]
        c = b.vert(frame @ Vector((0.0, cy, z)), weights)
        ring = ids[0] if first else ids[-1]
        for j in range(seg):
            jn = (j + 1) % seg
            tri = [c, ring[jn], ring[j]] if first else [ring[j], ring[jn], c]
            raw.append((tri, [swatch_uv(key)] * 3))
    flip = score < 0.0
    start = len(b.faces)
    for idx, uvs in raw:
        if flip:
            idx, uvs = idx[::-1], uvs[::-1]
        b.face(idx, uvs, mat)
    if outline:
        b.outline(start)
    return reg


# box faces as (outward axis, corners TL, TR, BR, BL seen from outside)
_BOX_FACES = [
    ((0, 1, 0), ((1, 1, 1), (-1, 1, 1), (-1, 1, -1), (1, 1, -1))),
    ((0, -1, 0), ((-1, -1, 1), (1, -1, 1), (1, -1, -1), (-1, -1, -1))),
    ((1, 0, 0), ((1, -1, 1), (1, 1, 1), (1, 1, -1), (1, -1, -1))),
    ((-1, 0, 0), ((-1, 1, 1), (-1, -1, 1), (-1, -1, -1), (-1, 1, -1))),
    ((0, 0, 1), ((-1, 1, 1), (1, 1, 1), (1, -1, 1), (-1, -1, 1))),
    ((0, 0, -1), ((-1, -1, -1), (1, -1, -1), (1, 1, -1), (-1, 1, -1))),
]


def box(b, reg_name, paint, center, size, weights, rw, rh, rot=None, mat=MAT_ATLAS, outline=True):
    """Box whose every face shows the whole `rw` x `rh` region, top row up."""
    reg = region(reg_name, rw, rh, paint)
    rot = rot if rot is not None else Matrix.Identity(3)
    c = Vector(center)
    ids = {}
    for sx in (-1, 1):
        for sy in (-1, 1):
            for sz in (-1, 1):
                p = c + rot @ Vector((sx * size[0] * 0.5, sy * size[1] * 0.5, sz * size[2] * 0.5))
                ids[(sx, sy, sz)] = b.vert(p, weights)
    start = len(b.faces)
    for axis, corners in _BOX_FACES:
        uvs = [(reg_name, 0, 0), (reg_name, reg.w, 0), (reg_name, reg.w, reg.h), (reg_name, 0, reg.h)]
        b.face([ids[k] for k in corners], uvs, mat, hint=rot @ Vector(axis))
    if outline:
        b.outline(start)
    return reg


def bipyramid(b, reg_name, paint, z_bottom, z_mid, z_top, radius, seg, mat, phase=0.0, outline=True):
    """Crystal: a ring of `seg` vertices between two apexes; one texel column per facet."""
    reg = region(reg_name, seg, 8, paint)
    ring = [b.vert((radius * math.sin(phase + j * TAU / seg), radius * math.cos(phase + j * TAU / seg), z_mid), None)
            for j in range(seg)]
    top = b.vert((0.0, 0.0, z_top), None)
    bot = b.vert((0.0, 0.0, z_bottom), None)
    centre = Vector((0.0, 0.0, z_mid))
    start = len(b.faces)
    for j in range(seg):
        jn = (j + 1) % seg
        for apex, v_apex in ((top, 0.0), (bot, 8.0)):
            idx = [ring[j], ring[jn], apex]
            uvs = [(reg_name, j, 4.0), (reg_name, j + 1, 4.0), (reg_name, j + 0.5, v_apex)]
            pts = [b.co[k] for k in idx]
            b.face(idx, uvs, mat, hint=sum(pts, Vector()) / 3.0 - centre)
    if outline:
        b.outline(start)
    return reg


# --------------------------------------------------------------------------
# painters (local texel coordinates, row 0 at the top of the region)
# --------------------------------------------------------------------------

def paint_skirt(P, r):
    W, H = r.w, r.h
    folds = [(int(W * 0.27), 0.30), (int(W * 0.47), 0.16), (int(W * 0.66), 0.34), (int(W * 0.86), 0.22)]
    for y in range(H):
        t = (y + 0.5) / H
        opening = 2 + int(t * 2.4)                      # grey under-robe widens toward the hem
        for x in range(W):
            k = "ROBE"
            if y == 0 or (y == 1 and x % 4 == 1):
                k = "ROBE_D"                             # under the sash
            if y >= H - 9 and (y >= H - 8 and (x + y) % 2 == 0 or x % 4 == 3):
                k = "ROBE_D"                             # one soft row into the hem shadow
            for fc, t0 in folds:                         # folds drift outward as they fall
                if t >= t0 and y < H - 7:
                    c = fc + int((t - t0) * 4.0)
                    if x == c:
                        k = "ROBE_D2" if t > 0.6 else "ROBE_D"
                    elif x == c - 1:
                        k = "ROBE_L"
            if x == W - 1 and t > 0.08:
                k = "ROBE_D"                             # back seam
            if x < opening:
                k = "GREY_D" if x == opening - 1 else ("GREY_L" if x == 0 and y % 7 == 3 else "GREY")
            elif x == opening:
                k = "TRIM"
            P.put(x, y, k)
    # hem band: piping, gold diamonds, piping, dark edge
    for x in range(W):
        P.put(x, H - 1, "ROBE_D2")
        P.put(x, H - 2, "TRIM")
        for dy, cols in ((3, (3,)), (4, (2, 4)), (5, (3,))):
            P.put(x, H - dy, "GOLD" if (x % 6) in cols else "ROBE_D")
        P.put(x, H - 6, "TRIM")
        P.put(x, H - 7, "ROBE_D")
    for x in range(0, 2 + int(2.4)):
        for dy in (1, 2):
            P.put(x, H - dy, "GREY_D")


def paint_torso(P, r):
    W, H = r.w, r.h
    for y in range(H):
        for x in range(W):
            k = "ROBE"
            if y < 3 or (y == 3 and (x + y) % 2 == 0):
                k = "ROBE_D"                             # under the mantle
            if y >= H - 2:
                k = "ROBE_D"
            if x in (int(W * 0.55), int(W * 0.55) + 1) and 4 <= y < H - 2:
                k = "ROBE_D" if x == int(W * 0.55) else "ROBE_L"   # crease under the arm
            if x < 2:
                k = "GREY"
            elif x == 2:
                k = "TRIM"
            P.put(x, y, k)


def paint_sash(P, r):
    rows = ("GOLD_D", "GOLD", "GOLD", "GOLD_D")
    for y in range(r.h):
        for x in range(r.w):
            k = rows[min(y, 3)]
            if y == 1 and x % 6 == 2:
                k = "GOLD_L"                             # glints, not a stripe
            if y == 2 and x % 6 == 5:
                k = "GOLD_D"                             # stitches
            P.put(x, y, k)
    for y in (1, 2):
        P.put(0, y, "CRYS")                              # clasp gem, 2 x 2 with the mirror
        P.put(1, y, "GOLD_D")


def paint_mantle(P, r):
    W = r.w
    rows = {0: "ROBE_D", 7: "TRIM", 8: "GOLD", 9: "ROBE_D2", 10: "ROBE_D2"}
    for y in range(r.h):
        for x in range(W):
            k = rows.get(y, "HOOD")
            if y == 1 or (y == 2 and (x + y) % 2 == 0):
                k = "HOOD_L"
            if y == 8 and x % 4 == 1:
                k = "GOLD_D"
            if y in (3, 4, 5, 6) and x % 8 == 5 and y >= 4:
                k = "ROBE_D"                             # fold where the mantle drapes
            P.put(x, y, k)
    for y in (1, 2, 3):                                  # brooch at the throat
        P.put(0, y, "CRYS" if y == 2 else "GOLD")
        P.put(1, y, "GOLD_D" if y != 2 else "GOLD")


# Face, drawn texel by texel like SoulArt. 12 columns centred on the front of
# the head (index 6 is the first column right of the centre line), row 3 is
# the eye row. l hood rim, S shadow, h hair, H dark hair, s skin, d skin shade,
# E eye, . leave the hood.
FACE_ROWS = (
    "...llllll...",
    "..lSSSSSSl..",
    ".lhhhsshhhl.",
    ".lhsEssEshl.",
    ".lhsssssshl.",
    ".lhhsddshhl.",
    "..hhsssshh..",
    "..HH....HH..",
)
FACE_KEYS = {"l": "TRIM", "S": "SHADOW", "h": "HAIR", "H": "HAIR_D", "s": "SKIN",
             "d": "SKIN_D", "E": "SHADOW"}
FACE_EYE_Z = 1.665


def paint_head(P, r):
    W, H = r.w, r.h
    for y in range(H):
        z = lathe_z(r, y)
        for x in range(W):
            phi = math.degrees(lathe_phi(r, x))
            k = "HOOD"
            if z > 1.83 or (z > 1.80 and (x + y) % 2 == 0):
                k = "HOOD_L"                             # the crown catches the light
            if z < 1.55 or (z < 1.58 and (x + y) % 2 == 0):
                k = "ROBE_D"                             # into the mantle
            if abs(phi) > 166.0 and z > 1.60:
                k = "ROBE_D"                             # seam down the back of the hood
            P.put(x, y, k)
    P.put(0, 0, "GOLD_L")
    for x in range(W):
        P.put(x, 0, "GOLD" if x % 2 else "GOLD_L")       # gold tip of the peak (the 2D hat star)
    eye = nearest_row(r, FACE_EYE_Z)
    c0 = W // 2
    for dy, row in enumerate(FACE_ROWS):
        for i, ch in enumerate(row):
            if ch != ".":
                P.put(c0 - 6 + i, eye - 3 + dy, FACE_KEYS[ch])


def paint_sleeve_upper(P, r):
    for y in range(r.h):
        for x in range(r.w):
            k = "ROBE"
            if y < 2 or (y == 2 and dith(x, y, 0.5)):
                k = "ROBE_D"
            if x == r.w // 2 and y > 2:
                k = "ROBE_D"
            if x == r.w // 2 - 1 and y > 2:
                k = "ROBE_L"
            P.put(x, y, k)


def paint_sleeve_lower(P, r):
    H = r.h
    for y in range(H):
        for x in range(r.w):
            k = "ROBE"
            if y == 0:
                k = "ROBE_D"
            if x in (3, r.w // 2 + 3) and 1 <= y < H - 3:
                k = "ROBE_D"
            if x in (2, r.w // 2 + 2) and 2 <= y < H - 3:
                k = "ROBE_L"
            if y == H - 3:
                k = "TRIM"
            if y == H - 2:
                k = "GOLD"
            if y == H - 1:
                k = "GOLD_D"
            P.put(x, y, k)


def paint_rows(*rows):
    def paint(P, r):
        for y in range(r.h):
            for x in range(r.w):
                P.put(x, y, rows[min(y, len(rows) - 1)])
    return paint


def paint_tail(P, r):
    rows = ("GOLD", "GOLD", "GOLD_D", "GOLD", "GOLD", "GOLD_D", "GOLD_L")
    for y in range(r.h):
        for x in range(r.w):
            k = rows[min(y, len(rows) - 1)]
            if x == r.w - 1 and k == "GOLD":
                k = "GOLD_D"
            P.put(x, y, k)


def paint_staff_upper(P, r):
    shade = ("WOOD_L", "WOOD", "WOOD", "WOOD_D", "WOOD", "WOOD")
    glyphs = (((0, 0), (0, 1), (0, 2), (1, 1)), ((0, 0), (1, 1), (0, 2)),
              ((0, 0), (0, 1), (0, 2), (1, 0), (1, 2)), ((1, 0), (0, 1), (1, 2)))
    rune_rows = [y for y in range(r.h) if 0.24 <= lathe_z(r, y) <= 0.70]
    for y in range(r.h):
        z = lathe_z(r, y)
        for x in range(r.w):
            k = shade[x % 6]
            if z > 0.725:
                k = "GOLD_D"
            elif 0.14 <= z <= 0.19:
                k = "GOLD_L" if z > 0.17 else "GOLD"
            elif z < 0.14:
                k = "GREY_D" if (x + y) % 3 == 0 else "GREY"     # grip wrap
            P.put(x, y, k)
    if rune_rows:
        top = rune_rows[0]
        for g in range(len(rune_rows) // 4):
            cx = (g * 2) % 6
            for dx, dy in glyphs[g % len(glyphs)]:
                P.put((cx + dx) % 6, top + g * 4 + dy, "CRYS")


def paint_staff_lower(P, r):
    shade = ("WOOD_L", "WOOD", "WOOD", "WOOD_D", "WOOD", "WOOD")
    for y in range(r.h):
        z = lathe_z(r, y)
        for x in range(r.w):
            k = shade[x % 6]
            if z > -0.10:
                k = "GREY_D" if (x + y) % 3 == 0 else "GREY"     # grip wrap
            elif z > -0.15:
                k = "GOLD" if z > -0.13 else "GOLD_D"
            elif hsh(x, y, 7) > 0.93:
                k = "WOOD_D"                                     # grain
            P.put(x, y, k)


def paint_gold_ring(P, r):
    for y in range(r.h):
        for x in range(r.w):
            k = "GOLD_L" if y == 0 else ("GOLD_D" if y == r.h - 1 else "GOLD")
            if y not in (0, r.h - 1) and x % 3 == 2:
                k = "GOLD_D"
            P.put(x, y, k)


def paint_crystal(P, r):
    rows = ("CRYS_L", "CRYS_L", "CRYS", "CRYS", "CRYS", "CRYS", "CRYS_D", "CRYS_D")
    darker = {"CRYS_L": "CRYS", "CRYS": "CRYS_D", "CRYS_D": "CRYS_D"}
    for y in range(r.h):
        for x in range(r.w):
            k = rows[y]
            if x % 2:
                k = darker[k]
            P.put(x, y, k)
    P.put(0, 2, "CRYS_L")
    P.put(2, 5, "CRYS_L")


def paint_swatches(P, r):
    for key, i in PAL_INDEX.items():
        P.put(i, 0, key)


# --------------------------------------------------------------------------
# geometry (Blender space)
# --------------------------------------------------------------------------

HIP_Z = 0.95          # hip joints of the hidden legs
LEG_LEN = 0.95        # hip joint to sole
SASH_Z = 1.02
HEM_Z = 0.03
LEG_PULL = 0.34       # share of the hem the knee / heel push bones carry
GRIP = (0.26, 0.262, 1.068)
STAFF_TILT_X = 6.0    # degrees about X: the ferrule stands forward, like a walking staff
STAFF_TILT_Y = -6.0   # degrees about Y: and out to the side, 7 cm clear of the hem

# (bone, head, tail, parent, connected). The WP11 mage bones plus Leg_L / Leg_R:
# hidden legs under the robe that plant the feet and push the hem.
BONES = [
    ("Hips", (0.0, 0.0, 0.92), (0.0, 0.0, 1.02), None, False),
    ("Spine", (0.0, 0.0, 1.02), (0.0, 0.0, 1.50), "Hips", False),
    ("Head", (0.0, 0.0, 1.50), (0.0, 0.0, 1.95), "Spine", False),
    ("UpperArm_L", (-0.26, 0.0, 1.38), (-0.26, 0.0, 1.10), "Spine", False),
    ("LowerArm_L", (-0.26, 0.0, 1.10), (-0.26, 0.03, 0.88), "UpperArm_L", True),
    ("UpperArm_R", (0.26, 0.0, 1.38), (0.26, 0.0, 1.10), "Spine", False),
    ("LowerArm_R", (0.26, 0.0, 1.10), (0.26, 0.22, 1.075), "UpperArm_R", True),
    ("Robe", (0.0, 0.0, 1.02), (0.0, 0.0, 0.10), "Hips", False),
    ("Leg_L", (-0.11, 0.0, HIP_Z), (-0.11, 0.0, 0.0), "Hips", False),
    ("Leg_R", (0.11, 0.0, HIP_Z), (0.11, 0.0, 0.0), "Hips", False),
    # the cloth in front of each knee and behind each heel: pushed, never pulled
    ("RobeFront_L", (-0.11, 0.0, HIP_Z), (-0.11, 0.0, 0.05), "Hips", False),
    ("RobeFront_R", (0.11, 0.0, HIP_Z), (0.11, 0.0, 0.05), "Hips", False),
    ("RobeBack_L", (-0.11, 0.0, HIP_Z), (-0.11, 0.0, 0.05), "Hips", False),
    ("RobeBack_R", (0.11, 0.0, HIP_Z), (0.11, 0.0, 0.05), "Hips", False),
]


def _smooth01(a, b, v):
    u = min(1.0, max(0.0, (v - a) / (b - a)))
    return u * u * (3.0 - 2.0 * u)


def skirt_weights(p):
    """Smooth skin: the robe bone at the sash, up to LEG_PULL of the robe push
    bones at the hem, front cloth on RobeFront_*, back cloth on RobeBack_*,
    left / right by x. The pull fades toward the sides, which keeps the hem
    clear of the staff."""
    t = min(1.0, max(0.0, (SASH_Z - 0.02 - p.z) / (SASH_Z - 0.02 - HEM_Z)))
    k = LEG_PULL * t ** 1.4 * (1.0 - 0.8 * _smooth01(0.06, 0.46, abs(p.x)))
    right = _smooth01(-0.20, 0.20, p.x)
    front = _smooth01(-0.10, 0.10, p.y - 0.012)
    return {"Robe": 1.0 - k,
            "RobeFront_R": k * right * front, "RobeBack_R": k * right * (1.0 - front),
            "RobeFront_L": k * (1.0 - right) * front, "RobeBack_L": k * (1.0 - right) * (1.0 - front)}


def build_body():
    b = Builder()
    lathe(b, "skirt", paint_skirt, [
        (1.00, 0.250, 0.212, 0.0), (0.84, 0.285, 0.245, 0.0), (0.66, 0.322, 0.280, 0.005),
        (0.46, 0.360, 0.315, 0.010), (0.26, 0.395, 0.348, 0.012), (0.10, 0.425, 0.378, 0.012),
        (HEM_Z, 0.438, 0.390, 0.012)], 16, skirt_weights, mirror=True, cap1="ROBE_D2")
    lathe(b, "torso", paint_torso, [
        (1.34, 0.19, 0.165, 0.0), (1.18, 0.242, 0.205, 0.0), (1.00, 0.25, 0.212, 0.0)],
        16, "Spine", mirror=True)
    lathe(b, "sash", paint_sash, [
        (1.078, 0.250, 0.212, 0.0), (1.070, 0.270, 0.232, 0.0), (0.972, 0.274, 0.236, 0.0),
        (0.965, 0.252, 0.214, 0.0)], 16, "Spine", mirror=True, v_rows=[0, 1, 3, 4])
    lathe(b, "mantle", paint_mantle, [
        (1.52, 0.125, 0.120, 0.0), (1.47, 0.215, 0.195, 0.0), (1.39, 0.315, 0.272, 0.0),
        (1.295, 0.345, 0.295, 0.0), (1.285, 0.230, 0.200, 0.0)], 16, "Spine", mirror=True,
        v_rows=[0, 3, 6, 9, 11])
    lathe(b, "head", paint_head, [
        (1.935, 0.075, 0.075, -0.105), (1.885, 0.135, 0.145, -0.055), (1.805, 0.192, 0.205, -0.022),
        (1.705, 0.215, 0.228, -0.006), (1.605, 0.205, 0.218, 0.0), (1.525, 0.168, 0.176, 0.008),
        (1.445, 0.100, 0.100, 0.0)], 13, "Head", apex=(1.975, -0.175), apex_first=True, width=44)
    # sash knot and tails on the front left
    box(b, "knot", paint_rows("GOLD_L", "GOLD_D"), (-0.09, 0.238, 1.022), (0.075, 0.04, 0.07),
        "Spine", 2, 2, rot=rot_z(-18))
    box(b, "tail", paint_tail, (-0.072, 0.248, 0.885), (0.05, 0.016, 0.21), "Robe", 2, 7,
        rot=rot_z(-18) @ rot_y(7))
    box(b, "tail", paint_tail, (-0.118, 0.232, 0.905), (0.045, 0.016, 0.17), "Robe", 2, 7,
        rot=rot_z(-24) @ rot_y(-9))

    def arm(s):
        x = 0.26 * s
        up = side_bone("UpperArm", s)
        low = side_bone("LowerArm", s)
        lathe(b, "sleeve_up", paint_sleeve_upper, [   # starts under the mantle, not through it
            (0.05, 0.058, 0.058, 0.0), (0.16, 0.078, 0.078, 0.0), (0.30, 0.085, 0.085, 0.0)], 8, up,
            frame=frame_along((x, 0.0, 1.40), (0, 0, -1), (0, 1, 0)), width=18)
        if s > 0:   # staff arm: forearm forward, elbow bent
            fr = frame_along((x, -0.035, 1.105), (0, 1.0, -0.11), (0, 0, 1))
            hand = ((x, 0.262, 1.068), (0.072, 0.075, 0.085))
        else:       # free arm hangs
            fr = frame_along((x, -0.004, 1.13), (0, 0.035, -0.26), (0, 1, 0))
            hand = ((x, 0.035, 0.838), (0.072, 0.075, 0.072))
        lathe(b, "sleeve_low", paint_sleeve_lower, [
            (0.0, 0.078, 0.078, 0.0), (0.12, 0.090, 0.090, 0.0), (0.25, 0.114, 0.114, 0.0)], 8, low,
            frame=fr, width=22, cap0="ROBE_D", cap1="ROBE_D2")
        box(b, "hand", paint_rows("SKIN", "SKIN", "SKIN_D"), hand[0], hand[1], low, 3, 3)
        box(b, "boot", paint_rows("GREY_D", "SHADOW", "OUTLINE"), (0.11 * s, 0.045, 0.04),
            (0.11, 0.21, 0.08), side_bone("Leg", s), 4, 3)
    mirror_x(arm)
    return b


def build_staff():
    """Origin at the grip, shaft along local +Z; no skin, bone-parented later."""
    b = Builder()
    lathe(b, "staff_up", paint_staff_upper, [
        (0.76, 0.028, 0.028, 0.0), (0.40, 0.027, 0.027, 0.0), (0.10, 0.026, 0.026, 0.0)], 6, None, width=6)
    lathe(b, "staff_low", paint_staff_lower, [
        (0.10, 0.026, 0.026, 0.0), (-0.40, 0.024, 0.024, 0.0), (-0.97, 0.021, 0.021, 0.0)], 6, None, width=6)
    lathe(b, "ferrule", paint_gold_ring, [
        (-0.965, 0.031, 0.031, 0.0), (-1.035, 0.030, 0.030, 0.0), (-1.05, 0.018, 0.018, 0.0)], 6, None,
        width=6, v_rows=[0, 2, 3], cap1="GOLD_D")
    lathe(b, "crown", paint_gold_ring, [
        (0.845, 0.050, 0.050, 0.0), (0.805, 0.060, 0.060, 0.0), (0.76, 0.034, 0.034, 0.0),
        (0.735, 0.030, 0.030, 0.0)], 6, None, width=6, v_rows=[0, 1, 2, 3], cap0="GOLD_D")
    for n in range(3):
        a = math.radians(30 + 120 * n)
        box(b, "prong", paint_rows("GOLD_L", "GOLD", "GOLD", "GOLD_D"),
            (0.058 * math.sin(a), 0.058 * math.cos(a), 0.905), (0.016, 0.016, 0.14), None, 1, 4,
            rot=rot_z(-math.degrees(a)) @ rot_x(-14))
    bipyramid(b, "crystal", paint_crystal, 0.83, 0.945, 1.10, 0.066, 6, MAT_GLOW)
    return b


# --------------------------------------------------------------------------
# atlas image and materials
# --------------------------------------------------------------------------

def paint_atlas(tw, th):
    canvas = [["ROBE_D2"] * tw for _ in range(th)]
    for r in REGIONS.values():
        r.paint(Painter(canvas, r), r)
    for r in REGIONS.values():   # extrude the edges into the padding
        for p in range(1, PAD + 1):
            for y in range(r.y - p, r.y + r.h + p):
                for x in range(r.x - p, r.x + r.w + p):
                    if r.x <= x < r.x + r.w and r.y <= y < r.y + r.h:
                        continue
                    if 0 <= x < tw and 0 <= y < th:
                        sx = min(max(x, r.x), r.x + r.w - 1)
                        sy = min(max(y, r.y), r.y + r.h - 1)
                        canvas[y][x] = canvas[sy][sx]
    return canvas


def write_png(path, width, height, rgb_rows):
    """Plain 8-bit RGB PNG, no metadata: byte-identical for identical pixels."""
    raw = b"".join(b"\x00" + bytes(row) for row in rgb_rows)

    def chunk(tag, data):
        return (struct.pack(">I", len(data)) + tag + data
                + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))

    folder = os.path.dirname(path)
    if folder and not os.path.isdir(folder):
        os.makedirs(folder)
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n")
        f.write(chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)))
        f.write(chunk(b"IDAT", zlib.compress(raw, 9)))
        f.write(chunk(b"IEND", b""))


def canvas_rows(canvas):
    return [[c for key in row for c in PAL_RGB[key]] for row in canvas]


def atlas_material(name, image, emission=None):
    mat = bpy.data.materials.get(name) or bpy.data.materials.new(name)
    mat.use_nodes = True
    nt = mat.node_tree
    bsdf = _principled(mat)
    tex = next((n for n in nt.nodes if n.type == "TEX_IMAGE"), None) or nt.nodes.new("ShaderNodeTexImage")
    tex.image = image
    tex.interpolation = "Closest"      # exported as a NEAREST glTF sampler
    tex.location = (-400, 200)
    nt.links.new(tex.outputs[0], _socket(bsdf, "Base Color"))
    for ident, value in (("Roughness", 1.0), ("Metallic", 0.0)):
        _socket(bsdf, ident).default_value = value
    if emission is not None:
        nt.links.new(tex.outputs[0], _socket(bsdf, "Emission Color"))
        _socket(bsdf, "Emission Strength").default_value = emission
    mat.use_backface_culling = True
    mat.diffuse_color = srgb_to_linear("#5C388C")
    return mat


def outline_material():
    mat = make_material("Mage_Outline", PALETTE[0][1], roughness=1.0)
    mat.use_backface_culling = True    # the inverted hull shows only its far side
    return mat


def to_object(b, name, materials, skinned):
    tw, th = ATLAS_SIZE
    purge_object(name)
    me = bpy.data.meshes.new(name)
    me.from_pydata([tuple(p) for p in b.co], [], [f[0] for f in b.faces])
    uv = me.uv_layers.new(name="UVMap")
    for poly, (idx, uvs, mat) in zip(me.polygons, b.faces):
        poly.material_index = mat
        poly.use_smooth = False
        for li, (rn, lx, ly) in zip(poly.loop_indices, uvs):
            r = REGIONS[rn]
            uv.data[li].uv = ((r.x + lx) / tw, 1.0 - (r.y + ly) / th)
    for m in materials:
        me.materials.append(m)
    if me.validate(verbose=False):
        raise RuntimeError("%s: mesh validation changed the mesh" % name)
    if len(me.polygons) != len(b.faces):
        raise RuntimeError("%s: %d polygons for %d faces" % (name, len(me.polygons), len(b.faces)))
    ob = bpy.data.objects.new(name, me)
    if skinned:
        groups = {}
        for i, w in enumerate(b.wt):
            total = sum(w.values())
            if total <= 0.0:
                raise RuntimeError("%s: vertex %d has no bone" % (name, i))
            for bone, value in w.items():
                if value > 1e-6:
                    groups.setdefault(bone, []).append((i, value / total))
        for bone in sorted(groups):
            vg = ob.vertex_groups.new(name=bone)
            for i, value in groups[bone]:
                vg.add([i], value, "REPLACE")
    return ob


# --------------------------------------------------------------------------
# animation
# --------------------------------------------------------------------------

STRIDE_D = 0.84       # sole travel relative to the hips over one stance
DUTY = 0.6            # share of the cycle a foot is planted
LIFT = 0.09           # foot lift at mid-swing, hidden by the robe
BOB = 0.025           # hips drop at each heel strike


def leg_pose(forward, lift, hip_dz, hip_dy=0.0):
    """Leg angle and slide that put the sole `forward` metres ahead of its rest
    spot (relative to a hip moved by hip_dy / hip_dz) and `lift` above z = 0.
    The slide runs along the leg's rest axis, hidden inside the robe."""
    f = forward - hip_dy
    theta = math.asin(max(-0.99, min(0.99, f / LEG_LEN)))
    slide = HIP_Z + hip_dz - lift - LEG_LEN * math.cos(theta)
    return {"rot": (math.degrees(theta), 0.0, 0.0), "loc": (0.0, slide, 0.0)}


def robe_push(side, leg, lift=0.0):
    """The front cloth follows a leg swinging forward (and the knee rising in
    the swing), the back cloth a leg swinging back; soft-clamped at zero so the
    hand-over between them has no kink."""
    theta = leg["rot"][0]
    soft = math.sqrt(theta * theta + 16.0)
    return {"RobeFront_" + side: {"rot": (0.5 * (theta + soft) + 6.0 * lift / LIFT, 0.0, 0.0)},
            "RobeBack_" + side: {"rot": (0.5 * (theta - soft), 0.0, 0.0)}}


def foot_track(q):
    """(forward, lift) of a sole at leg phase q: planted and sweeping back at
    constant speed for DUTY of the cycle, then swinging forward."""
    if q < DUTY:
        return STRIDE_D * (0.5 - q / DUTY), 0.0
    s = (q - DUTY) / (1.0 - DUTY)
    return STRIDE_D * (-0.5 + (1.0 - math.cos(math.pi * s)) * 0.5), LIFT * math.sin(math.pi * s)


def pose_walk(p):
    """Right heel strikes at phase 0.25, the left at 0.75."""
    c = math.cos(TAU * (p - 0.25))
    s = math.sin(TAU * (p - 0.25))
    c2 = math.cos(2.0 * TAU * (p - 0.25))
    dz = -BOB * (0.5 + 0.5 * c2)
    f_r, l_r = foot_track((p - 0.25) % 1.0)
    f_l, l_l = foot_track((p - 0.75) % 1.0)
    leg_r, leg_l = leg_pose(f_r, l_r, dz), leg_pose(f_l, l_l, dz)
    pose = {
        "Hips": {"loc": (0.0, dz, 0.0)},
        "Leg_R": leg_r,
        "Leg_L": leg_l,
        # the skirt twists with the leading leg (a hanging bone: -Y twist brings +X forward),
        # trails a little and rolls once per stride
        "Robe": {"rot": (-2.5 - 1.5 * c2, -3.0 * c, 2.5 * s)},
        "Spine": {"rot": (-4.0, -5.0 * c, 0.0)},
        "Head": {"rot": (3.0, 3.0 * c, 0.0)},
        "UpperArm_L": {"rot": (4.0 + 18.0 * c, 0.0, 0.0)},
        "LowerArm_L": {"rot": (8.0 + 12.0 * max(0.0, c), 0.0, 0.0)},
        # the staff arm swings a little; the forearm counters so the staff stays upright
        "UpperArm_R": {"rot": (4.0 - 7.0 * c, 0.0, 0.0)},
        "LowerArm_R": {"rot": (-4.0 + 5.0 * c, 0.0, 0.0)},
    }
    pose.update(robe_push("R", leg_r, l_r))
    pose.update(robe_push("L", leg_l, l_l))
    return pose


def pose_idle(p):
    s = math.sin(TAU * p)
    c = math.cos(TAU * p)
    return {
        "Spine": {"loc": (0.0, -0.008 * (1.0 - c), 0.0), "rot": (0.6 * s, 0.0, 0.0)},
        "Head": {"rot": (1.5 * math.sin(TAU * p - 0.6), 2.0 * math.sin(TAU * p + 1.0), 0.0)},
        "UpperArm_L": {"rot": (2.5 * math.sin(TAU * p + 0.8), 0.0, 0.0)},
        "LowerArm_L": {"rot": (4.0 + 2.0 * math.sin(TAU * p + 1.3), 0.0, 0.0)},
        "UpperArm_R": {"rot": (1.5 * s, 0.0, 0.0)},
        "LowerArm_R": {"rot": (-1.5 * s + math.sin(TAU * p + 0.5), 0.0, 0.0)},
        "Robe": {"rot": (0.0, 0.0, 1.0 * s)},
    }


# Cast: raise the staff back over the head, gather, thrust it forward, hold,
# recover. Rotations in degrees (local X pitch, Y twist, Z roll); "hips" is
# (forward, down) in metres, the feet stay planted.
CAST_RAISE = {
    "UpperArm_R": (125, 0, -8), "LowerArm_R": (-75, 0, 0),
    "UpperArm_L": (45, 0, 10), "LowerArm_L": (55, 0, 0),
    "Spine": (7, -6, 0), "Head": (6, 4, 0), "Robe": (4, 0, 0), "hips": (-0.02, 0.0)}
CAST_GATHER = {
    "UpperArm_R": (138, 0, -6), "LowerArm_R": (-70, 0, 0),
    "UpperArm_L": (78, 0, -6), "LowerArm_L": (38, 0, 0),
    "Spine": (5, -10, 0), "Head": (4, 6, 0), "Robe": (5, 0, 2), "hips": (-0.03, 0.035)}
CAST_THRUST = {
    "UpperArm_R": (42, 0, -14), "LowerArm_R": (-88, 0, 0),
    "UpperArm_L": (-22, 0, 20), "LowerArm_L": (15, 0, 0),
    "Spine": (-12, 12, 0), "Head": (7, -8, 0), "Robe": (-9, 0, 0), "hips": (0.07, 0.04)}
CAST_HOLD = {
    "UpperArm_R": (48, 0, -12), "LowerArm_R": (-86, 0, 0),
    "UpperArm_L": (-16, 0, 16), "LowerArm_L": (18, 0, 0),
    "Spine": (-10, 10, 0), "Head": (6, -7, 0), "Robe": (-6, 0, 0), "hips": (0.06, 0.035)}
CAST_KEYS = [(0.00, {}, "smooth"), (0.26, CAST_RAISE, "smooth"), (0.50, CAST_GATHER, "smooth"),
             (0.62, CAST_THRUST, "snap"), (0.78, CAST_HOLD, "smooth"), (1.00, {}, "smooth")]
CAST_BONES = ("UpperArm_R", "LowerArm_R", "UpperArm_L", "LowerArm_L", "Spine", "Head", "Robe")


def _ease(kind, u):
    if kind == "snap":                    # fast out of the gather, settling into the thrust
        return 1.0 - (1.0 - u) ** 3
    return u * u * (3.0 - 2.0 * u)


def pose_cast(t):
    for (t0, a, _), (t1, b, kind) in zip(CAST_KEYS, CAST_KEYS[1:]):
        if t <= t1 or t1 == CAST_KEYS[-1][0]:
            u = _ease(kind, min(1.0, max(0.0, (t - t0) / (t1 - t0))))
            break

    def mix(key, rest):
        va, vb = a.get(key, rest), b.get(key, rest)
        return tuple(x + (y - x) * u for x, y in zip(va, vb))

    pose = {bone: {"rot": mix(bone, (0.0, 0.0, 0.0))} for bone in CAST_BONES}
    # the staff trembles while the spell gathers
    w = max(0.0, math.sin(math.pi * min(1.0, max(0.0, (t - 0.28) / 0.26))))
    rx, ry, rz = pose["UpperArm_R"]["rot"]
    pose["UpperArm_R"]["rot"] = (rx + 1.6 * w * math.sin(TAU * 14.0 * t), ry, rz)
    fwd, down = mix("hips", (0.0, 0.0))
    pose["Hips"] = {"loc": (0.0, -down, -fwd)}   # upright bone: local Y up, local Z backward
    pose["Leg_R"] = leg_pose(0.0, 0.0, -down, fwd)
    pose["Leg_L"] = leg_pose(0.0, 0.0, -down, fwd)
    pose.update(robe_push("R", pose["Leg_R"]))
    pose.update(robe_push("L", pose["Leg_L"]))
    return pose


def author_clip(armature, name, frames, sample, loop):
    """A plain action keyed on every frame from 0 to `frames` inclusive, linear.
    A looping clip's last key repeats phase 0; a one-shot samples t = 1."""
    old = bpy.data.actions.get(name)
    if old is not None:
        bpy.data.actions.remove(old)
    act = bpy.data.actions.new(name)
    act.use_fake_user = True
    if armature.animation_data is None:
        armature.animation_data_create()
    armature.animation_data.action = act
    names = {pb.name for pb in armature.pose.bones}
    for pb in armature.pose.bones:
        pb.rotation_mode = "QUATERNION"
    for frame in range(frames + 1):
        t = frame / float(frames)
        pose = sample(0.0 if (loop and frame == frames) else t)
        unknown = set(pose) - names
        if unknown:
            raise RuntimeError("%s: no bones %s" % (name, sorted(unknown)))
        for pb in armature.pose.bones:
            v = pose.get(pb.name, {})
            pb.rotation_quaternion = Euler(tuple(math.radians(a) for a in v.get("rot", (0, 0, 0))),
                                           "XYZ").to_quaternion()
            pb.location = v.get("loc", (0.0, 0.0, 0.0))
            pb.keyframe_insert("rotation_quaternion", frame=frame, group=pb.name)
            pb.keyframe_insert("location", frame=frame, group=pb.name)
    for fc in act.fcurves:
        for kp in fc.keyframe_points:
            kp.interpolation = "LINEAR"
    armature.animation_data.action = None
    reset_pose(armature)
    return act


def evaluated_bone_tail(armature, bone):
    dg = bpy.context.evaluated_depsgraph_get()
    ev = armature.evaluated_get(dg)
    return ev.matrix_world @ ev.pose.bones[bone].tail


def measure_walk(armature, walk):
    """Ground distance of one walk cycle, from the planted right sole."""
    scene = assets_scene()
    prev = enter_assets_scene()
    armature.animation_data.action = walk
    ys, zs = [], []
    for frame in range(WALK_FRAMES + 1):
        scene.frame_set(frame)
        tail = evaluated_bone_tail(armature, "Leg_R")
        ys.append(tail.y)
        zs.append(tail.z)
    f0 = int(round(0.25 * WALK_FRAMES))
    f1 = int(round((0.25 + DUTY) * WALK_FRAMES))
    sweep = ys[f0] - ys[f1]
    stride = sweep / DUTY
    planted = max(abs(zs[f]) for f in range(f0, f1 + 1))
    slide = max(abs((ys[f0] - ys[f]) - sweep * (f - f0) / (f1 - f0)) for f in range(f0, f1 + 1))
    armature.animation_data.action = None
    reset_pose(armature)
    scene.frame_set(0)
    restore_scene(prev)
    print("SF_PIXEL_WALK sweep=%.4f m over %.2f s stride_per_cycle=%.4f m clip=1.000 s "
          "reference_speed=%.3f m/s planted_height<=%.4f m planted_speed_error<=%.4f m lift=%.2f m"
          % (sweep, DUTY, stride, stride / 1.0, planted, slide, LIFT))
    return stride


def measure_stretch(body, armature, clips):
    """Worst length change of a textured skirt edge over each clip: how far the
    smooth skin stretches or shears the robe's texels."""
    robe = body.vertex_groups["Robe"].index
    skirt = {v.index for v in body.data.vertices if any(g.group == robe for g in v.groups)}
    edges = set()
    for poly in body.data.polygons:
        vs = list(poly.vertices)
        if poly.material_index == MAT_ATLAS and len(vs) == 4 and all(v in skirt for v in vs):
            for a, b in zip(vs, vs[1:] + vs[:1]):
                edges.add((min(a, b), max(a, b)))
    edges = sorted(edges)
    scene = assets_scene()
    prev = enter_assets_scene()

    def lengths():
        ev = body.evaluated_get(bpy.context.evaluated_depsgraph_get())
        me = ev.to_mesh()
        out = [(me.vertices[a].co - me.vertices[b].co).length for a, b in edges]
        ev.to_mesh_clear()
        return out

    armature.animation_data.action = None
    reset_pose(armature)
    scene.frame_set(0)
    bpy.context.view_layer.update()
    rest = lengths()
    worst = {}
    for act, frames in clips:
        armature.animation_data.action = act
        w = 0.0
        for frame in range(frames + 1):
            scene.frame_set(frame)
            w = max([w] + [abs(n / r - 1.0) for n, r in zip(lengths(), rest) if r > 1e-4])
        worst[act.name] = w
    armature.animation_data.action = None
    reset_pose(armature)
    scene.frame_set(0)
    restore_scene(prev)
    print("SF_PIXEL_STRETCH skirt_edges=%d %s" % (len(edges), " ".join(
        "%s<=%.1f%%" % (name, 100.0 * w) for name, w in worst.items())))
    return worst


# --------------------------------------------------------------------------
# renders
# --------------------------------------------------------------------------

RIG_COLLECTION = "SF_PixelRig"
GAME_AMBIENT = (0.193, 0.237, 0.342)       # arena Environment (0.5, 0.55, 0.65) x 0.9, linear
GAME_SUN_DIR = Vector((-0.287, 0.497, -0.819))   # arena Sun rotation (-55, 30, 0), Blender axes
GAME_SUN_STRENGTH = 1.3 * math.pi          # Godot energy 1.3 lights white to 1.3; Blender needs x pi
ISO_DIR = Vector((0.579, -0.579, 0.574))   # CameraRig3D boom (yaw 45, pitch -35) in Blender axes
ISO_PX_PER_M = 900.0 / 14.0                # game: 14 m ortho height on a 900 px window
ISO_RES = (864, 486)
ISO_FACING_DEG = -140.0                    # toward the camera, the staff clear of the face


def eval_bounds(objects):
    dg = bpy.context.evaluated_depsgraph_get()
    lo = Vector((1e9, 1e9, 1e9))
    hi = Vector((-1e9, -1e9, -1e9))
    for ob in objects:
        if ob.type != "MESH":
            continue
        ev = ob.evaluated_get(dg)
        me = ev.to_mesh()
        mw = ev.matrix_world
        for v in me.vertices:
            p = mw @ v.co
            for i in range(3):
                lo[i] = min(lo[i], p[i])
                hi[i] = max(hi[i], p[i])
        ev.to_mesh_clear()
    return lo, hi


def _render_settings(scene, res, samples, filter_px):
    engines = [e.identifier for e in bpy.types.RenderSettings.bl_rna.properties["engine"].enum_items]
    wanted = [e for e in engines if "EEVEE" in e and "NEXT" in e] + [e for e in engines if "EEVEE" in e]
    for engine in wanted:
        try:
            scene.render.engine = engine
            break
        except TypeError:
            continue
    eevee = getattr(scene, "eevee", None)
    if eevee is not None and hasattr(eevee, "taa_render_samples"):
        eevee.taa_render_samples = samples
    r = scene.render
    r.resolution_x, r.resolution_y = res
    r.resolution_percentage = 100
    r.film_transparent = False
    r.filter_size = filter_px
    r.dither_intensity = 0.0
    for prop in r.bl_rna.properties:
        if prop.identifier.startswith("use_stamp") and prop.type == "BOOLEAN" and not prop.is_readonly:
            setattr(r, prop.identifier, False)
    settings = r.image_settings
    if "PNG" in {i.identifier for i in settings.bl_rna.properties["file_format"].enum_items}:
        settings.file_format = "PNG"
    if "RGB" in {i.identifier for i in settings.bl_rna.properties["color_mode"].enum_items}:
        settings.color_mode = "RGB"
    settings.compression = 100
    try:
        scene.view_settings.view_transform = "Standard"
        scene.view_settings.look = "None"
    except TypeError:
        pass
    scene.view_settings.exposure = 0.0
    scene.view_settings.gamma = 1.0


def _world(scene, color, strength=1.0):
    world = bpy.data.worlds.get("SF_PixelWorld") or bpy.data.worlds.new("SF_PixelWorld")
    world.use_nodes = True
    for n in world.node_tree.nodes:
        if n.type == "BACKGROUND":
            n.inputs[0].default_value = (color[0], color[1], color[2], 1.0)
            n.inputs[1].default_value = strength
    scene.world = world


def _ground(rig, kind, centre):
    me = bpy.data.meshes.new("SF_PixelGround")
    size = 40.0
    me.from_pydata([(-size / 2, -size / 2, 0), (size / 2, -size / 2, 0), (size / 2, size / 2, 0),
                    (-size / 2, size / 2, 0)], [], [(0, 1, 2, 3)])
    uv = me.uv_layers.new(name="UVMap")
    for li, (u, v) in zip(me.polygons[0].loop_indices, ((0, 0), (10, 0), (10, 10), (0, 10))):
        uv.data[li].uv = (u, v)       # a 2 x 2 checker image: 2 m tiles
    if kind == "iso":
        img = bpy.data.images.get("SF_IsoChecker") or bpy.data.images.new("SF_IsoChecker", 2, 2)
        # a byte image stores sRGB values as they are: GroundTile_A / _B greens
        a = [int("4E7A3C"[i:i + 2], 16) / 255.0 for i in (0, 2, 4)] + [1.0]
        b = [int("5F8A46"[i:i + 2], 16) / 255.0 for i in (0, 2, 4)] + [1.0]
        img.pixels = a + b + b + a
        mat = bpy.data.materials.get("SF_IsoGround") or bpy.data.materials.new("SF_IsoGround")
        mat.use_nodes = True
        nt = mat.node_tree
        bsdf = _principled(mat)
        tex = next((n for n in nt.nodes if n.type == "TEX_IMAGE"), None) or nt.nodes.new("ShaderNodeTexImage")
        tex.image = img
        tex.interpolation = "Closest"
        nt.links.new(tex.outputs[0], _socket(bsdf, "Base Color"))
        _socket(bsdf, "Roughness").default_value = 1.0
    else:
        mat = make_material("SF_PixelPreviewGround", "#6B7A6B", roughness=1.0)
    me.materials.append(mat)
    ob = bpy.data.objects.new("SF_PixelGround", me)
    ob.location = (centre.x, centre.y, 0.0) if kind != "iso" else (0.0, 0.0, 0.0)
    rig.objects.link(ob)
    return ob


def _sun(rig, travel, strength):
    data = bpy.data.lights.new("SF_PixelSun", "SUN")
    data.energy = strength
    data.angle = math.radians(3.0)
    ob = bpy.data.objects.new("SF_PixelSun", data)
    rig.objects.link(ob)
    ob.rotation_euler = Vector(travel).normalized().to_track_quat("-Z", "Y").to_euler()
    return ob


def render_shot(path, objects, res=(600, 800), yaw_deg=35.0, elev_deg=16.0, iso=False,
                filter_px=0.7, samples=32, margin=1.12, lens=50.0, ortho_m=None):
    """Front-style previews: perspective like sf_assets_common.render_preview,
    but lit like the arena (a sun at 1.3 plus the arena's ambient), with the
    sun on the camera's side. `iso`: the game's orthographic camera and sun."""
    path = os.path.abspath(path)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    scene = assets_scene()
    prev = enter_assets_scene()
    rig = get_or_make_collection(RIG_COLLECTION, scene.collection)
    clear_collection(rig)
    bpy.context.view_layer.update()
    lo, hi = eval_bounds(objects)
    centre = (lo + hi) * 0.5
    size = hi - lo
    cam_data = bpy.data.cameras.new("SF_PixelCam")
    cam = bpy.data.objects.new("SF_PixelCam", cam_data)
    rig.objects.link(cam)
    cam_data.sensor_fit = "VERTICAL"
    if iso:
        cam_data.type = "ORTHO"
        cam_data.ortho_scale = ortho_m or res[1] / ISO_PX_PER_M
        cam_data.clip_start, cam_data.clip_end = 0.05, 200.0
        target = Vector((0.0, 0.0, 1.0))           # CameraRig3D.LOOK_AT_HEIGHT above the feet
        cam.location = target + ISO_DIR * 30.0
        look_at(cam, target)
        _sun(rig, GAME_SUN_DIR, GAME_SUN_STRENGTH)
    else:
        cam_data.lens = lens
        cam_data.sensor_height = 24.0
        height = max(size.z, 0.2)
        width = max(math.hypot(size.x, size.y), 0.2)
        half_v = math.atan(12.0 / lens)
        half_h = math.atan(math.tan(half_v) * res[0] / float(res[1]))
        dist = max(height * 0.5 / math.tan(half_v), width * 0.5 / math.tan(half_h)) * margin + width * 0.5
        yaw, elev = math.radians(yaw_deg), math.radians(elev_deg)
        cam.location = centre + Vector((math.sin(yaw) * math.cos(elev), math.cos(yaw) * math.cos(elev),
                                        math.sin(elev))) * dist
        look_at(cam, centre)
        az, el = math.radians(yaw_deg - 45.0), math.radians(50.0)
        _sun(rig, -Vector((math.sin(az) * math.cos(el), math.cos(az) * math.cos(el), math.sin(el))),
             GAME_SUN_STRENGTH)
    scene.camera = cam
    _ground(rig, "iso" if iso else "plain", centre)
    _world(scene, GAME_AMBIENT)
    _render_settings(scene, res, samples, filter_px)
    scene.render.filepath = path
    keep = {ob.name for ob in objects} | {ob.name for ob in rig.objects}
    hidden = [ob for ob in scene.objects if ob.name not in keep and not ob.hide_render]
    for ob in hidden:
        ob.hide_render = True
    try:
        bpy.ops.render.render(write_still=True, scene=scene.name)
    finally:
        for ob in hidden:
            ob.hide_render = False
    clear_collection(rig)
    restore_scene(prev)
    try:
        shown = os.path.relpath(path, SF_ROOT)
    except ValueError:            # another drive
        shown = path
    print("SF_PIXEL_RENDER %s %dx%d" % (shown, res[0], res[1]))
    return path


def upscale_nearest(src, dst, factor):
    """Blow a low-resolution render up by an integer factor without filtering."""
    img = bpy.data.images.load(src, check_existing=False)
    w, h = img.size
    px = img.pixels[:]
    rows = []
    for y in range(h - 1, -1, -1):                  # Blender rows start at the bottom
        row = []
        for x in range(w):
            i = (y * w + x) * 4
            rgb = [int(round(min(1.0, max(0.0, px[i + c])) * 255.0)) for c in range(3)]
            row.extend(rgb * factor)
        rows.extend([row] * factor)
    bpy.data.images.remove(img)
    write_png(dst, w * factor, h * factor, rows)
    os.remove(src)


def set_frame(armature, action, frame):
    scene = assets_scene()
    armature.animation_data.action = action
    scene.frame_set(frame)
    update_depsgraph()


# --------------------------------------------------------------------------
# assembly
# --------------------------------------------------------------------------

def clean_factory_scene(scene):
    """Background runs only: drop the factory startup scene (Cube, Light, Camera)."""
    if not bpy.app.background or bpy.data.filepath:
        return False
    for other in list(bpy.data.scenes):
        if other is scene:
            continue
        for ob in list(other.objects):
            if len(ob.users_scene) == 1:
                data = ob.data
                bpy.data.objects.remove(ob, do_unlink=True)
                if data is not None:
                    _purge_data(data)
        bpy.data.scenes.remove(other)
    return True


def view_rig_for_blend(coll, objects):
    """A camera, a sun and the walk on the timeline, so the saved file opens ready to view."""
    scene = assets_scene()
    view = get_or_make_collection("Mage_View", scene.collection)
    clear_collection(view)
    cam_data = bpy.data.cameras.new("Mage_ViewCam")
    cam_data.lens = 50.0
    cam = bpy.data.objects.new("Mage_ViewCam", cam_data)
    view.objects.link(cam)
    cam.location = (2.6, 3.7, 1.9)
    look_at(cam, Vector((0.0, 0.0, 1.0)))
    scene.camera = cam
    _sun(view, -Vector((0.3, 0.6, 0.75)), GAME_SUN_STRENGTH)
    _world(scene, GAME_AMBIENT)
    scene.frame_start, scene.frame_end = 0, WALK_FRAMES


def main():
    scene = assets_scene()
    prev = activate_scene(scene)
    if clean_factory_scene(scene):
        prev = None
    scene.render.fps = ANIM_FPS
    scene.render.fps_base = 1.0
    coll = model_collection("SF_MagePixel")

    body_b = build_body()
    staff_b = build_staff()
    region("SW", len(PALETTE), 1, paint_swatches)
    body_b.build_hulls()
    staff_b.build_hulls()
    global ATLAS_SIZE
    ATLAS_SIZE = pack_regions()
    tw, th = ATLAS_SIZE
    canvas = paint_atlas(tw, th)
    used = sorted({k for row in canvas for k in row})
    atlas_path = os.path.join(MODEL_DIR, "mage_pixel_atlas.png")
    write_png(atlas_path, tw, th, canvas_rows(canvas))
    print("SF_PIXEL_ATLAS %dx%d regions=%d colours=%d/%d fill=%.0f%%"
          % (tw, th, len(REGIONS), len(used), len(PALETTE),
             100.0 * sum((r.w + 2 * PAD) * (r.h + 2 * PAD) for r in REGIONS.values()) / (tw * th)))
    for r in sorted(REGIONS.values(), key=lambda r: r.name):
        print("SF_PIXEL_REGION %-10s %3dx%-3d at (%d, %d)" % (r.name, r.w, r.h, r.x, r.y))

    image = bpy.data.images.load(atlas_path, check_existing=False)
    image.name = "Mage_Atlas"
    image.pack()
    mats = [atlas_material("Mage_Atlas", image), atlas_material("Mage_Glow", image, emission=1.0),
            outline_material()]
    body = to_object(body_b, "Mage_Body", mats, skinned=True)
    staff = to_object(staff_b, "Staff", mats, skinned=False)

    armature = build_armature("Mage_Armature", BONES, coll)
    link(coll, body)
    skin_to_armature(body, armature)
    update_depsgraph()
    link(coll, staff)
    parent_to_bone(staff, armature, "LowerArm_R",
                   world=Matrix.LocRotScale(Vector(GRIP), Euler((math.radians(STAFF_TILT_X),
                                                                 math.radians(STAFF_TILT_Y), 0.0)), None))
    update_depsgraph()
    lo, hi = world_bounds([body])
    hand = add_empty("HandPoint", GRIP, collection=coll)
    parent_to_bone(hand, armature, "LowerArm_R")
    overhead = add_empty("OverheadAnchor", (0.0, 0.0, hi.z + 0.25), parent=armature, collection=coll)
    objects = [armature, body, staff, hand, overhead]
    update_depsgraph()

    idle = author_clip(armature, "idle", IDLE_FRAMES, pose_idle, loop=True)
    walk = author_clip(armature, "walk", WALK_FRAMES, pose_walk, loop=True)
    cast = author_clip(armature, "cast", CAST_FRAMES, pose_cast, loop=False)
    stride = measure_walk(armature, walk)
    measure_stretch(body, armature, [(idle, IDLE_FRAMES), (walk, WALK_FRAMES), (cast, CAST_FRAMES)])

    hull_tris = sum(len(f[0]) - 2 for f in body_b.faces if f[2] == MAT_OUTLINE)
    staff_hull = sum(len(f[0]) - 2 for f in staff_b.faces if f[2] == MAT_OUTLINE)
    print("SF_PIXEL_PART body=%d (outline %d) staff=%d (outline %d) total=%d size=(%.3f, %.3f, %.3f) "
          "base_z=%.3f overhead=%.3f"
          % (body_b.tri_count(), hull_tris, staff_b.tri_count(), staff_hull,
             body_b.tri_count() + staff_b.tri_count(), hi.x - lo.x, hi.y - lo.y, hi.z - lo.z, lo.z,
             hi.z + 0.25))
    print("SF_PIXEL_RIG bones=%s groups=%s actions=%s"
          % ([bn.name for bn in armature.data.bones], sorted(g.name for g in body.vertex_groups),
             [(a.name, tuple(a.frame_range)) for a in (idle, walk, cast)]))
    for ob in (staff, hand, overhead):
        print("SF_PIXEL_ATTACH %-14s parent=%s/%s at %s" % (ob.name, ob.parent.name, ob.parent_bone or "-",
                                                            tuple(round(v, 3) for v in ob.matrix_world.translation)))

    export_glb(objects, os.path.join(MODEL_DIR, "mage_pixel.glb"), root_name="Mage", animations=True)

    if OPTS["renders"]:
        meshes = [body, staff]
        # front three-quarter from the free-hand side: from the staff side the shaft covers the face
        render_shot(os.path.join(PREVIEW_DIR, "mage_pixel_front.png"), meshes, yaw_deg=-35.0)
        render_shot(os.path.join(PREVIEW_DIR, "mage_pixel_side.png"), meshes, yaw_deg=90.0)
        render_shot(os.path.join(PREVIEW_DIR, "mage_pixel_back.png"), meshes, yaw_deg=215.0)
        set_frame(armature, walk, WALK_PREVIEW_FRAME)
        render_shot(os.path.join(PREVIEW_DIR, "mage_pixel_walk.png"), meshes, yaw_deg=-70.0)
        set_frame(armature, cast, CAST_PREVIEW_FRAME)
        render_shot(os.path.join(PREVIEW_DIR, "mage_pixel_cast.png"), meshes, yaw_deg=60.0)
        set_frame(armature, idle, 0)
        armature.rotation_euler = (0.0, 0.0, math.radians(ISO_FACING_DEG))
        update_depsgraph()
        render_shot(os.path.join(PREVIEW_DIR, "mage_pixel_iso.png"), meshes, res=ISO_RES, iso=True,
                    filter_px=0.7, samples=32)
        low = os.path.join(PREVIEW_DIR, "_mage_pixel_iso_low.png")
        render_shot(low, meshes, res=(ISO_RES[0] // 2, ISO_RES[1] // 2), iso=True, filter_px=0.01, samples=1,
                    ortho_m=ISO_RES[1] / ISO_PX_PER_M)
        upscale_nearest(low, os.path.join(PREVIEW_DIR, "mage_pixel_iso_pixelated.png"), 2)
        armature.rotation_euler = (0.0, 0.0, 0.0)
        armature.animation_data.action = None
        reset_pose(armature)
        assets_scene().frame_set(0)
        update_depsgraph()

    if OPTS["save_blend"]:
        view_rig_for_blend(coll, objects)
        armature.animation_data.action = walk
        os.makedirs(os.path.dirname(BLEND_PATH), exist_ok=True)
        bpy.ops.wm.save_as_mainfile(filepath=BLEND_PATH, copy=True)
        print("SF_PIXEL_BLEND %s" % BLEND_PATH)
    restore_scene(prev)
    print("SF_PIXEL DONE stride_per_cycle=%.3f m in %.1f s" % (stride, time.time() - T_START))


ATLAS_SIZE = (ATLAS_WIDTH, ATLAS_WIDTH)
main()
