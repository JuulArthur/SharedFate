# Shared Fate 3D style study: the mage in a "soft sculpted" style.
#
# Command line (Blender 4.3):
#     blender --background --factory-startup --python tools/blender/mage_styles/mage_soft.py -- --root <repo>
#         [--blend <path>]   where to save the viewable .blend (default: the main
#                            checkout's blender/mage_soft.blend)
#         [--no-render]      skip the preview renders (export only)
#
# Pipeline, all procedural:
#   1. Parts. The robe, cowl and sash are lathe surfaces with procedural folds,
#      the hood a deformed sphere shell (Solidify), the arms and hair Skin
#      modifier skeletons with Subdivision Surface, face, hands, feet, eyes and
#      knot ellipsoids.
#   2. Fuse. All parts are joined and voxel remeshed into one watertight
#      surface, smoothed, decimated to about 7,800 triangles and smoothed again.
#   3. Paint. Every final vertex takes the colour of the nearest source part
#      (with the robe's regions, fold shading and a vertical gradient), times a
#      baked ambient occlusion from 48 ray casts, into a float colour attribute
#      `Col`. The body has two materials that read it: cloth and gold.
#   4. Rig. The WP11 mage bones plus RobeFront_L/R, RobeBack and Foot_L/R.
#      Weights are computed from the part and the position (distance along
#      the arm chains, height and angle on the skirt), graph-smoothed and
#      limited to four influences. No automatic (heat) weights.
#   5. Clips `idle` (2.0 s loop), `walk` (1.0 s loop) and `cast` (1.0 s), keyed
#      every 2 frames at 60 fps, exported like WP11 (ACTIONS mode).
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
from mathutils import Vector, Matrix, Euler, Quaternion
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

MODEL_PATH = os.path.join(SF_ROOT, "assets", "3d", "models", "styles", "mage_soft.glb")
PREVIEW_DIR = os.path.join(SF_ROOT, "assets", "3d", "previews", "styles")
DO_RENDER = "--no-render" not in sys.argv


def _blend_path():
    if "--blend" in sys.argv:
        return os.path.abspath(sys.argv[sys.argv.index("--blend") + 1])
    root = os.path.abspath(SF_ROOT)
    marker = os.sep + ".claude" + os.sep + "worktrees" + os.sep
    main = root.split(marker)[0] if marker in root else root
    return os.path.join(main, "blender", "mage_soft.blend")


TAU = 2.0 * math.pi
ANIM_FPS = 60
IDLE_FRAMES, WALK_FRAMES, CAST_FRAMES = 120, 60, 60
KEY_STEP = 2
CAST_PEAK = 0.70                 # thrust fully extended
VOXEL = 0.008                    # remesh voxel, metres
TARGET_BODY_TRIS = 7800
DECIMATE_KEEP = 8.0              # Decimate vertex-group factor protecting colour edges
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


# --------------------------------------------------------------------------
# palette (sRGB hex, from generate_characters.py / SoulArt.MAGE_* / Soul.COLOR_MAGE)
# --------------------------------------------------------------------------

def _lin(h):
    return Vector(srgb_to_linear(h)[:3])


PAL = {k: _lin(h) for k, h in {
    "robe": "#5C388C", "robe_dark": "#3D2461", "trim": "#9E7AD1", "hood": "#4D2E7A",
    "hood_in": "#24172F", "skin": "#DBC2AD", "blush": "#E3A99A", "eye": "#2A1D33",
    "gold": "#D9B352", "grey": "#6E6E78", "under": "#8A8795", "hair": "#C7C7D1",
}.items()}

# --------------------------------------------------------------------------
# landmarks and rig
# --------------------------------------------------------------------------

J_R, E_R, W_R = V(0.265, -0.01, 1.35), V(0.30, -0.02, 1.10), V(0.31, 0.19, 1.155)
J_L, E_L, W_L = V(-0.265, -0.01, 1.35), V(-0.31, -0.01, 1.11), V(-0.335, 0.075, 0.935)
GRIP = W_R + (W_R - E_R).normalized() * 0.06          # HandPoint and staff origin
ARMS = {"R": (J_R, E_R, W_R), "L": (J_L, E_L, W_L)}

FOOT_Y, FOOT_X = 0.19, 0.10

# (bone, head, tail, parent, connected). The WP11 mage bones keep their names;
# the robe gets three hem bones and the feet (hidden under the hem) two root
# bones, so a planted foot never rides the hip bob.
BONES = [
    ("Hips", V(0, 0, 0.93), V(0, 0, 1.03), None, False),
    ("Spine", V(0, 0, 1.03), V(0, 0, 1.44), "Hips", False),
    ("Head", V(0, 0, 1.46), V(0, 0, 1.90), "Spine", False),
    ("UpperArm_L", J_L, E_L, "Spine", False),
    ("LowerArm_L", E_L, W_L, "UpperArm_L", True),
    ("UpperArm_R", J_R, E_R, "Spine", False),
    ("LowerArm_R", E_R, W_R, "UpperArm_R", True),
    ("Robe", V(0, 0, 1.00), V(0, 0, 0.12), "Hips", False),
    ("RobeFront_L", V(-0.10, 0.03, 0.92), V(-0.17, 0.30, 0.12), "Robe", False),
    ("RobeFront_R", V(0.10, 0.03, 0.92), V(0.17, 0.30, 0.12), "Robe", False),
    ("RobeBack", V(0, -0.03, 0.92), V(0, -0.30, 0.12), "Robe", False),
    ("Foot_L", V(-FOOT_X, FOOT_Y, 0.045), V(-FOOT_X, FOOT_Y + 0.14, 0.045), None, False),
    ("Foot_R", V(FOOT_X, FOOT_Y, 0.045), V(FOOT_X, FOOT_Y + 0.14, 0.045), None, False),
]
BONE_NAMES = [b[0] for b in BONES]
BI = {n: i for i, n in enumerate(BONE_NAMES)}

