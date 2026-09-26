# Shared Fate 3D style study: the mage as a cel-shaded toon character.
#
# Command line (the only supported path; deterministic, ~1 min):
#     blender --background --factory-startup --python tools/blender/mage_styles/mage_toon.py -- --root <repo>
#     optional: --blend <file.blend>   (default: <main checkout>/blender/mage_toon.blend)
#               --no-renders           (model, glb and .blend only)
#
# Writes
#     assets/3d/models/styles/mage_toon.glb        (ordinary materials, no outline)
#     assets/3d/previews/styles/mage_toon_{front,side,back,walk,cast}.png
#     <main checkout>/blender/mage_toon.blend      (toon shading and outline visible)
#
# Style: mid-poly shapes with smooth normals (lathes and lofts, not boxes), big
# flat colour regions, two/three hard light bands and a dark inverted-hull ink
# line. The look lives in the materials: in Blender a Diffuse BSDF feeds Shader
# to RGB and a constant Color Ramp (the bands), times the albedo, plus a rim
# band, out through an Emission shader; the outline is a Solidify modifier with
# flipped normals and a black backface-culled material. The glb carries plain
# Principled materials instead (the node trees are relinked for the export and
# the Solidify is switched off); `scripts/3d/toon_materials_3d.gd` swaps in the
# Godot toon shaders by material name. The band constants below are the same
# numbers as the defaults in `shaders/3d/toon.gdshader`.
#
# Conventions and rig contract as `tools/blender/generate_characters.py`: 1 unit
# = 1 m, +Z up, feet on z = 0, facing Blender +Y (Godot -Z after export), right
# hand at +X. Bones `Hips`, `Spine`, `Head`, `UpperArm_L/R`, `LowerArm_L/R`,
# `Robe` plus `Hood`, `Sleeve_L/R`, `RobeFront_L/R`, `RobeBack`; `HandPoint` and
# `Staff` bone-parented to `LowerArm_R`, `OverheadAnchor` on the armature.
# Skinning is smooth: every vertex gets up to four procedural weights.

import bpy
import bmesh
import math
import os
import sys
import time
from mathutils import Vector, Matrix, Euler

T_START = time.time()


def _sf_paths():
    here = globals().get("SF_DIR")
    if not here:
        here = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), os.pardir))
    root = globals().get("SF_ROOT")
    if not root:
        argv = sys.argv
        if "--root" in argv:
            root = argv[argv.index("--root") + 1]
        else:
            root = os.path.abspath(os.path.join(here, os.pardir, os.pardir))
    return here, os.path.abspath(root)


def _arg(name, default=None):
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    if name in argv:
        i = argv.index(name)
        return argv[i + 1] if i + 1 < len(argv) else True
    return default


SF_DIR, SF_ROOT = _sf_paths()
exec(open(os.path.join(SF_DIR, "sf_assets_common.py"), encoding="utf-8").read())

MODEL_PATH = os.path.join(SF_ROOT, "assets", "3d", "models", "styles", "mage_toon.glb")
PREVIEW_DIR = os.path.join(SF_ROOT, "assets", "3d", "previews", "styles")


def _default_blend():
    norm = SF_ROOT.replace("/", "\\")
    marker = "\\.claude\\worktrees\\"
    main = norm.split(marker)[0] if marker in norm else norm
    return os.path.join(main, "blender", "mage_toon.blend")


BLEND_PATH = _arg("--blend") or _default_blend()
DO_RENDERS = not _arg("--no-renders", False)

TAU = 2.0 * math.pi
ANIM_FPS = 60
IDLE_FRAMES = 120            # 2.0 s loop
WALK_FRAMES = 60             # 1.0 s loop
CAST_FRAMES = 60             # 1.0 s, not looping
WALK_PREVIEW_PHASE = 0.25    # right leg forward
CAST_PREVIEW_TIME = 0.62     # just after the thrust lands
OVERHEAD_CLEARANCE = 0.25

# --------------------------------------------------------------------------
# toon constants (same numbers as the uniforms in shaders/3d/toon.gdshader)
# --------------------------------------------------------------------------

BAND_SHADOW_THRESHOLD = 0.08     # N.L (times shadow) below this: shadow band
BAND_LIGHT_THRESHOLD = 0.62     # above this: full light; between: mid band
SHADOW_COLOR = (0.52, 0.46, 0.70)  # albedo multiplier in the shadow band (cool purple)
MID_MIX = 0.55                   # mid band = mix(shadow, 1, MID_MIX)
RIM_WIDTH = 0.22                 # 1 - N.V above 1 - RIM_WIDTH
RIM_STRENGTH = 0.28
RIM_COLOR = (1.0, 0.96, 1.0)
OUTLINE_HEX = "#140C1C"
OUTLINE_WIDTH_M = 0.011          # Blender shell thickness (Godot: pixels)

# Palette: the WP1/WP11 mage plus a boot, eye and gem colour.
PALETTE = [
    ("Mage_Robe", "#5C388C"),
    ("Mage_RobeDark", "#3D2461"),
    ("Mage_Trim", "#9E7AD1"),
    ("Mage_Hood", "#4D2E7A"),
    ("Mage_Visor", "#1E1426"),
    ("Mage_Skin", "#DBC2AD"),
    ("Mage_Band", "#D9B352"),
    ("Mage_Grey", "#6E6E78"),
    ("Mage_Hair", "#C7C7D1"),
    ("Mage_Boot", "#35303F"),
    ("Mage_Eye", "#2A1B36"),
    ("Mage_Gem", "#E4D6FF"),
]
GEM_EMISSION = ("#CC9EFF", 1.2)
(M_ROBE, M_ROBEDARK, M_TRIM, M_HOOD, M_VISOR, M_SKIN, M_BAND, M_GREY, M_HAIR,
 M_BOOT, M_EYE, M_GEM) = range(len(PALETTE))
BODY_MATS = list(range(M_GEM))              # everything but the gem
STAFF_MATS = [M_GREY, M_BAND, M_GEM, M_ROBEDARK]


def smoothstep(e0, e1, x):
    if e0 == e1:
        return 0.0 if x < e0 else 1.0
    t = min(1.0, max(0.0, (x - e0) / (e1 - e0)))
    return t * t * (3.0 - 2.0 * t)


def clamp01(x):
    return min(1.0, max(0.0, x))


def lerp(a, b, t):
    return a + (b - a) * t


# --------------------------------------------------------------------------
# materials: Principled for the export, toon node chain for the renders
# --------------------------------------------------------------------------

def _sock(sockets, ident):
    for s in sockets:
        if s.identifier == ident:
            return s
    for s in sockets:
        if s.name == ident:
            return s
    raise KeyError(ident)


def _vmath(nt, op, a, b, loc):
    n = nt.nodes.new("ShaderNodeVectorMath")
    n.operation = op
    n.location = loc
    nt.links.new(a, n.inputs[0])
    if isinstance(b, (tuple, list)):
        n.inputs[1].default_value = tuple(b[:3])
    else:
        nt.links.new(b, n.inputs[1])
    return n.outputs[0]


def _const_ramp(nt, stops, loc):
    """Constant Color Ramp: stops = [(position, (r, g, b)), ...]."""
    ramp = nt.nodes.new("ShaderNodeValToRGB")
    ramp.location = loc
    cr = ramp.color_ramp
    cr.interpolation = "CONSTANT"
    while len(cr.elements) > len(stops):
        cr.elements.remove(cr.elements[-1])
    while len(cr.elements) < len(stops):
        cr.elements.new(1.0)
    # new elements are appended at 1.0; assign in reverse so none collide
    for el, (pos, col) in reversed(list(zip(cr.elements, stops))):
        el.position = pos
        el.color = (col[0], col[1], col[2], 1.0)
    return ramp


