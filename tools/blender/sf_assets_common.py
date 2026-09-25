# Shared helpers for the Shared Fate 3D asset generators (WP1).
#
# This file is a plain Python script, not an importable module: the Blender MCP
# add-on runs code through `exec()` in a bare namespace, so `import
# sf_assets_common` would fail there. Every generator therefore loads it with
#
#     exec(open(os.path.join(SF_DIR, "sf_assets_common.py"), encoding="utf-8").read())
#
# where `SF_DIR` is the absolute path of this directory. From the command line
# the generators derive `SF_DIR` from `__file__`; when the text is sent through
# `execute_blender_code`, set `SF_DIR` (and optionally `SF_ROOT`, the repository
# root) in the namespace before exec-ing the generator text:
#
#     SF_DIR  = r"D:\workspace\SharedFate\tools\blender"
#     SF_ROOT = r"D:\workspace\SharedFate"
#     exec(open(SF_DIR + r"\generate_characters.py", encoding="utf-8").read())
#
# Conventions (docs/3d-port-contracts.md sections 2 and 10):
#   * 1 Blender unit = 1 m, +Z up, the model stands on z = 0.
#   * A character faces Blender +Y. `export_yup=True` maps Blender +Y to glTF
#     -Z, which is Godot's forward, and Blender +Z to glTF +Y.
#   * The character's right hand is at +X in Blender and stays +X in Godot.
#   * Flat shading everywhere, one material per colour, materials named
#     `<Model>_<Part>`.
#
# Nothing here touches the user's scenes: all work happens in a scene named
# `SharedFate_Assets` that the helpers create on demand.

import bpy
import bmesh
import math
import os
from mathutils import Vector, Matrix, Euler

SF_ASSET_SCENE = "SharedFate_Assets"
SF_RIG_COLLECTION = "SF_PreviewRig"

# Rigid skinning (WP11): while a body bmesh is being built, every primitive
# records the bone that owns its vertices. `skin_begin(bm)` starts recording for
# one bmesh, `skin_bone(name)` sets the owner of the parts that follow, and
# `finish_object` turns the record into one vertex group per bone (weight 1.0).
_SF_SKIN = {"bm": None, "bone": None, "bones": []}


# --------------------------------------------------------------------------
# colour and materials
# --------------------------------------------------------------------------

def srgb_to_linear(hexstr):
    """'#RRGGBB' (sRGB, as sampled from the 2D sprites) -> linear RGBA tuple."""
    h = hexstr.lstrip("#")
    r, g, b = (int(h[i:i + 2], 16) / 255.0 for i in (0, 2, 4))

    def f(c):
        return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4

    return (f(r), f(g), f(b), 1.0)


def _principled(mat):
    """The Principled BSDF of `mat`, looked up by node type (names are localised)."""
    nt = mat.node_tree
    for n in nt.nodes:
        if n.type == "BSDF_PRINCIPLED":
            return n
    node = nt.nodes.new("ShaderNodeBsdfPrincipled")
    out = None
    for n in nt.nodes:
        if n.type == "OUTPUT_MATERIAL":
            out = n
            break
    if out is None:
        out = nt.nodes.new("ShaderNodeOutputMaterial")
    nt.links.new(node.outputs[0], out.inputs[0])
    return node


def _socket(node, identifier):
    for s in node.inputs:
        if s.identifier == identifier:
            return s
    for s in node.inputs:
        if s.name == identifier:
            return s
    return None


def make_material(name, hexcol, metallic=0.0, roughness=0.5, emission=None,
                  emission_strength=1.0):
    """Create or update a flat-coloured Principled material called `name`."""
    mat = bpy.data.materials.get(name)
    if mat is None:
        mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    bsdf = _principled(mat)
    rgba = srgb_to_linear(hexcol)
    for ident, value in (("Base Color", rgba), ("Metallic", metallic),
                         ("Roughness", roughness)):
        sock = _socket(bsdf, ident)
        if sock is not None:
            sock.default_value = value
    if emission is not None:
        sock = _socket(bsdf, "Emission Color")
        if sock is not None:
            sock.default_value = srgb_to_linear(emission)
        sock = _socket(bsdf, "Emission Strength")
        if sock is not None:
            sock.default_value = emission_strength
    mat.diffuse_color = rgba  # solid-mode viewport colour only
    return mat


