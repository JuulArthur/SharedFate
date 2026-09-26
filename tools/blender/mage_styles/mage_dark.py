# Shared Fate 3D style study: a realistic dark fantasy mage, made to stand in
# the pre-rendered crypt (docs/style-study/mage_dark.md).
#
# Command line (Blender 4.3):
#     blender --background --factory-startup --python tools/blender/mage_styles/mage_dark.py -- --root <repo>
#         [--blend <path>]   where to save the viewable .blend (default: blender/mage_dark.blend)
#         [--no-render]      skip the preview renders (export only)
#         [--debug <dir>]    extra inspection renders into <dir>
#
# The pipeline is the soft mage's (tools/blender/mage_styles/mage_soft.py):
# parts as lathes, Skin tubes and ellipsoids, fused by one voxel remesh,
# decimated with colour edges protected, painted into a vertex colour `Col`
# with baked ambient occlusion, skinned with computed weights, and animated
# with `idle`, `walk` and `cast`. What changes is the figure:
#   * adult proportions: 1.86 m to the top of the hood, head about 1/7.5 of the
#     body, long arms, narrow shoulders;
#   * a deep pointed hood that keeps the gaunt, ashen face in shadow, two
#     crimson glowing eyes (their own emissive material) and a long grey beard;
#   * a charcoal robe with a tattered hem over an oxblood under-robe, tarnished
#     embroidery down the opening, a ragged mantle over the shoulders, bell
#     sleeves, a leather belt with a buckle, a pouch, a chained tome and a bone
#     charm, worn boots;
#   * a gnarled black staff whose head is a claw of roots around a crimson
#     crystal, with a bone band and two hanging charms.
#
# Conventions as generate_characters.py: +Z up, feet on z = 0, facing Blender
# +Y (glTF/Godot -Z), the right hand at +X. The staff is a separate object with
# its origin at the grip and its shaft along local +Z (+Y after export).

import bpy
import bmesh
import math
import os
import sys
import time
from mathutils import Vector, Matrix, Euler
from mathutils.bvhtree import BVHTree

T_START = time.time()


def _sf_paths():
    here = globals().get("SF_DIR")
    if not here:
        here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    argv = sys.argv
    if "--root" in argv:
        root = argv[argv.index("--root") + 1]
    else:
        root = globals().get("SF_ROOT") or os.path.abspath(os.path.join(here, os.pardir, os.pardir))
    return here, root


SF_DIR, SF_ROOT = _sf_paths()
exec(open(os.path.join(SF_DIR, "sf_assets_common.py"), encoding="utf-8").read())

MODEL_PATH = os.path.join(SF_ROOT, "assets", "3d", "models", "styles", "mage_dark.glb")
PREVIEW_DIR = os.path.join(SF_ROOT, "assets", "3d", "previews", "styles")
DO_RENDER = "--no-render" not in sys.argv


def _blend_path():
    if "--blend" in sys.argv:
        return os.path.abspath(sys.argv[sys.argv.index("--blend") + 1])
    root = os.path.abspath(SF_ROOT)
    marker = os.sep + ".claude" + os.sep + "worktrees" + os.sep
    main = root.split(marker)[0] if marker in root else root
    return os.path.join(main, "blender", "mage_dark.blend")


TAU = 2.0 * math.pi
ANIM_FPS = 60
IDLE_FRAMES, WALK_FRAMES, CAST_FRAMES = 120, 60, 60
KEY_STEP = 2
CAST_PEAK = 0.70
VOXEL = 0.007                    # remesh voxel, metres
TARGET_BODY_TRIS = 12000
DECIMATE_KEEP = 8.0
SKIN_SCALE = 1.22                # Skin + Subsurf shrinks a box tube to ~0.82 of its radius
OVERHEAD_CLEARANCE = 0.25


def V(x, y, z):
    return Vector((x, y, z))


def clamp(x, a=0.0, b=1.0):
    return a if x < a else b if x > b else x


def smoothstep(e0, e1, x):
    t = clamp((x - e0) / (e1 - e0))
    return t * t * (3.0 - 2.0 * t)


def lerp(a, b, t):
    return a + (b - a) * t


def hash1(i):
    """Deterministic pseudo-random 0..1 for an integer."""
    x = math.sin(i * 12.9898 + 78.233) * 43758.5453
    return x - math.floor(x)


def tatter(theta, count, depth, seed):
    """Ragged edge: 0 at the cloth's full length, up to `depth` shorter in
    irregular pointed tongues around the circle."""
    u = theta / TAU * count
    i = math.floor(u)
    f = u - i
    a = hash1(i + seed)
    b = hash1(i + seed + 101)
    tongue = abs(f - (0.35 + 0.3 * b)) * 2.0            # 0 at the tip of a tongue
    return depth * (0.25 + 0.75 * a) * min(1.0, tongue) ** 0.8


# --------------------------------------------------------------------------
# palette (sRGB hex)
# --------------------------------------------------------------------------

def _lin(h):
    return Vector(srgb_to_linear(h)[:3])


PAL = {k: _lin(h) for k, h in {
    "robe": "#2b272c", "robe_dark": "#18151a", "under": "#4a151a", "trim": "#6b5836",
    "mantle": "#332d31", "mantle_dark": "#1f1b1e", "hood": "#2e292d", "hood_in": "#070506",
    "skin": "#8c8078", "skin_dark": "#4c423d", "beard": "#9d9891", "sleeve_in": "#120f11",
    "leather": "#3d2c20", "leather_dark": "#261b14", "metal": "#7a6843", "bone": "#b9ad90",
    "boot": "#221d19", "tome": "#3a1a17",
}.items()}

# --------------------------------------------------------------------------
# landmarks and rig
# --------------------------------------------------------------------------

J_R, E_R, W_R = V(0.185, -0.01, 1.49), V(0.245, -0.035, 1.20), V(0.245, 0.215, 1.265)
J_L, E_L, W_L = V(-0.185, -0.01, 1.49), V(-0.25, -0.02, 1.20), V(-0.295, 0.075, 0.95)
GRIP = W_R + (W_R - E_R).normalized() * 0.055         # HandPoint and staff origin
ARMS = {"R": (J_R, E_R, W_R), "L": (J_L, E_L, W_L)}

FOOT_Y, FOOT_X = 0.06, 0.105

BONES = [
    ("Hips", V(0, 0, 0.98), V(0, 0, 1.08), None, False),
    ("Spine", V(0, 0, 1.08), V(0, 0, 1.53), "Hips", False),
    ("Head", V(0, 0, 1.56), V(0, 0, 1.92), "Spine", False),
    ("UpperArm_L", J_L, E_L, "Spine", False),
    ("LowerArm_L", E_L, W_L, "UpperArm_L", True),
    ("UpperArm_R", J_R, E_R, "Spine", False),
    ("LowerArm_R", E_R, W_R, "UpperArm_R", True),
    ("Robe", V(0, 0, 1.05), V(0, 0, 0.12), "Hips", False),
    ("RobeFront_L", V(-0.10, 0.03, 0.96), V(-0.15, 0.25, 0.12), "Robe", False),
    ("RobeFront_R", V(0.10, 0.03, 0.96), V(0.15, 0.25, 0.12), "Robe", False),
    ("RobeBack", V(0, -0.03, 0.96), V(0, -0.27, 0.12), "Robe", False),
    ("Foot_L", V(-FOOT_X, FOOT_Y, 0.045), V(-FOOT_X, FOOT_Y + 0.14, 0.045), None, False),
    ("Foot_R", V(FOOT_X, FOOT_Y, 0.045), V(FOOT_X, FOOT_Y + 0.14, 0.045), None, False),
]
BONE_NAMES = [b[0] for b in BONES]
BI = {n: i for i, n in enumerate(BONE_NAMES)}

# --------------------------------------------------------------------------
# geometry helpers (as mage_soft.py)
# --------------------------------------------------------------------------


def frame_from_z(zdir, xhint=V(1, 0, 0)):
    z = zdir.normalized()
    x = (xhint - z * xhint.dot(z)).normalized()
    return Matrix((x, z.cross(x), z)).transposed()


def ellipsoid(center, radii, axes=None, u=32, v=20):
    bm = bmesh.new()
    bmesh.ops.create_uvsphere(bm, u_segments=u, v_segments=v, radius=1.0)
    m = axes if axes is not None else Matrix.Identity(3)
    c0 = Vector(center)
    for vert in bm.verts:
        c = vert.co
        vert.co = c0 + m @ Vector((c.x * radii[0], c.y * radii[1], c.z * radii[2]))
    return bm


