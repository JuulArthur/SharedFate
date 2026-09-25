# Shared Fate 3D port, WP1 + WP11: knight, rogue and mage as low-poly,
# rigidly skinned characters with an `idle` and a `walk` cycle.
#
# Command line:
#     blender --background --factory-startup --python tools/blender/generate_characters.py -- --root <repo>
#     (--root defaults to the repository two levels above this file)
#
# Blender MCP (`execute_blender_code` cannot import a sibling module, so set the
# paths in the namespace first and send the file text):
#     SF_DIR  = r"D:\workspace\SharedFate\tools\blender"
#     SF_ROOT = r"D:\workspace\SharedFate"
#     exec(open(SF_DIR + r"\generate_characters.py", encoding="utf-8").read())
# The generator exec()s sf_assets_common.py out of SF_DIR itself; do not prepend
# it by hand.
#
# Conventions: 1 unit = 1 m, +Z up in Blender, feet on z = 0, the character
# faces Blender +Y which `export_yup=True` turns into glTF/Godot -Z. The
# character's right hand is at +X in both. Weapons are separate objects whose
# origin is the grip and whose blade or shaft runs along local +Z in Blender,
# i.e. local +Y after export.
#
# Rig (WP11): one armature `<Name>_Armature` per character. The body is still
# one mesh, `<Name>_Body`, but every primitive is assigned to exactly one bone
# through a vertex group (rigid skinning, weight 1.0) and the mesh deforms
# through an Armature modifier. `HandPoint` and the weapons are bone-parented
# to the forearms, `OverheadAnchor` to the armature object (it never bobs). Two
# plain actions per character, `idle` (2.0 s) and `walk` (1.0 s), both at
# 60 fps, are keyed from computed poses and exported as glTF animations.

import bpy
import bmesh
import math
import os
import sys
from mathutils import Vector, Matrix, Euler


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

OVERHEAD_CLEARANCE = 0.25

# Animation timing. The walk cycle is one stride (two steps) per second at the
# player's 3.5 m/s; Godot scales its playback by ground speed / 3.5.
ANIM_FPS = 60
IDLE_FRAMES = 120          # 2.0 s
WALK_FRAMES = 60           # 1.0 s
KEY_STEP = 2               # a key every 2 frames, linear in between
WALK_PREVIEW_PHASE = 0.25  # right leg forward, left leg back: mid-stride
WALK_PREVIEW_YAW_DEG = 70.0  # the standing sheet uses 35 degrees

TAU = 2.0 * math.pi


# --------------------------------------------------------------------------
# knight: palette sampled from assets/player/knight_south.png
# --------------------------------------------------------------------------

def knight_materials():
    return [
        make_material("Knight_Armor", "#464C5F", metallic=0.55, roughness=0.45),
        make_material("Knight_ArmorLight", "#5D6477", metallic=0.55, roughness=0.40),
        make_material("Knight_ArmorDark", "#2D2E3E", metallic=0.45, roughness=0.55),
        make_material("Knight_Visor", "#0F0909", metallic=0.20, roughness=0.60),
        make_material("Knight_Red", "#A92A20", metallic=0.0, roughness=0.80),
    ]


K_ARMOR, K_LIGHT, K_DARK, K_VISOR, K_RED = range(5)


def knight_visor_faces(c, r):
    """T-shaped visor painted on the front (+Y) of the helm."""
    az = math.degrees(math.atan2(c.x, c.y))          # 0 = straight ahead
    if 0.0 < c.z < 0.383 * r and abs(az) <= 50.0:    # eye band
        return K_VISOR
    if -0.383 * r < c.z <= 0.0 and abs(az) <= 20.0:  # vertical slit
        return K_VISOR
    return None