# --------------------------------------------------------------------------
# geometry helpers
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


def surface(rows, bottom=None, top=None, closed=True):
    """Quad grid through `rows` (lists of points, equal length, closed around),
    optionally capped with a fan to a pole at each end."""
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
    rows.reverse()                     # bottom first
    return surface(rows, bottom=V(0, 0, profile[-1][1]), top=V(0, 0, profile[0][1]))


def tube(path, radii, sides=8):
    """Closed tube along `path` (parallel-transported frames), capped."""
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
    me = bpy.data.meshes.new("_soft_tmp")
    src.to_mesh(me)
    dst.from_mesh(me)
    bpy.data.meshes.remove(me)


def eval_modifiers(bm_in, mods, setup=None):
    """Run `bm_in` through a modifier stack on a temporary object in the assets
    scene and return the evaluated result as a new bmesh (modifiers applied
    without operators, so it works in --background)."""
    me = bpy.data.meshes.new("_soft_eval")
    bm_in.to_mesh(me)
    ob = bpy.data.objects.new("_soft_eval", me)
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
    """Skin modifier on an edge skeleton + Subdivision Surface, applied."""
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
# the robe: a lathe with a flared profile, procedural folds and regions
# --------------------------------------------------------------------------

WAIST_Z = 1.02
NECK_Z = 1.49
ROBE_CP = [(0.00, 0.41, 0.385), (0.07, 0.40, 0.375), (0.20, 0.378, 0.352), (0.40, 0.333, 0.307),
           (0.60, 0.282, 0.257), (0.80, 0.226, 0.202), (0.95, 0.186, 0.166), (1.02, 0.176, 0.156),
           (1.12, 0.182, 0.158), (1.25, 0.183, 0.153), (1.35, 0.165, 0.140), (1.43, 0.112, 0.100),
           (1.49, 0.062, 0.060), (1.55, 0.030, 0.030)]
FOLDS = [(7, 0.55, 0.4, 1.3), (11, 0.28, 2.2, -0.9), (5, 0.17, 4.1, 0.6)]
FOLD_DEPTH = 0.042               # fold amplitude at the hem (m)
FOLD_PAINT = 0.24                # fold valleys painted this much darker, ridges lighter


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
    return clamp((WAIST_Z - z) / (WAIST_Z - 0.07))


def fold(theta, t):
    return sum(a * math.cos(k * theta + ph + dz * t + 0.3 * math.sin(2 * theta + ph))
               for k, a, ph, dz in FOLDS)


def hem_z(theta):
    return 0.07 + 0.012 * fold(theta, 1.0) + 0.022 * max(0.0, math.cos(theta)) ** 2


def opening_edge(theta, z):
    """Signed angular distance (rad) inside the front opening of the outer robe
    (> 0 inside), and the skirt fade-in."""
    t = skirt_t(z)
    th = math.atan2(math.sin(theta), math.cos(theta))
    return math.radians(24.0) * t ** 0.75 - abs(th), smoothstep(0.0, 0.12, t)


def robe_regions(theta, z):
    """(underrobe, trim, hem band, placket) membership in 0..1."""
    e, fade = opening_edge(theta, z)
    under = smoothstep(-0.015, 0.015, e) * fade
    trim = smoothstep(-0.10, -0.075, e) * (1.0 - smoothstep(-0.02, -0.005, e)) * fade
    band = smoothstep(hem_z(theta) + 0.075, hem_z(theta) + 0.06, z)
    th = math.atan2(math.sin(theta), math.cos(theta))
    placket = (1.0 - smoothstep(0.06, 0.085, abs(th))) * smoothstep(WAIST_Z, WAIST_Z + 0.02, z) \
        * (1.0 - smoothstep(1.38, 1.41, z))
    return under, trim, band, placket


def robe_point(theta, z):
    rx, ry = robe_profile(z)
    t = skirt_t(z)
    d = 0.0
    if z < WAIST_Z:
        d += (0.003 + FOLD_DEPTH * t ** 1.2) * fold(theta, t)
    elif z < WAIST_Z + 0.10:
        d += 0.007 * (1.0 - (z - WAIST_Z) / 0.10) * (0.6 * math.cos(9 * theta + 0.5) + 0.4)
    under, trim, band, placket = robe_regions(theta, z)
    d += -0.012 * under + 0.005 * trim + 0.008 * band + 0.004 * placket
    return V((rx + d) * math.sin(theta), (ry + d) * math.cos(theta), z)


def build_robe(n_theta=144, n_rows=100, cap_rows=6):
    rows = []
    for k in range(cap_rows, 0, -1):                     # bottom dome, inside out
        f = k / float(cap_rows + 1)
        row = []
        for j in range(n_theta):
            th = TAU * j / n_theta
            p = robe_point(th, hem_z(th))
            zc = hem_z(th) + (0.25 - hem_z(th)) * (1.0 - (1.0 - f) ** 2)
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
    return surface(rows, bottom=V(0, 0, 0.25), top=V(0, 0, NECK_Z + 0.02))


def build_cowl():
    prof = [(0.0, 1.535), (0.10, 1.53), (0.17, 1.505), (0.225, 1.46), (0.265, 1.40), (0.29, 1.34),
            (0.302, 1.29), (0.300, 1.262), (0.285, 1.248), (0.255, 1.25), (0.20, 1.27), (0.12, 1.30),
            (0.0, 1.31)]

    def edge(th, r, z):
        if z > 1.30 or r < 0.2:
            return 0.0
        return 0.012 * math.cos(6 * th + 0.5) - 0.035 * max(0.0, math.cos(th)) ** 8
    return lathe(prof, 96, radius_scale=(1.0, 0.93), edge_fn=edge)


COWL_EDGE_Z = 1.27
BROOCH_C = V(0.0, 0.255, 1.395)