def add_toon_nodes(mat, albedo_lin, emission_lin=None, emission_strength=0.0, rim=True):
    """Shader to RGB + constant ramp toon chain ending in an Emission node that
    the render uses; the Principled BSDF stays for the glTF export."""
    nt = mat.node_tree
    diffuse = nt.nodes.new("ShaderNodeBsdfDiffuse")
    diffuse.location = (-900, -300)
    _sock(diffuse.inputs, "Color").default_value = (1.0, 1.0, 1.0, 1.0)
    s2rgb = nt.nodes.new("ShaderNodeShaderToRGB")
    s2rgb.location = (-720, -300)
    nt.links.new(diffuse.outputs[0], s2rgb.inputs[0])
    bw = nt.nodes.new("ShaderNodeRGBToBW")
    bw.location = (-560, -300)
    nt.links.new(_sock(s2rgb.outputs, "Color"), bw.inputs[0])
    mid = tuple(lerp(SHADOW_COLOR[i], 1.0, MID_MIX) for i in range(3))
    bands = _const_ramp(nt, [(0.0, SHADOW_COLOR), (BAND_SHADOW_THRESHOLD, mid),
                             (BAND_LIGHT_THRESHOLD, (1.0, 1.0, 1.0))], (-400, -300))
    nt.links.new(bw.outputs[0], _sock(bands.inputs, "Fac"))
    colour = _vmath(nt, "MULTIPLY", _sock(bands.outputs, "Color"), albedo_lin, (-120, -300))
    if rim:
        lw = nt.nodes.new("ShaderNodeLayerWeight")
        lw.location = (-560, -600)
        _sock(lw.inputs, "Blend").default_value = 0.5
        rim_ramp = _const_ramp(nt, [(0.0, (0.0, 0.0, 0.0)), (1.0 - RIM_WIDTH, (1.0, 1.0, 1.0))],
                               (-400, -600))
        nt.links.new(_sock(lw.outputs, "Facing"), _sock(rim_ramp.inputs, "Fac"))
        lit = _const_ramp(nt, [(0.0, (0.0, 0.0, 0.0)), (BAND_SHADOW_THRESHOLD, (1.0, 1.0, 1.0))],
                          (-400, -850))
        nt.links.new(bw.outputs[0], _sock(lit.inputs, "Fac"))
        mask = _vmath(nt, "MULTIPLY", _sock(rim_ramp.outputs, "Color"),
                      _sock(lit.outputs, "Color"), (-120, -600))
        rim_col = _vmath(nt, "MULTIPLY", mask,
                         tuple(c * RIM_STRENGTH for c in RIM_COLOR), (40, -600))
        colour = _vmath(nt, "ADD", colour, rim_col, (200, -300))
    if emission_lin is not None and emission_strength > 0.0:
        colour = _vmath(nt, "ADD", colour,
                        tuple(c * emission_strength for c in emission_lin[:3]), (340, -300))
    em = nt.nodes.new("ShaderNodeEmission")
    em.location = (500, -300)
    em.name = "SF_ToonOut"
    nt.links.new(colour, _sock(em.inputs, "Color"))
    _sock(em.inputs, "Strength").default_value = 1.0
    set_toon(mat, True)


def _output(mat):
    return next(n for n in mat.node_tree.nodes if n.type == "OUTPUT_MATERIAL")


def set_toon(mat, on):
    """Route the material output to the toon chain (renders) or to the
    Principled BSDF (glTF export)."""
    nt = mat.node_tree
    out = _output(mat)
    src = None
    if on:
        src = nt.nodes.get("SF_ToonOut")
    if src is None:
        src = next((n for n in nt.nodes if n.type == "BSDF_PRINCIPLED"), None)
    if src is None:
        return
    for link in list(out.inputs[0].links):
        nt.links.remove(link)
    nt.links.new(src.outputs[0], out.inputs[0])


def build_materials():
    mats = []
    for name, hexcol in PALETTE:
        if name == "Mage_Gem":
            mat = make_material(name, hexcol, roughness=0.25, emission=GEM_EMISSION[0],
                                emission_strength=GEM_EMISSION[1])
            add_toon_nodes(mat, srgb_to_linear(hexcol), srgb_to_linear(GEM_EMISSION[0]),
                           GEM_EMISSION[1])
        else:
            mat = make_material(name, hexcol, roughness=0.8)
            add_toon_nodes(mat, srgb_to_linear(hexcol))
        mats.append(mat)
    return mats


def build_outline_material():
    mat = bpy.data.materials.get("Toon_Outline") or bpy.data.materials.new("Toon_Outline")
    mat.use_nodes = True
    nt = mat.node_tree
    for n in list(nt.nodes):
        if n.type != "OUTPUT_MATERIAL":
            nt.nodes.remove(n)
    em = nt.nodes.new("ShaderNodeEmission")
    _sock(em.inputs, "Color").default_value = srgb_to_linear(OUTLINE_HEX)
    nt.links.new(em.outputs[0], _output(mat).inputs[0])
    mat.use_backface_culling = True
    # The shell encloses the body: with culling in the shadow pass only its far
    # side casts, so it never shades the body it wraps.
    if hasattr(mat, "use_backface_culling_shadow"):
        mat.use_backface_culling_shadow = True
    mat.diffuse_color = srgb_to_linear(OUTLINE_HEX)
    return mat


# --------------------------------------------------------------------------
# mesh building: lofts over rings, with per-vertex smooth weights
# --------------------------------------------------------------------------

class Builder:
    def __init__(self):
        self.co = []
        self.w = []
        self.faces = []
        self.mats = []

    def vert(self, p, w):
        self.co.append(Vector(p))
        self.w.append(dict(w))
        return len(self.co) - 1

    def face(self, idx, m):
        self.faces.append(tuple(idx))
        self.mats.append(m)


def loft(b, rings, mat_fn, closed=False):
    """`rings`: list of rings, each either a pole (point, weights) or a list of
    (point, weights). Consecutive rings are joined by quads (or a fan at a
    pole); `closed` also joins the last ring to the first. `mat_fn(band, col)`
    gives each face its material."""
    ids = []
    for ring in rings:
        if isinstance(ring, tuple):
            ids.append(b.vert(ring[0], ring[1]))
        else:
            ids.append([b.vert(p, w) for p, w in ring])
    count = len(ids) if closed else len(ids) - 1
    for k in range(count):
        a = ids[k]
        c = ids[(k + 1) % len(ids)]
        if isinstance(a, int) and isinstance(c, int):
            continue
        if isinstance(a, int):
            n = len(c)
            for j in range(n):
                b.face((a, c[(j + 1) % n], c[j]), mat_fn(k, j))
        elif isinstance(c, int):
            n = len(a)
            for j in range(n):
                b.face((a[j], a[(j + 1) % n], c), mat_fn(k, j))
        else:
            n = len(a)
            for j in range(n):
                b.face((a[j], a[(j + 1) % n], c[(j + 1) % n], c[j]), mat_fn(k, j))
    return ids


def ellipsoid(b, center, radii, mat, weights, segs=12, rows=8):
    c = Vector(center)
    rings = [(c + Vector((0, 0, -radii[2])), weights)]
    for i in range(1, rows):
        lat = -math.pi / 2 + math.pi * i / rows
        ring = []
        for j in range(segs):
            a = TAU * j / segs
            p = c + Vector((radii[0] * math.cos(lat) * math.sin(a),
                            radii[1] * math.cos(lat) * math.cos(a),
                            radii[2] * math.sin(lat)))
            ring.append((p, weights))
        rings.append(ring)
    rings.append((c + Vector((0, 0, radii[2])), weights))
    loft(b, rings, lambda k, j: mat)


def tube_frame(t, ref):
    n1 = (ref - t * ref.dot(t))
    if n1.length < 1e-6:
        n1 = Vector((0, 1, 0)) - t * t.y
    n1.normalize()
    return n1, t.cross(n1).normalized()


def column_angles(h, tw, n_open, n_trim, n_rest):
    """Ring angles (0 = front, +X at 90 degrees) with column edges exactly on
    +/-h and +/-(h + tw), so an opening and its trim have clean borders."""
    out = []
    for i in range(n_open):
        out.append(-h + 2.0 * h * i / n_open)
    for i in range(n_trim):
        out.append(h + tw * i / n_trim)
    span = TAU - 2.0 * (h + tw)
    for i in range(n_rest):
        out.append(h + tw + span * i / n_rest)
    for i in range(n_trim):
        out.append(TAU - h - tw + tw * i / n_trim)
    return out


def limit_weights(w, n=4):
    items = sorted(((v, k) for k, v in w.items() if v > 1e-4), reverse=True)[:n]
    total = sum(v for v, _ in items) or 1.0
    return {k: v / total for v, k in items}