# (bone, head, tail, parent, connected). Hips at the belt, knees and elbows at
# the joint boxes, the arms hanging from the shoulder pivot.
KNIGHT_BONES = [
    ("Hips", (0.0, 0.0, 0.98), (0.0, 0.0, 1.08), None, False),
    ("Spine", (0.0, 0.0, 1.08), (0.0, 0.0, 1.53), "Hips", False),
    ("Head", (0.0, 0.0, 1.53), (0.0, 0.0, 1.97), "Spine", False),
    ("UpperArm_L", (-0.335, 0.0, 1.47), (-0.335, 0.0, 1.135), "Spine", False),
    ("LowerArm_L", (-0.335, 0.0, 1.135), (-0.335, 0.01, 0.83), "UpperArm_L", True),
    ("UpperArm_R", (0.335, 0.0, 1.47), (0.335, 0.0, 1.135), "Spine", False),
    ("LowerArm_R", (0.335, 0.0, 1.135), (0.335, 0.01, 0.83), "UpperArm_R", True),
    ("UpperLeg_L", (-0.13, 0.0, 0.96), (-0.13, 0.01, 0.60), "Hips", False),
    ("LowerLeg_L", (-0.13, 0.01, 0.60), (-0.13, 0.01, 0.05), "UpperLeg_L", True),
    ("UpperLeg_R", (0.13, 0.0, 0.96), (0.13, 0.01, 0.60), "Hips", False),
    ("LowerLeg_R", (0.13, 0.01, 0.60), (0.13, 0.01, 0.05), "UpperLeg_R", True),
    ("Cape", (0.0, -0.17, 1.53), (0.0, -0.35, 0.40), "Spine", False),
]


def build_knight_body():
    bm = bmesh.new()
    skin_begin(bm)

    def leg(s):
        x = 0.13 * s
        skin_bone(side_bone("LowerLeg", s))
        box(bm, (x, 0.04, 0.09), (0.17, 0.34, 0.18), K_DARK)                    # boot
        box(bm, (x, 0.14, 0.15), (0.13, 0.10, 0.06), K_DARK)                    # toe cap
        box(bm, (x, 0.0, 0.38), (0.15, 0.16, 0.38), K_ARMOR, taper=(1.15, 1.1))  # greave
        box(bm, (x, 0.01, 0.60), (0.18, 0.19, 0.10), K_DARK)                    # knee
        skin_bone(side_bone("UpperLeg", s))
        box(bm, (x, 0.0, 0.80), (0.18, 0.19, 0.32), K_ARMOR, taper=(1.05, 1.05))  # cuisse
    mirror_x(leg)

    skin_bone("Hips")
    box(bm, (0, 0, 0.98), (0.42, 0.28, 0.16), K_DARK)                            # pelvis
    skin_bone("Spine")
    box(bm, (0, 0, 1.08), (0.46, 0.31, 0.06), K_RED)                             # belt
    box(bm, (0, 0.16, 1.08), (0.10, 0.02, 0.07), K_LIGHT)                        # buckle
    box(bm, (0, 0, 1.31), (0.46, 0.29, 0.40), K_ARMOR, taper=(1.25, 1.12))       # breastplate
    box(bm, (0, 0.02, 1.53), (0.50, 0.26, 0.06), K_ARMOR)                        # collar plate
    box(bm, (0, 0.155, 1.36), (0.035, 0.02, 0.36), K_RED, rot=rot_y(32))         # strap
    box(bm, (0, 0.155, 1.36), (0.035, 0.02, 0.36), K_RED, rot=rot_y(-32))        # strap
    box(bm, (0, 0.165, 1.36), (0.06, 0.02, 0.06), K_LIGHT)                       # clasp

    skin_bone("Head")
    cylinder(bm, (0, 0, 1.56), 0.09, 0.10, K_DARK)                               # neck
    sphere(bm, (0, 0, 1.765), 0.20, K_LIGHT, scale=(1.0, 1.06, 1.15), u=12, v=8,
           face_mat=knight_visor_faces)                                          # closed helm
    box(bm, (0, 0.0, 1.965), (0.03, 0.28, 0.05), K_ARMOR)                        # crest seam
    cylinder(bm, (0, 0, 1.545), 0.20, 0.04, K_ARMOR, segments=12)                # helm ring

    def arm(s):
        x = 0.335 * s
        skin_bone(side_bone("UpperArm", s))
        sphere(bm, (x, 0.0, 1.50), 0.135, K_LIGHT, scale=(1.0, 0.95, 0.85))      # pauldron
        box(bm, (x, 0.0, 1.47), (0.24, 0.22, 0.05), K_RED)                       # trim
        box(bm, (x, 0.0, 1.30), (0.14, 0.14, 0.30), K_ARMOR, taper=(1.1, 1.1))   # upper arm
        skin_bone(side_bone("LowerArm", s))
        box(bm, (x, 0.0, 1.135), (0.16, 0.16, 0.08), K_DARK)                     # elbow
        box(bm, (x, 0.0, 1.00), (0.135, 0.135, 0.22), K_ARMOR)                   # forearm
        box(bm, (x, 0.0, 0.905), (0.16, 0.16, 0.02), K_RED)                      # cuff
        box(bm, (x, 0.01, 0.83), (0.15, 0.16, 0.14), K_DARK)                     # gauntlet
    mirror_x(arm)

    return finish_object(bm, "Knight_Body", knight_materials())


