# Builds a low-poly knight matching the Shared Fate player sprite
# (dark blue-grey plate, closed helm with T-visor, red belt/straps, dark red cape).
# Runs inside Blender via the MCP add-on. Re-running replaces the previous build.
import bpy
import bmesh
import math
from mathutils import Vector, Matrix

OUT_DIR = r"C:\Users\juula\AppData\Local\Temp\claude\D--workspace-SharedFate\92c1ea06-57cf-4509-8315-b0f707baf768\scratchpad"
SAVE_COPY = r"D:\workspace\SharedFate\blender\knight_lowpoly.blend"

# ---------- palette (from assets/player/knight_south.png) ----------
def srgb_to_linear(hexstr):
    h = hexstr.lstrip('#')
    r, g, b = (int(h[i:i + 2], 16) / 255.0 for i in (0, 2, 4))
    f = lambda c: c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4
    return (f(r), f(g), f(b), 1.0)

def make_mat(name, hexcol, metallic=0.0, roughness=0.5):
    m = bpy.data.materials.get(name)
    if m is None:
        m = bpy.data.materials.new(name)
    m.use_nodes = True
    bsdf = m.node_tree.nodes.get("Principled BSDF")
    bsdf.inputs["Base Color"].default_value = srgb_to_linear(hexcol)
    bsdf.inputs["Metallic"].default_value = metallic
    bsdf.inputs["Roughness"].default_value = roughness
    m.diffuse_color = srgb_to_linear(hexcol)  # solid-mode viewport colour
    return m

MATS = [
    make_mat("Knight_Armor",      "#464C5F", metallic=0.7, roughness=0.45),  # 0 main plate
    make_mat("Knight_ArmorLight", "#5D6477", metallic=0.7, roughness=0.40),  # 1 highlights (helmet, pauldrons)
    make_mat("Knight_ArmorDark",  "#2D2E3E", metallic=0.6, roughness=0.55),  # 2 joints, boots, gauntlets
    make_mat("Knight_Visor",      "#0F0909", metallic=0.2, roughness=0.60),  # 3 visor slit
    make_mat("Knight_Red",        "#A92A20", metallic=0.0, roughness=0.80),  # 4 belt / straps
    make_mat("Knight_Cape",       "#5B1204", metallic=0.0, roughness=0.90),  # 5 cape
    make_mat("Knight_Steel",      "#B8BCC8", metallic=0.9, roughness=0.30),  # 6 sword blade
]
ARMOR, LIGHT, DARK, VISOR, RED, CAPE, STEEL = range(7)

# ---------- bmesh helpers ----------
def _merge(bm, tmp, mi):
    for f in tmp.faces:
        f.material_index = mi
    me = bpy.data.meshes.new("_knight_tmp")
    tmp.to_mesh(me)
    tmp.free()
    bm.from_mesh(me)
    bpy.data.meshes.remove(me)

def _xform(tmp, scale, center, rot=None, taper=(1.0, 1.0)):
    for v in tmp.verts:
        v.co.x *= scale[0]; v.co.y *= scale[1]; v.co.z *= scale[2]
        if v.co.z > 0:
            v.co.x *= taper[0]; v.co.y *= taper[1]
        if rot is not None:
            v.co = rot @ v.co
        v.co += Vector(center)

def box(bm, center, size, mi, taper=(1.0, 1.0), rot=None):
    tmp = bmesh.new()
    bmesh.ops.create_cube(tmp, size=1.0)
    _xform(tmp, size, center, rot, taper)
    _merge(bm, tmp, mi)

def sphere(bm, center, radius, mi, scale=(1.0, 1.0, 1.0), u=8, v=6, face_mat=None):
    """face_mat(center_local, radius) -> material index or None, evaluated before scaling."""
    tmp = bmesh.new()
    bmesh.ops.create_uvsphere(tmp, u_segments=u, v_segments=v, radius=radius)
    overrides = {}
    if face_mat is not None:
        for f in tmp.faces:
            m = face_mat(f.calc_center_median(), radius)
            if m is not None:
                overrides[f.index] = m
    _xform(tmp, scale, center)
    for f in tmp.faces:
        f.material_index = overrides.get(f.index, mi)
    me = bpy.data.meshes.new("_knight_tmp")
    tmp.to_mesh(me)
    tmp.free()
    bm.from_mesh(me)
    bpy.data.meshes.remove(me)

