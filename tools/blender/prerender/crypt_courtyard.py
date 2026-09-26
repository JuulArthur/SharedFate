# Shared Fate 3D, approach 2 test: a pre-rendered dark fantasy background.
#
# Command line (Blender 4.3):
#     blender --background --factory-startup --python tools/blender/prerender/crypt_courtyard.py -- --root <repo>
#         [--ppm <n>]        render resolution in pixels per metre of screen (default 128)
#         [--samples <n>]    Cycles samples (default 512)
#         [--preview]        quick look: 40 px/m, 64 samples, writes *_preview.jpg only
#         [--no-render]      build, export the proxy glb and the json, skip the render
#         [--blend <path>]   where to save the viewable .blend (default blender/crypt_courtyard.blend)
#
# What it makes (docs/style-study/prerender_crypt.md):
#   1. A ruined crypt courtyard at night, all procedural: flagstones, a chapel
#      wall with a pointed-arch doorway and lancet windows, gothic pillars
#      (some broken), low broken walls in the foreground, two braziers, an
#      octagonal dais with a crimson sigil and an altar, a graveyard with a dead
#      tree, a sarcophagus behind the doorway, ground fog.
#   2. One Cycles render from the game camera (orthographic, yaw 45, pitch -35,
#      the same basis as CameraRig3D), painted with a Kuwahara filter and a soft
#      glow: assets/3d/prerender/crypt/crypt_color.jpg.
#   3. Light group passes at half resolution, so Godot can animate the light:
#      crypt_moon.jpg (moonlight only; the mage's shadow subtracts it),
#      crypt_fire.jpg (braziers and candles; flickers), crypt_sigil.jpg
#      (the circle; pulses), crypt_albedo.jpg (diffuse colour, for spell light).
#   4. crypt_proxy.glb: the same geometry minus flames, fog, grass and other
#      small bits. Godot draws it with the painting projected from the camera,
#      which gives per-pixel occlusion for free. Meshes named Walk_* are floor.
#   5. crypt_scene.json: camera, lights, flame positions and named test spots,
#      all in Godot coordinates (x, y, z) = Blender (x, z, -y).
#
# Layout is authored in screen-aligned ground coordinates: u points to screen
# right, v points away from the viewer. Blender x = (u - v) / sqrt(2),
# y = (u + v) / sqrt(2).

import bpy
import bmesh
import json
import math
import os
import random
import sys
import time
from mathutils import Vector, Matrix

T0 = time.time()
TAU = 2.0 * math.pi
S2 = math.sqrt(0.5)


def _arg(name, default=None):
    if name in sys.argv:
        return sys.argv[sys.argv.index(name) + 1]
    return default


SF_ROOT = os.path.abspath(_arg("--root", globals().get("SF_ROOT") or os.path.join(
    os.path.dirname(os.path.abspath(__file__)), os.pardir, os.pardir, os.pardir)))
PREVIEW = "--preview" in sys.argv
DO_RENDER = "--no-render" not in sys.argv
PPM = float(_arg("--ppm", 40 if PREVIEW else 128))
SAMPLES = int(_arg("--samples", 64 if PREVIEW else 512))
OUT_DIR = os.path.join(SF_ROOT, "assets", "3d", "prerender", "crypt")
os.makedirs(OUT_DIR, exist_ok=True)


def _blend_path():
    if _arg("--blend"):
        return os.path.abspath(_arg("--blend"))
    root = SF_ROOT
    marker = os.sep + ".claude" + os.sep + "worktrees" + os.sep
    main = root.split(marker)[0] if marker in root else root
    return os.path.join(main, "blender", "crypt_courtyard.blend")


# Screen rectangle of the render, in metres on the camera plane: x is u, y is
# 0.5736 v + 0.8192 z (sin and cos of the 35 degree pitch).
SCREEN_X = (-16.0, 16.0)
SCREEN_Y = (-6.4, 11.0)
# Where the mage may be sent (u, v), used by Godot to reject clicks.
WALK_RECT = (-13.5, 13.5, -10.0, 13.0)

rng = random.Random(1998)


# --------------------------------------------------------------------------
# small helpers
# --------------------------------------------------------------------------

def uv2xy(u, v):
    return ((u - v) * S2, (u + v) * S2)


def P(u, v, z=0.0):
    x, y = uv2xy(u, v)
    return Vector((x, y, z))


def to_godot(vec):
    return [round(vec.x, 5), round(vec.z, 5), round(-vec.y, 5)]


def frame_uv(u, v, z=0.0, rot=0.0):
    """Matrix whose local x runs along u, y along v, z up, at (u, v, z)."""
    return Matrix.Translation(P(u, v, z)) @ Matrix.Rotation(math.pi / 4 + rot, 4, "Z")


def clamp(x, a=0.0, b=1.0):
    return a if x < a else b if x > b else x


def smoothstep(e0, e1, x):
    t = clamp((x - e0) / (e1 - e0))
    return t * t * (3.0 - 2.0 * t)


def srgb(h, a=1.0):
    h = h.lstrip("#")
    r, g, b = (int(h[i:i + 2], 16) / 255.0 for i in (0, 2, 4))

    def f(c):
        return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4

    return (f(r), f(g), f(b), a)


# --------------------------------------------------------------------------
# scene and collections
# --------------------------------------------------------------------------

for ob in list(bpy.data.objects):
    bpy.data.objects.remove(ob, do_unlink=True)
for me in list(bpy.data.meshes):
    bpy.data.meshes.remove(me)
for mat in list(bpy.data.materials):
    bpy.data.materials.remove(mat)

scene = bpy.context.scene
scene.name = "Crypt_Courtyard"
COLL = {}
for cname in ("Proxy", "RenderOnly", "Cutters", "Lights"):
    c = bpy.data.collections.new(cname)
    scene.collection.children.link(c)
    COLL[cname] = c


def add_obj(name, bm, coll="Proxy", mat=None, lightgroup=""):
    me = bpy.data.meshes.new(name)
    bm.normal_update()
    bm.to_mesh(me)
    bm.free()
    ob = bpy.data.objects.new(name, me)
    COLL[coll].objects.link(ob)
    if mat is not None:
        me.materials.append(mat)
    if lightgroup:
        ob.lightgroup = lightgroup
    for poly in me.polygons:
        poly.use_smooth = False
    return ob


def cube(bm, matrix):
    """Unit cube (-0.5..0.5) transformed by matrix; returns its verts."""
    res = bmesh.ops.create_cube(bm, size=1.0, matrix=matrix)
    return res["verts"]


def box_matrix(u, v, z0, su, sv, sz, rot=0.0):
    """Box from z0 to z0 + sz, centred on (u, v), sides su x sv, turned by rot."""
    return frame_uv(u, v, z0 + sz / 2.0, rot) @ Matrix.Diagonal((su, sv, sz, 1.0))


def prism(bm, profile, y0, y1, matrix):
    """Extrude a closed (x, z) profile, counter-clockwise, from local y0 to y1."""
    front = [bm.verts.new(matrix @ Vector((x, y0, z))) for x, z in profile]
    back = [bm.verts.new(matrix @ Vector((x, y1, z))) for x, z in profile]
    n = len(profile)
    bm.faces.new(front)
    bm.faces.new(list(reversed(back)))
    for i in range(n):
        j = (i + 1) % n
        bm.faces.new((front[j], front[i], back[i], back[j]))
    return front + back


def tube(bm, pts, radii, sides=7, cap=True):
    rings = []
    n = len(pts)
    b1 = None
    for i, p in enumerate(pts):
        t = (pts[min(i + 1, n - 1)] - pts[max(i - 1, 0)]).normalized()
        if b1 is None:
            a = Vector((0, 0, 1)) if abs(t.z) < 0.9 else Vector((1, 0, 0))
            b1 = t.cross(a).normalized()
        else:
            b1 = (b1 - t * b1.dot(t)).normalized()
        b2 = t.cross(b1)
        ring = [bm.verts.new(p + (b1 * math.cos(k * TAU / sides) + b2 * math.sin(k * TAU / sides)) * radii[i])
                for k in range(sides)]
        rings.append(ring)
    for i in range(n - 1):
        for k in range(sides):
            k2 = (k + 1) % sides
            bm.faces.new((rings[i][k], rings[i][k2], rings[i + 1][k2], rings[i + 1][k]))
    if cap:
        bm.faces.new(list(reversed(rings[0])))
        bm.faces.new(rings[-1])
    return rings


def lathe(bm, profile, matrix, sides=16):
    """Revolve (r, z) points around local z; open at both ends."""
    rings = []
    for r, z in profile:
        rings.append([bm.verts.new(matrix @ Vector((r * math.cos(k * TAU / sides), r * math.sin(k * TAU / sides), z)))
                      for k in range(sides)])
    for i in range(len(rings) - 1):
        for k in range(sides):
            k2 = (k + 1) % sides
            bm.faces.new((rings[i][k], rings[i][k2], rings[i + 1][k2], rings[i + 1][k]))
    return rings