def build_knight_cape():
    """Quad grid hanging off the shoulders, thickened by a Solidify modifier.
    Rigidly skinned to the `Cape` bone, which trails behind in the walk."""
    bm = bmesh.new()
    rows, cols = 8, 5
    grid = []
    for i in range(rows):
        t = i / (rows - 1.0)                       # 0 = shoulders, 1 = hem
        z = 1.53 - t * 1.20
        half_w = 0.25 + 0.25 * t ** 0.8
        y_back = -(0.17 + 0.18 * t + 0.04 * math.sin(t * math.pi))
        row = []
        for j in range(cols):
            s = j / (cols - 1.0) * 2 - 1
            y = y_back + 0.09 * abs(s) ** 1.5      # the sides wrap toward the body
            zz = z - (0.05 * (1 - abs(s)) if i == rows - 1 else 0.0)
            row.append(bm.verts.new((half_w * s, y, zz)))
        grid.append(row)
    for i in range(rows - 1):
        for j in range(cols - 1):
            bm.faces.new((grid[i][j], grid[i][j + 1], grid[i + 1][j + 1], grid[i + 1][j]))
    cape = finish_object(bm, "Knight_Cape",
                         [make_material("Knight_Cape", "#5B1204", roughness=0.90)])
    sol = cape.modifiers.new("Solidify", "SOLIDIFY")
    sol.thickness = 0.02
    sol.offset = 0.0
    skin_whole(cape, "Cape")
    return cape


def build_sword():
    """Origin at the grip, blade along local +Z (local +Y once exported)."""
    mats = [
        make_material("Knight_ArmorDark", "#2D2E3E", metallic=0.45, roughness=0.55),
        make_material("Knight_ArmorLight", "#5D6477", metallic=0.55, roughness=0.40),
        make_material("Knight_Steel", "#B8BCC8", metallic=0.90, roughness=0.30),
    ]
    grip, light, steel = 0, 1, 2
    bm = bmesh.new()
    box(bm, (0, 0, 0.0), (0.045, 0.045, 0.16), grip)                       # grip
    box(bm, (0, 0, -0.095), (0.07, 0.07, 0.04), light)                     # pommel
    box(bm, (0, 0, 0.09), (0.24, 0.05, 0.035), light)                      # crossguard
    box(bm, (0, 0, 0.45), (0.065, 0.016, 0.66), steel)                     # blade
    box(bm, (0, 0, 0.81), (0.065, 0.016, 0.06), steel, taper=(0.15, 1.0))  # tip
    return finish_object(bm, "Sword", mats)


# --------------------------------------------------------------------------
# rogue: palette from SoulArt.ROGUE_* in scripts/soul_art.gd
# --------------------------------------------------------------------------

R_LEATHER, R_LIGHT, R_CLOTH, R_DARK, R_VISOR, R_SKIN, R_RED, R_BELT, R_STEEL, R_EYE = range(10)


def rogue_materials():
    return [
        make_material("Rogue_Leather", "#334D38", roughness=0.70),
        make_material("Rogue_LeatherLight", "#45664A", roughness=0.65),
        make_material("Rogue_Cloth", "#29302B", roughness=0.85),
        make_material("Rogue_Dark", "#1A1F1C", roughness=0.80),
        make_material("Rogue_Visor", "#241C1F", roughness=0.90),
        make_material("Rogue_Skin", "#9E806B", roughness=0.75),
        make_material("Rogue_Red", "#8C2929", roughness=0.85),
        make_material("Rogue_Belt", "#57381F", roughness=0.75),
        make_material("Rogue_Steel", "#B8BCC8", metallic=0.90, roughness=0.30),
        make_material("Rogue_Eye", "#CCFFD1", roughness=0.40,
                      emission="#8CED99", emission_strength=1.5),
    ]


def rogue_hood_faces(c, r):
    """Dark opening at the front (+Y) of the hood: the face sits in shadow."""
    az = math.degrees(math.atan2(c.x, c.y))
    if -0.50 * r < c.z < 0.42 * r and abs(az) <= 34.0:
        return R_VISOR
    return None