def block(center, size, axes=None):
    bm = bmesh.new()
    bmesh.ops.create_cube(bm, size=1.0)
    m = axes if axes is not None else Matrix.Identity(3)
    for vert in bm.verts:
        c = vert.co
        vert.co = Vector(center) + m @ Vector((c.x * size[0], c.y * size[1], c.z * size[2]))
    return bm


def surface(rows, bottom=None, top=None, closed=True):
    bm = bmesh.new()
    ring = [[bm.verts.new(p) for p in row] for row in rows]
    n = len(rows[0])
    span = n if closed else n - 1
    for i in range(len(ring) - 1):
        a, b = ring[i], ring[i + 1]
        for j in range(span):
            k = (j + 1) % n
            bm.faces.new((a[j], a[k], b[k], b[j]))
    if bottom is not None:
        c = bm.verts.new(bottom)
        for j in range(n):
            bm.faces.new((ring[0][(j + 1) % n], ring[0][j], c))
    if top is not None:
        c = bm.verts.new(top)
        for j in range(n):
            bm.faces.new((ring[-1][j], ring[-1][(j + 1) % n], c))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    return bm


def lathe(profile, n_theta, radius_scale=(1.0, 1.0), edge_fn=None):
    """Revolve a (r, z) profile whose first and last points lie on the axis."""
    rows = []
    for r, z in profile[1:-1]:
        row = []
        for j in range(n_theta):
            th = TAU * j / n_theta
            zz = z + (edge_fn(th, r, z) if edge_fn else 0.0)
            row.append(V(r * radius_scale[0] * math.sin(th), r * radius_scale[1] * math.cos(th), zz))
        rows.append(row)
    rows.reverse()
    return surface(rows, bottom=V(0, 0, profile[-1][1]), top=V(0, 0, profile[0][1]))


def tube(path, radii, sides=8):
    rows = []
    t_prev = None
    normal = None
    for i, p in enumerate(path):
        a = path[max(i - 1, 0)]
        b = path[min(i + 1, len(path) - 1)]
        t = (b - a).normalized()
        if normal is None:
            normal = (V(1, 0, 0) if abs(t.x) < 0.9 else V(0, 1, 0)).cross(t).normalized()
        else:
            normal = (normal - t * normal.dot(t)).normalized()
        binormal = t.cross(normal)
        rows.append([p + (normal * math.cos(TAU * k / sides) + binormal * math.sin(TAU * k / sides)) * radii[i]
                     for k in range(sides)])
        t_prev = t
    return surface(rows, bottom=path[0] - (path[1] - path[0]).normalized() * radii[0] * 0.5,
                   top=path[-1] + t_prev * radii[-1] * 0.5)


def merge(dst, src):
    me = bpy.data.meshes.new("_dark_tmp")
    src.to_mesh(me)
    dst.from_mesh(me)
    bpy.data.meshes.remove(me)


def eval_modifiers(bm_in, mods, setup=None):
    me = bpy.data.meshes.new("_dark_eval")
    bm_in.to_mesh(me)
    ob = bpy.data.objects.new("_dark_eval", me)
    assets_scene().collection.objects.link(ob)
    for typ, props in mods:
        m = ob.modifiers.new(typ.lower(), typ)
        for k, v in props.items():
            setattr(m, k, v)
    if setup is not None:
        setup(ob)
    bpy.context.view_layer.update()
    dg = bpy.context.evaluated_depsgraph_get()
    ev = ob.evaluated_get(dg)
    out = bmesh.new()
    out.from_mesh(ev.to_mesh())
    ev.to_mesh_clear()
    bpy.data.objects.remove(ob, do_unlink=True)
    bpy.data.meshes.remove(me)
    return out


def skin_tubes(verts, edges, radii, roots, levels=2):
    bm = bmesh.new()
    vs = [bm.verts.new(v) for v in verts]
    for a, b in edges:
        bm.edges.new((vs[a], vs[b]))

    def setup(ob):
        data = ob.data.skin_vertices[0].data
        for i, r in enumerate(radii):
            rr = r if isinstance(r, tuple) else (r, r)
            data[i].radius = (rr[0] * SKIN_SCALE, rr[1] * SKIN_SCALE)
            data[i].use_root = i in roots

    out = eval_modifiers(bm, [("SKIN", {"branch_smoothing": 0.6, "use_smooth_shade": True}),
                              ("SUBSURF", {"levels": levels, "render_levels": levels})], setup)
    bm.free()
    return out


# --------------------------------------------------------------------------
# the robe: a long lathe with deep folds, a front opening and a tattered hem
# --------------------------------------------------------------------------

WAIST_Z = 1.08
NECK_Z = 1.585
ROBE_CP = [(0.00, 0.355, 0.325), (0.10, 0.338, 0.308), (0.30, 0.30, 0.272), (0.55, 0.252, 0.224),
           (0.80, 0.205, 0.178), (0.98, 0.172, 0.146), (1.08, 0.158, 0.130), (1.20, 0.156, 0.132),
           (1.32, 0.164, 0.136), (1.42, 0.170, 0.132), (1.49, 0.150, 0.115), (1.545, 0.090, 0.080),
           (1.585, 0.056, 0.056), (1.62, 0.030, 0.030)]
FOLDS = [(9, 0.50, 0.4, 1.3), (14, 0.30, 2.2, -0.9), (5, 0.22, 4.1, 0.6)]
FOLD_DEPTH = 0.036
FOLD_PAINT = 0.30


def robe_profile(z):
    cp = ROBE_CP
    if z <= cp[0][0]:
        return cp[0][1], cp[0][2]
    for i in range(len(cp) - 1):
        if z <= cp[i + 1][0]:
            break
    u = (z - cp[i][0]) / (cp[i + 1][0] - cp[i][0])
    p0, p1, p2, p3 = cp[max(i - 1, 0)], cp[i], cp[i + 1], cp[min(i + 2, len(cp) - 1)]
    out = []
    for k in (1, 2):
        a, b, c, d = p0[k], p1[k], p2[k], p3[k]
        out.append(0.5 * ((2 * b) + (-a + c) * u + (2 * a - 5 * b + 4 * c - d) * u * u
                          + (-a + 3 * b - 3 * c + d) * u * u * u))
    return out[0], out[1]


def skirt_t(z):
    return clamp((WAIST_Z - z) / (WAIST_Z - 0.05))


def fold(theta, t):
    return sum(a * math.cos(k * theta + ph + dz * t + 0.3 * math.sin(2 * theta + ph))
               for k, a, ph, dz in FOLDS)


def hem_z(theta):
    # the hem drags at the back and is torn into tongues all round
    return 0.035 + 0.010 * fold(theta, 1.0) - 0.02 * max(0.0, -math.cos(theta)) + tatter(theta, 17, 0.075, 3)


def opening_edge(theta, z):
    t = skirt_t(z)
    th = math.atan2(math.sin(theta), math.cos(theta))
    return math.radians(17.0) * t ** 0.7 - abs(th), smoothstep(0.0, 0.10, t)


def robe_regions(theta, z):
    """(under-robe, embroidered trim, hem band) membership in 0..1."""
    e, fade = opening_edge(theta, z)
    under = smoothstep(-0.012, 0.012, e) * fade
    trim = smoothstep(-0.075, -0.055, e) * (1.0 - smoothstep(-0.018, -0.004, e)) * fade
    band = smoothstep(hem_z(theta) + 0.16, hem_z(theta) + 0.02, z)
    return under, trim, band


def robe_point(theta, z):
    rx, ry = robe_profile(z)
    t = skirt_t(z)
    d = 0.0
    if z < WAIST_Z:
        d += (0.003 + FOLD_DEPTH * t ** 1.1) * fold(theta, t)
    elif z < WAIST_Z + 0.10:
        d += 0.006 * (1.0 - (z - WAIST_Z) / 0.10) * (0.6 * math.cos(11 * theta + 0.5) + 0.4)
    under, trim, band = robe_regions(theta, z)
    d += -0.010 * under + 0.004 * trim
    return V((rx + d) * math.sin(theta), (ry + d) * math.cos(theta), z)