# ---- body parts ------------------------------------------------------------

SKIRT_TOP = 1.00
SKIRT_HEM = 0.035
SKIRT_ROWS = 13
SKIRT_OPEN, SKIRT_TRIM, SKIRT_REST = 4, 1, 30


def skirt_point(t, a):
    r = 0.200 + 0.235 * t ** 1.35
    ys = 0.80 + 0.12 * t
    rr = r * (1.0 + 0.075 * t ** 1.3 * math.cos(6.0 * a))
    z = SKIRT_TOP - (SKIRT_TOP - SKIRT_HEM) * t
    z += t ** 4 * (0.028 * (1.0 + math.cos(6.0 * a)) * 0.5 + 0.075 * max(0.0, math.cos(a)) ** 4)
    return Vector((rr * math.sin(a), rr * ys * math.cos(a), z))


def skirt_weights(p):
    t = clamp01((SKIRT_TOP - p.z) / (SKIRT_TOP - SKIRT_HEM))
    low = smoothstep(0.02, 0.45, t)
    az = math.atan2(p.x, p.y)
    k_r = 2.5 * max(0.0, math.cos(az - math.radians(28.0))) ** 4
    k_l = 2.5 * max(0.0, math.cos(az + math.radians(28.0))) ** 4
    k_b = max(0.0, -math.cos(az)) ** 2
    k_robe = 0.5
    s = k_r + k_l + k_b + k_robe
    return limit_weights({"Hips": 1.0 - low, "Robe": low * k_robe / s,
                          "RobeFront_R": low * k_r / s, "RobeFront_L": low * k_l / s,
                          "RobeBack": low * k_b / s})


def build_skirt(b):
    rings = []
    for i in range(SKIRT_ROWS):
        t = i / (SKIRT_ROWS - 1.0)
        angles = column_angles(math.radians(10.0 + 16.0 * t), math.radians(5.0),
                               SKIRT_OPEN, SKIRT_TRIM, SKIRT_REST)
        rings.append([(p, skirt_weights(p)) for p in (skirt_point(t, a) for a in angles)])
    inner = []
    for p, w in rings[-1]:
        q = Vector((p.x * 0.93, p.y * 0.93, p.z))
        inner.append((q, w))
    rings.append(inner)
    floor = Vector((0.0, 0.0, 0.30))
    rings.append((floor, skirt_weights(Vector((0.0, 0.0, 0.2)))))
    n_cols = SKIRT_OPEN + 2 * SKIRT_TRIM + SKIRT_REST

    def mat(k, j):
        if k >= SKIRT_ROWS - 1:
            return M_ROBEDARK                                  # rim and floor
        if j < SKIRT_OPEN:
            return M_GREY                                      # under-robe
        if j == SKIRT_OPEN or j == n_cols - 1:
            return M_TRIM                                      # opening edges
        if k == SKIRT_ROWS - 2:
            return M_TRIM                                      # hem band
        return M_ROBE
    loft(b, rings, mat)


def torso_weights(p):
    s = smoothstep(0.99, 1.14, p.z)
    return limit_weights({"Hips": 1.0 - s, "Spine": s})


def build_torso(b):
    profile = [(0.205, 0.975), (0.213, 1.06), (0.217, 1.16), (0.211, 1.25),
               (0.19, 1.33), (0.15, 1.40), (0.10, 1.46)]
    ys = 0.78
    angles = column_angles(math.radians(6.0), 0.0, 2, 0, 26)
    rings = [(Vector((0, 0, 0.985)), torso_weights(Vector((0, 0, 0.985))))]
    for r, z in profile:
        ring = []
        for a in angles:
            p = Vector((r * math.sin(a), r * ys * math.cos(a), z))
            ring.append((p, torso_weights(p)))
        rings.append(ring)
    rings.append((Vector((0, 0, 1.49)), torso_weights(Vector((0, 0, 1.49)))))
    loft(b, rings, lambda k, j: M_TRIM if j < 2 else M_ROBE)


def build_sash(b):
    profile = [(0.222, 0.955), (0.233, 0.975), (0.233, 1.035), (0.222, 1.055),
               (0.203, 1.055), (0.203, 0.955)]
    ys = 0.80
    rings = []
    for r, z in profile:
        ring = []
        for j in range(24):
            a = TAU * j / 24
            ring.append((Vector((r * math.sin(a), r * ys * math.cos(a), z)), {"Hips": 1.0}))
        rings.append(ring)
    loft(b, rings, lambda k, j: M_BAND, closed=True)
    # knot and two hanging tails at the front left
    ellipsoid(b, (-0.075, 0.192, 1.0), (0.042, 0.03, 0.036), M_BAND, {"Hips": 1.0},
              segs=10, rows=6)
    for x0, az0, length in ((-0.068, -20.0, 0.36), (-0.105, -30.0, 0.30)):
        pts = []
        steps = 6
        for i in range(steps + 1):
            u = i / float(steps)
            z = 0.985 - length * u
            t = clamp01((SKIRT_TOP - z) / (SKIRT_TOP - SKIRT_HEM))
            a = math.radians(az0 - 6.0 * u)
            surf = skirt_point(t, a)
            out = Vector((math.sin(a), math.cos(a), 0.0)) * (0.022 + 0.01 * u)
            pts.append(Vector((surf.x + out.x, surf.y + out.y, z)))
        rings = []
        for i, c in enumerate(pts):
            u = i / float(steps)
            t_dir = (pts[min(i + 1, steps)] - pts[max(i - 1, 0)]).normalized()
            n1, n2 = tube_frame(t_dir, Vector((1, 0, 0)))
            w = limit_weights({"Hips": 1.0 - u, "RobeFront_L": 0.65 * u, "Robe": 0.35 * u})
            ra, rb = 0.022 + 0.014 * u, 0.007
            ring = []
            for j in range(8):
                a = TAU * j / 8
                ring.append((c + n1 * (ra * math.cos(a)) + n2 * (rb * math.sin(a)), w))
            rings.append(ring)
        first_w = rings[0][0][1]
        last_w = rings[-1][0][1]
        rings = [(pts[0] + Vector((0, 0, 0.004)), first_w)] + rings + \
                [(pts[-1] - Vector((0, 0, 0.006)), last_w)]
        loft(b, rings, lambda k, j: M_BAND)


def build_mantle(b):
    outer = [(0.115, 1.49), (0.19, 1.45), (0.265, 1.375), (0.312, 1.29), (0.326, 1.235)]
    inner = [(0.302, 1.235), (0.25, 1.335), (0.17, 1.42), (0.10, 1.47)]
    ys = 0.86
    rings = []
    for r, z in outer + inner:
        f = smoothstep(1.34, 1.235, z)
        ring = []
        for j in range(30):
            a = TAU * j / 30
            lobe = math.cos(5.0 * (a - math.pi))
            rr = r * (1.0 + 0.045 * lobe * f)
            zz = z - 0.06 * f * max(0.0, lobe) ** 1.5
            ring.append((Vector((rr * math.sin(a), rr * ys * math.cos(a), zz)), {"Spine": 1.0}))
        rings.append(ring)
    loft(b, rings, lambda k, j: M_ROBEDARK, closed=True)
    ellipsoid(b, (0.0, 0.172, 1.425), (0.034, 0.022, 0.03), M_BAND, {"Spine": 1.0},
              segs=10, rows=6)                                          # clasp


HOOD_C = Vector((0.0, -0.015, 1.655))
HOOD_R = 0.205
HOOD_SCALE = (1.0, 1.06, 1.04)
HOOD_TIP = Vector((0.0, -0.55, 0.84)).normalized()
HOOD_THICKNESS = 0.028


def hood_weights(p):
    s = smoothstep(0.15, 0.34, (p - HOOD_C).dot(HOOD_TIP))
    return limit_weights({"Head": 1.0 - s, "Hood": s})


