# Shared Fate 3D port, WP1: tree, crate, chest and ground tile.
#
# Command line:
#     blender --background --python tools/blender/generate_props.py -- --root <repo>
#
# Blender MCP (`execute_blender_code` cannot import a sibling module, so set the
# paths in the namespace first and send the file text):
#     SF_DIR  = r"D:\workspace\SharedFate\tools\blender"
#     SF_ROOT = r"D:\workspace\SharedFate"
#     exec(open(SF_DIR + r"\generate_props.py", encoding="utf-8").read())
# The generator exec()s sf_assets_common.py out of SF_DIR itself.
#
# Every prop stands on z = 0 with its origin at the base and carries a child
# mesh named `<Object>_Col-colonly`, a box around the solid part. Godot's glTF
# importer turns that suffix into a `StaticBody3D` named `<Object>_Col` holding
# the collision shape, and drops the box mesh. The plain `-col` suffix asked for
# in the work package keeps the box as a second visible MeshInstance3D that also
# shadows the prop's own node name, so `-colonly` is used instead; see
# docs/deviations/wp1.md.

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


def collision_child(owner, name, center, size):
    """A box mesh named `<name>_Col-colonly`, parented to `owner`, in its local
    space. Godot imports it as a StaticBody3D named `<name>_Col`."""
    bm = bmesh.new()
    box(bm, center, size, 0)
    col = finish_object(bm, name + "_Col-colonly", [])
    col.parent = owner
    return col


# --------------------------------------------------------------------------
# tree: trunk plus three stacked canopies, 4.65 m
# --------------------------------------------------------------------------

def build_tree():
    mats = [
        make_material("Tree_Bark", "#5A4630", roughness=0.90),
        make_material("Tree_Leaf", "#3E6B32", roughness=0.85),
        make_material("Tree_LeafDark", "#2E5226", roughness=0.85),
    ]
    bark, leaf, leaf_dark = 0, 1, 2
    bm = bmesh.new()
    cylinder(bm, (0, 0, 0.12), 0.30, 0.24, bark, segments=7, r_top=0.22)   # root flare
    cylinder(bm, (0, 0, 1.15), 0.20, 2.10, bark, segments=7, r_top=0.15)   # trunk
    cone(bm, (0, 0, 2.60), 1.30, 1.50, leaf, segments=9)
    cone(bm, (0, 0, 3.35), 1.00, 1.30, leaf_dark, segments=9)
    cone(bm, (0, 0, 4.05), 0.70, 1.20, leaf, segments=9)
    tree = finish_object(bm, "Tree_Body", mats)
    return tree, collision_child(tree, "Tree", (0, 0, 1.10), (0.46, 0.46, 2.20))


# --------------------------------------------------------------------------
# crate: 0.8 m
# --------------------------------------------------------------------------

def build_crate():
    mats = [
        make_material("Crate_Wood", "#8A6A3C", roughness=0.85),
        make_material("Crate_Trim", "#5A4224", roughness=0.85),
        make_material("Crate_Nail", "#9A9AA2", metallic=0.7, roughness=0.45),
    ]
    wood, trim, nail = 0, 1, 2
    bm = bmesh.new()
    box(bm, (0, 0, 0.40), (0.80, 0.80, 0.80), wood)
    for sx in (-1.0, 1.0):
        for sy in (-1.0, 1.0):
            box(bm, (0.385 * sx, 0.385 * sy, 0.40), (0.07, 0.07, 0.80), trim)
            box(bm, (0.385 * sx, 0.385 * sy, 0.74), (0.085, 0.085, 0.05), nail)
    box(bm, (0, 0, 0.775), (0.84, 0.84, 0.06), trim)                     # top rail
    box(bm, (0, 0, 0.035), (0.84, 0.84, 0.06), trim)                     # bottom rail
    for sy in (-1.0, 1.0):
        box(bm, (0, 0.405 * sy, 0.40), (0.09, 0.02, 0.98), trim, rot=rot_y(42))
    crate = finish_object(bm, "Crate_Body", mats)
    return crate, collision_child(crate, "Crate", (0, 0, 0.40), (0.84, 0.84, 0.80))


