# Shared Fate 3D port, WP1 + WP12: the low-poly wolf enemy, rigidly skinned,
# with an `idle` and a `trot` cycle.
#
# Command line:
#     blender --background --factory-startup --python tools/blender/generate_wolf.py -- --root <repo>
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
#
# Rig (WP12): one armature `Wolf_Armature` with `Hips` (the root, at the
# haunches), `Spine`, `Neck`, `Head`, `Tail` and one bone per leg
# (`FrontLeg_L/R`, `HindLeg_L/R`: the legs are an upper box, a lower box and a
# paw with no joint box between them, so there is no knee to bend). Every part
# of `Wolf_Body` belongs to exactly one bone (rigid skinning, weight 1.0). All
# four legs hang from `Hips`, so the breathing and rolling `Spine` never lifts a
# planted paw. `OverheadAnchor` rides the armature object and never bobs.
#
# The trot is a diagonal gait with a duty factor of one half: the front-left
# and hind-right paws touch down together at phase 0 and sweep back on the
# ground until phase 0.5 while the other pair swings forward, then the pairs
# swap. During a stance the paw moves back relative to the body at a constant
# rate, and the body (Hips) sinks and each leg slides a little into the body so
# that the planted paw stays on z = 0 while the rigid leg tilts; a swinging leg
# is drawn up into the body to lift its paw. The stride per cycle is measured
# from the posed rig after authoring and printed as `SF_TROT`; Godot plays the
# clip at ground speed / (stride / clip length), see `Enemy3D`.

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

OVERHEAD_CLEARANCE = 0.20

# Animation timing, 60 fps like the characters, a key every 2 frames.
ANIM_FPS = 60
IDLE_FRAMES = 120            # 2.0 s
TROT_FRAMES = 24             # 0.4 s, one full cycle (both diagonal pairs step)
KEY_STEP = 2

# Legs. The shoulder and hip joints sit inside the torso, 2 cm above the tops
# of the upper leg boxes, so a tilted leg's top corners stay inside the body.
LEG_X = 0.105
FRONT_LEG_Y = 0.22
HIND_LEG_Y = -0.20
LEG_PIVOT_Z = 0.40           # the leg bone runs from here to the sole at z = 0
TROT_SWING_DEG = 28.0        # +/- about the vertical at touch-down and lift-off
TROT_PAW_LIFT = 0.06         # paw height at mid-swing
# Share of the stance height change taken by the body bob; the rest is taken
# by sliding the stance leg into the body, which the torso hides. 0.5 halves
# the bob to about 2.3 cm below a 2.3 cm crouch.
TROT_BOB_SHARE = 0.5

TROT_PREVIEW_FRAME = 3       # front-left pair planted, the other pair lifting
TROT_PREVIEW_YAW_DEG = 70.0  # more from the side than the standing sheet

TAU = 2.0 * math.pi


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


# (bone, head, tail, parent, connected) in Blender space. Heads follow the part
# boxes: Hips over the haunches, Spine through the torso to the chest, Neck and
# Head along the neck and skull, Tail along the tail box.
WOLF_BONES = [
    ("Hips", (0.0, -0.22, 0.45), (0.0, -0.06, 0.45), None, False),
    ("Spine", (0.0, -0.06, 0.45), (0.0, 0.32, 0.48), "Hips", True),
    ("Neck", (0.0, 0.32, 0.48), (0.0, 0.44, 0.53), "Spine", True),
    ("Head", (0.0, 0.44, 0.53), (0.0, 0.74, 0.52), "Neck", True),
    ("Tail", (0.0, -0.212, 0.483), (0.0, -0.388, 0.577), "Hips", False),
    ("FrontLeg_L", (-LEG_X, FRONT_LEG_Y, LEG_PIVOT_Z), (-LEG_X, FRONT_LEG_Y, 0.0), "Hips", False),
    ("FrontLeg_R", (LEG_X, FRONT_LEG_Y, LEG_PIVOT_Z), (LEG_X, FRONT_LEG_Y, 0.0), "Hips", False),
    ("HindLeg_L", (-LEG_X, HIND_LEG_Y, LEG_PIVOT_Z), (-LEG_X, HIND_LEG_Y, 0.0), "Hips", False),
    ("HindLeg_R", (LEG_X, HIND_LEG_Y, LEG_PIVOT_Z), (LEG_X, HIND_LEG_Y, 0.0), "Hips", False),
]