ROGUE_BONES = [
    ("Hips", (0.0, 0.0, 0.90), (0.0, 0.0, 1.02), None, False),
    ("Spine", (0.0, 0.0, 1.02), (0.0, 0.0, 1.46), "Hips", False),
    ("Head", (0.0, 0.0, 1.47), (0.0, 0.0, 1.90), "Spine", False),
    ("UpperArm_L", (-0.235, 0.0, 1.40), (-0.235, 0.0, 1.06), "Spine", False),
    ("LowerArm_L", (-0.235, 0.0, 1.06), (-0.235, 0.05, 0.80), "UpperArm_L", True),
    ("UpperArm_R", (0.235, 0.0, 1.40), (0.235, 0.0, 1.06), "Spine", False),
    ("LowerArm_R", (0.235, 0.0, 1.06), (0.235, 0.05, 0.80), "UpperArm_R", True),
    ("UpperLeg_L", (-0.11, 0.0, 0.90), (-0.11, 0.0, 0.58), "Hips", False),
    ("LowerLeg_L", (-0.11, 0.0, 0.58), (-0.11, 0.0, 0.05), "UpperLeg_L", True),
    ("UpperLeg_R", (0.11, 0.0, 0.90), (0.11, 0.0, 0.58), "Hips", False),
    ("LowerLeg_R", (0.11, 0.0, 0.58), (0.11, 0.0, 0.05), "UpperLeg_R", True),
]


def build_rogue_body():
    bm = bmesh.new()
    skin_begin(bm)

    def leg(s):
        x = 0.11 * s
        skin_bone(side_bone("LowerLeg", s))
        box(bm, (x, 0.02, 0.10), (0.14, 0.30, 0.20), R_DARK)                    # boot
        box(bm, (x, 0.13, 0.055), (0.11, 0.09, 0.09), R_DARK)                   # toe
        box(bm, (x, 0.0, 0.37), (0.115, 0.13, 0.34), R_DARK, taper=(1.1, 1.1))  # shin
        box(bm, (x, 0.0, 0.58), (0.135, 0.15, 0.10), R_CLOTH)                   # knee wrap
        skin_bone(side_bone("UpperLeg", s))
        box(bm, (x, 0.0, 0.76), (0.15, 0.16, 0.28), R_CLOTH, taper=(1.05, 1.05))  # thigh
    mirror_x(leg)

    skin_bone("Hips")
    box(bm, (0, 0, 0.92), (0.34, 0.24, 0.16), R_CLOTH)                          # hips
    skin_bone("Spine")
    box(bm, (0, 0, 1.02), (0.38, 0.27, 0.05), R_BELT)                           # belt
    box(bm, (0, 0.14, 1.02), (0.07, 0.02, 0.05), R_LIGHT)                       # buckle
    box(bm, (0, 0, 1.24), (0.36, 0.24, 0.38), R_LEATHER, taper=(1.14, 1.06))    # jerkin
    box(bm, (0, 0.128, 1.27), (0.05, 0.02, 0.34), R_BELT, rot=rot_y(22))        # baldric
    box(bm, (0, 0.0, 1.46), (0.44, 0.31, 0.16), R_CLOTH, taper=(0.72, 0.78))    # mantle
    box(bm, (0, 0.0, 1.41), (0.30, 0.24, 0.05), R_RED)                          # scarf

    skin_bone("Head")
    cylinder(bm, (0, 0, 1.52), 0.07, 0.10, R_DARK)                              # neck
    sphere(bm, (0, 0.0, 1.62), 0.14, R_SKIN, scale=(1.0, 1.05, 1.12))           # head
    sphere(bm, (0, -0.01, 1.65), 0.185, R_LEATHER, scale=(1.0, 1.10, 1.15),
           u=10, v=7, face_mat=rogue_hood_faces)                                # hood
    cone(bm, (0, -0.10, 1.80), 0.10, 0.22, R_LEATHER, segments=7, rot=rot_x(35))  # peak
    box(bm, (0, 0.145, 1.575), (0.10, 0.03, 0.06), R_SKIN)                      # chin
    box(bm, (0.045, 0.158, 1.655), (0.028, 0.02, 0.022), R_EYE)                 # eye glint
    box(bm, (-0.045, 0.158, 1.655), (0.028, 0.02, 0.022), R_EYE)

    def arm(s):
        x = 0.235 * s
        skin_bone(side_bone("UpperArm", s))
        box(bm, (x, 0.0, 1.42), (0.15, 0.15, 0.12), R_LEATHER)                  # shoulder
        box(bm, (x, 0.0, 1.20), (0.115, 0.115, 0.32), R_LEATHER, taper=(1.08, 1.08))
        skin_bone(side_bone("LowerArm", s))
        box(bm, (x + 0.01 * s, 0.02, 0.96), (0.105, 0.105, 0.24), R_DARK)       # bracer
        box(bm, (x + 0.01 * s, 0.02, 1.07), (0.115, 0.115, 0.04), R_LIGHT)      # bracer trim
        box(bm, (x + 0.015 * s, 0.05, 0.83), (0.095, 0.10, 0.10), R_SKIN)       # hand
    mirror_x(arm)

    return finish_object(bm, "Rogue_Body", rogue_materials())