def visor_faces(c, r):
    """T-shaped visor on the front (-Y) of the helm: eye band + vertical slit."""
    az = math.degrees(math.atan2(c.x, -c.y))          # 0 = straight ahead
    if 0.0 < c.z < 0.383 * r and abs(az) <= 50.0:     # eye slit ring
        return VISOR
    if -0.383 * r < c.z <= 0.0 and abs(az) <= 20.0:   # vertical slit below it
        return VISOR
    return None

def cylinder(bm, center, radius, height, mi, segments=8, r_top=None):
    tmp = bmesh.new()
    bmesh.ops.create_cone(tmp, cap_ends=True, segments=segments,
                          radius1=radius, radius2=radius if r_top is None else r_top, depth=height)
    _xform(tmp, (1, 1, 1), center)
    _merge(bm, tmp, mi)

def mirror_x(fn):
    """Call fn(sign) for both sides."""
    fn(-1.0); fn(1.0)

# ---------- knight body ----------
def build_body():
    bm = bmesh.new()
    rotY = lambda deg: Matrix.Rotation(math.radians(deg), 3, 'Y')
    rotX = lambda deg: Matrix.Rotation(math.radians(deg), 3, 'X')

    # legs & boots (character faces -Y)
    def leg(s):
        x = 0.13 * s
        box(bm, (x, -0.04, 0.09), (0.17, 0.34, 0.18), DARK)                 # boot
        box(bm, (x, -0.14, 0.15), (0.13, 0.10, 0.06), DARK)                 # toe cap
        box(bm, (x, 0.0, 0.38), (0.15, 0.16, 0.38), ARMOR, taper=(1.15, 1.1))  # greave
        box(bm, (x, -0.01, 0.60), (0.18, 0.19, 0.10), DARK)                 # knee
        box(bm, (x, 0.0, 0.80), (0.18, 0.19, 0.32), ARMOR, taper=(1.05, 1.05))  # cuisse
    mirror_x(leg)

    # pelvis, belt, torso
    box(bm, (0, 0, 0.98), (0.42, 0.28, 0.16), DARK)
    box(bm, (0, 0, 1.08), (0.46, 0.31, 0.06), RED)                           # belt
    box(bm, (0, -0.16, 1.08), (0.10, 0.02, 0.07), LIGHT)                      # buckle
    box(bm, (0, 0, 1.31), (0.46, 0.29, 0.40), ARMOR, taper=(1.25, 1.12))      # breastplate
    box(bm, (0, -0.02, 1.53), (0.50, 0.26, 0.06), ARMOR)                      # collar plate
    # red chest straps (X on the front)
    box(bm, (0, -0.155, 1.36), (0.035, 0.02, 0.36), RED, rot=rotY(32))
    box(bm, (0, -0.155, 1.36), (0.035, 0.02, 0.36), RED, rot=rotY(-32))
    box(bm, (0, -0.165, 1.36), (0.06, 0.02, 0.06), LIGHT)                     # centre clasp

    # neck & helmet
    cylinder(bm, (0, 0, 1.56), 0.09, 0.10, DARK)                              # neck (mostly hidden)
    sphere(bm, (0, 0, 1.765), 0.20, LIGHT, scale=(1.0, 1.06, 1.15), u=12, v=8,
           face_mat=visor_faces)                                              # closed helm with T-visor
    box(bm, (0, 0.0, 1.965), (0.03, 0.28, 0.05), ARMOR)                       # top ridge / seam
    cylinder(bm, (0, 0, 1.545), 0.20, 0.04, ARMOR, segments=12)               # helm base ring on the collar

    # arms
    def arm(s):
        x = 0.335 * s
        sphere(bm, (x, 0.0, 1.50), 0.135, LIGHT, scale=(1.0, 0.95, 0.85))    # pauldron
        box(bm, (x, 0.0, 1.47), (0.24, 0.22, 0.05), RED)                       # red pauldron trim
        box(bm, (x, 0.0, 1.30), (0.14, 0.14, 0.30), ARMOR, taper=(1.1, 1.1))  # upper arm
        box(bm, (x, 0.0, 1.135), (0.16, 0.16, 0.08), DARK)                     # elbow
        box(bm, (x, 0.0, 1.00), (0.135, 0.135, 0.22), ARMOR)                   # forearm
        box(bm, (x, 0.0, 0.905), (0.16, 0.16, 0.02), RED)                      # red cuff
        box(bm, (x, -0.01, 0.83), (0.15, 0.16, 0.14), DARK)                    # gauntlet
    mirror_x(arm)

    # sword in the right hand (character's right = -X), resting point-down
    sx = -0.335
    box(bm, (sx, -0.08, 0.86), (0.045, 0.045, 0.16), DARK)                     # grip
    box(bm, (sx, -0.08, 0.955), (0.07, 0.07, 0.04), LIGHT)                     # pommel
    box(bm, (sx, -0.08, 0.77), (0.24, 0.05, 0.035), LIGHT)                     # crossguard
    box(bm, (sx, -0.08, 0.43), (0.065, 0.016, 0.66), STEEL)                    # blade
    box(bm, (sx, -0.08, 0.075), (0.065, 0.016, 0.06), STEEL, taper=(0.15, 1.0), rot=rotX(180))  # tip

    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    me = bpy.data.meshes.new("Knight_LowPoly")
    bm.to_mesh(me); bm.free()
    for p in me.polygons:
        p.use_smooth = False
    for m in MATS:
        me.materials.append(m)
    return bpy.data.objects.new("Knight_LowPoly", me)