def build_sash():
    n, m = 96, 12
    rows = []
    for i in range(m):
        psi = TAU * i / m
        row = []
        for j in range(n):
            th = TAU * j / n
            rx, ry = robe_profile(WAIST_Z)
            rad = 0.010 + 0.022 * math.cos(psi)
            row.append(V((rx + rad) * math.sin(th), (ry + rad) * math.cos(th), WAIST_Z + 0.036 * math.sin(psi)))
        rows.append(row)
    # the tube's rows run around psi; close it by repeating the first row
    rows.append(rows[0])
    bm = surface(rows)
    bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=1e-5)
    return bm


KNOT_TH = -0.45


def _skirt_surface(theta, z, out=0.0):
    p = robe_point(theta, z)
    n = V(math.sin(theta), math.cos(theta), 0.0)
    return p + n * out, n


def build_knot():
    p, n = _skirt_surface(KNOT_TH, WAIST_Z, 0.038)
    return ellipsoid(p, (0.05, 0.034, 0.045), frame_from_z(V(0, 0, 1), xhint=V(n.y, -n.x, 0)))


def build_tails():
    bm = bmesh.new()
    for th, zc, half, splay in ((KNOT_TH + 0.05, 0.86, 0.13, -9.0), (KNOT_TH - 0.14, 0.845, 0.15, 11.0)):
        p, n = _skirt_surface(th, zc, 0.010)
        r_hi = robe_point(th, zc + 0.1).xy.length
        r_lo = robe_point(th, zc - 0.1).xy.length
        slope = math.atan2(r_lo - r_hi, 0.2)
        down = (V(0, 0, -1) + n * math.tan(slope)).normalized()
        down = Matrix.Rotation(math.radians(splay), 3, n) @ down
        tang = n.cross(down).normalized()
        axes = Matrix((tang, n, down)).transposed()
        merge(bm, ellipsoid(p, (0.034, 0.018, half), axes, u=24, v=16))
    return bm


def build_feet():
    bm = bmesh.new()
    for s in (-1.0, 1.0):
        merge(bm, ellipsoid(V(s * FOOT_X, FOOT_Y, 0.042), (0.066, 0.11, 0.042), u=24, v=14))
    return bm


# --------------------------------------------------------------------------
# head: face, eyes, nose, hair, neck, deep hood
# --------------------------------------------------------------------------

FACE_C, FACE_R = V(0.0, 0.035, 1.625), (0.13, 0.125, 0.145)
HOOD_C, HOOD_R = V(0.0, -0.015, 1.665), (0.215, 0.235, 0.225)
HOOD_TIP_DIR = V(0.0, -0.55, 0.83).normalized()
HOOD_TIP_LEN = 0.10
HOOD_OPEN = (0.60, 0.76, -0.06)       # x and z half-axes, z offset of the opening on the unit sphere


def _face_surface_y(x, z):
    q = 1.0 - (x / FACE_R[0]) ** 2 - ((z - FACE_C.z) / FACE_R[2]) ** 2
    return FACE_C.y + FACE_R[1] * math.sqrt(max(q, 0.0))


EYE_X, EYE_Z = 0.046, 1.628


def build_face():
    return ellipsoid(FACE_C, FACE_R, u=40, v=28)


def build_eyes():
    """Two beads set into the face. Features this small do not survive an 8 mm
    voxel remesh plus decimation, so they are appended after the fusion as
    their own islands (skinned to Head), like the painted-on eyes of a toy."""
    bm = bmesh.new()
    for s in (-1.0, 1.0):
        y = _face_surface_y(EYE_X, EYE_Z) - 0.004
        merge(bm, ellipsoid(V(s * EYE_X, y, EYE_Z), (0.017, 0.011, 0.024), u=10, v=6))
    return bm


NOT_FUSED = {"eyes"}


def build_nose():
    return ellipsoid(V(0, _face_surface_y(0.0, 1.60) + 0.002, 1.60), (0.022, 0.02, 0.02), u=16, v=12)


def build_hair():
    verts, edges, radii, roots = [], [], [], []
    for s in (-1.0, 1.0):
        base = len(verts)
        verts += [V(s * 0.100, 0.070, 1.725), V(s * 0.122, 0.090, 1.625), V(s * 0.116, 0.100, 1.53)]
        radii += [0.030, 0.034, 0.024]
        edges += [(base, base + 1), (base + 1, base + 2)]
        roots.append(base)
    bm = skin_tubes(verts, edges, radii, roots)
    merge(bm, ellipsoid(V(0.0, 0.10, 1.745), (0.10, 0.045, 0.028), u=24, v=12))     # fringe
    return bm


def build_neck():
    return ellipsoid(V(0.0, 0.0, 1.49), (0.08, 0.08, 0.085), u=20, v=12)


def _hood_open(d):
    return d.y > 0.0 and (d.x / HOOD_OPEN[0]) ** 2 + ((d.z - HOOD_OPEN[2]) / HOOD_OPEN[1]) ** 2 < 1.0


def build_hood():
    bm = bmesh.new()
    bmesh.ops.create_uvsphere(bm, u_segments=48, v_segments=32, radius=1.0)
    kill = [f for f in bm.faces
            if _hood_open(f.calc_center_median().normalized()) or f.calc_center_median().z < -0.74]
    bmesh.ops.delete(bm, geom=kill, context="FACES")
    for v in bm.verts:
        d = v.co.normalized()
        p = V(d.x * HOOD_R[0], d.y * HOOD_R[1], d.z * HOOD_R[2])
        p += HOOD_TIP_DIR * (HOOD_TIP_LEN * max(0.0, d.dot(HOOD_TIP_DIR)) ** 3)
        if d.z > 0.0 and d.y > 0.0:
            p.y += 0.03 * d.z * d.y                      # the brim overhangs the brow
        v.co = HOOD_C + p
    out = eval_modifiers(bm, [("SOLIDIFY", {"thickness": 0.04, "offset": -1.0, "use_rim": True,
                                            "use_even_offset": True})])
    bm.free()
    return out