def build_dagger(name):
    """Origin at the grip, blade along local +Z."""
    mats = [
        make_material("Rogue_Dark", "#1A1F1C", roughness=0.80),
        make_material("Rogue_Steel", "#B8BCC8", metallic=0.90, roughness=0.30),
    ]
    dark, steel = 0, 1
    bm = bmesh.new()
    box(bm, (0, 0, 0.0), (0.032, 0.032, 0.10), dark)                        # grip
    box(bm, (0, 0, -0.062), (0.05, 0.05, 0.025), steel)                     # pommel
    box(bm, (0, 0, 0.062), (0.11, 0.035, 0.022), steel)                     # guard
    box(bm, (0, 0, 0.175), (0.042, 0.014, 0.20), steel)                     # blade
    box(bm, (0, 0, 0.30), (0.042, 0.014, 0.05), steel, taper=(0.12, 1.0))   # tip
    return finish_object(bm, name, mats)


# --------------------------------------------------------------------------
# mage: palette from SoulArt.MAGE_* in scripts/soul_art.gd
# --------------------------------------------------------------------------

M_ROBE, M_ROBEDARK, M_TRIM, M_HOOD, M_VISOR, M_SKIN, M_BAND, M_GREY, M_HAIR = range(9)


def mage_materials():
    return [
        make_material("Mage_Robe", "#5C388C", roughness=0.80),
        make_material("Mage_RobeDark", "#3D2461", roughness=0.85),
        make_material("Mage_Trim", "#9E7AD1", roughness=0.70),
        make_material("Mage_Hood", "#4D2E7A", roughness=0.82),
        make_material("Mage_Visor", "#1E1426", roughness=0.90),
        make_material("Mage_Skin", "#DBC2AD", roughness=0.75),
        make_material("Mage_Band", "#D9B352", metallic=0.6, roughness=0.40),
        make_material("Mage_Grey", "#6E6E78", roughness=0.70),
        make_material("Mage_Hair", "#C7C7D1", roughness=0.75),
    ]


def mage_hood_faces(c, r):
    az = math.degrees(math.atan2(c.x, c.y))
    if -0.52 * r < c.z < 0.40 * r and abs(az) <= 33.0:
        return M_VISOR
    return None


# The robe covers the legs: no leg bones, one `Robe` bone hanging from the sash
# that sways instead of stepping.
MAGE_BONES = [
    ("Hips", (0.0, 0.0, 0.92), (0.0, 0.0, 1.02), None, False),
    ("Spine", (0.0, 0.0, 1.02), (0.0, 0.0, 1.50), "Hips", False),
    ("Head", (0.0, 0.0, 1.50), (0.0, 0.0, 1.92), "Spine", False),
    ("UpperArm_L", (-0.245, 0.0, 1.34), (-0.245, 0.0, 1.08), "Spine", False),
    ("LowerArm_L", (-0.245, 0.0, 1.08), (-0.245, 0.04, 0.88), "UpperArm_L", True),
    ("UpperArm_R", (0.245, 0.0, 1.34), (0.245, 0.0, 1.08), "Spine", False),
    ("LowerArm_R", (0.245, 0.0, 1.08), (0.245, 0.04, 0.88), "UpperArm_R", True),
    ("Robe", (0.0, 0.0, 1.02), (0.0, 0.0, 0.10), "Hips", False),
]

# The WP1 robe was one tapered cylinder from the hem (r 0.40) to the shoulders
# (r 0.17, z 1.34). It is split at the sash so the skirt can sway on its own
# bone; both halves keep the original taper, the sash covers the seam.
MAGE_ROBE_SPLIT_Z = 1.02
MAGE_ROBE_SPLIT_R = 0.40 + (0.17 - 0.40) * (MAGE_ROBE_SPLIT_Z / 1.34)