# --------------------------------------------------------------------------
# bmesh primitives
# --------------------------------------------------------------------------

def skin_begin(bm):
    """Record the owning bone of every vertex added to `bm` from now on."""
    _SF_SKIN["bm"] = bm
    _SF_SKIN["bone"] = None
    _SF_SKIN["bones"] = []


def skin_bone(name):
    """Bone that owns the parts added next (rigid skinning, weight 1.0)."""
    _SF_SKIN["bone"] = name


def side_bone(base, sign):
    """`UpperArm` + side: +X is the character's right (`_R`), -X its left."""
    return base + ("_R" if sign > 0 else "_L")


def _skin_record(bm, verts_before):
    if _SF_SKIN["bm"] is not bm:
        return
    added = len(bm.verts) - verts_before
    _SF_SKIN["bones"].extend([_SF_SKIN["bone"]] * added)


def _from_mesh_recorded(bm, me):
    before = len(bm.verts)
    bm.from_mesh(me)
    _skin_record(bm, before)


def _merge(bm, tmp, mi):
    for f in tmp.faces:
        f.material_index = mi
    me = bpy.data.meshes.new("_sf_tmp")
    tmp.to_mesh(me)
    tmp.free()
    _from_mesh_recorded(bm, me)
    bpy.data.meshes.remove(me)


def _xform(tmp, scale, center, rot=None, taper=(1.0, 1.0)):
    for v in tmp.verts:
        v.co.x *= scale[0]
        v.co.y *= scale[1]
        v.co.z *= scale[2]
        if v.co.z > 0:
            v.co.x *= taper[0]
            v.co.y *= taper[1]
        if rot is not None:
            v.co = rot @ v.co
        v.co += Vector(center)


def box(bm, center, size, mi, taper=(1.0, 1.0), rot=None):
    """Axis-aligned box of `size` centred on `center`; `taper` scales the top half."""
    tmp = bmesh.new()
    bmesh.ops.create_cube(tmp, size=1.0)
    _xform(tmp, size, center, rot, taper)
    _merge(bm, tmp, mi)


def sphere(bm, center, radius, mi, scale=(1.0, 1.0, 1.0), u=8, v=6, face_mat=None,
           rot=None):
    """UV sphere. `face_mat(center_local, radius) -> material index or None`
    is evaluated on the unscaled sphere, so painted bands stay symmetric."""
    tmp = bmesh.new()
    bmesh.ops.create_uvsphere(tmp, u_segments=u, v_segments=v, radius=radius)
    overrides = {}
    if face_mat is not None:
        for f in tmp.faces:
            m = face_mat(f.calc_center_median(), radius)
            if m is not None:
                overrides[f.index] = m
    _xform(tmp, scale, center, rot)
    for f in tmp.faces:
        f.material_index = overrides.get(f.index, mi)
    me = bpy.data.meshes.new("_sf_tmp")
    tmp.to_mesh(me)
    tmp.free()
    _from_mesh_recorded(bm, me)
    bpy.data.meshes.remove(me)


def cylinder(bm, center, radius, height, mi, segments=8, r_top=None, rot=None,
             cap_ends=True):
    tmp = bmesh.new()
    bmesh.ops.create_cone(tmp, cap_ends=cap_ends, segments=segments,
                          radius1=radius,
                          radius2=radius if r_top is None else r_top,
                          depth=height)
    _xform(tmp, (1, 1, 1), center, rot)
    _merge(bm, tmp, mi)


def cone(bm, center, radius, height, mi, segments=8, rot=None):
    cylinder(bm, center, radius, height, mi, segments=segments, r_top=0.0, rot=rot)


def grid_plane(bm, center, size_x, size_y, mi):
    tmp = bmesh.new()
    bmesh.ops.create_grid(tmp, x_segments=1, y_segments=1, size=0.5)
    _xform(tmp, (size_x, size_y, 1.0), center)
    _merge(bm, tmp, mi)


def bevel_edges(bm, offset, segments=1):
    """Bevel every edge of `bm` (used for the slight bevel on the ground tile)."""
    bmesh.ops.bevel(bm, geom=list(bm.verts) + list(bm.edges), offset=offset,
                    segments=segments, affect="EDGES", clamp_overlap=True)