def build_robe(n_theta=160, n_rows=110, cap_rows=6):
    rows = []
    for k in range(cap_rows, 0, -1):
        f = k / float(cap_rows + 1)
        row = []
        for j in range(n_theta):
            th = TAU * j / n_theta
            p = robe_point(th, hem_z(th))
            zc = hem_z(th) + (0.30 - hem_z(th)) * (1.0 - (1.0 - f) ** 2)
            row.append(V(p.x * (1.0 - f), p.y * (1.0 - f), zc))
        rows.append(row)
    for i in range(n_rows):
        s = i / float(n_rows - 1)
        row = []
        for j in range(n_theta):
            th = TAU * j / n_theta
            z0 = hem_z(th)
            row.append(robe_point(th, z0 + (NECK_Z - z0) * s))
        rows.append(row)
    return surface(rows, bottom=V(0, 0, 0.30), top=V(0, 0, NECK_Z + 0.02))


MANTLE_TOP, MANTLE_EDGE = 1.64, 1.20


def mantle_edge(theta):
    return 0.012 * math.cos(7 * theta + 0.5) + tatter(theta, 13, 0.09, 11) + 0.04 * max(0.0, math.cos(theta)) ** 4


def build_mantle():
    prof = [(0.0, 1.645), (0.08, 1.625), (0.145, 1.585), (0.20, 1.53), (0.24, 1.46), (0.268, 1.39),
            (0.29, 1.31), (0.302, 1.245), (0.305, 1.21), (0.29, 1.198), (0.255, 1.205), (0.19, 1.25),
            (0.12, 1.30), (0.0, 1.32)]

    def edge(th, r, z):
        if z > 1.26 or r < 0.2:
            return 0.004 * math.cos(9 * th) if z < 1.5 else 0.0
        return -mantle_edge(th)
    return lathe(prof, 128, radius_scale=(1.0, 0.72), edge_fn=edge)


# --------------------------------------------------------------------------
# belt, buckle, pouch, tome, charm, boots
# --------------------------------------------------------------------------

def build_belt():
    n, m = 110, 10
    rows = []
    for i in range(m):
        psi = TAU * i / m
        row = []
        for j in range(n):
            th = TAU * j / n
            rx, ry = robe_profile(WAIST_Z)
            rad = 0.008 + 0.012 * math.cos(psi)
            sag = 0.035 * max(0.0, math.cos(th - 0.25)) ** 2       # slung low at the front right
            row.append(V((rx + rad) * math.sin(th), (ry + rad) * math.cos(th), WAIST_Z - sag + 0.024 * math.sin(psi)))
        rows.append(row)
    rows.append(rows[0])
    bm = surface(rows)
    bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=1e-5)
    return bm


def _waist_surface(theta, z, out=0.0):
    rx, ry = robe_profile(z)
    n = V(math.sin(theta), math.cos(theta), 0.0)
    return V(rx * n.x, ry * n.y, z) + n * out, n


def build_buckle():
    p, n = _waist_surface(0.25, WAIST_Z - 0.032, 0.022)
    return block(p, (0.055, 0.016, 0.05), frame_from_z(V(0, 0, 1), xhint=V(n.y, -n.x, 0)))


def build_pouch():
    p, n = _waist_surface(-2.55, WAIST_Z - 0.09, 0.045)
    return ellipsoid(p, (0.065, 0.04, 0.075), frame_from_z(V(0, 0, 1), xhint=V(n.y, -n.x, 0)), u=24, v=14)


def build_tome():
    """A small book chained at the right hip, behind the staff arm."""
    p, n = _waist_surface(2.25, WAIST_Z - 0.21, 0.05)
    axes = frame_from_z(V(0, 0.15, 1).normalized(), xhint=V(n.y, -n.x, 0))
    bm = block(p, (0.13, 0.045, 0.17), axes)
    top = p + axes @ V(0, 0, 0.085)
    anchor, _ = _waist_surface(2.1, WAIST_Z - 0.01, 0.02)
    merge(bm, tube([anchor, (anchor + top) * 0.5 + V(0, 0, -0.02), top], [0.006, 0.006, 0.006], sides=5))
    return bm


def build_charm():
    """A bone charm (a small skull on a thong) at the right front of the belt."""
    p, n = _waist_surface(0.75, WAIST_Z - 0.20, 0.045)
    bm = ellipsoid(p, (0.028, 0.026, 0.033), u=16, v=12)
    merge(bm, ellipsoid(p + V(0, 0, -0.03) + n * 0.005, (0.02, 0.018, 0.012), u=12, v=8))
    anchor, _ = _waist_surface(0.62, WAIST_Z - 0.03, 0.02)
    merge(bm, tube([anchor, (anchor + p) * 0.5, p + V(0, 0, 0.03)], [0.004, 0.004, 0.004], sides=5))
    return bm


def build_feet():
    bm = bmesh.new()
    for s in (-1.0, 1.0):
        merge(bm, ellipsoid(V(s * FOOT_X, FOOT_Y + 0.03, 0.04), (0.05, 0.125, 0.042), u=24, v=14))
        merge(bm, ellipsoid(V(s * FOOT_X, FOOT_Y - 0.03, 0.08), (0.048, 0.06, 0.07), u=20, v=12))
    return bm


# --------------------------------------------------------------------------
# head: gaunt face, brow, nose, beard, glowing eyes, neck, deep hood
# --------------------------------------------------------------------------

FACE_C, FACE_R = V(0.0, 0.012, 1.705), (0.074, 0.088, 0.108)
HOOD_C, HOOD_R = V(0.0, 0.0, 1.725), (0.148, 0.17, 0.16)
HOOD_TIP_DIR = V(0.0, -0.62, 0.78).normalized()
HOOD_TIP_LEN = 0.12
HOOD_OPEN = (0.50, 0.62, -0.14)


def _face_surface_y(x, z):
    q = 1.0 - (x / FACE_R[0]) ** 2 - ((z - FACE_C.z) / FACE_R[2]) ** 2
    return FACE_C.y + FACE_R[1] * math.sqrt(max(q, 0.0))


EYE_X, EYE_Z = 0.028, 1.722


def build_face():
    bm = ellipsoid(FACE_C, FACE_R, u=40, v=28)
    # hollow cheeks and a long jaw: pinch the sides below the eyes, drop the chin
    for v in bm.verts:
        dz = v.co.z - FACE_C.z
        if dz < -0.01:
            k = smoothstep(-0.01, -0.06, dz)
            v.co.x *= 1.0 - 0.14 * k
            v.co.z -= 0.012 * k * max(0.0, (v.co.y - FACE_C.y) / FACE_R[1])
    return bm


def build_brow():
    y = _face_surface_y(0.0, 1.742)
    return ellipsoid(V(0.0, y - 0.012, 1.742), (0.064, 0.022, 0.015), u=24, v=12)


def build_nose():
    y = _face_surface_y(0.0, 1.70)
    return ellipsoid(V(0, y + 0.002, 1.698), (0.012, 0.018, 0.026), frame_from_z(V(0, 0.35, 1).normalized()), u=16, v=12)


def build_beard():
    """A long grey beard from the jaw to mid-chest, narrowing to a point."""
    pts = [V(0.0, 0.085, 1.66), V(0.0, 0.10, 1.61), V(0.0, 0.112, 1.55), V(0.0, 0.118, 1.49), V(0.0, 0.115, 1.43)]
    radii = [(0.058, 0.03), (0.052, 0.034), (0.04, 0.03), (0.026, 0.022), (0.012, 0.012)]
    verts, edges = pts, [(i, i + 1) for i in range(len(pts) - 1)]
    bm = skin_tubes(verts, edges, radii, roots=(0,))
    merge(bm, ellipsoid(V(0.0, 0.07, 1.675), (0.07, 0.04, 0.03), u=24, v=12))     # moustache and jaw
    return bm


def build_eyes():
    """Two glowing beads, appended after the fusion as their own islands."""
    bm = bmesh.new()
    for s in (-1.0, 1.0):
        y = _face_surface_y(EYE_X, EYE_Z) - 0.006
        merge(bm, ellipsoid(V(s * EYE_X, y, EYE_Z), (0.011, 0.007, 0.007), u=10, v=6))
    return bm


NOT_FUSED = {"eyes"}


def build_neck():
    return ellipsoid(V(0.0, 0.0, 1.585), (0.055, 0.058, 0.07), u=20, v=12)


def _hood_open(d):
    return d.y > 0.0 and (d.x / HOOD_OPEN[0]) ** 2 + ((d.z - HOOD_OPEN[2]) / HOOD_OPEN[1]) ** 2 < 1.0