def build_hood(b):
    bm = bmesh.new()
    # The sphere's rings run around the face opening instead of around Z, so
    # the opening edge is exactly ring 0: an oval 42 degrees wide and 33 high
    # around an axis looking forward and a little down. Ring K is the back pole.
    axis = Vector((0.0, 1.0, -0.14)).normalized()
    side = Vector((1.0, 0.0, 0.0))
    up = side.cross(axis).normalized()
    rings_n, segs = 12, 24
    grid = []
    for k in range(rings_n + 1):
        row = []
        for j in range(1 if k == rings_n else segs):
            psi = TAU * j / segs
            half = 1.0 / math.sqrt((math.cos(psi) / math.radians(42.0)) ** 2 +
                                   (math.sin(psi) / math.radians(33.0)) ** 2)
            phi = half + (math.pi - half) * (k / float(rings_n)) ** 0.9
            d = axis * math.cos(phi) + (side * math.cos(psi) + up * math.sin(psi)) * math.sin(phi)
            p = HOOD_C + Vector((HOOD_R * HOOD_SCALE[0] * d.x, HOOD_R * HOOD_SCALE[1] * d.y,
                                 HOOD_R * HOOD_SCALE[2] * d.z))
            deg = math.degrees(math.asin(max(-1.0, min(1.0, d.z))))
            if deg < -10.0:                                     # cowl drapes out
                f = clamp01((-deg - 10.0) / 40.0)
                radial = Vector((d.x, d.y, 0.0))
                if radial.length > 1e-6:
                    p += radial.normalized() * 0.05 * f
            s = max(0.0, (d.dot(HOOD_TIP) - 0.30) / 0.70) ** 2.0
            p += HOOD_TIP * (0.21 * s) + Vector((0.0, -0.11, -0.05)) * s ** 3
            row.append(bm.verts.new(p))
        grid.append(row * segs if len(row) == 1 else row)
    for k in range(rings_n):
        for j in range(segs):
            quad = (grid[k][j], grid[k][(j + 1) % segs], grid[k + 1][(j + 1) % segs], grid[k + 1][j])
            bm.faces.new(tuple(dict.fromkeys(quad)))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    # outward normals: most faces must point away from the head centre
    out_score = sum((f.calc_center_median() - HOOD_C).dot(f.normal) for f in bm.faces)
    if out_score < 0:
        bmesh.ops.reverse_faces(bm, faces=bm.faces)
    old_faces = set(bm.faces)
    old_verts = set(bm.verts)
    old_mean = sum(((v.co - HOOD_C).length for v in old_verts), 0.0) / len(old_verts)
    bmesh.ops.solidify(bm, geom=list(bm.faces), thickness=HOOD_THICKNESS)
    new_verts = [v for v in bm.verts if v not in old_verts]
    new_mean = sum(((v.co - HOOD_C).length for v in new_verts), 0.0) / max(1, len(new_verts))
    new_is_inner = new_mean < old_mean
    for f in bm.faces:
        verts_new = [v not in old_verts for v in f.verts]
        if f in old_faces:
            f.material_index = M_HOOD if new_is_inner else M_VISOR
        elif all(verts_new):
            f.material_index = M_VISOR if new_is_inner else M_HOOD
        else:
            f.material_index = M_BAND                            # gold rim of the opening
    bm.verts.ensure_lookup_table()
    index = {}
    for v in bm.verts:
        index[v] = b.vert(v.co, hood_weights(v.co))
    for f in bm.faces:
        b.face([index[v] for v in f.verts], f.material_index)
    bm.free()


def build_head(b):
    head = {"Head": 1.0}
    ellipsoid(b, (0.0, 0.05, 1.612), (0.104, 0.098, 0.118), M_SKIN, head, segs=16, rows=10)
    for s in (-1.0, 1.0):
        ellipsoid(b, (0.040 * s, 0.143, 1.628), (0.016, 0.010, 0.024), M_EYE, head,
                  segs=8, rows=6)
        ellipsoid(b, (0.086 * s, 0.082, 1.545), (0.030, 0.036, 0.072), M_HAIR, head,
                  segs=8, rows=6)
    ellipsoid(b, (0.0, 0.112, 1.712), (0.088, 0.036, 0.030), M_HAIR, head, segs=12, rows=6)


# Arms: the bones lie in the x = +/-0.235 planes (the rig helper requires every
# bone's local X to be +X); the sleeves splay outward from them.
SHOULDER_Z = 1.38
ELBOW = {1: Vector((0.235, 0.0, 1.13)), -1: Vector((-0.235, 0.0, 1.13))}
WRIST = {1: Vector((0.235, 0.26, 1.07)), -1: Vector((-0.235, 0.105, 0.90))}
GRIP_R = Vector((0.272, 0.315, 1.058))                  # HandPoint and the staff origin
STAFF_TILT = (math.radians(8.0), math.radians(-5.0), 0.0)   # butt forward and out


def _side(base, s):
    return base + ("_R" if s > 0 else "_L")


def build_sleeve(b, s):
    up, lo, sl = _side("UpperArm", s), _side("LowerArm", s), _side("Sleeve", s)
    S = Vector((0.235 * s, 0.0, SHOULDER_Z + 0.015))
    E = ELBOW[s]
    W = WRIST[s]
    fdir = (W - E).normalized()
    udir = (E - S).normalized()
    cuff = W + fdir * 0.015
    # (centre, tangent, radius, droop, splay, weights-kind)
    spec = [
        (S, udir, 0.078, 0.0, 0.0, "shoulder"),
        (S.lerp(E, 0.5), udir, 0.088, 0.0, 0.01, "upper"),
        (E + (fdir - udir) * 0.012, (udir + fdir).normalized(), 0.098, 0.0, 0.02, "elbow"),
        (E.lerp(W, 0.45), fdir, 0.112, 0.025, 0.03, "lower"),
        (E.lerp(W, 0.82), fdir, 0.136, 0.065, 0.04, "bell"),
        (cuff, fdir, 0.156, 0.10, 0.045, "bell"),
        (cuff - fdir * 0.006, fdir, 0.138, 0.09, 0.045, "bell"),
        (W - fdir * 0.09, fdir, 0.088, 0.03, 0.035, "inner"),
    ]
    down = Vector((0.0, 0.0, -1.0))
    rings = []
    for c, t_dir, r, droop, splay, kind in spec:
        n1, n2 = tube_frame(t_dir, Vector((1.0, 0.0, 0.0)))
        centre = c + Vector((splay * s, 0.0, 0.0))
        ring = []
        for j in range(16):
            a = TAU * j / 16
            off = n1 * math.cos(a) + n2 * math.sin(a)
            p = centre + off * r
            hang = max(0.0, off.dot(down))
            p += down * (droop * hang)
            if kind == "shoulder":
                w = {up: 0.7, "Spine": 0.3}
            elif kind == "upper":
                w = {up: 1.0}
            elif kind == "elbow":
                w = {up: 0.5, lo: 0.5}
            elif kind == "lower":
                w = {lo: 1.0}
            else:
                share = (0.35 if kind == "inner" else 0.85) * hang + (0.15 if kind == "bell" else 0.0)
                w = {lo: 1.0 - share, sl: share}
            ring.append((p, limit_weights(w)))
        rings.append(ring)
    end = W - fdir * 0.11 + Vector((0.035 * s, 0.0, 0.0))
    rings.append((end, {lo: 1.0}))
    rings.insert(0, (S + udir * -0.03, {up: 0.6, "Spine": 0.4}))

    def mat(k, j):
        # band k joins ring k and k+1 (ring 0 is the shoulder pole)
        if k in (5, 6):
            return M_TRIM                                        # cuff band and lip
        if k >= 7:
            return M_VISOR                                       # inside the bell
        return M_ROBE
    loft(b, rings, mat)
    # hand
    hand = WRIST[s] + fdir * 0.045 + Vector((0.04 * s, 0.0, 0.0))
    if s > 0:
        hand = GRIP_R.copy()
        ellipsoid(b, hand, (0.046, 0.05, 0.048), M_SKIN, {lo: 1.0}, segs=8, rows=6)
    else:
        ellipsoid(b, hand + fdir * 0.01, (0.038, 0.04, 0.056), M_SKIN, {lo: 1.0},
                  segs=8, rows=6)


def build_feet(b):
    for s in (-1.0, 1.0):
        ellipsoid(b, tuple(FOOT_REST[int(s)]), (0.062, 0.10, 0.048), M_BOOT,
                  {_side("RobeFront", s): 1.0}, segs=10, rows=6)