# --------------------------------------------------------------------------
# arms (one Skin skeleton through the shoulders) and hands
# --------------------------------------------------------------------------

def build_arms():
    cf = {s: E + (W - E) * 0.62 for s, (J, E, W) in ARMS.items()}
    verts = [W_L, cf["L"], E_L, J_L, V(-0.17, -0.01, 1.38), V(0.0, -0.01, 1.37),
             V(0.17, -0.01, 1.38), J_R, E_R, cf["R"], W_R]
    radii = [0.090, 0.068, 0.064, 0.072, 0.085, 0.100, 0.085, 0.072, 0.064, 0.068, 0.090]
    edges = [(i, i + 1) for i in range(len(verts) - 1)]
    return skin_tubes(verts, edges, radii, roots=(5,))


def build_hands():
    bm = bmesh.new()
    # right: a fist around the (vertical) staff, thumb on top
    d = (W_R - E_R).normalized()
    merge(bm, ellipsoid(GRIP, (0.052, 0.058, 0.062)))
    merge(bm, ellipsoid(GRIP + V(-0.03, 0.022, 0.045), (0.022, 0.03, 0.022), u=20, v=12))
    merge(bm, ellipsoid((W_R + GRIP) * 0.5 - d * 0.01, (0.04, 0.04, 0.06), frame_from_z(d), u=20, v=12))
    # left: a relaxed mitten, flat side to the body, thumb forward
    d = (W_L - E_L).normalized()
    h = W_L + d * 0.08
    merge(bm, ellipsoid(h, (0.032, 0.052, 0.075), frame_from_z(d)))
    merge(bm, ellipsoid(h + V(0.02, 0.042, 0.03), (0.018, 0.02, 0.035),
                        frame_from_z((d + V(0, 0.8, 0)).normalized()), u=20, v=12))
    merge(bm, ellipsoid(W_L + d * 0.01, (0.036, 0.036, 0.05), frame_from_z(d), u=20, v=12))
    return bm


# --------------------------------------------------------------------------
# the staff (separate object; origin at the grip, shaft along +Z)
# --------------------------------------------------------------------------

def build_staff():
    mats = [make_material("Mage_Grey", "#6E6E78", roughness=0.70),
            make_material("Mage_Band", "#D9B352", metallic=0.6, roughness=0.40),
            make_material("Mage_Gem", "#CC9EFF", roughness=0.20, emission="#CC9EFF", emission_strength=0.9)]
    wood, band, gem = 0, 1, 2
    parts = []

    def wob(z):
        return V(0.008 * (math.sin(2.3 * z + 0.4) - math.sin(0.4)),
                 0.007 * (math.sin(3.1 * z + 1.7) - math.sin(1.7)), z)
    zs = [-1.15 + 1.75 * i / 27.0 for i in range(28)]
    radius = [0.026 + 0.008 * (z + 1.15) / 1.75 + 0.004 * math.sin(9.0 * z) ** 2 for z in zs]
    parts.append((tube([wob(z) for z in zs], radius, sides=12), wood))
    for z0, z1, r in ((-1.10, -1.05, 0.036), (0.57, 0.625, 0.045)):
        prof = [(0.0, z1), (r * 0.8, z1), (r, (z0 + z1) * 0.5 + 0.012), (r, (z0 + z1) * 0.5 - 0.012),
                (r * 0.8, z0), (0.0, z0)]
        parts.append((lathe(prof, 12), band))
    for i in range(3):
        a = math.radians(30 + 120 * i)
        pts, rad = [], []
        for k in range(10):
            s = k / 9.0
            rho = 0.032 + 0.046 * math.sin(math.pi * s * 0.85) - 0.024 * s
            pts.append(V(rho * math.cos(a), rho * math.sin(a), 0.61 + 0.22 * s))
            rad.append(0.012 - 0.006 * s)
        parts.append((tube(pts, rad, sides=6), band))
    ring = lambda r, z, o: [V(r * math.cos(TAU * (k + o) / 8), r * math.sin(TAU * (k + o) / 8), z) for k in range(8)]
    parts.append((surface([ring(0.042, 0.665, 0), ring(0.058, 0.70, 0.5), ring(0.05, 0.755, 0)],
                          bottom=V(0, 0, 0.625), top=V(0, 0, 0.855)), gem))
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
    "robe": "trunk", "sash": "trunk", "knot": "trunk", "tails": "trunk", "cowl": "trunk", "brooch": "trunk",
    "hood": "head", "face": "head", "eyes": "head", "nose": "head", "hair": "head", "neck": "head",
    "arms": "arm", "hands": "arm", "feet": "foot",
}
GOLD_PARTS = {"sash", "knot", "tails", "brooch"}
# small parts win ties against the big surface they sit on
PART_BIAS = {"nose": 0.002, "brooch": 0.003, "knot": 0.002, "tails": 0.002, "hair": 0.001}


def build_parts():
    return [
        ("robe", build_robe()), ("cowl", build_cowl()), ("sash", build_sash()), ("knot", build_knot()),
        ("tails", build_tails()), ("brooch", ellipsoid(BROOCH_C, (0.032, 0.018, 0.032), u=20, v=12)),
        ("feet", build_feet()), ("face", build_face()), ("eyes", build_eyes()), ("nose", build_nose()),
        ("hair", build_hair()), ("neck", build_neck()), ("hood", build_hood()),
        ("arms", build_arms()), ("hands", build_hands()),
    ]