def build_mage_body():
    bm = bmesh.new()
    skin_begin(bm)

    # robe: skirt (hem to sash) on `Robe`, torso (sash to shoulders) on `Spine`
    skin_bone("Robe")
    cylinder(bm, (0, 0, MAGE_ROBE_SPLIT_Z * 0.5), 0.40, MAGE_ROBE_SPLIT_Z, M_ROBE,
             segments=10, r_top=MAGE_ROBE_SPLIT_R)                                 # skirt
    cylinder(bm, (0, 0, 0.06), 0.415, 0.12, M_ROBEDARK, segments=10, r_top=0.395)  # hem

    def foot(s):
        box(bm, (0.10 * s, 0.14, 0.045), (0.14, 0.22, 0.09), M_GREY)
    mirror_x(foot)                                                                  # under the hem

    skin_bone("Spine")
    cylinder(bm, (0, 0, (MAGE_ROBE_SPLIT_Z + 1.34) * 0.5), MAGE_ROBE_SPLIT_R,
             1.34 - MAGE_ROBE_SPLIT_Z, M_ROBE, segments=10, r_top=0.17)             # robe torso
    cylinder(bm, (0, 0, 1.02), 0.245, 0.07, M_BAND, segments=10)                   # sash
    cylinder(bm, (0, 0, 1.42), 0.30, 0.22, M_ROBEDARK, segments=10, r_top=0.19)    # mantle
    box(bm, (0, 0.205, 1.18), (0.10, 0.04, 0.24), M_TRIM, rot=rot_x(10))           # front trim

    skin_bone("Head")
    cylinder(bm, (0, 0, 1.50), 0.07, 0.10, M_ROBEDARK)                             # neck
    sphere(bm, (0, 0.0, 1.635), 0.135, M_SKIN, scale=(1.0, 1.05, 1.12))            # head
    box(bm, (0.150, -0.01, 1.50), (0.05, 0.15, 0.19), M_HAIR)                      # hair
    box(bm, (-0.150, -0.01, 1.50), (0.05, 0.15, 0.19), M_HAIR)
    sphere(bm, (0, -0.01, 1.665), 0.19, M_HOOD, scale=(1.0, 1.10, 1.16), u=10, v=7,
           face_mat=mage_hood_faces)                                               # hood
    cone(bm, (0, -0.105, 1.80), 0.10, 0.22, M_HOOD, segments=7, rot=rot_x(35))     # peak

    def arm(s):
        x = 0.245 * s
        skin_bone(side_bone("UpperArm", s))
        box(bm, (x, 0.0, 1.18), (0.135, 0.135, 0.36), M_ROBE, taper=(0.8, 0.8))    # sleeve
        skin_bone(side_bone("LowerArm", s))
        box(bm, (x, 0.01, 0.985), (0.15, 0.15, 0.05), M_TRIM)                      # cuff
        box(bm, (x, 0.04, 0.92), (0.10, 0.11, 0.10), M_SKIN)                       # hand
    mirror_x(arm)

    return finish_object(bm, "Mage_Body", mage_materials())


def build_staff():
    """Origin at the grip, shaft along local +Z."""
    mats = [
        make_material("Mage_Grey", "#6E6E78", roughness=0.70),
        make_material("Mage_Band", "#D9B352", metallic=0.6, roughness=0.40),
        make_material("Mage_Gem", "#CC9EFF", roughness=0.25,
                      emission="#CC9EFF", emission_strength=2.0),
    ]
    wood, band, gem = 0, 1, 2
    bm = bmesh.new()
    cylinder(bm, (0, 0, -0.02), 0.028, 1.76, wood, segments=6)      # shaft -0.90 .. 0.86
    cylinder(bm, (0, 0, -0.865), 0.036, 0.07, band, segments=6)     # ferrule
    cylinder(bm, (0, 0, 0.845), 0.045, 0.06, band, segments=6)      # crown
    sphere(bm, (0, 0, 0.93), 0.075, gem, u=6, v=4)                  # crystal
    return finish_object(bm, "Staff", mats)


# --------------------------------------------------------------------------
# poses (see sf_assets_common: rotation about local X is the forward/up pitch;
# + swings a hanging limb forward and tips an upright bone backward)
# --------------------------------------------------------------------------

def _knee_flex(phase):
    """Knee bend of one leg over its cycle (leg forward at phase 0.25, back at
    0.75): straight through the stance, bending from heel-off behind the body
    to a 59 degree peak just after the leg starts its swing forward."""
    lift = max(0.0, math.cos(TAU * (phase - 0.9)))
    return 4.0 + 55.0 * lift ** 1.5