# --------------------------------------------------------------------------
# chest: 0.9 m wide, lid closed
# --------------------------------------------------------------------------

def build_chest():
    mats = [
        make_material("Chest_Wood", "#7A5230", roughness=0.85),
        make_material("Chest_WoodDark", "#4E331C", roughness=0.85),
        make_material("Chest_Iron", "#4A4A52", metallic=0.75, roughness=0.45),
        make_material("Chest_Lock", "#C8A24A", metallic=0.80, roughness=0.35),
    ]
    wood, wood_dark, iron, lock = 0, 1, 2, 3
    bm = bmesh.new()
    box(bm, (0, 0, 0.22), (0.90, 0.56, 0.44), wood)                          # body
    box(bm, (0, 0, 0.025), (0.94, 0.60, 0.05), wood_dark)                    # plinth
    cylinder(bm, (0, 0, 0.46), 0.28, 0.90, wood, segments=8, rot=rot_y(90))  # lid
    for sx in (-1.0, 1.0):
        box(bm, (0.30 * sx, 0, 0.23), (0.06, 0.58, 0.44), iron)              # body band
        cylinder(bm, (0.30 * sx, 0, 0.46), 0.292, 0.06, iron, segments=8,
                 rot=rot_y(90))                                              # lid band
    box(bm, (0, 0.295, 0.42), (0.14, 0.05, 0.16), lock)                      # hasp
    chest = finish_object(bm, "Chest_Body", mats)
    return chest, collision_child(chest, "Chest", (0, 0, 0.37), (0.94, 0.60, 0.74))


# --------------------------------------------------------------------------
# ground tile: 2 x 2 m, top face at z = 0, two grass-green variants
# --------------------------------------------------------------------------

def build_ground_tile(name, hexcol, x_offset):
    mat = make_material(name.replace("GroundTile_", "GroundTile_Grass"), hexcol,
                        roughness=0.95)
    bm = bmesh.new()
    box(bm, (0, 0, -0.05), (2.0, 2.0, 0.10), 0)
    bevel_edges(bm, 0.03)
    tile = finish_object(bm, name, [mat])
    tile.location = (x_offset, 0.0, 0.0)
    return tile, collision_child(tile, name, (0, 0, -0.05), (2.0, 2.0, 0.10))


# --------------------------------------------------------------------------
# assembly
# --------------------------------------------------------------------------

def assemble(label, visible, colliders, **preview):
    root_name = label.title().replace("_", "")
    coll = model_collection("SF_" + root_name)
    link(coll, *visible)
    link(coll, *colliders)
    update_depsgraph()
    report(label, visible)
    export_glb(list(visible) + list(colliders),
               os.path.join(MODEL_DIR, label + ".glb"), root_name=root_name)
    render_preview(visible, os.path.join(PREVIEW_DIR, label + ".png"), **preview)


def main():
    scene = assets_scene()
    prev = activate_scene(scene)
    try:
        tree, tree_col = build_tree()
        assemble("tree", [tree], [tree_col])

        crate, crate_col = build_crate()
        assemble("crate", [crate], [crate_col])

        chest, chest_col = build_chest()
        assemble("chest", [chest], [chest_col])

        tile_a, tile_a_col = build_ground_tile("GroundTile_A", "#4E7A3C", -1.0)
        tile_b, tile_b_col = build_ground_tile("GroundTile_B", "#5F8A46", 1.0)
        assemble("ground_tile", [tile_a, tile_b], [tile_a_col, tile_b_col],
                 ground=False, elev_deg=30.0)
    finally:
        restore_scene(prev)
    print("SF_PROPS DONE")


main()