def rock(bm, centre, size, squash=0.6):
    res = bmesh.ops.create_icosphere(bm, subdivisions=1, radius=1.0)
    rot = Matrix.Rotation(rng.uniform(0, TAU), 3, "Z") @ Matrix.Rotation(rng.uniform(-0.4, 0.4), 3, "X")
    for vert in res["verts"]:
        d = vert.co.copy()
        d *= rng.uniform(0.75, 1.15)
        d = rot @ Vector((d.x * size * rng.uniform(0.8, 1.3), d.y * size, d.z * size * squash))
        vert.co = centre + d


def bevel_mod(ob, width=0.02, segments=1):
    m = ob.modifiers.new("Bevel", "BEVEL")
    m.width = width
    m.segments = segments
    m.limit_method = "ANGLE"
    return m


def recalc(bm):
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces[:])


# --------------------------------------------------------------------------
# materials (Cycles node trees; nodes looked up by type, never by name)
# --------------------------------------------------------------------------

class NT:
    def __init__(self, name):
        self.mat = bpy.data.materials.new(name)
        self.mat.use_nodes = True
        self.nt = self.mat.node_tree
        self.nt.nodes.clear()
        self.out = self.nt.nodes.new("ShaderNodeOutputMaterial")

    def n(self, kind, **props):
        node = self.nt.nodes.new(kind)
        for k, val in props.items():
            setattr(node, k, val)
        return node

    def link(self, a, b):
        self.nt.links.new(a, b)

    def coord(self, which="Object"):
        return self.n("ShaderNodeTexCoord").outputs[which]

    def noise(self, vec, scale, detail=4.0, rough=0.55, dims=None):
        node = self.n("ShaderNodeTexNoise")
        if vec is not None:
            self.link(vec, node.inputs["Vector"])
        node.inputs["Scale"].default_value = scale
        node.inputs["Detail"].default_value = detail
        node.inputs["Roughness"].default_value = rough
        return node.outputs["Fac"]

    def ramp(self, fac, stops):
        node = self.n("ShaderNodeValToRGB")
        self.link(fac, node.inputs["Fac"])
        els = node.color_ramp.elements
        while len(els) < len(stops):
            els.new(0.5)
        for el, (pos, col) in zip(els, stops):
            el.position = pos
            el.color = srgb(col) if isinstance(col, str) else col
        return node.outputs["Color"]

    def mix(self, fac, a, b, blend="MIX"):
        node = self.n("ShaderNodeMix", data_type="RGBA", blend_type=blend)
        f = [s for s in node.inputs if s.name == "Factor" and s.type == "VALUE"][0]
        sa = [s for s in node.inputs if s.name == "A" and s.type == "RGBA"][0]
        sb = [s for s in node.inputs if s.name == "B" and s.type == "RGBA"][0]
        for sock, val in ((f, fac), (sa, a), (sb, b)):
            if isinstance(val, (int, float)):
                sock.default_value = val
            elif isinstance(val, (tuple, list)):
                sock.default_value = val
            else:
                self.link(val, sock)
        return [s for s in node.outputs if s.type == "RGBA"][0]

    def math(self, op, a, b=None, clamp_=False):
        node = self.n("ShaderNodeMath", operation=op, use_clamp=clamp_)
        for i, val in enumerate((a, b)):
            if val is None:
                continue
            if isinstance(val, (int, float)):
                node.inputs[i].default_value = val
            else:
                self.link(val, node.inputs[i])
        return node.outputs[0]

    def maprange(self, val, fmin, fmax, tmin=0.0, tmax=1.0):
        node = self.n("ShaderNodeMapRange", clamp=True)
        self.link(val, node.inputs["Value"])
        node.inputs["From Min"].default_value = fmin
        node.inputs["From Max"].default_value = fmax
        node.inputs["To Min"].default_value = tmin
        node.inputs["To Max"].default_value = tmax
        return node.outputs["Result"]

    def bump(self, height, strength, distance=0.05, normal=None):
        node = self.n("ShaderNodeBump")
        self.link(height, node.inputs["Height"])
        node.inputs["Strength"].default_value = strength
        node.inputs["Distance"].default_value = distance
        if normal is not None:
            self.link(normal, node.inputs["Normal"])
        return node.outputs["Normal"]

    def principled(self, color, rough=0.9, metallic=0.0, normal=None, emission=None, estrength=0.0):
        bsdf = self.n("ShaderNodeBsdfPrincipled")
        for sock_name, val in (("Base Color", color), ("Roughness", rough), ("Metallic", metallic)):
            sock = bsdf.inputs[sock_name]
            if isinstance(val, (int, float, tuple, list)):
                sock.default_value = val
            else:
                self.link(val, sock)
        if normal is not None:
            self.link(normal, bsdf.inputs["Normal"])
        if emission is not None:
            e = bsdf.inputs["Emission Color"]
            if isinstance(emission, (tuple, list)):
                e.default_value = emission
            else:
                self.link(emission, e)
            bsdf.inputs["Emission Strength"].default_value = estrength
        self.link(bsdf.outputs[0], self.out.inputs["Surface"])
        return bsdf

    def emission(self, color, strength):
        em = self.n("ShaderNodeEmission")
        if isinstance(color, (tuple, list)):
            em.inputs["Color"].default_value = color
        else:
            self.link(color, em.inputs["Color"])
        em.inputs["Strength"].default_value = strength
        self.link(em.outputs[0], self.out.inputs["Surface"])


def mat_flagstone():
    m = NT("Crypt_Flagstone")
    co = m.coord()
    rand = m.n("ShaderNodeAttribute", attribute_name="stone_rand").outputs["Fac"]
    base = m.ramp(m.noise(co, 2.6, 6.0, 0.6), [(0.3, "#34362f"), (0.75, "#5a5a51")])
    tint = m.ramp(rand, [(0.0, "#8f978f"), (0.5, "#b3ada2"), (1.0, "#8a837a")])
    col = m.mix(1.0, base, tint, "MULTIPLY")
    col = m.mix(0.55, col, base, "MIX")
    moss = m.maprange(m.noise(co, 0.9, 3.0), 0.55, 0.68)
    col = m.mix(m.math("MULTIPLY", moss, 0.75), col, srgb("#1f2a18"))
    grime = m.maprange(m.noise(co, 7.0, 2.0), 0.4, 0.7)
    col = m.mix(m.math("MULTIPLY", grime, 0.35), col, srgb("#15130f"))
    nrm = m.bump(m.noise(co, 16.0, 8.0, 0.65), 0.35, 0.02)
    m.principled(col, 0.88, normal=nrm)
    return m.mat


def mat_brick(name="Crypt_WallStone", c1="#4a4a44", c2="#5e5b52", mortar="#1d1c19"):
    m = NT(name)
    geo = m.n("ShaderNodeNewGeometry").outputs["Position"]
    ualong = m.n("ShaderNodeVectorMath", operation="DOT_PRODUCT")
    m.link(geo, ualong.inputs[0])
    ualong.inputs[1].default_value = (S2, S2, 0.0)
    sep = m.n("ShaderNodeSeparateXYZ")
    m.link(geo, sep.inputs[0])
    comb = m.n("ShaderNodeCombineXYZ")
    m.link(ualong.outputs["Value"], comb.inputs[0])
    m.link(sep.outputs[2], comb.inputs[1])
    brick = m.n("ShaderNodeTexBrick", offset=0.5, offset_frequency=2)
    m.link(comb.outputs[0], brick.inputs["Vector"])
    brick.inputs["Scale"].default_value = 1.0
    brick.inputs["Brick Width"].default_value = 0.62
    brick.inputs["Row Height"].default_value = 0.31
    brick.inputs["Mortar Size"].default_value = 0.018
    brick.inputs["Mortar Smooth"].default_value = 0.2
    brick.inputs["Bias"].default_value = 0.0
    brick.inputs["Color1"].default_value = srgb(c1)
    brick.inputs["Color2"].default_value = srgb(c2)
    brick.inputs["Mortar"].default_value = srgb(mortar)
    co = m.coord()
    var = m.ramp(m.noise(co, 3.0, 5.0), [(0.3, "#7d7d7a"), (0.8, "#c9c4b8")])
    col = m.mix(1.0, brick.outputs["Color"], var, "MULTIPLY")
    col = m.mix(0.4, col, brick.outputs["Color"])
    # grime rising from the ground and vertical streaks
    low = m.maprange(sep.outputs[2], 0.0, 1.8, 1.0, 0.0)
    col = m.mix(m.math("MULTIPLY", low, 0.55), col, srgb("#151812"))
    streak_v = m.n("ShaderNodeMapping")
    m.link(comb.outputs[0], streak_v.inputs["Vector"])
    streak_v.inputs["Scale"].default_value = (3.0, 0.25, 1.0)
    streak = m.maprange(m.noise(streak_v.outputs[0], 2.0, 3.0), 0.5, 0.75)
    col = m.mix(m.math("MULTIPLY", streak, 0.45), col, srgb("#16150f"))
    moss = m.math("MULTIPLY", m.maprange(m.noise(co, 1.4, 3.0), 0.55, 0.7), low)
    col = m.mix(moss, col, srgb("#1c2616"))
    h = m.math("ADD", m.math("MULTIPLY", brick.outputs["Fac"], -1.0), m.math("MULTIPLY", m.noise(co, 12.0, 6.0), 0.4))
    nrm = m.bump(h, 0.55, 0.03)
    m.principled(col, 0.93, normal=nrm)
    return m.mat