def to_object(b, name, materials):
    purge_object(name)
    me = bpy.data.meshes.new(name)
    me.from_pydata([tuple(v) for v in b.co], [], b.faces)
    me.update()
    for m in materials:
        me.materials.append(m)
    me.polygons.foreach_set("material_index", b.mats)
    bm = bmesh.new()
    bm.from_mesh(me)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    bm.to_mesh(me)
    bm.free()
    me.polygons.foreach_set("use_smooth", [True] * len(me.polygons))
    me.update()
    ob = bpy.data.objects.new(name, me)
    groups = {}
    for i, w in enumerate(b.w):
        for bone, value in w.items():
            groups.setdefault(bone, []).append((i, value))
    for bone in sorted(groups):
        vg = ob.vertex_groups.new(name=bone)
        for i, value in groups[bone]:
            vg.add([i], value, "REPLACE")
    return ob


def build_body(mats):
    b = Builder()
    build_skirt(b)
    build_torso(b)
    build_sash(b)
    build_mantle(b)
    build_hood(b)
    build_head(b)
    for s in (-1, 1):
        build_sleeve(b, s)
    build_feet(b)
    if any(not w for w in b.w):
        raise RuntimeError("Mage_Body: a vertex has no weights")
    return to_object(b, "Mage_Body", [mats[i] for i in BODY_MATS])


def build_staff(mats):
    """Origin at the grip, shaft along local +Z (+Y after export)."""
    b = Builder()
    none = {}
    grey, band, gem, wrap = range(4)                     # slots of STAFF_MATS
    shaft_segs = 8
    shaft = [(0.020, -1.04), (0.024, -0.99), (0.025, -0.97), (0.026, -0.50),
             (0.026, -0.07), (0.029, -0.06), (0.029, 0.07), (0.026, 0.08),
             (0.025, 0.40), (0.023, 0.64)]
    rings = [(Vector((0, 0, -1.045)), none)]
    for r, z in shaft:
        rings.append([(Vector((r * math.cos(TAU * j / shaft_segs), r * math.sin(TAU * j / shaft_segs), z)), none)
                      for j in range(shaft_segs)])
    rings.append((Vector((0, 0, 0.645)), none))

    def shaft_mat(k, j):
        if k <= 2:
            return band                                          # ferrule
        if k in (5, 6):
            return wrap                                          # grip wrap
        return grey
    loft(b, rings, shaft_mat)
    collar = [(0.034, 0.60), (0.044, 0.625), (0.044, 0.655), (0.030, 0.68), (0.018, 0.68),
              (0.018, 0.60)]
    rings = [[(Vector((r * math.cos(TAU * j / 12), r * math.sin(TAU * j / 12), z)), none)
              for j in range(12)] for r, z in collar]
    loft(b, rings, lambda k, j: band, closed=True)
    for i in range(3):                                           # claws around the gem
        phi = TAU * i / 3 + math.radians(30.0)
        radial = Vector((math.cos(phi), math.sin(phi), 0.0))
        path = [(0.030, 0.655), (0.066, 0.71), (0.086, 0.79), (0.078, 0.88), (0.046, 0.95),
                (0.022, 0.975)]
        pts = [radial * r + Vector((0, 0, z)) for r, z in path]
        rings = []
        for k, c in enumerate(pts):
            t_dir = (pts[min(k + 1, len(pts) - 1)] - pts[max(k - 1, 0)]).normalized()
            n1, n2 = tube_frame(t_dir, radial.cross(Vector((0, 0, 1))))
            rad = 0.015 - 0.0014 * k
            rings.append([(c + (n1 * math.cos(TAU * j / 6) + n2 * math.sin(TAU * j / 6)) * rad, none)
                          for j in range(6)])
        rings = [(pts[0] - (pts[1] - pts[0]).normalized() * 0.008, none)] + rings + \
                [(pts[-1] + (pts[-1] - pts[-2]).normalized() * 0.008, none)]
        loft(b, rings, lambda k, j: band)
    crystal = [(0.058, 0.78), (0.068, 0.84), (0.062, 0.92)]
    rings = [(Vector((0, 0, 0.70)), none)]
    for r, z in crystal:
        rings.append([(Vector((r * math.cos(TAU * j / 8), r * math.sin(TAU * j / 8), z)), none)
                      for j in range(8)])
    rings.append((Vector((0, 0, 1.06)), none))
    loft(b, rings, lambda k, j: gem)
    return to_object(b, "Staff", [mats[i] for i in STAFF_MATS])


# --------------------------------------------------------------------------
# rig
# --------------------------------------------------------------------------

BONES = [
    ("Hips", (0.0, 0.0, 0.95), (0.0, 0.0, 1.05), None, False),
    ("Spine", (0.0, 0.0, 1.05), (0.0, 0.0, 1.45), "Hips", False),
    ("Head", (0.0, 0.0, 1.47), (0.0, 0.0, 1.90), "Spine", False),
    ("Hood", (0.0, -0.10, 1.76), (0.0, -0.30, 1.96), "Head", False),
    ("UpperArm_L", (-0.235, 0.0, SHOULDER_Z), tuple(ELBOW[-1]), "Spine", False),
    ("LowerArm_L", tuple(ELBOW[-1]), tuple(WRIST[-1]), "UpperArm_L", True),
    ("Sleeve_L", (-0.235, 0.07, 0.97), (-0.235, 0.07, 0.80), "LowerArm_L", False),
    ("UpperArm_R", (0.235, 0.0, SHOULDER_Z), tuple(ELBOW[1]), "Spine", False),
    ("LowerArm_R", tuple(ELBOW[1]), tuple(WRIST[1]), "UpperArm_R", True),
    ("Sleeve_R", (0.235, 0.17, 1.09), (0.235, 0.17, 0.92), "LowerArm_R", False),
    ("Robe", (0.0, 0.0, 1.00), (0.0, 0.0, 0.10), "Hips", False),
    # the legs under the robe: vertical, so a swing moves the foot forward
    # rather than up
    ("RobeFront_L", (-0.11, 0.29, 0.95), (-0.11, 0.29, 0.06), "Hips", False),
    ("RobeFront_R", (0.11, 0.29, 0.95), (0.11, 0.29, 0.06), "Hips", False),
    ("RobeBack", (0.0, -0.05, 1.00), (0.0, -0.28, 0.10), "Hips", False),
]
FOOT_REST = {1: Vector((0.11, 0.30, 0.048)), -1: Vector((-0.11, 0.30, 0.048))}


# --------------------------------------------------------------------------
# animation (rotations in degrees about the bone's local axes; see
# sf_assets_common: +X swings a hanging limb forward, tips an upright bone
# back and lifts a forward-pointing forearm)
# --------------------------------------------------------------------------

def pose_idle(p):
    s = math.sin(TAU * p)
    c = math.cos(TAU * p)
    return {
        "Spine": {"loc": (0.0, -0.012 * (1.0 - c), 0.0), "rot": (0.8 * s, 0.0, 0.0)},
        "Head": {"rot": (2.0 * math.sin(TAU * p - 0.6), 0.0, 1.2 * math.sin(TAU * p + 1.0))},
        "Hood": {"rot": (3.0 * math.sin(TAU * p - 1.3), 0.0, 1.5 * math.sin(TAU * p + 0.3))},
        "UpperArm_R": {"rot": (1.5 * s, 0.0, 0.0)},
        "LowerArm_R": {"rot": (1.5 * math.sin(TAU * p + 0.5), 0.0, 0.0)},
        "UpperArm_L": {"rot": (3.0 * math.sin(TAU * p + 0.8), 0.0, -2.0)},
        "LowerArm_L": {"rot": (4.0 + 3.0 * math.sin(TAU * p + 1.3), 0.0, 0.0)},
        "Sleeve_L": {"rot": (-3.0 * math.sin(TAU * p + 0.2), 0.0, 1.5 * s)},
        "Sleeve_R": {"rot": (-2.0 * math.sin(TAU * p - 0.3), 0.0, 0.0)},
        "Robe": {"rot": (0.0, 1.0 * s, 1.2 * s)},
        "RobeBack": {"rot": (-1.5 * (1.0 - c), 0.0, 0.0)},
    }