def build_wolf_body():
    bm = bmesh.new()
    skin_begin(bm)

    # torso, front to back along +Y
    skin_bone("Spine")
    box(bm, (0, 0.02, 0.46), (0.28, 0.50, 0.28), W_FUR, taper=(0.95, 1.0))
    box(bm, (0, 0.26, 0.45), (0.28, 0.20, 0.28), W_FUR)            # chest
    skin_bone("Hips")
    box(bm, (0, -0.20, 0.42), (0.28, 0.20, 0.28), W_FUR)           # haunches
    skin_bone("Spine")
    box(bm, (0, 0.02, 0.335), (0.24, 0.48, 0.05), W_BELLY)         # belly

    # neck and head
    skin_bone("Neck")
    box(bm, (0, 0.38, 0.50), (0.20, 0.16, 0.20), W_FUR)
    skin_bone("Head")
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

    # legs: upper box, lower box and paw, all on the leg's one bone
    def leg(x, y, bone):
        skin_bone(bone)
        box(bm, (x, y, 0.27), (0.10, 0.13, 0.22), W_FUR)
        box(bm, (x, y - 0.01, 0.10), (0.075, 0.09, 0.18), W_DARK)
        box(bm, (x, y + 0.01, 0.0275), (0.095, 0.13, 0.055), W_DARK)

    for s in (-1.0, 1.0):
        leg(LEG_X * s, FRONT_LEG_Y, side_bone("FrontLeg", s))
        leg(LEG_X * s, HIND_LEG_Y, side_bone("HindLeg", s))

    # tail, sweeping up and back
    skin_bone("Tail")
    box(bm, (0, -0.30, 0.53), (0.085, 0.20, 0.085), W_FUR, rot=rot_x(-28))

    return finish_object(bm, "Wolf_Body", wolf_materials())


# --------------------------------------------------------------------------
# poses (sf_assets_common: every bone's local X is +X. A rotation about local X
# swings a hanging leg forward (+), lifts a forward-pointing bone's tip (+) and
# lowers the tail (+); about local Z it turns the head and wags the tail. A
# leg's local -Y is world up, Hips' local Z is world up.)
# --------------------------------------------------------------------------

LEG_LENGTH = LEG_PIVOT_Z
SIN_SWING = math.sin(math.radians(TROT_SWING_DEG))
COS_SWING = math.cos(math.radians(TROT_SWING_DEG))
# Constant crouch while trotting, so the stance leg never has to leave the body.
TROT_CROUCH = (1.0 - TROT_BOB_SHARE) * LEG_LENGTH * (1.0 - COS_SWING)
TROT_BOB_MAX = TROT_BOB_SHARE * LEG_LENGTH * (1.0 - COS_SWING)


def _trot_leg(phase):
    """(tilt in radians, paw lift in metres, in stance) for a leg whose own
    phase is 0 at touch-down in front. Stance: the paw moves back relative to
    the body at a constant rate. Swing: it eases forward and lifts."""
    phase %= 1.0
    if phase < 0.5:
        u = phase / 0.5
        return math.asin(SIN_SWING * (1.0 - 2.0 * u)), 0.0, True
    u = (phase - 0.5) / 0.5
    return (math.asin(-SIN_SWING * math.cos(math.pi * u)),
            TROT_PAW_LIFT * math.sin(math.pi * u), False)


def pose_trot(phase):
    """Front-left with hind-right touch down at phase 0, front-right with
    hind-left at 0.5."""
    pairs = {"FrontLeg_L": 0.0, "HindLeg_R": 0.0, "FrontLeg_R": 0.5, "HindLeg_L": 0.5}
    legs = {bone: _trot_leg(phase + offset) for bone, offset in pairs.items()}
    stance_tilt = next(t for t, _lift, stance in legs.values() if stance)
    bob = TROT_BOB_SHARE * LEG_LENGTH * (1.0 - math.cos(stance_tilt))
    drop = TROT_CROUCH + bob
    bob_n = bob / TROT_BOB_MAX if TROT_BOB_MAX > 0.0 else 0.0   # 0 at mid-stance, 1 at the swap
    s = math.sin(TAU * phase)
    pose = {
        "Hips": {"loc": (0.0, 0.0, -drop)},
        # the body rolls a little toward the planted front paw
        "Spine": {"rot": (0.0, 2.0 * s, 0.0)},
        # the head rises as the body sinks and sways against the tail
        "Neck": {"rot": (3.0 * bob_n - 2.0, 0.0, 0.0)},
        "Head": {"rot": (1.0, 0.0, -3.0 * s)},
        "Tail": {"rot": (8.0 - 5.0 * bob_n, 0.0, 10.0 * s)},
    }
    for bone, (tilt, lift, _stance) in legs.items():
        # Slide the leg along its axis so the paw sits exactly `lift` above the
        # ground: pivot height (rest - drop + slide) minus the tilted leg.
        slide = drop - LEG_LENGTH * (1.0 - math.cos(tilt)) + lift
        pose[bone] = {"rot": (math.degrees(tilt), 0.0, 0.0), "loc": (0.0, -slide, 0.0)}
    return pose


def pose_idle(phase):
    """Breathing on Spine (the chest rises 1.2 degrees and settles), a slow tail
    wag, a small head turn."""
    s = math.sin(TAU * phase)
    return {
        "Spine": {"rot": (0.6 * (1.0 - math.cos(TAU * phase)), 0.0, 0.0)},
        "Neck": {"rot": (1.0 * math.sin(TAU * phase - 0.6), 0.0, 0.0)},
        "Head": {"rot": (1.0 * math.sin(TAU * phase + 1.1), 0.0, 6.0 * math.sin(TAU * phase + 0.4))},
        "Tail": {"rot": (2.0 * math.sin(2.0 * TAU * phase), 0.0, 10.0 * s)},
    }