def mat_stone(name, dark, light, crack=False, scale=3.0):
    m = NT(name)
    co = m.coord()
    col = m.ramp(m.noise(co, scale, 6.0, 0.6), [(0.25, dark), (0.8, light)])
    stv = m.n("ShaderNodeMapping")
    m.link(co, stv.inputs["Vector"])
    stv.inputs["Scale"].default_value = (4.0, 4.0, 0.3)
    streak = m.maprange(m.noise(stv.outputs[0], 3.0, 3.0), 0.5, 0.78)
    col = m.mix(m.math("MULTIPLY", streak, 0.4), col, srgb("#14130f"))
    h = m.math("MULTIPLY", m.noise(co, 14.0, 8.0, 0.6), 0.5)
    if crack:
        vor = m.n("ShaderNodeTexVoronoi", feature="DISTANCE_TO_EDGE")
        m.link(co, vor.inputs["Vector"])
        vor.inputs["Scale"].default_value = 1.6
        cr = m.maprange(vor.outputs["Distance"], 0.0, 0.025, 1.0, 0.0)
        cr = m.math("MULTIPLY", cr, m.maprange(m.noise(co, 2.0, 2.0), 0.45, 0.6))
        col = m.mix(cr, col, srgb("#0c0b0a"))
        h = m.math("SUBTRACT", h, m.math("MULTIPLY", cr, 0.6))
    nrm = m.bump(h, 0.4, 0.03)
    m.principled(col, 0.85, normal=nrm)
    return m.mat


def mat_soil():
    m = NT("Crypt_Soil")
    co = m.coord()
    col = m.ramp(m.noise(co, 1.6, 6.0, 0.62), [(0.3, "#16130f"), (0.75, "#2c271f")])
    leaves = m.maprange(m.noise(co, 9.0, 2.0), 0.62, 0.7)
    col = m.mix(m.math("MULTIPLY", leaves, 0.6), col, srgb("#3a2f1f"))
    # the world fades to black toward the edges of the render
    dist = m.n("ShaderNodeVectorMath", operation="LENGTH")
    m.link(co, dist.inputs[0])
    fade = m.maprange(dist.outputs["Value"], 11.0, 19.0)
    col = m.mix(m.math("MULTIPLY", fade, 0.92), col, srgb("#030304"))
    nrm = m.bump(m.noise(co, 10.0, 8.0), 0.5, 0.04)
    m.principled(col, 1.0, normal=nrm)
    return m.mat


def mat_iron():
    m = NT("Crypt_Iron")
    co = m.coord()
    rust = m.maprange(m.noise(co, 6.0, 4.0), 0.45, 0.7)
    col = m.mix(rust, srgb("#1c1a19"), srgb("#3d2618"))
    rough = m.math("ADD", 0.45, m.math("MULTIPLY", rust, 0.45))
    metal = m.math("SUBTRACT", 0.9, m.math("MULTIPLY", rust, 0.7))
    m.principled(col, rough, metal, normal=m.bump(m.noise(co, 30.0, 4.0), 0.2, 0.01))
    return m.mat


def mat_bark():
    m = NT("Crypt_Bark")
    co = m.coord()
    mp = m.n("ShaderNodeMapping")
    m.link(co, mp.inputs["Vector"])
    mp.inputs["Scale"].default_value = (6.0, 6.0, 0.8)
    n1 = m.noise(mp.outputs[0], 3.0, 8.0, 0.7)
    col = m.ramp(n1, [(0.3, "#141210"), (0.7, "#3a342d")])
    m.principled(col, 0.95, normal=m.bump(n1, 0.8, 0.05))
    return m.mat


def mat_plain(name, hexcol, rough=0.8, metallic=0.0):
    m = NT(name)
    m.principled(srgb(hexcol), rough, metallic)
    return m.mat


def mat_cloth():
    m = NT("Crypt_Banner")
    co = m.coord()
    col = m.ramp(m.noise(co, 4.0, 5.0), [(0.3, "#2a070a"), (0.8, "#5c1016")])
    dirt = m.maprange(m.noise(co, 1.5, 3.0), 0.5, 0.75)
    col = m.mix(m.math("MULTIPLY", dirt, 0.6), col, srgb("#140c0a"))
    m.principled(col, 1.0, normal=m.bump(m.noise(co, 25.0, 4.0), 0.3, 0.01))
    return m.mat


def mat_fire(name="Crypt_Fire", strength=22.0):
    m = NT(name)
    co = m.coord("Generated")
    sep = m.n("ShaderNodeSeparateXYZ")
    m.link(co, sep.inputs[0])
    col = m.ramp(sep.outputs[2], [(0.0, "#fff1b0"), (0.45, "#ffae3c"), (1.0, "#ff4a10")])
    m.emission(col, strength)
    return m.mat


def mat_emit(name, hexcol, strength):
    m = NT(name)
    m.emission(srgb(hexcol), strength)
    return m.mat


def mat_coal():
    m = NT("Crypt_Coal")
    co = m.coord()
    glow = m.maprange(m.noise(co, 20.0, 3.0), 0.4, 0.65)
    col = m.mix(glow, srgb("#050403"), srgb("#ff3c10"))
    m.principled(srgb("#0a0908"), 0.9, emission=col, estrength=6.0)
    return m.mat


def mat_fog():
    m = NT("Crypt_Fog")
    geo = m.n("ShaderNodeNewGeometry").outputs["Position"]
    mp = m.n("ShaderNodeMapping")
    m.link(geo, mp.inputs["Vector"])
    mp.inputs["Scale"].default_value = (0.22, 0.22, 0.6)
    wisps = m.maprange(m.noise(mp.outputs[0], 1.0, 4.0, 0.55), 0.42, 0.78)
    sep = m.n("ShaderNodeSeparateXYZ")
    m.link(geo, sep.inputs[0])
    fall = m.maprange(sep.outputs[2], 0.0, 1.3, 1.0, 0.0)
    fall = m.math("POWER", fall, 2.0)
    dens = m.math("MULTIPLY", m.math("MULTIPLY", wisps, fall), 0.32)
    vol = m.n("ShaderNodeVolumePrincipled")
    vol.inputs["Color"].default_value = srgb("#9aa6b8")
    vol.inputs["Anisotropy"].default_value = 0.35
    m.link(dens, vol.inputs["Density"])
    m.link(vol.outputs[0], m.out.inputs["Volume"])
    return m.mat


MAT = {
    "flag": mat_flagstone(),
    "wall": mat_brick(),
    "lowwall": mat_brick("Crypt_LowWall", "#44443d", "#57554c", "#1a1916"),
    "pillar": mat_stone("Crypt_Pillar", "#3e3d37", "#6d6a60"),
    "trim": mat_stone("Crypt_Trim", "#4a4841", "#7a766b", scale=4.0),
    "dais": mat_stone("Crypt_Dais", "#232226", "#3f3d43", crack=True, scale=2.0),
    "grave": mat_stone("Crypt_Grave", "#2f322c", "#56574e", crack=True),
    "rubble": mat_stone("Crypt_Rubble", "#2f2e2a", "#5a574e", scale=6.0),
    "soil": mat_soil(),
    "iron": mat_iron(),
    "bark": mat_bark(),
    "bone": mat_plain("Crypt_Bone", "#b9ae96", 0.6),
    "wax": mat_plain("Crypt_Wax", "#cfc3a4", 0.5),
    "grass": mat_plain("Crypt_Grass", "#4d4630", 1.0),
    "dark": mat_plain("Crypt_Dark", "#0b0a0a", 1.0),
    "banner": mat_cloth(),
    "fire": mat_fire(),
    "flame": mat_emit("Crypt_CandleFlame", "#ffc46b", 30.0),
    "coal": mat_coal(),
    "sigil": mat_emit("Crypt_Sigil", "#ff1a0a", 4.0),
    "fog": mat_fog(),
}


# --------------------------------------------------------------------------
# ground
# --------------------------------------------------------------------------