WALK_LEG_FORWARD = 18.0      # degrees the front panel (the leg under it) swings forward
WALK_LEG_BACK = 8.0          # and back: the back of the robe takes the trailing leg


def _leg(sv):
    return WALK_LEG_FORWARD * sv if sv > 0 else WALK_LEG_BACK * sv


def pose_walk(p):
    s = math.sin(TAU * p)
    c = math.cos(TAU * p)
    c2 = math.cos(2.0 * TAU * p)
    lean = 6.0
    return {
        "Hips": {"loc": (0.0, -0.028 * s * s, 0.0), "rot": (0.0, 4.0 * s, 0.0)},
        "Spine": {"rot": (-lean, -7.0 * s, 1.5 * math.sin(TAU * p + 0.4))},
        "Head": {"rot": (lean - 1.0, 4.0 * s, 0.0)},
        "Hood": {"rot": (6.0 * math.cos(2.0 * TAU * p - 1.0) + 4.0, 0.0, 5.0 * s)},
        "UpperArm_R": {"rot": (lean - 8.0 * s, 0.0, 0.0)},
        # spine, upper and lower arm pitches add up to the staff's tilt
        "LowerArm_R": {"rot": (4.0 * max(0.0, -s), 0.0, 0.0)},
        "UpperArm_L": {"rot": (lean + 24.0 * s, 0.0, -4.0)},
        "LowerArm_L": {"rot": (10.0 + 16.0 * max(0.0, s), 0.0, 0.0)},
        # the bells trail the arm swing by a quarter cycle
        "Sleeve_L": {"rot": (-16.0 * c, 0.0, 4.0 * s)},
        "Sleeve_R": {"rot": (7.0 * c - 4.0, 0.0, 0.0)},
        "RobeFront_R": {"rot": (_leg(s), 0.0, 0.0)},
        "RobeFront_L": {"rot": (_leg(-s), 0.0, 0.0)},
        "RobeBack": {"rot": (-(3.0 + 8.0 * s * s), 0.0, -3.0 * s)},
        "Robe": {"rot": (-(2.0 + 2.0 * c2), -5.0 * s, 4.0 * math.sin(TAU * p - 0.6))},
    }


# Cast: anticipation (crouch, lean back, staff raised and tipped back over the
# head), a held gather, a fast thrust (lean in, left foot steps, staff tips
# forward, arms out), an overshoot and a slow settle back to rest. The staff is
# rigid on the forearm, so its tilt is the sum of the spine, upper and lower arm
# pitches.
CAST_KEYS = [
    (0.00, "inout", {}),
    (0.30, "inout", {
        "Hips": {"loc": (0.0, -0.055, 0.02), "rot": (0.0, -12.0, 0.0)},
        "Spine": {"rot": (14.0, -10.0, 3.0)},
        "Head": {"rot": (-8.0, 8.0, 0.0)},
        "Hood": {"rot": (-12.0, 0.0, 0.0)},
        "UpperArm_R": {"rot": (100.0, 0.0, 6.0)},
        "LowerArm_R": {"rot": (-70.0, 0.0, 0.0)},
        "UpperArm_L": {"rot": (65.0, 0.0, -18.0)},
        "LowerArm_L": {"rot": (35.0, 0.0, 0.0)},
        "Sleeve_R": {"rot": (-28.0, 0.0, 0.0)},
        "Sleeve_L": {"rot": (-22.0, 0.0, 0.0)},
        "RobeFront_R": {"rot": (-6.0, 0.0, 0.0)},
        "RobeFront_L": {"rot": (5.0, 0.0, 0.0)},
        "RobeBack": {"rot": (-4.0, 0.0, 0.0)},
        "Robe": {"rot": (3.0, -6.0, 0.0)},
    }),
    (0.44, "out", {
        "Hips": {"loc": (0.0, -0.07, 0.03), "rot": (0.0, -15.0, 0.0)},
        "Spine": {"rot": (18.0, -14.0, 3.0)},
        "Head": {"rot": (-10.0, 10.0, 0.0)},
        "Hood": {"rot": (-15.0, 0.0, 0.0)},
        "UpperArm_R": {"rot": (112.0, 0.0, 8.0)},
        "LowerArm_R": {"rot": (-72.0, 0.0, 0.0)},
        "UpperArm_L": {"rot": (38.0, 0.0, -8.0)},
        "LowerArm_L": {"rot": (95.0, 0.0, 0.0)},
        "Sleeve_R": {"rot": (-34.0, 0.0, 0.0)},
        "Sleeve_L": {"rot": (-12.0, 0.0, 0.0)},
        "RobeFront_R": {"rot": (-8.0, 0.0, 0.0)},
        "RobeFront_L": {"rot": (6.0, 0.0, 0.0)},
        "RobeBack": {"rot": (-5.0, 0.0, 0.0)},
        "Robe": {"rot": (4.0, -8.0, 0.0)},
    }),
    (0.56, "in", {
        "Hips": {"loc": (0.0, -0.05, -0.07), "rot": (0.0, 14.0, 0.0)},
        "Spine": {"rot": (-26.0, 14.0, -2.0)},
        "Head": {"rot": (14.0, -8.0, 0.0)},
        "Hood": {"rot": (24.0, 0.0, 0.0)},
        "UpperArm_R": {"rot": (84.0, 0.0, 4.0)},
        "LowerArm_R": {"rot": (-100.0, 0.0, 0.0)},
        "UpperArm_L": {"rot": (84.0, 0.0, -10.0)},
        "LowerArm_L": {"rot": (-8.0, 0.0, 0.0)},
        "Sleeve_R": {"rot": (-12.0, 0.0, 0.0)},
        "Sleeve_L": {"rot": (-14.0, 0.0, 0.0)},
        "RobeFront_R": {"rot": (-8.0, 0.0, 0.0)},
        "RobeFront_L": {"rot": (9.0, 0.0, 0.0)},
        "RobeBack": {"rot": (-22.0, 0.0, 0.0)},
        "Robe": {"rot": (-6.0, 10.0, 0.0)},
    }),
    (0.68, "out", {
        "Hips": {"loc": (0.0, -0.055, -0.08), "rot": (0.0, 16.0, 0.0)},
        "Spine": {"rot": (-30.0, 16.0, -2.0)},
        "Head": {"rot": (17.0, -9.0, 0.0)},
        "Hood": {"rot": (34.0, 0.0, 0.0)},
        "UpperArm_R": {"rot": (88.0, 0.0, 4.0)},
        "LowerArm_R": {"rot": (-104.0, 0.0, 0.0)},
        "UpperArm_L": {"rot": (88.0, 0.0, -12.0)},
        "LowerArm_L": {"rot": (-10.0, 0.0, 0.0)},
        "Sleeve_R": {"rot": (42.0, 0.0, 0.0)},
        "Sleeve_L": {"rot": (38.0, 0.0, 0.0)},
        "RobeFront_R": {"rot": (-6.0, 0.0, 0.0)},
        "RobeFront_L": {"rot": (10.0, 0.0, 0.0)},
        "RobeBack": {"rot": (-32.0, 0.0, 0.0)},
        "Robe": {"rot": (-7.0, 12.0, 0.0)},
    }),
    (1.00, "inout", {}),
]


def _ease(u, kind):
    if kind == "in":
        return u ** 2.4
    if kind == "out":
        return 1.0 - (1.0 - u) ** 2.2
    return 0.5 - 0.5 * math.cos(math.pi * u)


def pose_cast(t):
    for i in range(len(CAST_KEYS) - 1):
        t0, _, a = CAST_KEYS[i]
        t1, kind, c = CAST_KEYS[i + 1]
        if t <= t1 or i == len(CAST_KEYS) - 2:
            u = _ease(clamp01((t - t0) / (t1 - t0)), kind)
            pose = {}
            for bone in set(a) | set(c):
                entry = {}
                for ch in ("rot", "loc"):
                    va = a.get(bone, {}).get(ch, (0.0, 0.0, 0.0))
                    vc = c.get(bone, {}).get(ch, (0.0, 0.0, 0.0))
                    entry[ch] = tuple(lerp(va[k], vc[k], u) for k in range(3))
                pose[bone] = entry
            return pose
    return {}


