# Shared Fate (The Bound Three)

Godot 4.7 isometric CRPG. Read `CODEBASE_GUIDE.md` for the 2D architecture before touching gameplay code.

## Branch `feat/3d-test`: the 3D port

The 3D version is being built beside the 2D game, never on top of it. Plan: `docs/3d-test-plan.md`. Conventions and contracts every 3D package must follow: `docs/3d-port-contracts.md`.

Rules on this branch:

- 2D scripts, scenes and assets are read-only. New code goes under `scripts/3d/`, `scenes/3d/`, `assets/3d/`, `tools/blender/`.
- Only the shared files named in the contracts document may be edited, and only additively (new optional parameters, widened types, new methods, new guarded branches).
- 1 unit = 1 m, +Y up, ground at y = 0, characters face local -Z. 2D y becomes 3D z. All conversions go through `GroundMath`; never inline them.
- Actors are called duck-typed from the coordinator; keep the method names in the actor contract exactly.
- Before finishing: run the headless checks in the contracts document (section 11) and `git diff --stat 2d-baseline -- scenes scripts`; only `3d` paths and the allowed additive files may appear.
- Stay inside the files your work package owns. If another file needs a change, write it in the deviations log of the contracts document and stop.

## Working notes

- The repository is checked out with `core.autocrlf=true`; hundreds of `.import` files show as modified from line endings alone. Do not stage them.
- `blender/` holds Blender source files (`knight_lowpoly.blend`).