def pose_walk(phase, legs=True, cape=False, robe=False, leg_amp=30.0,
              arm_amp_r=25.0, arm_amp_l=25.0):
    """One stride: the right leg forward at phase 0.25, the left at 0.75."""
    s = math.sin(TAU * phase)
    c2 = math.cos(2.0 * TAU * phase)
    lean = 5.0
    pose = {
        # 3 cm hip bob at twice the stride frequency: highest while the legs
        # pass under the body, lowest at full stride; a slight hip twist.
        "Hips": {"loc": (0.0, -0.03 * s * s, 0.0), "rot": (0.0, 3.0 * s, 0.0)},
        # lean forward, shoulders counter-twisting against the hips
        "Spine": {"rot": (-lean, -6.0 * s, 0.0)},
        "Head": {"rot": (lean - 1.0, 3.0 * s, 0.0)},
        # arms counter-swing; the lean is taken out so they swing about the
        # vertical, elbows bending a little more on the forward swing
        "UpperArm_R": {"rot": (lean - arm_amp_r * s, 0.0, 0.0)},
        "UpperArm_L": {"rot": (lean + arm_amp_l * s, 0.0, 0.0)},
        "LowerArm_R": {"rot": (8.0 + 12.0 * max(0.0, -s) * arm_amp_r / 25.0, 0.0, 0.0)},
        "LowerArm_L": {"rot": (8.0 + 12.0 * max(0.0, s) * arm_amp_l / 25.0, 0.0, 0.0)},
    }
    if legs:
        pose["UpperLeg_R"] = {"rot": (leg_amp * s, 0.0, 0.0)}
        pose["UpperLeg_L"] = {"rot": (-leg_amp * s, 0.0, 0.0)}
        pose["LowerLeg_R"] = {"rot": (-_knee_flex(phase), 0.0, 0.0)}
        pose["LowerLeg_L"] = {"rot": (-_knee_flex(phase + 0.5), 0.0, 0.0)}
    if cape:
        # trails behind the walking legs, fluttering once per step
        pose["Cape"] = {"rot": (-(16.0 + 4.0 * c2), 0.0, 0.0)}
    if robe:
        # the skirt trails a little, twists with the hips and rolls side to
        # side once per stride instead of stepping
        pose["Robe"] = {"rot": (-(3.0 + 2.0 * c2), -5.0 * s, 4.0 * math.sin(TAU * phase - 0.6))}
    return pose


def pose_idle(phase, cape=False, robe=False):
    """Breathing: the torso sinks 2 cm into the pelvis and back (never lifts
    off it), the arms sway a few degrees forward and back."""
    s = math.sin(TAU * phase)
    c = math.cos(TAU * phase)
    pose = {
        "Spine": {"loc": (0.0, -0.01 * (1.0 - c), 0.0)},
        "Head": {"rot": (1.5 * math.sin(TAU * phase - 0.6), 0.0, 0.0)},
        "UpperArm_R": {"rot": (3.0 * s, 0.0, 0.0)},
        "UpperArm_L": {"rot": (3.0 * math.sin(TAU * phase + 0.8), 0.0, 0.0)},
        "LowerArm_R": {"rot": (4.0 + 2.0 * math.sin(TAU * phase + 0.5), 0.0, 0.0)},
        "LowerArm_L": {"rot": (4.0 + 2.0 * math.sin(TAU * phase + 1.3), 0.0, 0.0)},
    }
    if cape:
        pose["Cape"] = {"rot": (-(1.5 + 1.5 * s), 0.0, 0.0)}
    if robe:
        pose["Robe"] = {"rot": (0.0, 0.0, 1.0 * s)}
    return pose


# --------------------------------------------------------------------------
# assembly
# --------------------------------------------------------------------------

def _set_frame(scene, frame):
    scene.frame_set(frame)
    update_depsgraph()