def mirror_x(fn):
    """Call fn(sign) for the left and the right side."""
    fn(-1.0)
    fn(1.0)


def rot_x(deg):
    return Matrix.Rotation(math.radians(deg), 3, "X")


def rot_y(deg):
    return Matrix.Rotation(math.radians(deg), 3, "Y")


def rot_z(deg):
    return Matrix.Rotation(math.radians(deg), 3, "Z")


# --------------------------------------------------------------------------
# objects, collections, scene
# --------------------------------------------------------------------------

def purge_object(name):
    """Remove an object (and its orphaned data) so a rebuild keeps the exact name."""
    ob = bpy.data.objects.get(name)
    if ob is not None:
        data = ob.data
        bpy.data.objects.remove(ob, do_unlink=True)
        _purge_data(data)
    me = bpy.data.meshes.get(name)
    if me is not None and me.users == 0:
        bpy.data.meshes.remove(me)


def _purge_data(data):
    if data is None or data.users:
        return
    if isinstance(data, bpy.types.Mesh):
        bpy.data.meshes.remove(data)
    elif isinstance(data, bpy.types.Camera):
        bpy.data.cameras.remove(data)
    elif isinstance(data, bpy.types.Light):
        bpy.data.lights.remove(data)
    elif isinstance(data, bpy.types.Armature):
        bpy.data.armatures.remove(data)


def finish_object(bm, name, materials, smooth=False):
    """Close a bmesh into a flat-shaded object with the given material slots.

    When `skin_begin(bm)` recorded the parts' bones, every vertex lands in
    exactly one vertex group named after its bone, with weight 1.0."""
    skinned = _SF_SKIN["bm"] is bm
    bones = list(_SF_SKIN["bones"]) if skinned else []
    if skinned:
        _SF_SKIN["bm"] = None
        _SF_SKIN["bones"] = []
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    purge_object(name)
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    for p in me.polygons:
        p.use_smooth = smooth
    for m in materials:
        me.materials.append(m)
    ob = bpy.data.objects.new(name, me)
    if skinned:
        if len(bones) != len(me.vertices):
            raise RuntimeError("%s: %d skin records for %d vertices"
                               % (name, len(bones), len(me.vertices)))
        if None in bones:
            raise RuntimeError("%s: %d vertices were added before skin_bone()"
                               % (name, bones.count(None)))
        groups = {}
        for index, bone in enumerate(bones):
            groups.setdefault(bone, []).append(index)
        for bone, indices in groups.items():
            ob.vertex_groups.new(name=bone).add(indices, 1.0, "REPLACE")
    return ob


def get_or_make_collection(name, parent):
    coll = bpy.data.collections.get(name)
    if coll is None:
        coll = bpy.data.collections.new(name)
    if coll.name not in parent.children:
        parent.children.link(coll)
    return coll


def clear_collection(coll):
    for ob in list(coll.objects):
        data = ob.data
        bpy.data.objects.remove(ob, do_unlink=True)
        _purge_data(data)


def assets_scene():
    """The scene the generators work in; created on demand, never the user's."""
    scene = bpy.data.scenes.get(SF_ASSET_SCENE)
    if scene is None:
        scene = bpy.data.scenes.new(SF_ASSET_SCENE)
    return scene


def activate_scene(scene):
    """Make `scene` current and return the previous one (None when headless)."""
    win = getattr(bpy.context, "window", None)
    if win is None:
        return None
    prev = win.scene
    win.scene = scene
    return prev


def restore_scene(prev):
    win = getattr(bpy.context, "window", None)
    if win is not None and prev is not None:
        win.scene = prev


def model_collection(name):
    """A cleared collection named `name` inside the assets scene."""
    coll = get_or_make_collection(name, assets_scene().collection)
    clear_collection(coll)
    return coll


def link(coll, *objects):
    for ob in objects:
        if ob.name not in coll.objects:
            coll.objects.link(ob)
    return objects


def add_empty(name, location, parent=None, collection=None, size=0.08):
    purge_object(name)
    emp = bpy.data.objects.new(name, None)
    emp.empty_display_type = "PLAIN_AXES"
    emp.empty_display_size = size
    if collection is not None:
        collection.objects.link(emp)
    emp.location = location
    if parent is not None:
        emp.parent = parent
        emp.matrix_parent_inverse = parent.matrix_world.inverted()
    return emp