def report_gaps(bvh):
    """Distances that must stay open for the arms and feet to move freely."""
    def min_dist(part, target, keep):
        best = 1e9
        for v in dict(PARTS)[part].verts:
            if keep(v.co):
                hit = bvh[target].find_nearest(v.co)
                if hit[0] is not None:
                    best = min(best, hit[3])
        return best
    below_shoulder = lambda c: c.z < 1.22
    print("SF_SOFT_GAP arms-robe=%.3f hands-robe=%.3f feet-robe=%.3f (voxel %.3f)"
          % (min_dist("arms", "robe", below_shoulder), min_dist("hands", "robe", lambda c: True),
             min_dist("feet", "robe", lambda c: True), VOXEL))


def fuse(parts, bvh):
    union = bmesh.new()
    for name, bm in parts:
        if name not in NOT_FUSED:
            merge(union, bm)
    rem = eval_modifiers(union, [("REMESH", {"mode": "VOXEL", "voxel_size": VOXEL, "adaptivity": 0.0,
                                             "use_smooth_shade": True}),
                                 ("SMOOTH", {"factor": 0.5, "iterations": 4})])
    union.free()
    tris = sum(len(f.verts) - 2 for f in rem.faces)
    ratio = TARGET_BODY_TRIS / float(tris)
    # Colour boundaries decimate into ragged edges unless they keep their
    # density: paint the fine mesh once, and give the vertices on a colour
    # edge (and their neighbours) weight 0 in the Decimate vertex group, which
    # raises their collapse cost (Blender weighs the cost by 2 - w1 - w2).
    rem.verts.ensure_lookup_table()
    rem.normal_update()
    labels = classify(rem, bvh)
    cols = [part_colour(lab, v.co, v.normal) for v, lab in zip(rem.verts, labels)]
    edge = [False] * len(rem.verts)
    for e in rem.edges:
        a, b = e.verts[0].index, e.verts[1].index
        if labels[a] != labels[b] or max(abs(x - y) for x, y in zip(cols[a], cols[b])) > 0.035:
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
                               ("SMOOTH", {"factor": 0.35, "iterations": 2})],
                         setup=lambda ob: ob.vertex_groups.new(name="keep"))
    print("SF_SOFT_FUSE remesh_tris=%d ratio=%.4f boundary_verts=%d final_tris=%d verts=%d"
          % (tris, ratio, sum(keep), len(dec.faces), len(dec.verts)))
    rem.free()
    for layer in list(dec.verts.layers.deform.values()):   # the "keep" weights must not become Hips
        dec.verts.layers.deform.remove(layer)
    # decimation leaves a few stray triangles where the hair tips thin out
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
    print("SF_SOFT_CRUMBS removed_verts=%d" % len(crumbs))
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


def part_colour(part, p, n):
    """Albedo (linear) of a final vertex at `p` with normal `n`."""
    z = p.z
    if part == "robe":
        th = math.atan2(p.x, p.y)
        under, trim, band, placket = robe_regions(th, z)
        c = PAL["robe"].copy()
        c = c.lerp(PAL["robe_dark"], band)
        c = c.lerp(PAL["under"], under)
        c = c.lerp(PAL["trim"], max(trim, placket))
        t = skirt_t(z)
        c = c * (1.0 + FOLD_PAINT * fold(th, t) * t ** 0.8)           # painted fold depth
        return c * lerp(0.80, 1.06, smoothstep(0.05, 1.35, z))
    if part == "cowl":
        c = PAL["hood"].lerp(PAL["trim"], smoothstep(COWL_EDGE_Z + 0.035, COWL_EDGE_Z + 0.02, z))
        return c * lerp(0.92, 1.05, smoothstep(1.25, 1.5, z))
    if part in ("sash", "knot", "tails", "brooch"):
        return PAL["gold"] * lerp(0.85, 1.0, clamp(n.z * 0.5 + 0.5))
    if part == "hood":
        d = (p - HOOD_C)
        d = V(d.x / HOOD_R[0], d.y / HOOD_R[1], d.z / HOOD_R[2]).normalized()
        inside = n.dot(HOOD_C - p) > 0.0
        if inside:
            return PAL["hood_in"]
        e = (d.x / HOOD_OPEN[0]) ** 2 + ((d.z - HOOD_OPEN[2]) / HOOD_OPEN[1]) ** 2
        rim = d.y > 0.0 and e < 1.32
        return (PAL["trim"] if rim else PAL["hood"]) * lerp(0.9, 1.08, smoothstep(1.5, 1.95, z))
    if part in ("face", "nose"):
        c = PAL["skin"].copy()
        for s in (-1.0, 1.0):
            k = (V(s * 0.075, 0.0, 1.595) - V(p.x, 0.0, p.z)).length
            c = c.lerp(PAL["blush"], 0.55 * (1.0 - smoothstep(0.015, 0.04, k)) * (1.0 if p.y > 0.08 else 0.0))
        return c
    if part == "eyes":
        return PAL["eye"]
    if part == "hair":
        return PAL["hair"]
    if part == "neck":
        return PAL["hood_in"]
    if part == "arms":
        side = "R" if p.x > 0 else "L"
        J, E, W = ARMS[side]
        along = (p - E).dot((W - E).normalized()) / (W - E).length
        c = PAL["robe"].lerp(PAL["trim"], smoothstep(0.80, 0.86, along) if abs(p.x) > 0.2 else 0.0)
        return c * 1.02
    if part == "hands":
        return PAL["skin"]
    if part == "feet":
        return PAL["grey"]
    return PAL["robe"]


# --------------------------------------------------------------------------
# weights (computed, then graph-smoothed)
# --------------------------------------------------------------------------

HEM_ANGLES = {"RobeFront_L": -0.60, "RobeFront_R": 0.60, "RobeBack": math.pi}


def trunk_weights(p):
    w = {}
    z = p.z
    spine = smoothstep(0.96, 1.08, z)
    head = spine * smoothstep(1.45, 1.53, z) * (1.0 - smoothstep(0.16, 0.24, p.xy.length))
    w["Head"] = head
    w["Spine"] = spine - head
    lower = 1.0 - spine
    skirt = lower * smoothstep(0.99, 0.80, z)
    w["Hips"] = lower - skirt
    hem = smoothstep(0.85, 0.30, z)
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