def build_hood():
    bm = bmesh.new()
    bmesh.ops.create_uvsphere(bm, u_segments=48, v_segments=32, radius=1.0)
    kill = [f for f in bm.faces
            if _hood_open(f.calc_center_median().normalized()) or f.calc_center_median().z < -0.8]
    bmesh.ops.delete(bm, geom=kill, context="FACES")
    for v in bm.verts:
        d = v.co.normalized()
        p = V(d.x * HOOD_R[0], d.y * HOOD_R[1], d.z * HOOD_R[2])
        p += HOOD_TIP_DIR * (HOOD_TIP_LEN * max(0.0, d.dot(HOOD_TIP_DIR)) ** 3)
        if d.z > 0.0 and d.y > 0.0:
            p.y += 0.075 * d.z * d.y                     # the brim overhangs the brow
        if d.z < -0.3:
            p.x *= 1.0 + 0.35 * smoothstep(-0.3, -0.8, d.z)   # widens into the mantle
        v.co = HOOD_C + p
    out = eval_modifiers(bm, [("SOLIDIFY", {"thickness": 0.025, "offset": -1.0, "use_rim": True,
                                            "use_even_offset": True})])
    bm.free()
    return out


# --------------------------------------------------------------------------
# arms (one Skin skeleton through the shoulders, bell sleeves) and hands
# --------------------------------------------------------------------------

def build_arms():
    cf = {s: E + (W - E) * 0.55 for s, (J, E, W) in ARMS.items()}
    verts = [W_L, cf["L"], E_L, J_L, V(-0.10, -0.01, 1.47), V(0.0, -0.01, 1.46),
             V(0.10, -0.01, 1.47), J_R, E_R, cf["R"], W_R]
    radii = [0.064, 0.05, 0.048, 0.058, 0.07, 0.085, 0.07, 0.058, 0.05, 0.056, 0.078]
    edges = [(i, i + 1) for i in range(len(verts) - 1)]
    return skin_tubes(verts, edges, radii, roots=(5,))


def build_hands():
    bm = bmesh.new()
    d = (W_R - E_R).normalized()
    merge(bm, ellipsoid(GRIP, (0.036, 0.042, 0.046)))                                      # fist on the staff
    merge(bm, ellipsoid(GRIP + V(-0.022, 0.016, 0.034), (0.014, 0.022, 0.014), u=20, v=12))  # thumb
    merge(bm, ellipsoid((W_R + GRIP) * 0.5 - d * 0.01, (0.028, 0.03, 0.045), frame_from_z(d), u=20, v=12))
    d = (W_L - E_L).normalized()
    h = W_L + d * 0.075
    merge(bm, ellipsoid(h, (0.022, 0.04, 0.066), frame_from_z(d)))                          # long thin hand
    merge(bm, ellipsoid(h + d * 0.055 + V(0, 0.01, 0), (0.016, 0.03, 0.04), frame_from_z(d), u=20, v=12))
    merge(bm, ellipsoid(h + V(0.014, 0.03, 0.02), (0.012, 0.014, 0.03),
                        frame_from_z((d + V(0, 0.8, 0)).normalized()), u=20, v=12))
    merge(bm, ellipsoid(W_L + d * 0.01, (0.026, 0.026, 0.04), frame_from_z(d), u=20, v=12))
    return bm


# --------------------------------------------------------------------------
# the staff (separate object; origin at the grip, shaft along +Z)
# --------------------------------------------------------------------------

def build_staff():
    mats = [make_material("Mage_Wood", "#231c17", roughness=0.85),
            make_material("Mage_Bone", "#b9ad90", roughness=0.6),
            make_material("Mage_Gem", "#ff2a14", roughness=0.25, emission="#ff2a14", emission_strength=3.0)]
    wood, bone, gem = 0, 1, 2
    parts = []
    bottom = -GRIP.z + 0.01

    def bend(z):
        return (0.012 * math.sin(3.1 * z + 0.4) + 0.006 * math.sin(7.3 * z),
                0.010 * math.sin(2.3 * z + 1.7) + 0.005 * math.sin(8.9 * z + 0.3))

    def gnarl(z):                      # passes through the grip at z = 0
        bx, by = bend(z)
        ox, oy = bend(0.0)
        return V(bx - ox, by - oy, z)
    zs = [bottom + (0.56 - bottom) * i / 39.0 for i in range(40)]
    radius = [0.018 + 0.006 * (z - bottom) / (0.56 - bottom) + 0.006 * max(0.0, math.sin(11.0 * z + 0.7)) ** 6
              for z in zs]
    parts.append((tube([gnarl(z) for z in zs], radius, sides=10), wood))
    top = gnarl(0.56)
    # a claw of four roots curling up and in around the crystal
    for i in range(4):
        a = math.radians(20 + 90 * i)
        pts, rad = [], []
        for k in range(12):
            s = k / 11.0
            rho = 0.02 + 0.05 * math.sin(math.pi * s * 0.9) - 0.03 * s
            twist = a + 0.9 * s
            pts.append(top + V(rho * math.cos(twist), rho * math.sin(twist), 0.28 * s))
            rad.append(0.013 - 0.009 * s)
        parts.append((tube(pts, rad, sides=6), wood))
    # crimson crystal, long and faceted
    ring = lambda r, z, o, n=6: [top + V(r * math.cos(TAU * (k + o) / n), r * math.sin(TAU * (k + o) / n), z) for k in range(n)]
    parts.append((surface([ring(0.022, 0.07, 0), ring(0.034, 0.13, 0.5), ring(0.026, 0.2, 0)],
                          bottom=top + V(0, 0, 0.035), top=top + V(0, 0, 0.27)), gem))
    # bone band under the claw and two hanging charms
    prof = [(0.0, 0.53), (0.026, 0.53), (0.029, 0.505), (0.026, 0.48), (0.0, 0.48)]
    parts.append((lathe(prof, 12), bone))
    for i, (ang, drop) in enumerate(((0.8, 0.16), (2.6, 0.22))):
        anchor = gnarl(0.5) + V(0.028 * math.cos(ang), 0.028 * math.sin(ang), 0.0)
        end = anchor + V(0.02 * math.cos(ang), 0.02 * math.sin(ang), -drop)
        parts.append((tube([anchor, (anchor + end) * 0.5 + V(0.006, 0, 0), end], [0.003, 0.003, 0.003], sides=4), wood))
        parts.append((ellipsoid(end + V(0, 0, -0.018), (0.012, 0.009, 0.022), u=10, v=8), bone))
    bm = bmesh.new()
    for part, mi in parts:
        for f in part.faces:
            f.material_index = mi
            f.smooth = mi != gem
        merge(bm, part)
        part.free()
    ob = finish_object(bm, "Staff", mats, smooth=False)
    for p in ob.data.polygons:
        p.use_smooth = p.material_index != gem
    return ob


# --------------------------------------------------------------------------
# parts, fusion, paint
# --------------------------------------------------------------------------

PART_GROUP = {
    "robe": "trunk", "mantle": "trunk", "belt": "trunk", "buckle": "trunk", "pouch": "trunk",
    "tome": "trunk", "charm": "trunk",
    "hood": "head", "face": "head", "brow": "head", "eyes": "head", "nose": "head", "beard": "head", "neck": "head",
    "arms": "arm", "hands": "arm", "feet": "foot",
}
METAL_PARTS = {"buckle"}
PART_BIAS = {"nose": 0.002, "brow": 0.002, "buckle": 0.003, "charm": 0.003, "beard": 0.002, "tome": 0.002}


def build_parts():
    return [
        ("robe", build_robe()), ("mantle", build_mantle()), ("belt", build_belt()), ("buckle", build_buckle()),
        ("pouch", build_pouch()), ("tome", build_tome()), ("charm", build_charm()),
        ("feet", build_feet()), ("face", build_face()), ("brow", build_brow()), ("eyes", build_eyes()),
        ("nose", build_nose()), ("beard", build_beard()), ("neck", build_neck()), ("hood", build_hood()),
        ("arms", build_arms()), ("hands", build_hands()),
    ]


def report_gaps(bvh):
    def min_dist(part, target, keep):
        best = 1e9
        for v in dict(PARTS)[part].verts:
            if keep(v.co):
                hit = bvh[target].find_nearest(v.co)
                if hit[0] is not None:
                    best = min(best, hit[3])
        return best
    below_mantle = lambda c: c.z < 1.30 and abs(c.x) > 0.19
    print("SF_DARK_GAP arms-robe=%.3f hands-robe=%.3f feet-robe=%.3f (voxel %.3f)"
          % (min_dist("arms", "robe", below_mantle), min_dist("hands", "robe", lambda c: True),
             min_dist("feet", "robe", lambda c: True), VOXEL))