def enter_assets_scene():
    """Make the assets scene current and return the scene to restore afterwards.

    Everything that needs an evaluated depsgraph (modifier application on
    export, `matrix_world`) must run with this scene actually active:
    `bpy.context.temp_override(scene=...)` leaves the context view layer
    pointing at the old scene and crashes the glTF exporter in
    `CTX_data_ensure_evaluated_depsgraph`.
    """
    scene = assets_scene()
    if bpy.context.scene is scene:
        return None
    prev = activate_scene(scene)
    if bpy.context.scene is not scene:
        raise RuntimeError("could not activate the %r scene (context scene is %r)"
                           % (SF_ASSET_SCENE, bpy.context.scene.name))
    return prev


def update_depsgraph():
    """Flush parenting and transform changes so `matrix_world` is current."""
    prev = enter_assets_scene()
    bpy.context.view_layer.update()
    restore_scene(prev)


def tri_count(ob):
    if ob is None or ob.type != "MESH":
        return 0
    return sum(len(p.vertices) - 2 for p in ob.data.polygons)


def world_bounds(objects):
    """(min, max) world-space corners over the mesh objects in `objects`."""
    lo = Vector((1e9, 1e9, 1e9))
    hi = Vector((-1e9, -1e9, -1e9))
    for ob in objects:
        if ob.type != "MESH":
            continue
        for corner in ob.bound_box:
            p = ob.matrix_world @ Vector(corner)
            for i in range(3):
                lo[i] = min(lo[i], p[i])
                hi[i] = max(hi[i], p[i])
    return lo, hi


def look_at(ob, target):
    d = Vector(target) - ob.location
    ob.rotation_euler = d.to_track_quat("-Z", "Y").to_euler()


# --------------------------------------------------------------------------
# armature, rigid skinning and actions (WP11)
# --------------------------------------------------------------------------
#
# Every bone is rolled so its local X axis is the armature's +X (the
# character's right). A pose rotation about local X is then a pitch in the
# forward/up plane for every bone, up- or down-pointing alike: a positive angle
# swings a hanging limb forward (+Y) and tips an upright bone backward. Local Y
# runs along the bone (world up for Hips/Spine/Head, world down for the limbs),
# so a rotation about local Y is a twist about the vertical, and for a hanging
# bone local Z is world +Y, so a rotation about local Z is a sideways roll.

def build_armature(name, bones, collection):
    """Armature object `name` at the origin with `bones`, a list of
    (bone, head, tail, parent or None, connected) tuples in Blender space."""
    purge_object(name)
    arm = bpy.data.armatures.get(name)
    if arm is not None and arm.users == 0:
        bpy.data.armatures.remove(arm)
    arm = bpy.data.armatures.new(name)
    ob = bpy.data.objects.new(name, arm)
    collection.objects.link(ob)
    prev = enter_assets_scene()
    view_layer = bpy.context.view_layer
    for other in view_layer.objects:
        other.select_set(False)
    view_layer.objects.active = ob
    ob.select_set(True)
    bpy.ops.object.mode_set(mode="EDIT")
    try:
        x_axis = Vector((1.0, 0.0, 0.0))
        for bone, head, tail, parent, connected in bones:
            eb = arm.edit_bones.new(bone)
            eb.head = Vector(head)
            eb.tail = Vector(tail)
            eb.align_roll(x_axis.cross((eb.tail - eb.head).normalized()))
            if parent is not None:
                eb.parent = arm.edit_bones[parent]
                eb.use_connect = connected
    finally:
        bpy.ops.object.mode_set(mode="OBJECT")
    ob.select_set(False)
    restore_scene(prev)
    for bone in arm.bones:
        x = bone.matrix_local.col[0].xyz
        if (x - x_axis).length > 1e-4:
            raise RuntimeError("%s: bone %s has local X %s, expected +X" % (name, bone.name, tuple(x)))
    return ob