def arm_weights(p):
    side = "R" if p.x > 0 else "L"
    J, E, W = ARMS[side]
    du = (E - J).normalized()
    dl = (W - E).normalized()
    b = (p - J).dot(du)
    a = (p - E).dot((du + dl).normalized())
    arm = smoothstep(-0.07, 0.03, b)
    low = smoothstep(-0.04, 0.04, a)
    return {"Spine": 1.0 - arm, "UpperArm_" + side: arm * (1.0 - low), "LowerArm_" + side: arm * low}


def compute_weights(bm, labels):
    rows = []
    for v, part in zip(bm.verts, labels):
        g = PART_GROUP[part]
        p = v.co
        if g == "trunk":
            w = trunk_weights(p)
        elif g == "head":
            h = smoothstep(1.43, 1.51, p.z)
            w = {"Head": h, "Spine": 1.0 - h}
        elif g == "arm":
            w = {"LowerArm_" + ("R" if p.x > 0 else "L"): 1.0} if part == "hands" else arm_weights(p)
        else:
            w = {"Foot_" + ("R" if p.x > 0 else "L"): 1.0}
        row = [0.0] * len(BONE_NAMES)
        for bone, x in w.items():
            row[BI[bone]] += x
        rows.append(row)
    # graph smoothing: removes creases where two formulas meet (cowl/sleeve,
    # hood/neck) without crossing gaps (hands and feet are their own islands
    # or joined only through the sleeve)
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
        if labels[i] == "feet":                       # rigid, never smoothed away
            row = new_row = [0.0] * len(BONE_NAMES)
            new_row[BI["Foot_" + ("R" if bm.verts[i].co.x > 0 else "L")]] = 1.0
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
    mat.diffuse_color = (0.3, 0.2, 0.45, 1.0)
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
        # the face sits in the hood's shadow already; full AO turned it grey
        k = 0.30 if part in ("face", "nose", "eyes", "hair") else 0.62
        c = part_colour(part, v.co, v.normal) * clamp(1.0 - k * occ, 0.30, 1.0)
        colours.append((c.x, c.y, c.z, 1.0))
    weights = compute_weights(bm, labels)
    gold = []
    for f in bm.faces:
        g = sum(1 for v in f.verts if labels[v.index] in GOLD_PARTS)
        gold.append(g * 2 > len(f.verts))
    islands = count_islands(bm, labels)
    for _, pbm in PARTS:
        pbm.free()

    me = bpy.data.meshes.new("Mage_Body")
    bm.to_mesh(me)
    bm.free()
    for poly, is_gold in zip(me.polygons, gold):
        poly.use_smooth = True
        poly.material_index = 1 if is_gold else 0
    me.materials.append(vc_material("Mage_Cloth", 0.74, 0.0))
    me.materials.append(vc_material("Mage_Gold", 0.38, 0.55))
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
    print("SF_SOFT_BODY tris=%d verts=%d islands=%d gold_faces=%d parts=%s"
          % (len(me.polygons), len(me.vertices), islands, sum(gold), sorted(counts.items())))
    return ob


def count_islands(bm, labels):
    """Number of connected pieces; prints each one's size and main part."""
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
    print("SF_SOFT_ISLANDS %s" % sorted(pieces, reverse=True))
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
            eb.align_roll(V(1, 0, 0).cross((tail - head).normalized()))  # local X ~ +X: pitch about X
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


STEP_LEN = 0.46      # foot travel per step under the robe (m): the toe just clears the kicked hem
FOOT_LIFT = 0.05


def foot_track(q):
    """(forward offset, lift, toe pitch) of a foot; q = 0 is the foot fully forward
    (heel strike), stance until 0.5 at constant speed, then the swing."""
    q %= 1.0
    if q < 0.5:
        return STEP_LEN * (0.5 - q / 0.5), 0.0, 0.0
    u = (q - 0.5) / 0.5
    return -0.5 * STEP_LEN + STEP_LEN * u * u * (3 - 2 * u), FOOT_LIFT * math.sin(math.pi * u), 12.0 * math.sin(math.pi * u)


def pose_walk(p):
    s = math.sin(TAU * p)
    c2 = math.cos(2 * TAU * p)
    lean = 4.0
    pose = {
        "Hips": {"loc": (0.0, -0.02 * s * s, 0.0), "rot": (0.0, 4.0 * s, -2.0 * s)},
        "Spine": {"rot": (-lean, -5.0 * s, 1.5 * s)},
        "Head": {"rot": (lean - 1.0, 3.0 * s, -1.0 * s)},
        "UpperArm_L": {"rot": (lean + 18.0 * s, 0.0, 0.0)},
        "LowerArm_L": {"rot": (6.0 + 10.0 * max(0.0, s), 0.0, 0.0)},
        "UpperArm_R": {"rot": (lean - 7.0 * s, 0.0, 0.0)},
        "LowerArm_R": {"rot": (-3.0 * s, 0.0, 0.0)},
        "Robe": {"rot": (-2.0, -4.0 * s, 2.5 * math.sin(TAU * p - 0.6))},
        "RobeBack": {"rot": (-(5.0 + 3.0 * c2), 0.0, 1.5 * math.sin(TAU * p - 1.0))},
    }
    for side, q0 in (("R", 0.25), ("L", 0.75)):
        y, z, pitch = foot_track(p - q0)
        pose["Foot_" + side] = {"loc": (0.0, y, z), "rot": (pitch, 0.0, 0.0)}
        lag_y = foot_track(p - q0 - 0.06)[0]
        kick = max(0.0, lag_y / (0.5 * STEP_LEN)) ** 1.3
        pose["RobeFront_" + side] = {"rot": (2.0 + 18.0 * kick, 0.0, 0.0)}
    return pose