def author(armature, name, frames, sample, loop, step):
    """Plain action keyed from frame 0 to `frames`; a loop repeats phase 0 on
    its last key, a one-shot samples `sample(seconds)` on every key."""
    if armature.animation_data is None:
        armature.animation_data_create()
    old = bpy.data.actions.get(name)
    if old is not None:
        bpy.data.actions.remove(old)
    act = bpy.data.actions.new(name)
    act.use_fake_user = True
    armature.animation_data.action = act
    names = {pb.name for pb in armature.pose.bones}
    for pb in armature.pose.bones:
        pb.rotation_mode = "QUATERNION"
    for frame in range(0, frames + 1, step):
        pose = sample((frame % frames) / float(frames)) if loop else sample(frame / float(ANIM_FPS))
        unknown = set(pose) - names
        if unknown:
            raise RuntimeError("%s: no bones %s" % (name, sorted(unknown)))
        for pb in armature.pose.bones:
            values = pose.get(pb.name, {})
            rot = values.get("rot", (0.0, 0.0, 0.0))
            pb.rotation_quaternion = Euler(tuple(math.radians(v) for v in rot), "XYZ").to_quaternion()
            pb.location = values.get("loc", (0.0, 0.0, 0.0))
            pb.keyframe_insert("rotation_quaternion", frame=frame, group=pb.name)
            pb.keyframe_insert("location", frame=frame, group=pb.name)
    for fc in act.fcurves:
        for kp in fc.keyframe_points:
            kp.interpolation = "LINEAR"
    armature.animation_data.action = None
    reset_pose(armature)
    return act


def _pose_point(armature, bone, rest_point):
    pb = armature.pose.bones[bone]
    return armature.matrix_world @ pb.matrix @ pb.bone.matrix_local.inverted() @ rest_point


def measure_walk(scene, armature, walk):
    """The feet ride the RobeFront bones: sample them over one cycle."""
    armature.animation_data.action = walk
    ys, zs = [], []
    for frame in range(WALK_FRAMES + 1):
        scene.frame_set(frame)
        update_depsgraph()
        p = _pose_point(armature, "RobeFront_R", FOOT_REST[1])
        ys.append(p.y)
        zs.append(p.z)
    armature.animation_data.action = None
    reset_pose(armature)
    sweep = max(ys) - min(ys)
    stride = 2.0 * sweep
    print("SF_TOON_WALK foot_sweep=%.3f m (fwd %.3f, back %.3f) stride_per_cycle=%.3f m "
          "cycle=%.2f s matched_speed=%.2f m/s foot_z=%.3f..%.3f"
          % (sweep, max(ys) - FOOT_REST[1].y, FOOT_REST[1].y - min(ys), stride,
             WALK_FRAMES / float(ANIM_FPS), stride * ANIM_FPS / WALK_FRAMES, min(zs), max(zs)))
    return stride


# --------------------------------------------------------------------------
# outline shell (Blender only)
# --------------------------------------------------------------------------

def add_outline(ob, outline_mat):
    """Inverted hull: Solidify pushed outward with flipped normals, its shell on
    the black backface-culled material appended as the last slot."""
    ob.data.materials.append(outline_mat)
    mod = ob.modifiers.new("ToonOutline", "SOLIDIFY")
    mod.thickness = OUTLINE_WIDTH_M
    mod.offset = 1.0
    mod.use_flip_normals = True
    mod.use_rim = False
    mod.use_even_offset = False
    mod.use_quality_normals = True
    mod.material_offset = len(ob.data.materials) - 1        # clamps to the outline slot
    return mod


def check_outline(ob, mod):
    """The shell must lie outside the surface with its normals pointing in."""
    update_depsgraph()
    prev = enter_assets_scene()
    deps = bpy.context.evaluated_depsgraph_get()
    ev = ob.evaluated_get(deps)
    me = ev.to_mesh()
    last = len(ob.data.materials) - 1
    shell_in = orig_out = 0
    total_shell = total_orig = 0
    centre = Vector((0.0, 0.0, 1.0)) if ob.name == "Mage_Body" else Vector((0.0, 0.0, 0.0))
    for p in me.polygons:
        d = (Vector(p.center) - centre)
        if p.material_index >= last:
            total_shell += 1
            shell_in += 1 if d.dot(p.normal) < 0 else 0
        else:
            total_orig += 1
            orig_out += 1 if d.dot(p.normal) > 0 else 0
    ev.to_mesh_clear()
    restore_scene(prev)
    print("SF_TOON_OUTLINE %-9s shell faces %d (%.0f%% facing in), surface faces %d (%.0f%% facing out)"
          % (ob.name, total_shell, 100.0 * shell_in / max(1, total_shell), total_orig,
             100.0 * orig_out / max(1, total_orig)))
    if total_shell == 0 or shell_in < 0.6 * total_shell:
        raise RuntimeError("%s: outline shell is not inverted" % ob.name)


def export_mode(objects_with_outline, mats, on):
    """on=True: plain materials, no shell (glTF). on=False: back to toon."""
    for ob, mod, outline_mat in objects_with_outline:
        mod.show_viewport = not on
        mod.show_render = not on
        if on:
            ob.data.materials.pop()
        else:
            ob.data.materials.append(outline_mat)
    for m in mats:
        set_toon(m, not on)


# --------------------------------------------------------------------------
# renders
# --------------------------------------------------------------------------

BG_HEX = "#A7AEBD"
GROUND_HEX = "#7D8C6C"


def setup_render_world(scene, mats_ground):
    world = bpy.data.worlds.get("Toon_World") or bpy.data.worlds.new("Toon_World")
    world.use_nodes = True
    nt = world.node_tree
    for n in list(nt.nodes):
        nt.nodes.remove(n)
    out = nt.nodes.new("ShaderNodeOutputWorld")
    lit = nt.nodes.new("ShaderNodeBackground")
    _sock(lit.inputs, "Color").default_value = (0.0, 0.0, 0.0, 1.0)
    _sock(lit.inputs, "Strength").default_value = 0.0
    seen = nt.nodes.new("ShaderNodeBackground")
    _sock(seen.inputs, "Color").default_value = srgb_to_linear(BG_HEX)
    _sock(seen.inputs, "Strength").default_value = 1.0
    lp = nt.nodes.new("ShaderNodeLightPath")
    mix = nt.nodes.new("ShaderNodeMixShader")
    # the camera sees the backdrop colour; nothing is lit by the world, so the
    # Shader to RGB value is the sun alone and the bands are exact
    nt.links.new(_sock(lp.outputs, "Is Camera Ray"), mix.inputs[0])
    nt.links.new(lit.outputs[0], mix.inputs[1])
    nt.links.new(seen.outputs[0], mix.inputs[2])
    nt.links.new(mix.outputs[0], out.inputs[0])
    scene.world = world

    rig = get_or_make_collection("Toon_RenderRig", scene.collection)
    clear_collection(rig)
    gb = Builder()
    rings = [(Vector((0, 0, 0)), {})]
    for r in (1.0, 2.2, 3.5):
        rings.append([(Vector((r * math.cos(TAU * j / 48), r * math.sin(TAU * j / 48), 0.0)), {})
                      for j in range(48)])
    loft(gb, rings, lambda k, j: 0)
    ground = to_object(gb, "Toon_Ground", [mats_ground])
    for p in ground.data.polygons:
        p.use_smooth = False
    rig.objects.link(ground)
    cam_data = bpy.data.cameras.new("Toon_Cam")
    cam_data.lens = 50.0
    cam_data.sensor_fit = "VERTICAL"
    cam_data.sensor_height = 24.0
    cam = bpy.data.objects.new("Toon_Cam", cam_data)
    rig.objects.link(cam)
    sun_data = bpy.data.lights.new("Toon_Sun", "SUN")
    sun_data.energy = 1.0
    sun_data.angle = math.radians(0.5)
    sun = bpy.data.objects.new("Toon_Sun", sun_data)
    rig.objects.link(sun)
    scene.camera = cam

    engines = {e.identifier for e in bpy.types.RenderSettings.bl_rna.properties["engine"].enum_items}
    for engine in ("BLENDER_EEVEE_NEXT", "BLENDER_EEVEE"):
        if engine not in engines and engine != scene.render.engine:
            continue
        try:
            scene.render.engine = engine
            break
        except TypeError:
            continue
    if hasattr(scene.eevee, "taa_render_samples"):
        scene.eevee.taa_render_samples = 32
    if hasattr(scene.eevee, "use_shadows"):
        scene.eevee.use_shadows = True               # False on a scene made by scenes.new()
    if hasattr(scene.eevee, "shadow_resolution_scale"):
        scene.eevee.shadow_resolution_scale = 1.0
    scene.render.resolution_x = 600
    scene.render.resolution_y = 800
    scene.render.resolution_percentage = 100
    scene.render.film_transparent = False
    scene.render.dither_intensity = 0.0
    settings = scene.render.image_settings
    fmts = {i.identifier for i in settings.bl_rna.properties["file_format"].enum_items}
    if "PNG" in fmts:
        settings.file_format = "PNG"
    modes = {i.identifier for i in settings.bl_rna.properties["color_mode"].enum_items}
    if "RGB" in modes:
        settings.color_mode = "RGB"
    settings.compression = 100
    try:
        scene.view_settings.view_transform = "Standard"
    except TypeError:
        pass
    try:
        scene.view_settings.look = "None"
    except TypeError:
        pass
    return cam, sun


