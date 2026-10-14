# Working on Day One Patch

Godot 4.4 GDScript project. The design doc (GDD) lives in the Claude project files at
`code-crusader/game-design-doc.md`; section numbers in comments (e.g. "GDD 8.3") refer to it.

## Rules of thumb
- Content is data. Prefer editing `data/**/*.json` over code. New mechanics should be expressible as data the code interprets (see `StatResolver`, `RoastDirector`).
- The host is authoritative. Anything that affects fairness (damage, HP, Morale, currencies, purchases, roast judging) runs where `multiplayer.is_server()` is true. Clients send `srv_*` RPCs and render state.
- Every RPC that a client can call is `@rpc("any_peer", "call_local", ...)` and checks the sender (`_from_owner()` / `_from_host()`).
- Scenes are built in code (see `Fx` helpers); keep it that way so diffs stay readable.
- Placeholder art only: primitives from `scripts/game/fx.gd`.
- Satire targets corporate behavior and public product outcomes, never real people.

## Before pushing
Run `tools/run_tests.sh <godot-binary>`. It must print `ALL CHECKS PASSED`. If you change gameplay flow, extend `scripts/game/autotest.gd` so the new behavior is exercised through the real network path.

## Gotchas
- Typed GDScript can't infer types from Dictionary/Variant values: write `var x: float = d.value`, not `var x := d.value`; use `maxf`/`minf` with `:=`.
- JSON numbers load as floats; cast with `int()` when comparing ids or counts.
- Controls under a `CanvasLayer` need `set_anchors_and_offsets_preset(PRESET_FULL_RECT)` or they stay 0×0.
- After adding a `class_name`, run `godot --headless --path . --import` once so the global class cache updates.
