# WP6 deviations log

Deviations from `docs/3d-port-contracts.md` found while implementing world items
(`ItemPickup3D`, the `LootDropper`/`LootMenu` 3D branches, and the pickup test scene).

## 1. `LootDropper.drop_items` 2D branch is not literally byte-for-byte identical

The work order asked for the 2D branch of `LootDropper.drop_items` to stay
byte-for-byte identical after widening `source` from `Node2D` to `Node`. That
turned out to be impossible under GDScript's static typing: `Node` has no
`global_position` member (only `Node2D`/`Node3D` declare it separately), so
`var origin := source.global_position` does not compile once `source` is
typed `Node`.

The minimal fix was to inline a cast on that one line:
`var origin := (source as Node2D).global_position`. Every other line in the
2D branch — the null guards, the parent lookup, the scene load, the ring loop,
the deferred spawn calls — is untouched. Diff-wise this is one changed line
plus the widened parameter type and the new `if source is Node3D: ...; return`
branch prepended above it; everything else is a pure addition.

## 2. `LootMenu` internal storage widened beyond `request_loot`'s signature

The work order named `request_loot(pickup, looter)` and `open_for(pickups, looter)`
as the touch points, but making a 3D `ItemPickup3D` pile actually work end to
end required widening every place that stores or types a pickup, not just the
two public entry points:

- `_pile`, `_shown`: `Array[Node2D]` -> `Array[Node]`
- `_selected`, `_pending_pickup`: `Node2D` -> `Node`
- `_take`, `_neighbour_of`, `_filtered_pile`, `_build_slot`, `_on_slot_pressed`,
  `_on_slot_gui_input`, and the local `live` / `matching` arrays in
  `_prune_pile` / `_filtered_pile`: `Node2D` -> `Node`
- `open_for`'s merge loop cast `pickup as Node2D` -> `pickup as Node`, which
  was the one line that would otherwise have silently dropped every
  `ItemPickup3D` from the pile (a `Node3D` failing an `as Node2D` cast becomes
  `null` and is skipped)

None of these needed a 3D/2D branch — they hold pickups generically and never
touch a 2D-specific member, so widening the type was the whole change. Only
`_in_loot_range` needed an actual branch (added, computing
`GroundMath.ground_distance(...) <= LOOT_RANGE_M` when both sides are `Node3D`,
otherwise the original `LOOT_RANGE` check via `Node2D` casts). This is
consistent with the work order's own instruction to "audit `_process` /
`_input` for `Node2D` casts ... and branch them the same way" — the audit
found the casts lived one level down, inside `_in_loot_range`, not in
`_process`/`_input` themselves (which already delegate to it and needed no
changes).

## 3. `ItemPickup3D.gather_pile()` return type

The contract text (section 8) writes `gather_pile() -> Array` (untyped), which
is what `ItemPickup3D` implements, matching the work order's explicit
signature. The 2D `ItemPickup.gather_pile()` returns `Array[Node2D]`; the 3D
version intentionally does not use `Array[ItemPickup3D]` either, to match the
literal signature given.

## 4. Pickup test: "gone next frame" interpreted as "gone after the collect animation"

`ItemPickup3D.take()` mirrors the 2D pickup's collect animation: `_claimed`
flips (and the item lands in the inventory) synchronously inside `take()`,
but the node itself is only `queue_free()`d after a `COLLECT_ANIM_SECONDS`
(0.18 s) tween, exactly like `scripts/item_pickup.gd`. `scripts/3d/tests/pickup_test.gd`
checks the inventory immediately (synchronous) and then polls
`is_instance_valid()` for up to 30 frames (well under the animation length at
a real frame rate, and comfortably inside the scene's overall frame budget)
before asserting the pickup is gone, rather than checking exactly one frame
later. Freeing it truly on the next frame would have meant dropping the
collect animation, which the work order's part A explicitly asked for
("plays a short collect animation, frees itself").