def place_view(cam, sun, yaw_deg, elev_deg=14.0, target=(0.0, 0.0, 1.06), dist=5.6):
    """Perspective 50 mm camera at `yaw_deg` (0 = in front, 90 = the right side)."""
    yaw = math.radians(yaw_deg)
    elev = math.radians(elev_deg)
    tgt = Vector(target)
    d = Vector((math.sin(yaw) * math.cos(elev), math.cos(yaw) * math.cos(elev), math.sin(elev)))
    cam.location = tgt + d * dist
    look_at(cam, tgt)
    # the sun sits where the game's sun sits relative to the game camera: 15
    # degrees to the camera's left and 55 degrees up
    ly = math.radians(yaw_deg + 15.0)
    le = math.radians(55.0)
    towards = Vector((math.sin(ly) * math.cos(le), math.cos(ly) * math.cos(le), math.sin(le)))
    sun.rotation_euler = towards.to_track_quat("Z", "Y").to_euler()


def render_to(scene, path):
    prev = enter_assets_scene()
    scene.render.filepath = os.path.abspath(path)
    bpy.ops.render.render(write_still=True, scene=scene.name)
    restore_scene(prev)
    print("SF_TOON_RENDER %s" % path)


def set_frame(scene, armature, action, frame):
    armature.animation_data.action = action
    scene.frame_set(frame)
    update_depsgraph()


# --------------------------------------------------------------------------
# main
# --------------------------------------------------------------------------

def remove_factory_objects():
    for name in ("Cube", "Light", "Camera"):
        ob = bpy.data.objects.get(name)
        if ob is not None:
            data = ob.data
            bpy.data.objects.remove(ob, do_unlink=True)
            _purge_data(data)


def viewport_to_rendered():
    for screen in bpy.data.screens:
        for area in screen.areas:
            if area.type != "VIEW_3D":
                continue
            for space in area.spaces:
                if space.type == "VIEW_3D":
                    space.shading.type = "RENDERED"
                    if space.region_3d is not None:
                        space.region_3d.view_perspective = "CAMERA"


def main():
    remove_factory_objects()
    scene = assets_scene()
    activate_scene(scene)
    default = bpy.data.scenes.get("Scene")
    if default is not None and default is not scene and bpy.context.scene is scene:
        bpy.data.scenes.remove(default)
    scene.render.fps = ANIM_FPS
    scene.render.fps_base = 1.0
    coll = model_collection("SF_MageToon")

    mats = build_materials()
    outline_mat = build_outline_material()
    body = build_body(mats)
    staff = build_staff(mats)

    armature = build_armature("Mage_Armature", BONES, coll)
    link(coll, body)
    skin_to_armature(body, armature)
    update_depsgraph()
    link(coll, staff)
    parent_to_bone(staff, armature, "LowerArm_R",
                   world=Matrix.LocRotScale(GRIP_R, Euler(STAFF_TILT, "XYZ"), None))
    update_depsgraph()
    top = world_bounds([body])[1].z
    hand = add_empty("HandPoint", tuple(GRIP_R), collection=coll)
    parent_to_bone(hand, armature, "LowerArm_R")
    overhead = add_empty("OverheadAnchor", (0.0, 0.0, top + OVERHEAD_CLEARANCE),
                         parent=armature, collection=coll)
    update_depsgraph()
    objects = [armature, body, staff, hand, overhead]

    idle = author(armature, "idle", IDLE_FRAMES, pose_idle, loop=True, step=2)
    walk = author(armature, "walk", WALK_FRAMES, pose_walk, loop=True, step=2)
    cast = author(armature, "cast", CAST_FRAMES, pose_cast, loop=False, step=1)
    scene.frame_set(0)
    stride = measure_walk(scene, armature, walk)

    lo, hi = world_bounds([body, staff])
    print("SF_TOON_MODEL tris body=%d staff=%d total=%d height=%.3f (body top %.3f) "
          "bones=%d anchor=%.3f hand=%s"
          % (tri_count(body), tri_count(staff), tri_count(body) + tri_count(staff), hi.z, top,
             len(armature.data.bones), top + OVERHEAD_CLEARANCE,
             tuple(round(v, 3) for v in GRIP_R)))
    print("SF_TOON_CLIPS %s" % [(a.name, tuple(a.frame_range), (a.frame_range[1] - a.frame_range[0]) / ANIM_FPS)
                                for a in (idle, walk, cast)])

    outlined = []
    for ob in (body, staff):
        mod = add_outline(ob, outline_mat)
        check_outline(ob, mod)
        outlined.append((ob, mod, outline_mat))

    export_mode(outlined, mats, True)
    try:
        export_glb(objects, MODEL_PATH, root_name="Mage", animations=True)
    finally:
        export_mode(outlined, mats, False)
    print("SF_TOON_EXPORT %s" % MODEL_PATH)
    t_export = time.time() - T_START

    ground_mat = make_material("Toon_Ground", GROUND_HEX, roughness=1.0)
    if ground_mat.node_tree.nodes.get("SF_ToonOut") is None:
        add_toon_nodes(ground_mat, srgb_to_linear(GROUND_HEX), rim=False)
    cam, sun = setup_render_world(scene, ground_mat)

    if DO_RENDERS:
        views = [("front", 35.0, None, 0, {}), ("side", 90.0, None, 0, {}),
                 ("back", 200.0, None, 0, {}),
                 ("walk", 70.0, walk, int(round(WALK_PREVIEW_PHASE * WALK_FRAMES)), {}),
                 # from the front left: the torso twists toward this side on the thrust
                 ("cast", -78.0, cast, int(round(CAST_PREVIEW_TIME * ANIM_FPS)),
                  {"target": (0.0, 0.32, 1.10), "dist": 6.6})]
        for label, yaw, action, frame, framing in views:
            if action is None:
                armature.animation_data.action = None
                reset_pose(armature)
                scene.frame_set(0)
                update_depsgraph()
            else:
                set_frame(scene, armature, action, frame)
            place_view(cam, sun, yaw, **framing)
            render_to(scene, os.path.join(PREVIEW_DIR, "mage_toon_%s.png" % label))
    t_render = time.time() - T_START - t_export

    # The .blend opens on the front view with the idle clip on the timeline.
    armature.animation_data.action = idle
    scene.frame_start = 0
    scene.frame_end = IDLE_FRAMES
    scene.frame_set(0)
    place_view(cam, sun, 35.0)
    viewport_to_rendered()
    folder = os.path.dirname(BLEND_PATH)
    if folder and os.path.isdir(folder):
        bpy.ops.wm.save_as_mainfile(filepath=BLEND_PATH, copy=True)
        print("SF_TOON_BLEND %s" % BLEND_PATH)
    else:
        print("SF_TOON_BLEND skipped: no folder %s" % folder)
    print("SF_TOON_TIME export=%.1f s renders=%.1f s total=%.1f s"
          % (t_export, t_render, time.time() - T_START))
    print("SF_TOON DONE stride=%.3f" % stride)


main()