def assemble(label, body, cape, weapons, hand_point, bones, walk, idle):
    """Rig, animate, export and preview one character.

    `weapons` is a list of (object, location, rotation_euler, bone) tuples,
    `hand_point` the rest position of the right hand, `bones` the armature
    table, `walk` / `idle` the pose functions of the two actions."""
    name = label.capitalize()
    coll = model_collection("SF_" + name)
    scene = assets_scene()
    scene.render.fps = ANIM_FPS
    scene.render.fps_base = 1.0

    armature = build_armature(name + "_Armature", bones, coll)
    link(coll, body)
    skin_to_armature(body, armature)
    objects = [armature, body]
    if cape is not None:
        link(coll, cape)
        skin_to_armature(cape, armature)
        objects.append(cape)
    update_depsgraph()
    for ob, loc, rot, bone in weapons:
        link(coll, ob)
        parent_to_bone(ob, armature, bone,
                       world=Matrix.LocRotScale(Vector(loc), Euler(rot, "XYZ"), None))
        objects.append(ob)

    update_depsgraph()
    top = world_bounds([body])[1].z
    hand = add_empty("HandPoint", hand_point, collection=coll)
    parent_to_bone(hand, armature, "LowerArm_R")
    overhead = add_empty("OverheadAnchor", (0.0, 0.0, top + OVERHEAD_CLEARANCE),
                         parent=armature, collection=coll)
    objects.extend([hand, overhead])
    update_depsgraph()
    for ob in objects[2:]:
        if ob.type == "EMPTY" or ob.parent_type == "BONE":
            print("SF_ATTACH %-8s %-14s parent=%s/%s at %s"
                  % (label, ob.name, ob.parent.name, ob.parent_bone or "-",
                     tuple(round(v, 3) for v in ob.matrix_world.translation)))

    actions = [
        author_action(armature, "idle", IDLE_FRAMES, idle, step=KEY_STEP),
        author_action(armature, "walk", WALK_FRAMES, walk, step=KEY_STEP),
    ]
    _set_frame(scene, 0)

    groups = sorted(g.name for g in body.vertex_groups)
    print("SF_PART  %-8s body=%d cape=%d weapons=%s head_top=%.3f hand=%s"
          % (label, tri_count(body), tri_count(cape),
             [(w[0].name, tri_count(w[0])) for w in weapons], top,
             tuple(round(v, 3) for v in hand_point)))
    print("SF_RIG   %-8s bones=%s groups=%s actions=%s"
          % (label, [b.name for b in armature.data.bones], groups,
             [(a.name, tuple(a.frame_range)) for a in actions]))
    report(label, objects)

    export_glb(objects, os.path.join(MODEL_DIR, label + ".glb"),
               root_name=name, animations=True)
    render_preview(objects, os.path.join(PREVIEW_DIR, label + ".png"))

    # Mid-stride frame of the walk for the preview sheet.
    armature.animation_data.action = actions[1]
    _set_frame(scene, int(round(WALK_PREVIEW_PHASE * WALK_FRAMES)))
    hand_walk = hand.matrix_world.translation.copy()
    print("SF_WALK  %-8s frame=%d hand=%s (rest %s)"
          % (label, scene.frame_current, tuple(round(v, 3) for v in hand_walk),
             tuple(round(v, 3) for v in hand_point)))
    # Seen more from the side than the standing sheet, so the stride reads.
    render_preview(objects, os.path.join(PREVIEW_DIR, label + "_walk.png"),
                   yaw_deg=WALK_PREVIEW_YAW_DEG)
    armature.animation_data.action = None
    reset_pose(armature)
    _set_frame(scene, 0)

    # Blender names are unique per file: free "HandPoint", "OverheadAnchor",
    # "idle" and "walk" for the next character now that this one is exported.
    # The actions are removed, so the next export cannot pick them up.
    hand.name = name + "_HandPoint"
    overhead.name = name + "_OverheadAnchor"
    for act in actions:
        bpy.data.actions.remove(act)
    return objects


def main():
    scene = assets_scene()
    prev = activate_scene(scene)
    try:
        assemble("knight", build_knight_body(), build_knight_cape(),
                 [(build_sword(), (0.335, 0.08, 0.86), (math.pi, 0.0, 0.0), "LowerArm_R")],
                 (0.335, 0.08, 0.86), KNIGHT_BONES,
                 walk=lambda p: pose_walk(p, cape=True),
                 idle=lambda p: pose_idle(p, cape=True))
        assemble("rogue", build_rogue_body(), None,
                 [(build_dagger("Dagger_R"), (0.265, 0.06, 0.83), (math.pi, 0.0, 0.0), "LowerArm_R"),
                  (build_dagger("Dagger_L"), (-0.265, 0.06, 0.83), (math.pi, 0.0, 0.0), "LowerArm_L")],
                 (0.265, 0.06, 0.83), ROGUE_BONES,
                 walk=lambda p: pose_walk(p),
                 idle=lambda p: pose_idle(p))
        # The staff hand swings less than the free hand.
        assemble("mage", build_mage_body(), None,
                 [(build_staff(), (0.245, 0.06, 0.92), (0.0, 0.0, 0.0), "LowerArm_R")],
                 (0.245, 0.06, 0.92), MAGE_BONES,
                 walk=lambda p: pose_walk(p, legs=False, robe=True, arm_amp_r=10.0, arm_amp_l=18.0),
                 idle=lambda p: pose_idle(p, robe=True))
    finally:
        restore_scene(prev)
    print("SF_CHARACTERS DONE")


main()