def skin_to_armature(ob, armature):
    """Parent a mesh to the armature (object parent, rest transform kept) and
    deform it with an Armature modifier through its vertex groups."""
    ob.parent = armature
    ob.matrix_parent_inverse = armature.matrix_world.inverted()
    mod = ob.modifiers.new("Armature", "ARMATURE")
    mod.object = armature
    mod.use_vertex_groups = True
    return mod


def skin_whole(ob, bone):
    """Assign every vertex of `ob` to `bone` with weight 1.0."""
    group = ob.vertex_groups.get(bone) or ob.vertex_groups.new(name=bone)
    group.add([v.index for v in ob.data.vertices], 1.0, "REPLACE")


def parent_to_bone(ob, armature, bone_name, world=None):
    """Bone-parent `ob` (an empty or a rigid mesh) to `bone_name`, keeping its
    world transform at rest. `world` defaults to the object's own transform
    (its parent must be the armature's space, i.e. the origin, or none)."""
    if world is None:
        world = ob.matrix_basis.copy()
    bone = armature.data.bones[bone_name]
    # Blender's bone parent space is the bone's tail, in the bone's rest frame.
    parent_mat = (armature.matrix_world @ bone.matrix_local
                  @ Matrix.Translation((0.0, bone.length, 0.0)))
    ob.parent = armature
    ob.parent_type = "BONE"
    ob.parent_bone = bone_name
    ob.matrix_parent_inverse = Matrix.Identity(4)
    ob.matrix_basis = parent_mat.inverted() @ world
    return ob


def reset_pose(armature):
    for pb in armature.pose.bones:
        pb.rotation_mode = "QUATERNION"
        pb.rotation_quaternion = (1.0, 0.0, 0.0, 0.0)
        pb.location = (0.0, 0.0, 0.0)
        pb.scale = (1.0, 1.0, 1.0)


def author_action(armature, name, frames, sample, step=2):
    """A plain action `name`, `frames` long, keyed every `step` frames from
    frame 0 to `frames` inclusive with linear interpolation.

    `sample(phase)` gets the loop phase in [0, 1) and returns
    {bone: {"rot": (x, y, z) degrees in the bone's local axes,
            "loc": (x, y, z) metres in the bone's local axes}}.
    Every pose bone is keyed on every sample (missing bones at rest), and the
    last key repeats phase 0 so the clip loops seamlessly."""
    if armature.animation_data is None:
        armature.animation_data_create()
    old = bpy.data.actions.get(name)
    if old is not None:
        bpy.data.actions.remove(old)
    act = bpy.data.actions.new(name)
    act.use_fake_user = True
    armature.animation_data.action = act
    for pb in armature.pose.bones:
        pb.rotation_mode = "QUATERNION"
    for frame in range(0, frames + 1, step):
        phase = (frame % frames) / float(frames)
        pose = sample(phase)
        unknown = set(pose) - set(pb.name for pb in armature.pose.bones)
        if unknown:
            raise RuntimeError("%s: no bones %s" % (name, sorted(unknown)))
        for pb in armature.pose.bones:
            values = pose.get(pb.name, {})
            rot = values.get("rot", (0.0, 0.0, 0.0))
            pb.rotation_quaternion = Euler(tuple(math.radians(a) for a in rot), "XYZ").to_quaternion()
            pb.location = values.get("loc", (0.0, 0.0, 0.0))
            pb.keyframe_insert("rotation_quaternion", frame=frame, group=pb.name)
            pb.keyframe_insert("location", frame=frame, group=pb.name)
    for fc in act.fcurves:
        for kp in fc.keyframe_points:
            kp.interpolation = "LINEAR"
    armature.animation_data.action = None
    reset_pose(armature)
    return act


# --------------------------------------------------------------------------
# export
# --------------------------------------------------------------------------