def pose_idle(p):
    s = math.sin(TAU * p)
    c = math.cos(TAU * p)
    return {
        "Spine": {"loc": (0.0, -0.006 * (1.0 - c), 0.0), "rot": (-0.8 * s, 0.0, 0.0)},
        "Head": {"rot": (1.5 * math.sin(TAU * p - 0.6), 3.0 * math.sin(TAU * p + 0.4), 0.0)},
        "UpperArm_R": {"rot": (1.5 * s, 0.0, 0.0)},
        "LowerArm_R": {"rot": (1.5 * math.sin(TAU * p + 0.5), 0.0, 0.0)},
        "UpperArm_L": {"rot": (3.0 * math.sin(TAU * p + 0.8), 0.0, 0.0)},
        "LowerArm_L": {"rot": (3.0 + 2.0 * math.sin(TAU * p + 1.3), 0.0, 0.0)},
        "Robe": {"rot": (0.0, 0.0, 1.0 * s)},
        "RobeBack": {"rot": (1.2 * math.sin(TAU * p + 1.0), 0.0, 0.0)},
        "RobeFront_L": {"rot": (0.8 * math.sin(TAU * p + 2.0), 0.0, 0.0)},
        "RobeFront_R": {"rot": (0.8 * math.sin(TAU * p + 2.6), 0.0, 0.0)},
    }


