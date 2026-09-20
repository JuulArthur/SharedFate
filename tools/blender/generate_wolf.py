# Shared Fate 3D port, WP1: the low-poly wolf enemy.
#
# Command line:
#     blender --background --python tools/blender/generate_wolf.py -- --root <repo>
#
# Blender MCP (`execute_blender_code` cannot import a sibling module, so set the
# paths in the namespace first and send the file text):
#     SF_DIR  = r"D:\workspace\SharedFate\tools\blender"
#     SF_ROOT = r"D:\workspace\SharedFate"
#     exec(open(SF_DIR + r"\generate_wolf.py", encoding="utf-8").read())
# The generator exec()s sf_assets_common.py out of SF_DIR itself.
#
# About 1.1 m nose to tail and 0.7 m at the ears, origin at the paws on z = 0,
# facing Blender +Y (Godot -Z after `export_yup=True`).

import bpy
import bmesh
import math
import os
import sys
from mathutils import Vector, Matrix


def _sf_paths():
    d = globals().get("SF_DIR")
    if not d:
        try:
            d = os.path.dirname(os.path.abspath(__file__))
        except NameError:
            raise RuntimeError("set SF_DIR to the absolute path of tools/blender")
    r = globals().get("SF_ROOT")
    if not r:
        argv = sys.argv
        if "--root" in argv:
            r = argv[argv.index("--root") + 1]
        else:
            r = os.path.abspath(os.path.join(d, os.pardir, os.pardir))
    return d, r


SF_DIR, SF_ROOT = _sf_paths()
exec(open(os.path.join(SF_DIR, "sf_assets_common.py"), encoding="utf-8").read())

MODEL_DIR = os.path.join(SF_ROOT, "assets", "3d", "models")
PREVIEW_DIR = os.path.join(SF_ROOT, "assets", "3d", "previews")

W_FUR, W_DARK, W_BELLY, W_EYE, W_TEETH, W_NOSE = range(6)


def wolf_materials():
    return [
        make_material("Wolf_Fur", "#6B6258", roughness=0.85),
        make_material("Wolf_FurDark", "#47413A", roughness=0.85),
        make_material("Wolf_Belly", "#928779", roughness=0.85),
        make_material("Wolf_Eye", "#C8501E", roughness=0.35,
                      emission="#C8501E", emission_strength=0.6),
        make_material("Wolf_Teeth", "#E5E0D6", roughness=0.45),
        make_material("Wolf_Nose", "#2A2622", roughness=0.40),
    ]


def build_wolf_body():
    bm = bmesh.new()

    # torso, front to back along +Y
    box(bm, (0, 0.02, 0.46), (0.28, 0.50, 0.28), W_FUR, taper=(0.95, 1.0))
    box(bm, (0, 0.26, 0.45), (0.28, 0.20, 0.28), W_FUR)            # chest
    box(bm, (0, -0.20, 0.42), (0.28, 0.20, 0.28), W_FUR)           # haunches
    box(bm, (0, 0.02, 0.335), (0.24, 0.48, 0.05), W_BELLY)         # belly

    # neck and head
    box(bm, (0, 0.38, 0.50), (0.20, 0.16, 0.20), W_FUR)
    box(bm, (0, 0.525, 0.545), (0.21, 0.19, 0.18), W_FUR)
    box(bm, (0, 0.655, 0.495), (0.12, 0.14, 0.10), W_DARK)         # muzzle
    box(bm, (0, 0.733, 0.515), (0.065, 0.025, 0.045), W_NOSE)
    box(bm, (0, 0.63, 0.445), (0.10, 0.12, 0.03), W_TEETH)         # lower jaw

    def ear(s):
        box(bm, (0.075 * s, 0.48, 0.675), (0.07, 0.03, 0.10), W_DARK,
            taper=(0.25, 0.4))
    mirror_x(ear)

    def eye(s):
        box(bm, (0.072 * s, 0.615, 0.575), (0.035, 0.02, 0.028), W_EYE)
    mirror_x(eye)

    # legs
    def leg(x, y):
        box(bm, (x, y, 0.27), (0.10, 0.13, 0.22), W_FUR)
        box(bm, (x, y - 0.01, 0.10), (0.075, 0.09, 0.18), W_DARK)
        box(bm, (x, y + 0.01, 0.0275), (0.095, 0.13, 0.055), W_DARK)

    for s in (-1.0, 1.0):
        leg(0.105 * s, 0.22)
        leg(0.105 * s, -0.20)

    # tail, sweeping up and back
    box(bm, (0, -0.30, 0.53), (0.085, 0.20, 0.085), W_FUR, rot=rot_x(-28))

    return finish_object(bm, "Wolf_Body", wolf_materials())


def main():
    scene = assets_scene()
    prev = activate_scene(scene)
    try:
        coll = model_collection("SF_Wolf")
        body = build_wolf_body()
        link(coll, body)
        update_depsgraph()

        top = world_bounds([body])[1].z
        overhead = add_empty("OverheadAnchor", (0.0, 0.0, top + 0.20),
                             parent=body, collection=coll)
        update_depsgraph()

        objects = [body, overhead]
        report("wolf", objects)
        export_glb(objects, os.path.join(MODEL_DIR, "wolf.glb"), root_name="Wolf")
        render_preview(objects, os.path.join(PREVIEW_DIR, "wolf.png"),
                       elev_deg=12.0)
        overhead.name = "Wolf_OverheadAnchor"
    finally:
        restore_scene(prev)
    print("SF_WOLF DONE")


main()