def fuse(parts, bvh):
    union = bmesh.new()
    for name, bm in parts:
        if name not in NOT_FUSED:
            merge(union, bm)
    rem = eval_modifiers(union, [("REMESH", {"mode": "VOXEL", "voxel_size": VOXEL, "adaptivity": 0.0,
                                             "use_smooth_shade": True}),
                                 ("SMOOTH", {"factor": 0.5, "iterations": 3})])
    union.free()
    tris = sum(len(f.verts) - 2 for f in rem.faces)
    ratio = TARGET_BODY_TRIS / float(tris)
    rem.verts.ensure_lookup_table()
    rem.normal_update()
    labels = classify(rem, bvh)
    cols = [part_colour(lab, v.co, v.normal) for v, lab in zip(rem.verts, labels)]
    edge = [False] * len(rem.verts)
    for e in rem.edges:
        a, b = e.verts[0].index, e.verts[1].index
        if labels[a] != labels[b] or max(abs(x - y) for x, y in zip(cols[a], cols[b])) > 0.02:
            edge[a] = edge[b] = True
    keep = list(edge)
    for v in rem.verts:
        if edge[v.index]:
            for e in v.link_edges:
                keep[e.other_vert(v).index] = True
    dl = rem.verts.layers.deform.verify()
    for v in rem.verts:
        v[dl][0] = 0.0 if keep[v.index] else 1.0
    dec = eval_modifiers(rem, [("DECIMATE", {"decimate_type": "COLLAPSE", "ratio": ratio,
                                             "use_collapse_triangulate": True, "vertex_group": "keep",
                                             "vertex_group_factor": DECIMATE_KEEP}),
                               ("SMOOTH", {"factor": 0.3, "iterations": 2})],
                         setup=lambda ob: ob.vertex_groups.new(name="keep"))
    print("SF_DARK_FUSE remesh_tris=%d ratio=%.4f boundary_verts=%d final_tris=%d verts=%d"
          % (tris, ratio, sum(keep), len(dec.faces), len(dec.verts)))
    rem.free()
    for layer in list(dec.verts.layers.deform.values()):
        dec.verts.layers.deform.remove(layer)
    seen, crumbs = set(), []
    for v in dec.verts:
        if v in seen:
            continue
        stack, piece = [v], [v]
        seen.add(v)
        while stack:
            for e in stack.pop().link_edges:
                for o in e.verts:
                    if o not in seen:
                        seen.add(o)
                        stack.append(o)
                        piece.append(o)
        if len(piece) < 12:
            crumbs.extend(piece)
    if crumbs:
        bmesh.ops.delete(dec, geom=crumbs, context="VERTS")
    print("SF_DARK_CRUMBS removed_verts=%d" % len(crumbs))
    for name, bm in parts:
        if name in NOT_FUSED:
            merge(dec, bm)
    return dec


def classify(bm, bvh):
    names = [n for n, _ in PARTS]
    labels = []
    for v in bm.verts:
        best, best_d = None, 1e9
        for n in names:
            hit = bvh[n].find_nearest(v.co)
            if hit[0] is None:
                continue
            d = hit[3] - PART_BIAS.get(n, 0.0)
            if d < best_d:
                best, best_d = n, d
        labels.append(best)
    return labels


def fib_dirs(n=48):
    out = []
    ga = math.pi * (3.0 - math.sqrt(5.0))
    for i in range(n):
        z = 1.0 - 2.0 * (i + 0.5) / n
        r = math.sqrt(1.0 - z * z)
        out.append(V(r * math.cos(ga * i), r * math.sin(ga * i), z))
    return out


def bake_ao(bm, max_dist=0.30):
    bvh = BVHTree.FromBMesh(bm)
    dirs = fib_dirs(48)
    ao = []
    for v in bm.verts:
        n = v.normal
        o = v.co + n * 0.004
        tot = hit = 0.0
        for d in dirs:
            c = d.dot(n)
            if c <= 0.05:
                continue
            tot += c
            loc = bvh.ray_cast(o, d, max_dist)[0]
            if loc is not None or (d.z < 0.0 and o.z / -d.z < max_dist):
                hit += c
        ao.append(hit / tot if tot > 0 else 0.0)
    return ao


def grain(p, scale, seed=0.0):
    """Cheap value noise for cloth wear, -1..1."""
    return (math.sin(p.x * scale * 1.7 + seed) * math.sin(p.y * scale * 2.3 + seed * 1.3)
            * math.sin(p.z * scale * 1.1 + seed * 0.7))


def part_colour(part, p, n):
    z = p.z
    wear = 1.0 + 0.10 * grain(p, 37.0, 1.0) + 0.06 * grain(p, 91.0, 4.0)
    if part == "robe":
        th = math.atan2(p.x, p.y)
        under, trim, band = robe_regions(th, z)
        c = PAL["robe"].copy()
        c = c.lerp(PAL["robe_dark"], band * 0.85)
        c = c.lerp(PAL["under"], under)
        c = c.lerp(PAL["trim"], trim * (0.55 + 0.45 * max(0.0, math.sin(z * 90.0))))
        t = skirt_t(z)
        c = c * (1.0 + FOLD_PAINT * fold(th, t) * t ** 0.8)
        return c * lerp(0.72, 1.05, smoothstep(0.05, 1.4, z)) * wear
    if part == "mantle":
        th = math.atan2(p.x, p.y)
        edge = smoothstep(MANTLE_EDGE + 0.09 - mantle_edge(th), MANTLE_EDGE - mantle_edge(th), z)
        c = PAL["mantle"].lerp(PAL["mantle_dark"], edge * 0.8)
        return c * lerp(0.85, 1.08, smoothstep(1.2, 1.6, z)) * wear
    if part == "belt":
        return PAL["leather"] * lerp(0.8, 1.05, clamp(n.z * 0.5 + 0.5)) * wear
    if part in ("buckle",):
        return PAL["metal"]
    if part == "pouch":
        return PAL["leather_dark"] * wear
    if part == "tome":
        return PAL["tome"].lerp(PAL["metal"], 0.35 if abs(n.z) > 0.7 else 0.0) * wear
    if part == "charm":
        return PAL["bone"]
    if part == "hood":
        inside = n.dot(HOOD_C - p) > 0.0
        if inside:
            return PAL["hood_in"]
        d = (p - HOOD_C)
        d = V(d.x / HOOD_R[0], d.y / HOOD_R[1], d.z / HOOD_R[2]).normalized()
        e = (d.x / HOOD_OPEN[0]) ** 2 + ((d.z - HOOD_OPEN[2]) / HOOD_OPEN[1]) ** 2
        rim = d.y > 0.0 and e < 1.25
        return (PAL["mantle_dark"] if rim else PAL["hood"]) * lerp(0.88, 1.06, smoothstep(1.6, 1.95, z)) * wear
    if part in ("face", "nose", "brow"):
        c = PAL["skin"].copy()
        for s in (-1.0, 1.0):                                  # sunken eyes and cheeks
            k = (V(s * EYE_X, 0.0, EYE_Z) - V(p.x, 0.0, p.z)).length
            c = c.lerp(PAL["skin_dark"], 0.7 * (1.0 - smoothstep(0.012, 0.03, k)))
            k2 = (V(s * 0.048, 0.0, 1.685) - V(p.x, 0.0, p.z)).length
            c = c.lerp(PAL["skin_dark"], 0.35 * (1.0 - smoothstep(0.01, 0.03, k2)))
        return c
    if part == "beard":
        return PAL["beard"] * (0.85 + 0.2 * abs(math.sin(p.x * 160.0 + p.z * 40.0)))
    if part == "eyes":
        return V(1.0, 0.15, 0.08)
    if part == "neck":
        return PAL["hood_in"]
    if part == "arms":
        side = "R" if p.x > 0 else "L"
        J, E, W = ARMS[side]
        along = (p - E).dot((W - E).normalized()) / (W - E).length
        cuff = smoothstep(0.85, 0.95, along) if abs(p.x) > 0.15 else 0.0
        return PAL["robe"].lerp(PAL["sleeve_in"], cuff * 0.8) * 1.03 * wear
    if part == "hands":
        return PAL["skin"] * 0.92
    if part == "feet":
        return PAL["boot"]
    return PAL["robe"]


# --------------------------------------------------------------------------
# weights (computed, then graph-smoothed)
# --------------------------------------------------------------------------

HEM_ANGLES = {"RobeFront_L": -0.60, "RobeFront_R": 0.60, "RobeBack": math.pi}