# --------------------------------------------------------------------------
# measurement
# --------------------------------------------------------------------------

def _set_frame(scene, frame):
    scene.frame_set(frame)
    update_depsgraph()


def _paw(armature, bone):
    """World position of `bone`'s tail (the sole) in the evaluated pose."""
    prev = enter_assets_scene()
    depsgraph = bpy.context.evaluated_depsgraph_get()
    evaluated = armature.evaluated_get(depsgraph)
    pb = evaluated.pose.bones[bone]
    point = evaluated.matrix_world @ pb.tail
    restore_scene(prev)
    return point


def measure_trot(armature, action, scene):
    """Sample the front-left paw over the trot. Returns (stride per cycle,
    stance sweep, worst stance height, highest swing height). The stride per
    cycle is the distance the body must cover in one cycle for the planted paw
    not to slide: the paw's backward sweep relative to the body over its stance,
    scaled by cycle / stance (the other pair carries the body the other half)."""
    armature.animation_data.action = action
    stance_frames = TROT_FRAMES // 2
    start = end = None
    worst_stance = 0.0
    highest = 0.0
    for frame in range(0, TROT_FRAMES + 1):
        _set_frame(scene, frame)
        paw = _paw(armature, "FrontLeg_L")
        if frame <= stance_frames:
            worst_stance = max(worst_stance, abs(paw.z))
        highest = max(highest, paw.z)
        if frame == 0:
            start = paw.copy()
        if frame == stance_frames:
            end = paw.copy()
    sweep = start.y - end.y
    stride = sweep * TROT_FRAMES / float(stance_frames)
    armature.animation_data.action = None
    reset_pose(armature)
    _set_frame(scene, 0)
    return stride, sweep, worst_stance, highest


# --------------------------------------------------------------------------
# assembly
# --------------------------------------------------------------------------

def main():
    scene = assets_scene()
    prev = activate_scene(scene)
    try:
        coll = model_collection("SF_Wolf")
        scene.render.fps = ANIM_FPS
        scene.render.fps_base = 1.0

        armature = build_armature("Wolf_Armature", WOLF_BONES, coll)
        body = build_wolf_body()
        link(coll, body)
        skin_to_armature(body, armature)
        update_depsgraph()

        top = world_bounds([body])[1].z
        overhead = add_empty("OverheadAnchor", (0.0, 0.0, top + OVERHEAD_CLEARANCE),
                             parent=armature, collection=coll)
        update_depsgraph()

        idle = author_action(armature, "idle", IDLE_FRAMES, pose_idle, step=KEY_STEP)
        trot = author_action(armature, "trot", TROT_FRAMES, pose_trot, step=KEY_STEP)
        _set_frame(scene, 0)

        stride, sweep, worst_stance, highest = measure_trot(armature, trot, scene)
        analytic = 4.0 * LEG_LENGTH * SIN_SWING
        if abs(stride - analytic) > 0.005:
            raise RuntimeError("trot stride %.4f m measured, %.4f m expected" % (stride, analytic))
        if worst_stance > 0.003:
            raise RuntimeError("trot: the planted paw leaves the ground by %.4f m" % worst_stance)
        clip_seconds = TROT_FRAMES / float(ANIM_FPS)
        print("SF_TROT  wolf leg=%.3f m swing=+/-%.1f deg sweep=%.4f m stride_per_cycle=%.4f m "
              "clip=%.3f s reference_speed=%.4f m/s stance_height<=%.4f m swing_lift=%.3f m "
              "crouch=%.4f m bob=%.4f m"
              % (LEG_LENGTH, TROT_SWING_DEG, sweep, stride, clip_seconds, stride / clip_seconds,
                 worst_stance, highest, TROT_CROUCH, TROT_BOB_MAX))

        groups = sorted(g.name for g in body.vertex_groups)
        print("SF_RIG   wolf bones=%s groups=%s actions=%s overhead=%s parent=%s"
              % ([b.name for b in armature.data.bones], groups,
                 [(a.name, tuple(a.frame_range)) for a in (idle, trot)],
                 tuple(round(v, 3) for v in overhead.matrix_world.translation),
                 overhead.parent.name))

        objects = [armature, body, overhead]
        report("wolf", objects)
        export_glb(objects, os.path.join(MODEL_DIR, "wolf.glb"), root_name="Wolf",
                   animations=True)
        render_preview(objects, os.path.join(PREVIEW_DIR, "wolf.png"),
                       elev_deg=12.0)

        armature.animation_data.action = trot
        _set_frame(scene, TROT_PREVIEW_FRAME)
        render_preview(objects, os.path.join(PREVIEW_DIR, "wolf_trot.png"),
                       elev_deg=12.0, yaw_deg=TROT_PREVIEW_YAW_DEG)
        armature.animation_data.action = None
        reset_pose(armature)
        _set_frame(scene, 0)
        overhead.name = "Wolf_OverheadAnchor"
    finally:
        restore_scene(prev)
    print("SF_WOLF DONE")


main()