Z3 = (0.0, 0.0, 0.0)
# Per-bone key tracks of the cast: (time 0..1, rot degrees, loc metres), eased
# with smootherstep between keys. Raise the staff (0.30), gather (0.52),
# thrust the crystal forward (0.68..0.82), recover to rest (1.0). The staff is
# rigid in the right fist, so its tilt is UpperArm_R + LowerArm_R about X
# (+ tips the crystal back): +53 raised behind the head, -54 thrust forward.
CAST = {
    "UpperArm_R": [(0, Z3), (0.30, (115, 0, -10)), (0.52, (125, 0, -12)), (0.68, (46, 0, -2)), (0.82, (42, 0, -2)), (1, Z3)],
    "LowerArm_R": [(0, Z3), (0.30, (-62, 0, 0)), (0.52, (-68, 0, 0)), (0.68, (-100, 0, 0)), (0.82, (-96, 0, 0)), (1, Z3)],
    "Spine": [(0, Z3), (0.30, (8, -12, 0)), (0.52, (11, -16, 0)), (0.68, (-14, 10, 0)), (0.82, (-11, 8, 0)), (1, Z3)],
    "Head": [(0, Z3), (0.30, (-3, 10, 0)), (0.52, (-2, 14, 0)), (0.68, (8, -8, 0)), (0.82, (6, -6, 0)), (1, Z3)],
    "UpperArm_L": [(0, Z3), (0.30, (50, 0, 12)), (0.52, (40, 0, 6)), (0.68, (-22, 0, 10)), (0.82, (-18, 0, 8)), (1, Z3)],
    "LowerArm_L": [(0, Z3), (0.30, (40, 0, 0)), (0.52, (80, 0, 0)), (0.68, (22, 0, 0)), (0.82, (20, 0, 0)), (1, Z3)],
    "Hips": [(0, Z3), (0.30, (0, -4, 0)), (0.52, (0, -6, 0)), (0.68, (0, 6, 0)), (0.82, (0, 5, 0)), (1, Z3)],
    "Robe": [(0, Z3), (0.30, (2, -5, 0)), (0.52, (3, -7, 0)), (0.68, (-6, 6, 0)), (0.82, (-3, 4, 0)), (1, Z3)],
    "RobeBack": [(0, Z3), (0.52, (4, 0, 0)), (0.70, (-12, 0, 0)), (0.86, (-4, 0, 0)), (1, Z3)],
    "RobeFront_R": [(0, Z3), (0.52, Z3), (0.68, (12, 0, 0)), (0.84, (8, 0, 0)), (1, Z3)],
    "RobeFront_L": [(0, Z3), (0.68, (4, 0, 0)), (1, Z3)],
    "Foot_R": [(0, Z3), (0.60, (10, 0, 0)), (0.68, Z3), (0.86, Z3), (0.93, (8, 0, 0)), (1, Z3)],
}
CAST_LOC = {
    # Hips local axes: X right, Y up, Z back
    "Hips": [(0, Z3), (0.52, (0, 0, 0.03)), (0.68, (0, -0.02, -0.06)), (0.82, (0, -0.02, -0.05)), (1, Z3)],
    "Foot_R": [(0, Z3), (0.52, Z3), (0.60, (0, 0.07, 0.045)), (0.68, (0, 0.15, 0)), (0.86, (0, 0.15, 0)),
               (0.93, (0, 0.075, 0.03)), (1, Z3)],
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
    """Ground distance per cycle, from the posed right foot during its stance."""
    armature.animation_data.action = act
    ys, zs = [], []
    for f in range(15, 46):                 # right foot planted from phase 0.25 to 0.75
        scene.frame_set(f)
        bpy.context.view_layer.update()
        h = armature.matrix_world @ armature.pose.bones["Foot_R"].head
        ys.append(h.y)
        zs.append(h.z)
    sweep = ys[0] - ys[-1]
    per_cycle = 2.0 * sweep
    print("SF_SOFT_WALK stance_sweep=%.4f m per_cycle=%.4f m clip=%.2f s natural_speed=%.3f m/s "
          "planted_z_range=%.4f m speed_scale_at_3.5=%.2f"
          % (sweep, per_cycle, WALK_FRAMES / float(ANIM_FPS), per_cycle * ANIM_FPS / WALK_FRAMES,
             max(zs) - min(zs), 3.5 / (per_cycle * ANIM_FPS / WALK_FRAMES)))
    armature.animation_data.action = None
    return per_cycle


def deformation_report(scene, body, armature, clips):
    """Largest edge stretch and squash against the rest mesh, per checked frame:
    a quantitative look for tearing and candy-wrapper collapse."""
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
        print("SF_SOFT_DEFORM %-5s frame=%-3d min=%.2f p1=%.2f p99=%.2f max=%.2f worst_at_rest=%s"
              % (act.name, frame, ratios[0], ratios[k // 100], ratios[-k // 100], ratios[-1],
                 tuple(round(c, 2) for c in worst)))
    armature.animation_data.action = None
    reset_pose(armature)
    scene.frame_set(0)


# --------------------------------------------------------------------------
# export, renders, blend
# --------------------------------------------------------------------------

def export_soft_glb(objects, path):
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
    print("SF_SOFT_GLB %s bytes=%d scenes=%d nodes=%d anims=%s color0=%s"
          % (os.path.basename(path), len(data), len(js.get("scenes", [])), len(js["nodes"]),
             [a["name"] for a in js.get("animations", [])], col))


def render_iso(objects, armature, path, facing_deg=-150.0):
    """The game's camera: orthographic, yaw 45, pitch -35 (Godot), 64 px per metre
    at 800 x 450, i.e. the in-game pixel size at 1600 x 900 and size 14 m."""
    scene = assets_scene()
    rig = get_or_make_collection(SF_RIG_COLLECTION, scene.collection)
    clear_collection(rig)
    armature.rotation_euler = (0.0, 0.0, math.radians(facing_deg))
    bpy.context.view_layer.update()
    cam_data = bpy.data.cameras.new("SF_IsoCam")
    cam_data.type = "ORTHO"
    cam_data.sensor_fit = "VERTICAL"
    cam_data.ortho_scale = 7.0
    cam_data.clip_end = 200.0
    cam = bpy.data.objects.new("SF_IsoCam", cam_data)
    rig.objects.link(cam)
    target = V(0.0, 0.0, 1.0)
    # Godot camera basis z for yaw 45, pitch -35 is (0.579, 0.574, 0.579); Blender (x, -z, y)
    cam.location = target + V(0.5792, -0.5792, 0.5736) * 30.0
    look_at(cam, target)
    scene.camera = cam
    sun_data = bpy.data.lights.new("SF_IsoSun", "SUN")
    sun_data.energy = 3.4
    sun_data.angle = math.radians(4.0)
    sun = bpy.data.objects.new("SF_IsoSun", sun_data)
    rig.objects.link(sun)
    sun.location = V(0, 0, 10)
    look_at(sun, sun.location + V(-0.287, 0.497, -0.819))   # arena Sun (-55, 30, 0)
    gb = bmesh.new()
    for i in range(-9, 9):
        for j in range(-9, 9):
            grid_plane(gb, (i * 2.0 + 1.0, j * 2.0 + 1.0, 0.0), 2.0, 2.0, (i + j) % 2)
    ground = finish_object(gb, "SF_IsoGround", [make_material("SF_IsoGroundA", "#4E7A3C", roughness=1.0),
                                                make_material("SF_IsoGroundB", "#5F8A46", roughness=1.0)])
    rig.objects.link(ground)
    world = bpy.data.worlds.get("SF_IsoWorld") or bpy.data.worlds.new("SF_IsoWorld")
    world.use_nodes = True
    for nd in world.node_tree.nodes:
        if nd.type == "BACKGROUND":
            nd.inputs[0].default_value = (0.21, 0.26, 0.38, 1.0)
            nd.inputs[1].default_value = 0.9
    old_world = scene.world
    scene.world = world
    scene.render.resolution_x, scene.render.resolution_y = 800, 450
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
        scene.world = old_world
        armature.rotation_euler = (0.0, 0.0, 0.0)
        clear_collection(rig)
        bpy.context.view_layer.update()


def render_all(scene, objects, armature, acts):
    os.makedirs(PREVIEW_DIR, exist_ok=True)
    out = lambda n: os.path.join(PREVIEW_DIR, "mage_soft_%s.png" % n)
    render_preview(objects, out("front"), yaw_deg=35.0)
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
    if "--debug" in sys.argv:           # extra inspection frames, outside the repository
        ddir = sys.argv[sys.argv.index("--debug") + 1]
        for act, frame, yaw in (("cast", 18, 35.0), ("cast", 31, 20.0), ("cast", 31, 110.0),
                                ("walk", 45, 20.0), ("cast", 42, 20.0)):
            armature.animation_data.action = acts[act]
            scene.frame_set(frame)
            bpy.context.view_layer.update()
            render_preview(objects, os.path.join(ddir, "dbg_%s_%d_%d.png" % (act, frame, yaw)), yaw_deg=yaw)
    armature.animation_data.action = None
    reset_pose(armature)
    scene.frame_set(0)
    bpy.context.view_layer.update()
    render_iso(objects, armature, out("iso"))


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
    print("SF_SOFT_BLEND %s" % path)


def main():
    scene = assets_scene()
    activate_scene(scene)
    scene.render.fps, scene.render.fps_base = ANIM_FPS, 1.0
    coll = model_collection("SF_MageSoft")

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
    print("SF_SOFT_MODEL body_tris=%d staff_tris=%d height_body=%.3f height_staff=%.3f base_z=%.3f "
          "grip=%s overhead=%.3f bones=%d"
          % (tri_count(body), tri_count(staff), top, hi.z, lo.z, tuple(round(c, 3) for c in GRIP),
             top + OVERHEAD_CLEARANCE, len(armature.data.bones)))
    export_soft_glb(objects, MODEL_PATH)
    if DO_RENDER:
        render_all(scene, objects, armature, acts)
    save_blend(scene, armature, acts)
    print("SF_SOFT_TIME body=%.1f s total=%.1f s" % (t_body, time.time() - T_START))
    print("SF_MAGE_SOFT DONE")


main()