def trunk_weights(p):
    w = {}
    z = p.z
    spine = smoothstep(1.02, 1.14, z)
    head = spine * smoothstep(1.56, 1.63, z) * (1.0 - smoothstep(0.12, 0.2, p.xy.length))
    w["Head"] = head
    w["Spine"] = spine - head
    lower = 1.0 - spine
    skirt = lower * smoothstep(1.04, 0.86, z)
    w["Hips"] = lower - skirt
    hem = smoothstep(0.90, 0.30, z)
    w["Robe"] = skirt * (1.0 - hem)
    th = math.atan2(p.x, p.y)
    ks = {}
    for bone, c in HEM_ANGLES.items():
        dth = math.atan2(math.sin(th - c), math.cos(th - c))
        ks[bone] = math.exp(-(dth / 0.9) ** 2)
    tot = sum(ks.values())
    for bone, k in ks.items():
        w[bone] = skirt * hem * k / tot
    return w


def mantle_weights(p):
    """The mantle rides the spine, and over each shoulder follows the upper arm
    a little, so a raised arm lifts the cloth instead of spearing through it."""
    w = trunk_weights(p)
    side = "R" if p.x > 0 else "L"
    J, E, W = ARMS[side]
    b = (p - J).dot((E - J).normalized())
    over = smoothstep(0.10, 0.2, abs(p.x)) * smoothstep(-0.05, 0.08, b) * 0.55
    w = {k: x * (1.0 - over) for k, x in w.items()}
    w["UpperArm_" + side] = w.get("UpperArm_" + side, 0.0) + over
    return w


def arm_weights(p):
    side = "R" if p.x > 0 else "L"
    J, E, W = ARMS[side]
    du = (E - J).normalized()
    dl = (W - E).normalized()
    b = (p - J).dot(du)
    a = (p - E).dot((du + dl).normalized())
    arm = smoothstep(-0.06, 0.03, b)
    low = smoothstep(-0.035, 0.035, a)
    return {"Spine": 1.0 - arm, "UpperArm_" + side: arm * (1.0 - low), "LowerArm_" + side: arm * low}


def compute_weights(bm, labels):
    rows = []
    for v, part in zip(bm.verts, labels):
        g = PART_GROUP[part]
        p = v.co
        if part == "mantle":
            w = mantle_weights(p)
        elif g == "trunk":
            w = trunk_weights(p)
        elif g == "head":
            h = smoothstep(1.53, 1.61, p.z) if part != "beard" else smoothstep(1.40, 1.60, p.z) * 0.6 + 0.4
            w = {"Head": h, "Spine": 1.0 - h}
        elif g == "arm":
            w = {"LowerArm_" + ("R" if p.x > 0 else "L"): 1.0} if part == "hands" else arm_weights(p)
        else:
            w = {"Foot_" + ("R" if p.x > 0 else "L"): 1.0}
        row = [0.0] * len(BONE_NAMES)
        for bone, x in w.items():
            row[BI[bone]] += x
        rows.append(row)
    nbrs = [[e.other_vert(v).index for e in v.link_edges] for v in bm.verts]
    for _ in range(3):
        new = []
        for i, row in enumerate(rows):
            if not nbrs[i]:
                new.append(row)
                continue
            avg = [sum(rows[j][k] for j in nbrs[i]) / len(nbrs[i]) for k in range(len(row))]
            new.append([0.5 * row[k] + 0.5 * avg[k] for k in range(len(row))])
        rows = new
    out = []
    for i, row in enumerate(rows):
        if labels[i] == "feet":
            row = [0.0] * len(BONE_NAMES)
            row[BI["Foot_" + ("R" if bm.verts[i].co.x > 0 else "L")]] = 1.0
        top = sorted(((x, k) for k, x in enumerate(row) if x > 0.01), reverse=True)[:4]
        tot = sum(x for x, _ in top)
        out.append([(k, x / tot) for x, k in top])
    return out


# --------------------------------------------------------------------------
# body object
# --------------------------------------------------------------------------

def vc_material(name, roughness, metallic):
    mat = bpy.data.materials.get(name) or bpy.data.materials.new(name)
    mat.use_nodes = True
    bsdf = _principled(mat)
    node = None
    for nd in mat.node_tree.nodes:
        if nd.type == "VERTEX_COLOR":
            node = nd
    if node is None:
        node = mat.node_tree.nodes.new("ShaderNodeVertexColor")
    node.layer_name = "Col"
    mat.node_tree.links.new(node.outputs[0], _socket(bsdf, "Base Color"))
    _socket(bsdf, "Roughness").default_value = roughness
    _socket(bsdf, "Metallic").default_value = metallic
    mat.diffuse_color = (0.15, 0.13, 0.15, 1.0)
    return mat


def build_body():
    global PARTS
    PARTS = build_parts()
    bvh = {n: BVHTree.FromBMesh(bm) for n, bm in PARTS}
    report_gaps(bvh)
    bm = fuse(PARTS, bvh)
    bm.verts.ensure_lookup_table()
    bm.normal_update()
    labels = classify(bm, bvh)
    ao = bake_ao(bm)
    colours = []
    for v, part, occ in zip(bm.verts, labels, ao):
        # the face is meant to sit in the hood's shadow: keep its occlusion strong
        k = {"eyes": 0.0, "face": 0.7, "nose": 0.7, "brow": 0.7, "beard": 0.5}.get(part, 0.62)
        c = part_colour(part, v.co, v.normal) * clamp(1.0 - k * occ, 0.25, 1.0)
        colours.append((c.x, c.y, c.z, 1.0))
    weights = compute_weights(bm, labels)
    mat_index = []
    for f in bm.faces:
        names = [labels[v.index] for v in f.verts]
        if sum(1 for n in names if n == "eyes") * 2 > len(names):
            mat_index.append(2)
        elif sum(1 for n in names if n in METAL_PARTS) * 2 > len(names):
            mat_index.append(1)
        else:
            mat_index.append(0)
    islands = count_islands(bm, labels)
    for _, pbm in PARTS:
        pbm.free()

    me = bpy.data.meshes.new("Mage_Body")
    bm.to_mesh(me)
    bm.free()
    for poly, mi in zip(me.polygons, mat_index):
        poly.use_smooth = True
        poly.material_index = mi
    me.materials.append(vc_material("Mage_Cloth", 0.88, 0.0))
    me.materials.append(vc_material("Mage_Metal", 0.45, 0.6))
    me.materials.append(make_material("Mage_Glow", "#ff2a14", roughness=0.4, emission="#ff2a14", emission_strength=4.0))
    attr = me.color_attributes.new("Col", "FLOAT_COLOR", "POINT")
    for i, c in enumerate(colours):
        attr.data[i].color = c
    try:
        me.color_attributes.active_color = attr
        me.color_attributes.render_color_index = me.color_attributes.active_color_index
    except (AttributeError, TypeError):
        pass
    ob = bpy.data.objects.new("Mage_Body", me)
    for k, name in enumerate(BONE_NAMES):
        grp = ob.vertex_groups.new(name=name)
        for i, row in enumerate(weights):
            for bk, x in row:
                if bk == k:
                    grp.add([i], x, "REPLACE")
    counts = {}
    for p in labels:
        counts[p] = counts.get(p, 0) + 1
    print("SF_DARK_BODY tris=%d verts=%d islands=%d glow_faces=%d metal_faces=%d parts=%s"
          % (len(me.polygons), len(me.vertices), islands, mat_index.count(2), mat_index.count(1),
             sorted(counts.items())))
    return ob


def count_islands(bm, labels):
    seen = set()
    pieces = []
    for v in bm.verts:
        if v.index in seen:
            continue
        stack, members = [v], []
        seen.add(v.index)
        while stack:
            cur = stack.pop()
            members.append(cur.index)
            for e in cur.link_edges:
                o = e.other_vert(cur)
                if o.index not in seen:
                    seen.add(o.index)
                    stack.append(o)
        names = [labels[i] for i in members]
        pieces.append((len(members), max(set(names), key=names.count)))
    print("SF_DARK_ISLANDS %s" % sorted(pieces, reverse=True))
    return len(pieces)


# --------------------------------------------------------------------------
# rig and clips
# --------------------------------------------------------------------------

def build_rig(coll):
    purge_object("Mage_Armature")
    arm = bpy.data.armatures.new("Mage_Armature")
    ob = bpy.data.objects.new("Mage_Armature", arm)
    coll.objects.link(ob)
    vl = bpy.context.view_layer
    for other in vl.objects:
        other.select_set(False)
    vl.objects.active = ob
    ob.select_set(True)
    bpy.ops.object.mode_set(mode="EDIT")
    try:
        for name, head, tail, parent, connected in BONES:
            eb = arm.edit_bones.new(name)
            eb.head, eb.tail = head, tail
            eb.align_roll(V(1, 0, 0).cross((tail - head).normalized()))
            if parent:
                eb.parent = arm.edit_bones[parent]
                eb.use_connect = connected
    finally:
        bpy.ops.object.mode_set(mode="OBJECT")
    ob.select_set(False)
    return ob