def export_glb(objects, path, root_name=None, animations=False):
    """Export exactly `objects` (meshes and empties) to a .glb at `path`.

    The glTF scene name becomes the root node name of the imported Godot scene,
    and the exporter takes it from the Blender scene, so the assets scene is
    renamed to `root_name` for the duration of the export.

    `animations=True` (WP11) exports the skin and every armature action as its
    own glTF animation named after the action ("ACTIONS" mode with
    `export_anim_single_armature`, which needs exactly one armature among
    `objects`). The actions themselves must be plain (no NLA), keyed from
    frame 0, and the scene frame rate decides their length in seconds.
    """
    path = os.path.abspath(path)
    folder = os.path.dirname(path)
    if folder and not os.path.isdir(folder):
        os.makedirs(folder)
    prev = enter_assets_scene()
    scene_name = bpy.context.scene.name
    if root_name:
        bpy.context.scene.name = root_name
    view_layer = bpy.context.view_layer
    for ob in view_layer.objects:
        ob.select_set(False)
    for ob in objects:
        ob.select_set(True)
    view_layer.objects.active = objects[0]
    options = dict(
        filepath=path,
        use_selection=True,
        # Only the assets scene: without this the exporter writes every scene
        # with a selection, and the factory startup's selected default Cube
        # rode along in a second glTF scene in every WP1 file (WP11 fix).
        use_active_scene=True,
        export_format="GLB",
        export_yup=True,
        export_apply=True,
        export_cameras=False,
        export_lights=False,
        export_animations=animations,
        export_extras=False,
    )
    if animations:
        options.update(
            export_skins=True,
            export_def_bones=False,
            export_rest_position_armature=True,
            export_animation_mode="ACTIONS",
            export_anim_single_armature=True,
            export_force_sampling=True,
            export_frame_range=False,
            export_anim_slide_to_zero=False,
            export_reset_pose_bones=True,
            export_bake_animation=False,
            export_morph_animation=False,
        )
    known = {p.identifier for p in bpy.ops.export_scene.gltf.get_rna_type().properties}
    missing = sorted(set(options) - known)
    if missing:
        raise RuntimeError("glTF exporter has no options %s" % missing)
    try:
        bpy.ops.export_scene.gltf(**options)
    finally:
        bpy.context.scene.name = scene_name
    restore_scene(prev)
    return path


# --------------------------------------------------------------------------
# preview render
# --------------------------------------------------------------------------

def _preview_rig(scene):
    rig = get_or_make_collection(SF_RIG_COLLECTION, scene.collection)
    clear_collection(rig)
    return rig