# ---------- cape ----------
def build_cape():
    bm = bmesh.new()
    rows, cols = 8, 5
    grid = []
    for i in range(rows):
        t = i / (rows - 1)                      # 0 = shoulders, 1 = hem
        z = 1.53 - t * 1.20                     # 1.53 -> 0.33
        half_w = 0.25 + 0.25 * t ** 0.8          # flares to ~0.5
        y_back = 0.17 + 0.18 * t + 0.04 * math.sin(t * math.pi)
        row = []
        for j in range(cols):
            s = j / (cols - 1) * 2 - 1           # -1 .. 1 across
            y = y_back - 0.09 * abs(s) ** 1.5    # sides wrap toward the body
            zz = z - (0.05 * (1 - abs(s)) if i == rows - 1 else 0.0)  # centre of hem hangs lowest
            row.append(bm.verts.new((half_w * s, y, zz)))
        grid.append(row)
    for i in range(rows - 1):
        for j in range(cols - 1):
            bm.faces.new((grid[i][j], grid[i][j + 1], grid[i + 1][j + 1], grid[i + 1][j]))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    for f in bm.faces:
        f.material_index = 0
    me = bpy.data.meshes.new("Knight_Cape")
    bm.to_mesh(me); bm.free()
    for p in me.polygons:
        p.use_smooth = False
    me.materials.append(MATS[CAPE])
    ob = bpy.data.objects.new("Knight_Cape", me)
    sol = ob.modifiers.new("Solidify", 'SOLIDIFY')
    sol.thickness = 0.02
    sol.offset = 0.0
    return ob

# ---------- scene assembly ----------
def get_or_make_collection(name, parent):
    coll = bpy.data.collections.get(name)
    if coll is None:
        coll = bpy.data.collections.new(name)
    if coll.name not in parent.children:
        parent.children.link(coll)
    return coll

def clear_collection(coll):
    for ob in list(coll.objects):
        me = ob.data
        bpy.data.objects.remove(ob, do_unlink=True)
        if me is not None and me.users == 0:
            if isinstance(me, bpy.types.Mesh):
                bpy.data.meshes.remove(me)
            elif isinstance(me, bpy.types.Camera):
                bpy.data.cameras.remove(me)
            elif isinstance(me, bpy.types.Light):
                bpy.data.lights.remove(me)

user_scene = bpy.context.scene
knight_coll = get_or_make_collection("Knight", user_scene.collection)
clear_collection(knight_coll)

body = build_body()
cape = build_cape()
knight_coll.objects.link(body)
knight_coll.objects.link(cape)
cape.parent = body

# ---------- preview scene (separate, so the user's scene stays untouched) ----------
def look_at(ob, target):
    d = Vector(target) - ob.location
    ob.rotation_euler = d.to_track_quat('-Z', 'Y').to_euler()