def author_clip(armature, name, frames, sample, loop=True):
    if armature.animation_data is None:
        armature.animation_data_create()
    act = bpy.data.actions.new(name)
    act.use_fake_user = True
    armature.animation_data.action = act
    prev = {}
    for pb in armature.pose.bones:
        pb.rotation_mode = "QUATERNION"
    for frame in range(0, frames + 1, KEY_STEP):
        phase = (frame % frames) / float(frames) if loop else frame / float(frames)
        pose = sample(phase)
        for pb in armature.pose.bones:
            vals = pose.get(pb.name, {})
            q = Euler([math.radians(a) for a in vals.get("rot", (0, 0, 0))], "XYZ").to_quaternion()
            if pb.name in prev and prev[pb.name].dot(q) < 0.0:
                q.negate()
            prev[pb.name] = q
            pb.rotation_quaternion = q
            pb.location = vals.get("loc", (0.0, 0.0, 0.0))
            pb.keyframe_insert("rotation_quaternion", frame=frame, group=pb.name)
            pb.keyframe_insert("location", frame=frame, group=pb.name)
    for fc in act.fcurves:
        for kp in fc.keyframe_points:
            kp.interpolation = "LINEAR"
    armature.animation_data.action = None
    reset_pose(armature)
    return act


STEP_LEN = 0.52      # a long, slow stride; the boots show under the torn hem
FOOT_LIFT = 0.06


def foot_track(q):
    q %= 1.0
    if q < 0.5:
        return STEP_LEN * (0.5 - q / 0.5), 0.0, 0.0
    u = (q - 0.5) / 0.5
    return -0.5 * STEP_LEN + STEP_LEN * u * u * (3 - 2 * u), FOOT_LIFT * math.sin(math.pi * u), 14.0 * math.sin(math.pi * u)


def pose_walk(p):
    s = math.sin(TAU * p)
    c2 = math.cos(2 * TAU * p)
    lean = 5.0                               # a slight stoop, the staff planted with each step
    pose = {
        "Hips": {"loc": (0.0, -0.018 * s * s, 0.0), "rot": (0.0, 5.0 * s, -2.0 * s)},
        "Spine": {"rot": (-lean, -5.0 * s, 1.5 * s)},
        "Head": {"rot": (lean - 2.0, 3.0 * s, -1.0 * s)},
        "UpperArm_L": {"rot": (lean + 14.0 * s, 0.0, 0.0)},
        "LowerArm_L": {"rot": (8.0 + 8.0 * max(0.0, s), 0.0, 0.0)},
        "UpperArm_R": {"rot": (lean - 9.0 * s, 0.0, 0.0)},
        "LowerArm_R": {"rot": (-4.0 * s, 0.0, 0.0)},
        "Robe": {"rot": (-2.0, -4.0 * s, 2.5 * math.sin(TAU * p - 0.6))},
        "RobeBack": {"rot": (-(6.0 + 3.0 * c2), 0.0, 1.5 * math.sin(TAU * p - 1.0))},
    }
    for side, q0 in (("R", 0.25), ("L", 0.75)):
        y, z, pitch = foot_track(p - q0)
        pose["Foot_" + side] = {"loc": (0.0, y, z), "rot": (pitch, 0.0, 0.0)}
        lag_y = foot_track(p - q0 - 0.06)[0]
        kick = max(0.0, lag_y / (0.5 * STEP_LEN)) ** 1.3
        pose["RobeFront_" + side] = {"rot": (2.0 + 20.0 * kick, 0.0, 0.0)}
    return pose


def pose_idle(p):
    s = math.sin(TAU * p)
    c = math.cos(TAU * p)
    return {
        "Spine": {"loc": (0.0, -0.005 * (1.0 - c), 0.0), "rot": (-2.0 - 0.8 * s, 0.0, 0.0)},
        "Head": {"rot": (2.0 + 1.5 * math.sin(TAU * p - 0.6), 4.0 * math.sin(TAU * p + 0.4), 0.0)},
        "UpperArm_R": {"rot": (1.2 * s, 0.0, 0.0)},
        "LowerArm_R": {"rot": (1.2 * math.sin(TAU * p + 0.5), 0.0, 0.0)},
        "UpperArm_L": {"rot": (2.5 * math.sin(TAU * p + 0.8), 0.0, 0.0)},
        "LowerArm_L": {"rot": (4.0 + 2.0 * math.sin(TAU * p + 1.3), 0.0, 0.0)},
        "Robe": {"rot": (0.0, 0.0, 1.0 * s)},
        "RobeBack": {"rot": (1.2 * math.sin(TAU * p + 1.0), 0.0, 0.0)},
        "RobeFront_L": {"rot": (0.8 * math.sin(TAU * p + 2.0), 0.0, 0.0)},
        "RobeFront_R": {"rot": (0.8 * math.sin(TAU * p + 2.6), 0.0, 0.0)},
    }


Z3 = (0.0, 0.0, 0.0)
# Raise the staff (0.30), gather (0.52), thrust the crystal forward
# (0.68..0.82), recover (1.0). The staff is rigid in the right fist, so its
# tilt is UpperArm_R + LowerArm_R about X.
CAST = {
    "UpperArm_R": [(0, Z3), (0.30, (110, 0, -10)), (0.52, (120, 0, -12)), (0.68, (48, 0, -2)), (0.82, (44, 0, -2)), (1, Z3)],
    "LowerArm_R": [(0, Z3), (0.30, (-60, 0, 0)), (0.52, (-66, 0, 0)), (0.68, (-100, 0, 0)), (0.82, (-96, 0, 0)), (1, Z3)],
    "Spine": [(0, Z3), (0.30, (8, -12, 0)), (0.52, (11, -16, 0)), (0.68, (-14, 10, 0)), (0.82, (-11, 8, 0)), (1, Z3)],
    "Head": [(0, Z3), (0.30, (-3, 10, 0)), (0.52, (-2, 14, 0)), (0.68, (8, -8, 0)), (0.82, (6, -6, 0)), (1, Z3)],
    "UpperArm_L": [(0, Z3), (0.30, (50, 0, 12)), (0.52, (40, 0, 6)), (0.68, (-22, 0, 10)), (0.82, (-18, 0, 8)), (1, Z3)],
    "LowerArm_L": [(0, Z3), (0.30, (40, 0, 0)), (0.52, (80, 0, 0)), (0.68, (22, 0, 0)), (0.82, (20, 0, 0)), (1, Z3)],
    "Hips": [(0, Z3), (0.30, (0, -4, 0)), (0.52, (0, -6, 0)), (0.68, (0, 6, 0)), (0.82, (0, 5, 0)), (1, Z3)],
    "Robe": [(0, Z3), (0.30, (2, -5, 0)), (0.52, (3, -7, 0)), (0.68, (-6, 6, 0)), (0.82, (-3, 4, 0)), (1, Z3)],
    "RobeBack": [(0, Z3), (0.52, (4, 0, 0)), (0.70, (-12, 0, 0)), (0.86, (-4, 0, 0)), (1, Z3)],
    "RobeFront_R": [(0, Z3), (0.52, Z3), (0.68, (14, 0, 0)), (0.84, (9, 0, 0)), (1, Z3)],
    "RobeFront_L": [(0, Z3), (0.68, (4, 0, 0)), (1, Z3)],
    "Foot_R": [(0, Z3), (0.60, (10, 0, 0)), (0.68, Z3), (0.86, Z3), (0.93, (8, 0, 0)), (1, Z3)],
}
CAST_LOC = {
    "Hips": [(0, Z3), (0.52, (0, 0, 0.03)), (0.68, (0, -0.02, -0.06)), (0.82, (0, -0.02, -0.05)), (1, Z3)],
    "Foot_R": [(0, Z3), (0.52, Z3), (0.60, (0, 0.08, 0.05)), (0.68, (0, 0.17, 0)), (0.86, (0, 0.17, 0)),
               (0.93, (0, 0.085, 0.03)), (1, Z3)],
}


def _track(keys, t):
    for i in range(len(keys) - 1):
        t0, a = keys[i]
        t1, b = keys[i + 1]
        if t <= t1:
            u = clamp((t - t0) / (t1 - t0))
            u = u * u * u * (u * (6 * u - 15) + 10)
            return tuple(lerp(x, y, u) for x, y in zip(a, b))
    return keys[-1][1]