def render_preview(objects, path, res=(600, 800), yaw_deg=35.0, elev_deg=16.0,
                   margin=1.18, lens=50.0, samples=48, ground=True):
    """Render a 600x800 front three-quarter preview of `objects` to `path`.

    The camera and lights are temporary: they live in `SF_PreviewRig` inside the
    assets scene and are cleared on the next call. The models face Blender +Y,
    so the camera sits on the +Y side, to their left and above: a front
    three-quarter view.
    """
    path = os.path.abspath(path)
    folder = os.path.dirname(path)
    if folder and not os.path.isdir(folder):
        os.makedirs(folder)

    scene = assets_scene()
    prev = enter_assets_scene()
    rig = _preview_rig(scene)

    lo, hi = world_bounds(objects)
    centre = (lo + hi) * 0.5
    size = hi - lo
    height = max(size.z, 0.2)
    width = max(math.hypot(size.x, size.y), 0.2)

    cam_data = bpy.data.cameras.new("SF_PreviewCam")
    cam_data.lens = lens
    cam_data.sensor_fit = "VERTICAL"
    cam_data.sensor_height = 24.0
    cam = bpy.data.objects.new("SF_PreviewCam", cam_data)
    rig.objects.link(cam)

    half_v = math.atan(cam_data.sensor_height * 0.5 / lens)
    aspect = res[0] / float(res[1])
    half_h = math.atan(math.tan(half_v) * aspect)
    dist = max(height * 0.5 / math.tan(half_v),
               width * 0.5 / math.tan(half_h)) * margin + width * 0.5

    yaw = math.radians(yaw_deg)
    elev = math.radians(elev_deg)
    direction = Vector((math.sin(yaw) * math.cos(elev),
                        math.cos(yaw) * math.cos(elev),
                        math.sin(elev)))
    cam.location = centre + direction * dist
    look_at(cam, centre)
    scene.camera = cam

    key_data = bpy.data.lights.new("SF_PreviewKey", "SUN")
    key_data.energy = 3.2
    key_data.angle = math.radians(10)
    key = bpy.data.objects.new("SF_PreviewKey", key_data)
    rig.objects.link(key)
    key.location = centre + Vector((width * 2.0, width * 2.0,
                                    height * 2.0 + width * 1.2 + 1.5))
    look_at(key, centre)

    fill_data = bpy.data.lights.new("SF_PreviewFill", "AREA")
    fill_data.energy = 120.0 * max(1.0, height)
    fill_data.size = max(3.0, width * 3.0)
    fill = bpy.data.objects.new("SF_PreviewFill", fill_data)
    rig.objects.link(fill)
    fill.location = centre + Vector((-width * 2.5, width * 1.6, height * 0.8))
    look_at(fill, centre)

    rim_data = bpy.data.lights.new("SF_PreviewRim", "AREA")
    rim_data.energy = 110.0 * max(1.0, height)
    rim_data.size = max(2.5, width * 2.0)
    rim = bpy.data.objects.new("SF_PreviewRim", rim_data)
    rig.objects.link(rim)
    rim.location = centre + Vector((width * 0.6, -width * 2.6, height * 1.4))
    look_at(rim, centre)

    if ground:
        gb = bmesh.new()
        grid_plane(gb, (centre.x, centre.y, lo.z - 0.01),
                   max(8.0, width * 6.0), max(8.0, width * 6.0), 0)
        ground_ob = finish_object(gb, "SF_PreviewGround",
                                  [make_material("SF_PreviewGround", "#6B7A6B",
                                                 roughness=1.0)])
        rig.objects.link(ground_ob)

    world = bpy.data.worlds.get("SF_PreviewWorld")
    if world is None:
        world = bpy.data.worlds.new("SF_PreviewWorld")
    world.use_nodes = True
    for n in world.node_tree.nodes:
        if n.type == "BACKGROUND":
            n.inputs[0].default_value = (0.33, 0.36, 0.34, 1.0)
            n.inputs[1].default_value = 0.9
    scene.world = world

    engines = {e.identifier
               for e in bpy.types.RenderSettings.bl_rna.properties["engine"].enum_items}
    for engine in ("BLENDER_EEVEE_NEXT", "BLENDER_EEVEE", "CYCLES"):
        if engine not in engines and engine != scene.render.engine:
            continue
        try:
            scene.render.engine = engine
            break
        except TypeError:
            continue
    eevee = getattr(scene, "eevee", None)
    if eevee is not None and hasattr(eevee, "taa_render_samples"):
        eevee.taa_render_samples = samples
    scene.render.resolution_x = res[0]
    scene.render.resolution_y = res[1]
    scene.render.resolution_percentage = 100
    scene.render.film_transparent = False
    settings = scene.render.image_settings
    fmts = {i.identifier for i in
            settings.bl_rna.properties["file_format"].enum_items}
    if "PNG" in fmts:
        settings.file_format = "PNG"
    modes = {i.identifier for i in settings.bl_rna.properties["color_mode"].enum_items}
    if "RGB" in modes:
        settings.color_mode = "RGB"          # the previews are opaque
    settings.compression = 100
    # Flat-shaded renders are large, flat colour fields; dithering would turn
    # them into noise that PNG cannot compress.
    scene.render.dither_intensity = 0.0
    try:
        scene.view_settings.view_transform = "Standard"
    except TypeError:
        pass
    scene.render.filepath = path

    # Models already built in the assets scene share the origin, so hide
    # everything that is not part of this one or of the preview rig.
    keep = {ob.name for ob in objects} | {ob.name for ob in rig.objects}
    hidden = []
    for ob in scene.objects:
        if ob.name not in keep and not ob.hide_render:
            ob.hide_render = True
            hidden.append(ob)
    try:
        bpy.ops.render.render(write_still=True, scene=scene.name)
    finally:
        for ob in hidden:
            ob.hide_render = False
    clear_collection(rig)
    restore_scene(prev)
    return path


# --------------------------------------------------------------------------
# reporting
# --------------------------------------------------------------------------

def report(label, objects):
    lo, hi = world_bounds(objects)
    size = hi - lo
    tris = sum(tri_count(ob) for ob in objects)
    names = ",".join(ob.name for ob in objects)
    print("SF_MODEL %-12s tris=%-5d size=(%.3f, %.3f, %.3f) base_z=%.3f objects=[%s]"
          % (label, tris, size.x, size.y, size.z, lo.z, names))
    return tris