prev = bpy.data.scenes.get("Knight_Preview")
if prev is None:
    prev = bpy.data.scenes.new("Knight_Preview")
if knight_coll.name not in prev.collection.children:
    prev.collection.children.link(knight_coll)
rig_coll = get_or_make_collection("Knight_PreviewRig", prev.collection)
clear_collection(rig_coll)

def add_cam(name, loc, target):
    cd = bpy.data.cameras.new(name); cd.lens = 55
    cam = bpy.data.objects.new(name, cd)
    rig_coll.objects.link(cam)
    cam.location = loc
    look_at(cam, target)
    return cam

cam_front = add_cam("Knight_Cam_Front34", (2.3, -3.1, 1.5), (0.0, 0.0, 0.98))
cam_back = add_cam("Knight_Cam_Back34", (-2.3, 3.1, 1.5), (0.0, 0.0, 0.98))

key_d = bpy.data.lights.new("Knight_Key", 'SUN'); key_d.energy = 3.0; key_d.angle = math.radians(8)
key = bpy.data.objects.new("Knight_Key", key_d); rig_coll.objects.link(key)
key.location = (3, -2, 5); look_at(key, (0, 0, 1))
fill_d = bpy.data.lights.new("Knight_Fill", 'AREA'); fill_d.energy = 250; fill_d.size = 4
fill = bpy.data.objects.new("Knight_Fill", fill_d); rig_coll.objects.link(fill)
fill.location = (-3.5, -1.5, 2.5); look_at(fill, (0, 0, 1))
rim_d = bpy.data.lights.new("Knight_Rim", 'AREA'); rim_d.energy = 200; rim_d.size = 3
rim = bpy.data.objects.new("Knight_Rim", rim_d); rig_coll.objects.link(rim)
rim.location = (0.5, 3.5, 3.0); look_at(rim, (0, 0, 1))

ground_me = bpy.data.meshes.new("Knight_Ground")
gb = bmesh.new(); bmesh.ops.create_grid(gb, x_segments=1, y_segments=1, size=6); gb.to_mesh(ground_me); gb.free()
ground = bpy.data.objects.new("Knight_Ground", ground_me); rig_coll.objects.link(ground)
ground_me.materials.append(make_mat("Knight_GroundMat", "#6B7A6B", roughness=1.0))

world = bpy.data.worlds.get("Knight_PreviewWorld")
if world is None:
    world = bpy.data.worlds.new("Knight_PreviewWorld")
world.use_nodes = True
bg = world.node_tree.nodes.get("Background")
bg.inputs["Color"].default_value = (0.35, 0.38, 0.35, 1.0)
bg.inputs["Strength"].default_value = 0.8
prev.world = world

engines = {e.identifier for e in bpy.types.RenderSettings.bl_rna.properties['engine'].enum_items}
prev.render.engine = 'BLENDER_EEVEE_NEXT' if 'BLENDER_EEVEE_NEXT' in engines else 'BLENDER_EEVEE'
prev.eevee.taa_render_samples = 32
prev.render.resolution_x = 900
prev.render.resolution_y = 1100
prev.render.resolution_percentage = 100
prev.render.image_settings.file_format = 'PNG'
prev.view_settings.view_transform = 'Standard'

outputs = []
for cam, fname in ((cam_front, "knight_preview_front.png"), (cam_back, "knight_preview_back.png")):
    prev.camera = cam
    prev.render.filepath = OUT_DIR + "\\" + fname
    bpy.ops.render.render(write_still=True, scene=prev.name)
    outputs.append(prev.render.filepath)

# keep the user's scene active
bpy.context.window.scene = user_scene

# save a copy next to the open file (the open file itself is left as it was)
bpy.ops.wm.save_as_mainfile(filepath=SAVE_COPY, copy=True)

def tri_count(ob):
    return sum(len(p.vertices) - 2 for p in ob.data.polygons)

print("BUILT")
print("body tris:", tri_count(body), "verts:", len(body.data.vertices))
print("cape tris (before solidify):", tri_count(cape))
print("dims:", tuple(round(v, 3) for v in body.dimensions))
print("renders:", outputs)
print("saved copy:", SAVE_COPY)