def build_soil():
    bm = bmesh.new()
    corners = [P(-18, -13), P(18, -13), P(18, 21.5), P(-18, 21.5)]
    verts = [bm.verts.new(c + Vector((0, 0, -0.03))) for c in corners]
    bm.faces.new(verts)
    return add_obj("Walk_Soil", bm, "Proxy", MAT["soil"])


def paving_region(u, v):
    """Inside distance (m) of the main paved area; negative outside."""
    return min(u + 11.0, 11.0 - u, v + 6.2, 8.35 - v)


def build_flagstones(name, u0, u1, v0, v1, inside, holes=()):
    """Rows run along world x (45 degrees to the screen), so the paving reads as
    a floor seen from above rather than as a brick wall."""
    bm = bmesh.new()
    rands = []
    corners = [P(u, v) for u in (u0, u1) for v in (v0, v1)]
    x0, x1 = min(c.x for c in corners), max(c.x for c in corners)
    y0, y1 = min(c.y for c in corners), max(c.y for c in corners)
    y = y0
    while y < y1:
        depth = rng.uniform(0.5, 0.9)
        x = x0 + rng.uniform(-0.5, 0.0)
        while x < x1:
            width = rng.uniform(0.5, 1.25)
            cx, cy = x + width / 2, y + depth / 2
            x += width
            cu, cv = (cx + cy) * S2, (cy - cx) * S2
            d = inside(cu, cv)
            if d < 0:
                continue
            skip = 0.02 + 0.65 * smoothstep(1.4, 0.0, d)
            if any(math.hypot(cu - hu, cv - hv) < hr for hu, hv, hr in holes):
                continue
            if rng.random() < skip:
                continue
            top = -rng.uniform(0.0, 0.022)
            m = (Matrix.Translation((cx, cy, top - 0.07))
                 @ Matrix.Rotation(rng.uniform(-0.04, 0.04), 4, "Z")
                 @ Matrix.Rotation(rng.uniform(-0.018, 0.018), 4, "X")
                 @ Matrix.Rotation(rng.uniform(-0.018, 0.018), 4, "Y")
                 @ Matrix.Diagonal((width - 0.035, depth - 0.035, 0.14, 1.0)))
            cube(bm, m)
            rands.append(rng.random())
        y += depth
    ob = add_obj(name, bm, "Proxy", MAT["flag"])
    attr = ob.data.attributes.new("stone_rand", "FLOAT", "FACE")
    for i, poly in enumerate(ob.data.polygons):
        attr.data[i].value = rands[i // 6]
    bevel_mod(ob, 0.018, 2)
    return ob


# --------------------------------------------------------------------------
# walls
# --------------------------------------------------------------------------

def wall(name, u0, u1, vc, thick, height_fn, mat, step=0.25, z0=-0.1):
    bm = bmesh.new()
    cols = []
    n = max(2, int(round((u1 - u0) / step)))
    for i in range(n + 1):
        u = u0 + (u1 - u0) * i / n
        h = height_fn(u)
        hb = h + rng.uniform(-0.12, 0.12)
        cols.append((bm.verts.new(P(u, vc - thick / 2, z0)), bm.verts.new(P(u, vc - thick / 2, h)),
                     bm.verts.new(P(u, vc + thick / 2, hb)), bm.verts.new(P(u, vc + thick / 2, z0))))
    for i in range(n):
        fb, ft, bt, bb = cols[i]
        fb2, ft2, bt2, bb2 = cols[i + 1]
        bm.faces.new((fb, fb2, ft2, ft))
        bm.faces.new((ft, ft2, bt2, bt))
        bm.faces.new((bb2, bb, bt, bt2))
        bm.faces.new((fb2, fb, bb, bb2))
    bm.faces.new(cols[0][::-1])
    bm.faces.new(cols[-1])
    recalc(bm)
    return add_obj(name, bm, "Proxy", mat)


def jag(u, amp=0.16, notch=0.12):
    h = rng.uniform(-amp, amp)
    if rng.random() < notch:
        h -= rng.uniform(0.25, 0.6)
    return h


def back_wall_height(u):
    h = 6.3 + 0.25 * math.sin(u * 0.7)
    h = h * (1 - smoothstep(-13.0, -15.0, u)) + 3.4 * smoothstep(-13.0, -15.0, u)
    collapse = smoothstep(4.4, 5.4, u) * (1 - smoothstep(8.2, 9.2, u))
    h = h * (1 - collapse) + (2.0 + rng.uniform(-0.3, 0.3)) * collapse
    return h + jag(u)


def pointed_profile(w, spring, rfac=0.75, base=-0.3, steps=10):
    r = rfac * w
    cx = -w / 2 + r
    ang_apex = math.acos((0.0 - cx) / r)
    left = [(-w / 2, base)]
    for i in range(steps + 1):
        a = math.pi - (math.pi - ang_apex) * i / steps
        left.append((cx + r * math.cos(a), spring + r * math.sin(a)))
    right = [(-x, z) for x, z in reversed(left[:-1])]
    pts = left + right
    return [p for p in pts]  # left base, up the left arc, apex, down, right base: clockwise in (x, z)


def arch_cutter(name, u, v, w, spring, thick, base=-0.3):
    bm = bmesh.new()
    prof = list(reversed(pointed_profile(w, spring, base=base)))
    prism(bm, prof, -thick / 2, thick / 2, frame_uv(u, v))
    recalc(bm)
    ob = add_obj(name, bm, "Cutters")
    ob.hide_render = True
    ob.display_type = "WIRE"
    return ob


def build_back_wall():
    vc, thick = 9.0, 1.0
    ob = wall("Occ_ChapelWall", -15.2, 11.2, vc, thick, back_wall_height, MAT["wall"])
    door = arch_cutter("Cut_Door", -2.0, vc, 2.4, 3.0, 3.0)
    arch_cutter("Cut_WindowL", -8.3, vc, 0.9, 3.9, 3.0, base=2.3)
    arch_cutter("Cut_WindowR", 3.6, vc, 0.9, 3.9, 3.0, base=2.3)
    mod = ob.modifiers.new("Openings", "BOOLEAN")
    mod.operation = "DIFFERENCE"
    mod.operand_type = "COLLECTION"
    mod.collection = COLL["Cutters"]
    mod.solver = "EXACT"
    # moulded frame around the doorway
    bm = bmesh.new()
    prof = list(reversed(pointed_profile(2.4 + 0.7, 3.0, rfac=0.75, base=-0.1)))
    prism(bm, prof, -thick / 2 - 0.16, thick / 2 + 0.16, frame_uv(-2.0, vc))
    recalc(bm)
    frame = add_obj("Occ_DoorFrame", bm, "Proxy", MAT["trim"])
    fm = frame.modifiers.new("Opening", "BOOLEAN")
    fm.operation = "DIFFERENCE"
    fm.object = door
    fm.solver = "EXACT"
    bevel_mod(frame, 0.03, 2)
    # buttresses, stepped
    bm = bmesh.new()
    for u in (-11.0, -5.6, 1.5, 10.3):
        cube(bm, box_matrix(u, vc - 0.5 - 0.45, -0.1, 0.95, 0.9, 3.0))
        cube(bm, box_matrix(u, vc - 0.5 - 0.3, 2.9, 0.8, 0.6, 1.6))
        top = [bm.verts.new(P(u - 0.4, vc - 0.5 - 0.6, 4.5)), bm.verts.new(P(u + 0.4, vc - 0.5 - 0.6, 4.5)),
               bm.verts.new(P(u + 0.4, vc - 0.5, 5.2)), bm.verts.new(P(u - 0.4, vc - 0.5, 5.2))]
        low = [bm.verts.new(P(u - 0.4, vc - 0.5 - 0.6, 4.4)), bm.verts.new(P(u + 0.4, vc - 0.5 - 0.6, 4.4)),
               bm.verts.new(P(u + 0.4, vc - 0.5, 4.4)), bm.verts.new(P(u - 0.4, vc - 0.5, 4.4))]
        bm.faces.new(top)
        bm.faces.new(low[::-1])
        for i in range(4):
            j = (i + 1) % 4
            bm.faces.new((low[i], low[j], top[j], top[i]))
    recalc(bm)
    but = add_obj("Occ_Buttresses", bm, "Proxy", MAT["wall"])
    bevel_mod(but, 0.02, 1)
    # rubble heap in front of the collapse
    bm = bmesh.new()
    for _ in range(90):
        u = rng.uniform(4.6, 8.9)
        v = rng.uniform(6.9, 8.6)
        pile = 0.9 * (1 - abs(u - 6.8) / 2.4) * smoothstep(6.8, 8.4, v)
        size = rng.uniform(0.12, 0.34)
        rock(bm, P(u, v, max(0.05, rng.uniform(0.0, pile))), size)
    add_obj("Occ_WallRubble", bm, "Proxy", MAT["rubble"])
    return ob


def build_low_walls():
    def h_fn(base):
        return lambda u: base + 0.35 * math.sin(u * 1.3) + jag(u, 0.12, 0.2)
    wall("Occ_LowWallA", -13.0, -5.6, -7.8, 0.55, h_fn(1.45), MAT["lowwall"])
    wall("Occ_LowWallB", 4.2, 11.0, -7.8, 0.55, h_fn(1.3), MAT["lowwall"])
    bm = bmesh.new()
    for _ in range(26):
        u = rng.choice((rng.uniform(-13.5, -5.0), rng.uniform(3.8, 11.5)))
        v = -7.8 + rng.uniform(-1.2, -0.35)
        rock(bm, P(u, v, 0.05), rng.uniform(0.1, 0.26))
    add_obj("Occ_LowWallRubble", bm, "Proxy", MAT["rubble"])


def build_banners():
    bm = bmesh.new()
    for u in (-6.7, 2.6):
        cols, rows = 6, 12
        grid = []
        for r in range(rows + 1):
            row = []
            for c in range(cols + 1):
                x = (c / cols - 0.5) * 0.85
                z = 5.9 - 2.7 * r / rows
                if r == rows:
                    z += rng.uniform(0.0, 0.45) * (0.4 + 0.6 * abs(math.sin(c * 1.7)))
                fold = 0.05 * math.sin(c * 2.3 + r * 0.3) * (r / rows)
                row.append(bm.verts.new(frame_uv(u, 8.43 - 0.03 - fold) @ Vector((x, 0, z))))
            grid.append(row)
        for r in range(rows):
            for c in range(cols):
                bm.faces.new((grid[r][c], grid[r][c + 1], grid[r + 1][c + 1], grid[r + 1][c]))
    ob = add_obj("Occ_Banners", bm, "Proxy", MAT["banner"])
    sol = ob.modifiers.new("Thick", "SOLIDIFY")
    sol.thickness = 0.02


# --------------------------------------------------------------------------
# pillars
# --------------------------------------------------------------------------

def pillar(name, u, v, height, broken, rot=0.0):
    bm = bmesh.new()
    cube(bm, box_matrix(u, v, -0.05, 1.2, 1.2, 0.42, rot))
    cube(bm, box_matrix(u, v, 0.35, 1.02, 1.02, 0.16, rot))
    top = height - (0.0 if broken else 0.62)
    sides = 16
    rings = []
    z = 0.51
    levels = max(2, int((top - z) / 0.6) + 1)
    base = frame_uv(u, v, 0.0, rot)
    for li in range(levels + 1):
        zz = z + (top - z) * li / levels
        ring = []
        for k in range(sides):
            a = k * TAU / sides
            r = (0.45 if k % 2 == 0 else 0.4) * rng.uniform(0.97, 1.02)
            dz = rng.uniform(-0.28, 0.08) if (broken and li == levels) else 0.0
            ring.append(bm.verts.new(base @ Vector((r * math.cos(a), r * math.sin(a), zz + dz))))
        rings.append(ring)
    for i in range(levels):
        for k in range(sides):
            k2 = (k + 1) % sides
            bm.faces.new((rings[i][k], rings[i][k2], rings[i + 1][k2], rings[i + 1][k]))
    bm.faces.new(list(reversed(rings[0])))
    capf = bm.faces.new(rings[-1])
    if broken:
        res = bmesh.ops.poke(bm, faces=[capf])
        for vert in res["verts"]:
            vert.co.z -= rng.uniform(0.05, 0.2)
    else:
        prof = [(0.43, top), (0.5, top + 0.18), (0.66, top + 0.42), (0.7, top + 0.47)]
        lathe(bm, prof, base, sides=8)
        cube(bm, box_matrix(u, v, top + 0.45, 1.3, 1.3, 0.2, rot))
    recalc(bm)
    ob = add_obj(name, bm, "Proxy", MAT["pillar"])
    return ob


def build_pillars():
    pillar("Occ_PillarL1", -5.5, -2.0, 5.3, False)
    pillar("Occ_PillarL2", -5.5, 2.6, 2.7, True)
    pillar("Occ_PillarL3", -5.5, 7.0, 5.3, False)
    pillar("Occ_PillarR1", 5.5, -2.0, 1.25, True)
    pillar("Occ_PillarR2", 5.5, 2.6, 5.3, False)
    pillar("Occ_PillarR3", 5.5, 7.0, 3.6, True)
    # the fallen drum of R1 and scattered chunks
    bm = bmesh.new()
    axis_m = frame_uv(7.1, -1.5, 0.4, 0.35) @ Matrix.Rotation(math.pi / 2, 4, "Y")
    tube(bm, [axis_m @ Vector((0, 0, -1.1)), axis_m @ Vector((0, 0, 1.1))], [0.42, 0.42], sides=16)
    for _ in range(16):
        rock(bm, P(rng.uniform(5.0, 8.6), rng.uniform(-3.0, -0.4), 0.05), rng.uniform(0.1, 0.25))
    for _ in range(10):
        rock(bm, P(rng.uniform(-6.6, -4.4), rng.uniform(1.6, 3.8), 0.05), rng.uniform(0.08, 0.22))
    add_obj("Occ_PillarRubble", bm, "Proxy", MAT["pillar"])


# --------------------------------------------------------------------------
# dais, altar, sigil, candles
# --------------------------------------------------------------------------

DAIS = (0.0, 2.6)
CANDLES = []


def octagon(bm, u, v, r, z0, z1):
    prof = []
    m = frame_uv(u, v, 0.0, math.pi / 8)
    bottom = [bm.verts.new(m @ Vector((r * math.cos(k * TAU / 8), r * math.sin(k * TAU / 8), z0))) for k in range(8)]
    top = [bm.verts.new(m @ Vector((r * math.cos(k * TAU / 8), r * math.sin(k * TAU / 8), z1))) for k in range(8)]
    bm.faces.new(bottom[::-1])
    bm.faces.new(top)
    for k in range(8):
        k2 = (k + 1) % 8
        bm.faces.new((bottom[k], bottom[k2], top[k2], top[k]))


def build_dais():
    u, v = DAIS
    bm = bmesh.new()
    octagon(bm, u, v, 3.3, -0.05, 0.12)
    ob = add_obj("Walk_DaisOuter", bm, "Proxy", MAT["dais"])
    bevel_mod(ob, 0.02, 2)
    bm = bmesh.new()
    octagon(bm, u, v, 2.7, 0.0, 0.25)
    ob = add_obj("Walk_DaisInner", bm, "Proxy", MAT["dais"])
    bevel_mod(ob, 0.02, 2)
    # altar
    bm = bmesh.new()
    cube(bm, box_matrix(u, v, 0.25, 1.45, 0.78, 0.85))
    cube(bm, box_matrix(u, v, 1.1, 1.7, 0.98, 0.13))
    ob = add_obj("Occ_Altar", bm, "Proxy", MAT["trim"])
    bevel_mod(ob, 0.025, 2)
    # skull on the altar
    bm = bmesh.new()
    res = bmesh.ops.create_icosphere(bm, subdivisions=3, radius=1.0)
    skm = frame_uv(u + 0.15, v, 1.33, -0.4)
    for vert in res["verts"]:
        c = vert.co
        c2 = Vector((c.x * 0.085, c.y * 0.105, c.z * 0.095))
        if c.y < -0.3 and c.z < 0.2:
            c2.z -= 0.02
        vert.co = skm @ c2
    cube(bm, skm @ Matrix.Translation((0, -0.05, -0.08)) @ Matrix.Diagonal((0.1, 0.09, 0.04, 1)))
    add_obj("Occ_Skull", bm, "Proxy", MAT["bone"])
    # sigil: two rings, a pentagram and runes, a hair above the inner top
    bm = bmesh.new()
    zs = 0.254
    base = frame_uv(u, v, zs)

    def ring(r0, r1, seg=64):
        inner = [bm.verts.new(base @ Vector((r0 * math.cos(k * TAU / seg), r0 * math.sin(k * TAU / seg), 0))) for k in range(seg)]
        outer = [bm.verts.new(base @ Vector((r1 * math.cos(k * TAU / seg), r1 * math.sin(k * TAU / seg), 0))) for k in range(seg)]
        for k in range(seg):
            k2 = (k + 1) % seg
            bm.faces.new((inner[k], inner[k2], outer[k2], outer[k]))

    def strip(a, b, w):
        d = (b - a).normalized()
        nrm = Vector((-d.y, d.x, 0)) * (w / 2)
        bm.faces.new([bm.verts.new(base @ Vector((p.x, p.y, 0))) for p in (a - nrm, b - nrm, b + nrm, a + nrm)])

    ring(2.18, 2.26)
    ring(1.72, 1.77)
    star = [Vector((1.74 * math.cos(math.pi / 2 + k * TAU / 5), 1.74 * math.sin(math.pi / 2 + k * TAU / 5), 0)) for k in range(5)]
    for k in range(5):
        strip(star[k], star[(k + 2) % 5], 0.045)
    for k in range(14):
        a = k * TAU / 14 + 0.1
        c = Vector((1.98 * math.cos(a), 1.98 * math.sin(a), 0))
        t = Vector((-math.sin(a), math.cos(a), 0))
        rr = Vector((math.cos(a), math.sin(a), 0))
        strip(c - rr * 0.1, c + rr * 0.1, 0.03)
        for _ in range(2):
            o = c + rr * rng.uniform(-0.08, 0.08)
            strip(o, o + (t * rng.choice((-1, 1)) + rr * rng.uniform(-0.6, 0.6)).normalized() * 0.09, 0.028)
    add_obj("Fx_Sigil", bm, "RenderOnly", MAT["sigil"], "sigil")
    # candles on the outer step and on the altar
    spots = [(u + 3.0 * math.cos(math.pi / 8 + k * TAU / 8 + math.pi / 4),
              v + 3.0 * math.sin(math.pi / 8 + k * TAU / 8 + math.pi / 4), 0.12) for k in range(8)]
    spots += [(u - 0.6, v + 0.2, 1.23), (u - 0.45, v - 0.25, 1.23), (u + 0.62, v + 0.28, 1.23)]
    build_candles("Fx_DaisCandles", spots)


def build_candles(name, spots):
    bm_wax, bm_fl = bmesh.new(), bmesh.new()
    for (u, v, z) in spots:
        for _ in range(rng.randint(1, 3)):
            du, dv = rng.uniform(-0.1, 0.1), rng.uniform(-0.1, 0.1)
            h = rng.uniform(0.1, 0.3)
            r = rng.uniform(0.03, 0.05)
            c = P(u + du, v + dv, z)
            tube(bm_wax, [c, c + Vector((0, 0, h))], [r, r * 0.95], sides=8)
            res = bmesh.ops.create_icosphere(bm_fl, subdivisions=1, radius=1.0)
            for vert in res["verts"]:
                vert.co = c + Vector((vert.co.x * 0.018, vert.co.y * 0.018, 0.035 + h + vert.co.z * 0.04))
            CANDLES.append(c + Vector((0, 0, h + 0.04)))
    add_obj(name + "_Wax", bm_wax, "RenderOnly", MAT["wax"])
    add_obj(name + "_Flames", bm_fl, "RenderOnly", MAT["flame"], "fire")


# --------------------------------------------------------------------------
# braziers
# --------------------------------------------------------------------------

BRAZIERS = [(-2.3, -3.4), (2.3, -3.4)]
FLAMES = []
FIRE_LIGHTS = []


def build_braziers():
    bm_iron, bm_coal, bm_fire = bmesh.new(), bmesh.new(), bmesh.new()
    for (u, v) in BRAZIERS:
        c = P(u, v)
        for k in range(3):
            a = math.pi / 2 + k * TAU / 3
            foot = c + Vector((0.38 * math.cos(a), 0.38 * math.sin(a), 0.0))
            knee = c + Vector((0.3 * math.cos(a), 0.3 * math.sin(a), 0.45))
            top = c + Vector((0.2 * math.cos(a), 0.2 * math.sin(a), 0.92))
            tube(bm_iron, [foot, knee, top], [0.03, 0.028, 0.025], sides=6)
        prof = [(0.05, 0.84), (0.2, 0.86), (0.32, 0.93), (0.38, 1.05), (0.41, 1.09), (0.38, 1.1), (0.34, 1.04), (0.27, 0.95), (0.15, 0.9), (0.05, 0.89)]
        lathe(bm_iron, prof, Matrix.Translation(c), sides=16)
        for _ in range(14):
            rock(bm_coal, c + Vector((rng.uniform(-0.22, 0.22), rng.uniform(-0.22, 0.22), 1.0)), rng.uniform(0.05, 0.09), 0.7)
        for i in range(5):
            res = bmesh.ops.create_icosphere(bm_fire, subdivisions=2, radius=1.0)
            off = Vector((rng.uniform(-0.12, 0.12), rng.uniform(-0.12, 0.12), 0))
            h = rng.uniform(0.35, 0.62) * (1.2 if i == 0 else 1.0)
            w = rng.uniform(0.08, 0.14) * (1.3 if i == 0 else 1.0)
            for vert in res["verts"]:
                t = (vert.co.z + 1) / 2
                taper = (1 - t) ** 0.8
                vert.co = c + off + Vector((vert.co.x * w * taper, vert.co.y * w * taper, 1.05 + t * h))
        FLAMES.append({"position": to_godot(c + Vector((0, 0, 1.05))), "height": 0.75, "width": 0.55})
        light = bpy.data.lights.new(f"BrazierLight_{len(FIRE_LIGHTS)}", "POINT")
        light.color = (1.0, 0.5, 0.2)
        light.energy = 420.0
        light.shadow_soft_size = 0.15
        lo = bpy.data.objects.new(light.name, light)
        lo.location = c + Vector((0, 0, 1.4))
        lo.lightgroup = "fire"
        COLL["Lights"].objects.link(lo)
        FIRE_LIGHTS.append({"position": to_godot(lo.location), "color": list(light.color), "group": "fire"})
    add_obj("Occ_Braziers", bm_iron, "Proxy", MAT["iron"])
    add_obj("Fx_Coals", bm_coal, "RenderOnly", MAT["coal"], "fire")
    add_obj("Fx_BrazierFire", bm_fire, "RenderOnly", MAT["fire"], "fire")


# --------------------------------------------------------------------------
# graveyard, trees, chapel interior
# --------------------------------------------------------------------------

def gravestone(bm, u, v, w, h, rot, tilt, cross=False):
    m = frame_uv(u, v, -0.15, rot) @ Matrix.Rotation(tilt[0], 4, "X") @ Matrix.Rotation(tilt[1], 4, "Y")
    if cross:
        cube(bm, m @ Matrix.Translation((0, 0, (h + 0.15) / 2)) @ Matrix.Diagonal((0.16, 0.14, h + 0.15, 1)))
        cube(bm, m @ Matrix.Translation((0, 0, h * 0.72)) @ Matrix.Diagonal((w, 0.14, 0.15, 1)))
        return
    prof = [(-w / 2, 0.0), (w / 2, 0.0)]
    for i in range(9):
        a = i * math.pi / 8
        prof.append((w / 2 * math.cos(a), h - w / 2 + w / 2 * math.sin(a) + 0.15))
    prof = [prof[0], prof[1]] + prof[2:]
    prism(bm, prof, -0.08, 0.08, m)


def branch(bm, start, direction, length, radius, depth):
    pts, rad = [start], [radius]
    d = direction.normalized()
    p = start
    segs = 4
    for s in range(1, segs + 1):
        d = (d + Vector((rng.uniform(-0.4, 0.4), rng.uniform(-0.4, 0.4), rng.uniform(-0.12, 0.2)))).normalized()
        p = p + d * (length / segs)
        pts.append(p)
        rad.append(max(0.012, radius * (1 - 0.8 * s / segs)))
    tube(bm, pts, rad, sides=6)
    if depth > 0:
        for _ in range(rng.randint(2, 3)):
            i = rng.randint(2, segs)
            side = Vector((rng.uniform(-1, 1), rng.uniform(-1, 1), rng.uniform(-0.1, 0.5)))
            nd = (d + side * 1.1).normalized()
            branch(bm, pts[i], nd, length * rng.uniform(0.5, 0.7), rad[i] * 0.85, depth - 1)


def dead_tree(bm, u, v, height=5.0, radius=0.3):
    base = P(u, v, -0.1)
    pts, rad = [base], [radius * 1.3]
    d = Vector((0.15, -0.1, 1)).normalized()
    p = base
    for s in range(1, 6):
        d = (d + Vector((rng.uniform(-0.25, 0.25), rng.uniform(-0.25, 0.25), 0.3))).normalized()
        p = p + d * (height * 0.62 / 5)
        pts.append(p)
        rad.append(radius * (1 - 0.55 * s / 5))
    tube(bm, pts, rad, sides=8)
    for i in (2, 3, 4, 5, 5):
        side = Vector((rng.uniform(-1, 1), rng.uniform(-1, 1), rng.uniform(0.2, 0.9)))
        branch(bm, pts[i], side, height * rng.uniform(0.3, 0.45), rad[i] * 0.8, 2)
    for k in range(5):
        a = k * TAU / 5 + rng.uniform(-0.3, 0.3)
        out = Vector((math.cos(a), math.sin(a), -0.25))
        branch(bm, base + Vector((0, 0, 0.35)), out, rng.uniform(0.8, 1.3), radius * 0.6, 0)


def build_graveyard():
    bm = bmesh.new()
    placed = []
    tries = 0
    while len(placed) < 13 and tries < 400:
        tries += 1
        u, v = rng.uniform(8.3, 13.8), rng.uniform(-5.0, 6.2)
        if math.hypot(u - 11.5, v - 2.5) < 1.4 or any(math.hypot(u - a, v - b) < 1.3 for a, b in placed):
            continue
        placed.append((u, v))
        gravestone(bm, u, v, rng.uniform(0.45, 0.7), rng.uniform(0.6, 1.05), rng.uniform(-0.25, 0.25),
                   (rng.uniform(-0.2, 0.2), rng.uniform(-0.15, 0.15)), cross=rng.random() < 0.25)
    for (u, v) in ((-9.5, -4.5), (-10.5, 5.2), (-12.8, 1.0), (-8.8, 0.5)):
        gravestone(bm, u, v, rng.uniform(0.5, 0.65), rng.uniform(0.7, 1.0), rng.uniform(-0.3, 0.3),
                   (rng.uniform(-0.2, 0.2), rng.uniform(-0.15, 0.15)))
    recalc(bm)
    ob = add_obj("Occ_Gravestones", bm, "Proxy", MAT["grave"])
    bevel_mod(ob, 0.015, 1)
    bm = bmesh.new()
    dead_tree(bm, 11.5, 2.5, 5.4, 0.3)
    add_obj("Occ_DeadTree", bm, "Proxy", MAT["bark"])
    bm = bmesh.new()
    for (u, v, h) in ((-13.5, 15.0, 6.5), (-6.0, 17.5, 7.5), (1.5, 16.0, 6.8), (7.5, 15.5, 7.2), (13.0, 13.5, 6.0), (-15.5, 8.0, 5.5)):
        dead_tree(bm, u, v, h, 0.28)
    add_obj("Fx_FarTrees", bm, "RenderOnly", MAT["bark"])


def build_interior():
    build_flagstones("Walk_ChapelFloor", -9.0, 5.0, 9.6, 13.6, lambda u, v: min(u + 8.5, 4.5 - u, v - 9.55, 13.5 - v))
    bm = bmesh.new()
    cube(bm, box_matrix(-2.0, 11.6, 0.0, 1.0, 2.2, 0.75))
    cube(bm, box_matrix(-2.0, 11.6, 0.75, 1.15, 2.35, 0.16))
    ob = add_obj("Occ_Sarcophagus", bm, "Proxy", MAT["dais"])
    bevel_mod(ob, 0.03, 2)
    build_candles("Fx_ChapelCandles", [(-2.35, 10.8, 0.91), (-1.65, 10.75, 0.91), (-2.0, 12.4, 0.91)])
    light = bpy.data.lights.new("ChapelLight", "POINT")
    light.color = (1.0, 0.62, 0.3)
    light.energy = 90.0
    light.shadow_soft_size = 0.3
    lo = bpy.data.objects.new(light.name, light)
    lo.location = P(-2.0, 11.0, 1.4)
    lo.lightgroup = "fire"
    COLL["Lights"].objects.link(lo)
    FIRE_LIGHTS.append({"position": to_godot(lo.location), "color": list(light.color), "group": "fire"})


def build_grass_and_rocks():
    bm = bmesh.new()
    count = 0
    while count < 700:
        u, v = rng.uniform(-17, 17), rng.uniform(-12, 20)
        if paving_region(u, v) > -0.2 and v < 8.5:
            continue
        if 8.4 < v < 9.7 and -15.3 < u < 11.3:
            continue
        count += 1
        c = P(u, v, -0.03)
        for _ in range(rng.randint(3, 6)):
            h = rng.uniform(0.12, 0.3)
            tip = c + Vector((rng.uniform(-0.1, 0.1), rng.uniform(-0.1, 0.1), h))
            off = Vector((rng.uniform(-0.05, 0.05), rng.uniform(-0.05, 0.05), 0))
            a = bm.verts.new(c + off + Vector((-0.012, 0, 0)))
            b = bm.verts.new(c + off + Vector((0.012, 0, 0)))
            t = bm.verts.new(tip)
            bm.faces.new((a, b, t))
    add_obj("Fx_Grass", bm, "RenderOnly", MAT["grass"])
    bm = bmesh.new()
    for _ in range(160):
        u, v = rng.uniform(-16, 16), rng.uniform(-11, 19)
        rock(bm, P(u, v, -0.02), rng.uniform(0.04, 0.12), 0.5)
    add_obj("Fx_Pebbles", bm, "RenderOnly", MAT["rubble"])


def build_fog():
    bm = bmesh.new()
    cube(bm, box_matrix(0.0, 4.0, -0.05, 38.0, 36.0, 1.45))
    add_obj("Fx_GroundFog", bm, "RenderOnly", MAT["fog"])


def build_lights():
    sun = bpy.data.lights.new("Moon", "SUN")
    sun.color = (0.6, 0.7, 1.0)
    sun.energy = 3.2
    sun.angle = math.radians(1.2)
    so = bpy.data.objects.new("Moon", sun)
    # The moon sits front-left of the viewer, 42 degrees up, so the chapel wall
    # catches it and the pillars throw their shadows up and to the right.
    horiz = (P(-0.45, -1.0) ).normalized()
    elev = math.radians(42.0)
    to_light = Vector((horiz.x * math.cos(elev), horiz.y * math.cos(elev), math.sin(elev))).normalized()
    so.rotation_euler = (-to_light).to_track_quat("-Z", "Y").to_euler()
    so["travel"] = list(-to_light)  # matrix_world is stale until the depsgraph updates
    so.lightgroup = "moon"
    COLL["Lights"].objects.link(so)
    sig = bpy.data.lights.new("SigilLight", "POINT")
    sig.color = (1.0, 0.12, 0.06)
    sig.energy = 70.0
    sig.shadow_soft_size = 1.2
    sl = bpy.data.objects.new(sig.name, sig)
    sl.location = P(DAIS[0], DAIS[1], 0.7)
    sl.lightgroup = "sigil"
    COLL["Lights"].objects.link(sl)
    world = bpy.data.worlds.new("Crypt_Night")
    world.use_nodes = True
    bg = [n for n in world.node_tree.nodes if n.type == "BACKGROUND"][0]
    bg.inputs["Color"].default_value = (0.0035, 0.0045, 0.008, 1.0)
    bg.inputs["Strength"].default_value = 1.0
    scene.world = world
    return so, sl


# --------------------------------------------------------------------------
# build
# --------------------------------------------------------------------------

vl = scene.view_layers[0]
for lg in ("moon", "fire", "sigil"):
    vl.lightgroups.add(name=lg)

build_soil()
build_flagstones("Walk_Flagstones", -11.5, 11.5, -6.2, 8.35, paving_region, holes=[(DAIS[0], DAIS[1], 3.25)])
build_back_wall()
build_low_walls()
build_banners()
build_pillars()
build_dais()
build_braziers()
build_graveyard()
build_interior()
build_grass_and_rocks()
build_fog()
moon, sigil_light = build_lights()
print("CRYPT built in %.1f s" % (time.time() - T0))

# --------------------------------------------------------------------------
# camera: the game camera's basis (CameraRig3D) converted to Blender axes
# --------------------------------------------------------------------------

R = Vector((S2, S2, 0.0))
yaw, pitch = math.radians(45.0), math.radians(-35.0)
# Godot basis for Basis.from_euler((pitch, yaw, 0)): y = (-sin(yaw) sin(pitch)... ) worked out:
up_g = Vector((math.sin(yaw) * math.sin(-pitch) * -1.0, math.cos(pitch), math.cos(yaw) * math.sin(-pitch) * -1.0))
back_g = Vector((math.sin(yaw) * math.cos(pitch), math.sin(-pitch), math.cos(yaw) * math.cos(pitch)))
right_g = Vector((math.cos(yaw), 0.0, -math.sin(yaw)))


def g2b(g):
    return Vector((g.x, -g.z, g.y))


R, U, B = g2b(right_g), g2b(up_g), g2b(back_g)
assert abs(R.dot(U)) < 1e-6 and abs(R.dot(B)) < 1e-6 and abs(U.dot(B)) < 1e-6
res_x = int(round((SCREEN_X[1] - SCREEN_X[0]) * PPM))
res_y = int(round((SCREEN_Y[1] - SCREEN_Y[0]) * PPM))
view_w, view_h = res_x / PPM, res_y / PPM
sx_c = (SCREEN_X[0] + SCREEN_X[1]) / 2
sy_c = (SCREEN_Y[0] + SCREEN_Y[1]) / 2
centre = R * sx_c + U * sy_c
cam_data = bpy.data.cameras.new("GameCamera")
cam_data.type = "ORTHO"
cam_data.ortho_scale = max(view_w, view_h)
cam_data.sensor_fit = "AUTO"
cam_data.clip_start = 0.1
cam_data.clip_end = 300.0
cam = bpy.data.objects.new("GameCamera", cam_data)
rot = Matrix((R, U, B)).transposed()
cam.matrix_world = Matrix.Translation(centre + B * 80.0) @ rot.to_4x4()
scene.collection.objects.link(cam)
scene.camera = cam
scene.render.resolution_x = res_x
scene.render.resolution_y = res_y
scene.render.resolution_percentage = 100
print("CRYPT camera %dx%d px, view %.3f x %.3f m, centre %s" % (res_x, res_y, view_w, view_h, tuple(round(c, 3) for c in centre)))

# --------------------------------------------------------------------------
# export the proxy and the json
# --------------------------------------------------------------------------

def export_proxy(path):
    bpy.ops.object.select_all(action="DESELECT")
    for ob in COLL["Proxy"].objects:
        ob.select_set(True)
    bpy.context.view_layer.objects.active = COLL["Proxy"].objects[0]
    bpy.ops.export_scene.gltf(filepath=path, export_format="GLB", use_selection=True, export_apply=True,
                              export_materials="NONE", export_yup=True, export_animations=False,
                              export_skins=False, export_morph=False, export_cameras=False,
                              export_lights=False, export_extras=False)


def spot(u, v, z=0.0):
    return to_godot(P(u, v, z))


moon_dir = Vector(moon["travel"])
data = {
    "version": 1,
    "generator": "tools/blender/prerender/crypt_courtyard.py",
    "ppm": PPM,
    "image_size": [res_x, res_y],
    "pass_scale": 0.5,
    "view_size": [view_w, view_h],
    "cam_center": to_godot(centre),
    "cam_right": to_godot(R),
    "cam_up": to_godot(U),
    "cam_back": to_godot(B),
    "screen_rect": [SCREEN_X[0], SCREEN_X[1], SCREEN_Y[0], SCREEN_Y[1]],
    "uv_axes": {"u": to_godot(P(1, 0)), "v": to_godot(P(0, 1))},
    "walk_rect_uv": list(WALK_RECT),
    "moon": {"direction": to_godot(moon_dir), "color": list(moon.data.color)},
    "fire_lights": FIRE_LIGHTS,
    "sigil_light": {"position": to_godot(sigil_light.location), "color": list(sigil_light.data.color)},
    "flames": FLAMES,
    "candles": [to_godot(c) for c in CANDLES],
    "spots": {
        "spawn": spot(0.0, -5.6),
        "front_of_pillar": spot(-5.5, -3.3),
        "behind_pillar": spot(-5.05, -0.95),
        "behind_low_wall": spot(-9.0, -6.95),
        "on_dais": spot(0.0, 0.75, 0.25),
        "in_doorway": spot(-2.0, 9.0),
        "behind_wall": spot(-6.5, 11.2),
        "by_brazier": spot(-1.2, -3.9),
    },
    "textures": {"color": "crypt_color.jpg", "moon": "crypt_moon.jpg", "fire": "crypt_fire.jpg",
                 "sigil": "crypt_sigil.jpg", "albedo": "crypt_albedo.jpg"},
}
if not PREVIEW:
    export_proxy(os.path.join(OUT_DIR, "crypt_proxy.glb"))
    with open(os.path.join(OUT_DIR, "crypt_scene.json"), "w", encoding="utf-8") as fh:
        json.dump(data, fh, indent=1)
    print("CRYPT exported proxy and json")

# --------------------------------------------------------------------------
# render settings and compositor
# --------------------------------------------------------------------------

scene.render.engine = "CYCLES"
try:
    prefs = bpy.context.preferences.addons["cycles"].preferences
    prefs.compute_device_type = "OPTIX"
    prefs.get_devices()
    for d in prefs.devices:
        d.use = d.type == "OPTIX"
    scene.cycles.device = "GPU"
except Exception as exc:  # no GPU: CPU works, only slower
    print("CRYPT GPU unavailable:", exc)
scene.cycles.samples = SAMPLES
scene.cycles.use_adaptive_sampling = True
scene.cycles.adaptive_threshold = 0.01
scene.cycles.use_denoising = True
for name in ("OPTIX", "OPENIMAGEDENOISE"):
    try:
        scene.cycles.denoiser = name
        break
    except TypeError:
        pass
scene.cycles.max_bounces = 6
scene.cycles.volume_bounces = 0
scene.cycles.sample_clamp_indirect = 6.0
scene.cycles.blur_glossy = 1.0
scene.render.film_transparent = False
scene.render.filter_size = 1.2
for vt in ("Standard",):
    try:
        scene.view_settings.view_transform = vt
    except TypeError:
        pass
scene.view_settings.look = "None"
scene.view_settings.exposure = 0.0
scene.view_settings.gamma = 1.0

vl.use_pass_diffuse_color = True
vl.cycles.denoising_store_passes = True

scene.render.image_settings.file_format = "JPEG"
scene.render.image_settings.quality = 92
scene.render.image_settings.color_mode = "RGB"
scene.frame_current = 1

scene.use_nodes = True
tree = scene.node_tree
tree.nodes.clear()
rl = tree.nodes.new("CompositorNodeRLayers")
kuw = tree.nodes.new("CompositorNodeKuwahara")
for prop, val in (("variation", "ANISOTROPIC"), ("use_high_precision", True), ("uniformity", 4),
                  ("sharpness", 0.6), ("eccentricity", 1.0)):
    try:
        setattr(kuw, prop, val)
    except (AttributeError, TypeError):
        pass
kuw_size = max(2, int(round(PPM / 32)))
if "Size" in kuw.inputs:
    kuw.inputs["Size"].default_value = kuw_size
else:
    kuw.size = kuw_size
glare = tree.nodes.new("CompositorNodeGlare")
glare.glare_type = "FOG_GLOW"
glare.quality = "HIGH"
glare.threshold = 0.85
glare.mix = -0.55
glare.size = 8
comp = tree.nodes.new("CompositorNodeComposite")
tree.links.new(rl.outputs["Image"], kuw.inputs["Image"])
tree.links.new(kuw.outputs["Image"], glare.inputs["Image"])
tree.links.new(glare.outputs["Image"], comp.inputs["Image"])


def half(sock):
    sc = tree.nodes.new("CompositorNodeScale")
    sc.space = "RELATIVE"
    sc.inputs[1].default_value = 0.5
    sc.inputs[2].default_value = 0.5
    tree.links.new(sock, sc.inputs[0])
    return sc.outputs[0]


h_normal = half(rl.outputs["Denoising Normal"])
h_albedo = half(rl.outputs["Denoising Albedo"])
fout = tree.nodes.new("CompositorNodeOutputFile")
fout.base_path = OUT_DIR
fout.format.file_format = "JPEG"
fout.format.quality = 90
fout.format.color_mode = "RGB"
fout.file_slots.clear()
PASS_FILES = {}
for pname, sock_name in (("moon", "Combined_moon"), ("fire", "Combined_fire"), ("sigil", "Combined_sigil"), ("albedo", "DiffCol")):
    src = half(rl.outputs[sock_name])
    if pname != "albedo":
        dn = tree.nodes.new("CompositorNodeDenoise")
        try:
            dn.use_hdr = True
            dn.prefilter = "ACCURATE"
        except (AttributeError, TypeError):
            pass
        tree.links.new(src, dn.inputs["Image"])
        tree.links.new(h_normal, dn.inputs["Normal"])
        tree.links.new(h_albedo, dn.inputs["Albedo"])
        src = dn.outputs[0]
    slot_name = ("preview_" if PREVIEW else "") + f"crypt_{pname}_"
    fout.file_slots.new(slot_name)
    tree.links.new(src, fout.inputs[slot_name])
    PASS_FILES[pname] = slot_name

os.makedirs(os.path.dirname(_blend_path()), exist_ok=True)
bpy.ops.wm.save_as_mainfile(filepath=_blend_path(), compress=True)
print("CRYPT saved", _blend_path())

if DO_RENDER:
    t = time.time()
    color_name = "crypt_color_preview.jpg" if PREVIEW else "crypt_color.jpg"
    scene.render.filepath = os.path.join(OUT_DIR, color_name)
    bpy.ops.render.render(write_still=True)
    for pname, slot in PASS_FILES.items():
        src = os.path.join(OUT_DIR, slot + "0001.jpg")
        dst = os.path.join(OUT_DIR, ("crypt_%s_preview.jpg" if PREVIEW else "crypt_%s.jpg") % pname)
        if os.path.exists(src):
            os.replace(src, dst)
    print("CRYPT rendered %s in %.1f s" % (color_name, time.time() - t))

print("CRYPT done in %.1f s" % (time.time() - T0))