def pose_cast(t):
    pose = {b: {"rot": _track(k, t)} for b, k in CAST.items()}
    for b, k in CAST_LOC.items():
        pose.setdefault(b, {})["loc"] = _track(k, t)
    return pose


def measure_walk(scene, armature, act):
    armature.animation_data.action = act
    ys, zs = [], []
    for f in range(15, 46):
        scene.frame_set(f)
        bpy.context.view_layer.update()
        h = armature.matrix_world @ armature.pose.bones["Foot_R"].head
        ys.append(h.y)
        zs.append(h.z)
    sweep = ys[0] - ys[-1]
    per_cycle = 2.0 * sweep
    print("SF_DARK_WALK stance_sweep=%.4f m per_cycle=%.4f m clip=%.2f s natural_speed=%.3f m/s planted_z_range=%.4f m"
          % (sweep, per_cycle, WALK_FRAMES / float(ANIM_FPS), per_cycle * ANIM_FPS / WALK_FRAMES, max(zs) - min(zs)))
    armature.animation_data.action = None
    return per_cycle


def deformation_report(scene, body, armature, clips):
    rest = [(e.vertices[0], e.vertices[1], (body.data.vertices[e.vertices[0]].co
                                            - body.data.vertices[e.vertices[1]].co).length)
            for e in body.data.edges]
    for act, frame in clips:
        armature.animation_data.action = act
        scene.frame_set(frame)
        bpy.context.view_layer.update()
        dg = bpy.context.evaluated_depsgraph_get()
        me = body.evaluated_get(dg).to_mesh()
        pairs = sorted(((me.vertices[a].co - me.vertices[b].co).length / max(l, 1e-6), a) for a, b, l in rest)
        worst = body.data.vertices[pairs[-1][1]].co
        body.evaluated_get(dg).to_mesh_clear()
        ratios = [r for r, _ in pairs]
        k = len(ratios)
        print("SF_DARK_DEFORM %-5s frame=%-3d min=%.2f p1=%.2f p99=%.2f max=%.2f worst_at_rest=%s"
              % (act.name, frame, ratios[0], ratios[k // 100], ratios[-k // 100], ratios[-1],
                 tuple(round(c, 2) for c in worst)))
    armature.animation_data.action = None
    reset_pose(armature)
    scene.frame_set(0)


# --------------------------------------------------------------------------
# export, renders, blend
# --------------------------------------------------------------------------

def export_glb(objects, path):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    scene = bpy.context.scene
    old = scene.name
    scene.name = "Mage"
    vl = bpy.context.view_layer
    for ob in vl.objects:
        ob.select_set(False)
    for ob in objects:
        ob.select_set(True)
    vl.objects.active = objects[0]
    try:
        bpy.ops.export_scene.gltf(
            filepath=path, use_selection=True, use_active_scene=True, export_format="GLB",
            export_yup=True, export_apply=True, export_cameras=False, export_lights=False,
            export_extras=False, export_animations=True, export_skins=True, export_def_bones=False,
            export_rest_position_armature=True, export_animation_mode="ACTIONS",
            export_anim_single_armature=True, export_force_sampling=True, export_frame_range=False,
            export_anim_slide_to_zero=False, export_reset_pose_bones=True, export_bake_animation=False,
            export_morph_animation=False, export_vertex_color="MATERIAL")
    finally:
        scene.name = old
    for ob in objects:
        ob.select_set(False)
    import json
    import struct
    with open(path, "rb") as fh:
        data = fh.read()
    n = struct.unpack("<I", data[12:16])[0]
    js = json.loads(data[20:20 + n].decode("utf-8"))
    col = any("COLOR_0" in prim["attributes"] for m in js["meshes"] for prim in m["primitives"])
    print("SF_DARK_GLB %s bytes=%d scenes=%d nodes=%d anims=%s color0=%s materials=%s"
          % (os.path.basename(path), len(data), len(js.get("scenes", [])), len(js["nodes"]),
             [a["name"] for a in js.get("animations", [])], col, [m["name"] for m in js.get("materials", [])]))


def render_all(scene, objects, armature, acts):
    os.makedirs(PREVIEW_DIR, exist_ok=True)
    out = lambda n: os.path.join(PREVIEW_DIR, "mage_dark_%s.png" % n)
    render_preview(objects, out("front"), yaw_deg=25.0)
    render_preview(objects, out("side"), yaw_deg=90.0)
    render_preview(objects, out("back"), yaw_deg=180.0 + 35.0)
    armature.animation_data.action = acts["walk"]
    scene.frame_set(int(round(0.25 * WALK_FRAMES)))
    bpy.context.view_layer.update()
    render_preview(objects, out("walk"), yaw_deg=70.0)
    armature.animation_data.action = acts["cast"]
    scene.frame_set(int(round(CAST_PEAK * CAST_FRAMES)))
    bpy.context.view_layer.update()
    render_preview(objects, out("cast"), yaw_deg=65.0)
    if "--debug" in sys.argv:
        ddir = sys.argv[sys.argv.index("--debug") + 1]
        for act, frame, yaw in (("cast", 18, 35.0), ("cast", 31, 20.0), ("walk", 45, 20.0), ("idle", 0, 0.0)):
            armature.animation_data.action = acts[act]
            scene.frame_set(frame)
            bpy.context.view_layer.update()
            render_preview(objects, os.path.join(ddir, "dbg_%s_%d_%d.png" % (act, frame, yaw)), yaw_deg=yaw)
    armature.animation_data.action = None
    reset_pose(armature)
    scene.frame_set(0)
    bpy.context.view_layer.update()


def save_blend(scene, armature, acts):
    path = _blend_path()
    os.makedirs(os.path.dirname(path), exist_ok=True)
    armature.animation_data.action = acts["walk"]
    scene.frame_start, scene.frame_end = 0, WALK_FRAMES
    scene.frame_set(0)
    for name in ("Cube", "Light", "Camera"):
        ob = bpy.data.objects.get(name)
        if ob is not None:
            bpy.data.objects.remove(ob, do_unlink=True)
    bpy.ops.wm.save_as_mainfile(filepath=path, copy=True)
    print("SF_DARK_BLEND %s" % path)


def main():
    scene = assets_scene()
    activate_scene(scene)
    scene.render.fps, scene.render.fps_base = ANIM_FPS, 1.0
    coll = model_collection("SF_MageDark")

    t0 = time.time()
    body = build_body()
    t_body = time.time() - t0
    staff = build_staff()
    armature = build_rig(coll)
    link(coll, body, staff)
    skin_to_armature(body, armature)
    bpy.context.view_layer.update()
    parent_to_bone(staff, armature, "LowerArm_R", world=Matrix.Translation(GRIP))
    top = world_bounds([body])[1].z
    hand = add_empty("HandPoint", tuple(GRIP), collection=coll)
    parent_to_bone(hand, armature, "LowerArm_R")
    overhead = add_empty("OverheadAnchor", (0.0, 0.0, top + OVERHEAD_CLEARANCE), parent=armature, collection=coll)
    bpy.context.view_layer.update()

    acts = {
        "idle": author_clip(armature, "idle", IDLE_FRAMES, pose_idle),
        "walk": author_clip(armature, "walk", WALK_FRAMES, pose_walk),
        "cast": author_clip(armature, "cast", CAST_FRAMES, pose_cast, loop=False),
    }
    measure_walk(scene, armature, acts["walk"])
    deformation_report(scene, body, armature,
                       [(acts["walk"], 15), (acts["walk"], 45), (acts["cast"], 18), (acts["cast"], 31),
                        (acts["cast"], 42)])
    objects = [armature, body, staff, hand, overhead]
    lo, hi = world_bounds([body, staff])
    print("SF_DARK_MODEL body_tris=%d staff_tris=%d height_body=%.3f height_staff=%.3f base_z=%.3f "
          "grip=%s overhead=%.3f bones=%d"
          % (tri_count(body), tri_count(staff), top, hi.z, lo.z, tuple(round(c, 3) for c in GRIP),
             top + OVERHEAD_CLEARANCE, len(armature.data.bones)))
    export_glb(objects, MODEL_PATH)
    if DO_RENDER:
        render_all(scene, objects, armature, acts)
    save_blend(scene, armature, acts)
    print("SF_DARK_TIME body=%.1f s total=%.1f s" % (t_body, time.time() - T_START))
    print("SF_MAGE_DARK DONE")


main()
