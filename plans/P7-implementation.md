# P7 — Missions, NPCs, Scenario Backups

## Context

P7 (feature spec: `plans/P7-missions.md`) makes the sim presentable/fun: a mission-objective HUD, payload physics + a DELIVER target type, no-fly zones, a visible interceptor behind the P5 shoot-down stub, adversary drones, and scenario-based backup inventory. P5/P6 left deliberate slot-in points for all of this (extensible `MissionTarget.Type` enum, one-line `lose_signal()` in `airspace_control.gd:71`, `JammingNode` as the documented no-fly-zone primitive, `FollowerPilot`/kamikaze machinery reusable as NPC brains).

**Agreed with user:** 3 PRs on sequential branches (`p7.1-missions` → `p7.2-npcs` → `p7.3-backups`); no-fly zones get a JAMMING/SHOOT_DOWN mode switch; payload is a real dropped RigidBody; interceptor kills by proximity (explosion sim), adversary drones by physical ram; both use a vision cone the player can evade — except inside no-fly zones, where tracking is automatic; backup pool covers CALL BACKUP **and** player crash-respawn, empty pool + crash = MISSION FAILED; NPC traffic (vehicles) stays in the backlog.

Branches are sequential because 7.2 edits files 7.1 creates (`no_fly_zone.gd`, `debug_hud.gd`) and 7.3 touches 7.2's files. Per project convention: ask before opening each PR into `main`.

**Plan file handling:** this plan lives as a single `plans/P7-implementation.md` (committed as the first commit on `p7.1-missions`), riding through all three sequential branches — no per-PR split (the shared file map/conventions would just be duplicated 3×). `plans/P7-missions.md` stays the feature spec; both get trashed when P7 completes.

---

## PR 7.1 — Missions (`p7.1-missions`)

**New:** `scripts/mission/no_fly_zone.gd` (+ `scenes/mission/no_fly_zone.tscn`), `scripts/mission/payload.gd` + `scenes/mission/payload.tscn` with **Blender-authored geometry**: `assets/models/payload.blend` → `payload.glb` (jammer.blend precedent; export via Blender MCP), mesh visible/inspectable in the editor. Drop instantiates `payload.tscn`.
**Modified:** `mission_target.gd`, `drone_controller.gd`, `debug_hud.gd`, `pad_menu.gd`, `mission_test.gd` + its scene, `main.tscn`.

### Mission HUD panel
`debug_hud.gd`: ColorRect+Label panel below the telemetry box, one row per group `"mission_targets"` member (type name; ✓ CLEARED / OBSERVE dwell `2.1/3.0s` / distance `▸ 240m`). Iterate the group directly (compass already does at ~:945) — **zero MissionTracker changes**. `show_missions` toggle + one entry in `pad_menu._build_hud_entries()`.

### NoFlyZone
`@tool` Node3D, jamming_node ground-snap pattern; exports `enum Mode { JAMMING, SHOOT_DOWN }`, `radius`, `countdown_time`, `terrain_path`. Always joins group `"no_fly_zones"` (HUD banner + 7.2 auto-track; absent = neutral).
- **JAMMING:** also joins group `"jammers"` with `var strength := 1.0` — SignalField duck-types `strength`/`radius` (`signal_field.gd:75-78`), so **signal_field.gd unchanged**.
- **SHOOT_DOWN:** zone owns its own per-drone countdown dict (~30-line copy of `airspace_control.gd:43-78` pattern, condition = horizontal distance ≤ radius); expiry calls `drone.lose_signal()` (7.2 swaps this line for the SAM launch). Don't extend AirspaceControl — orthogonal trigger, duplication beats abstraction here.
- HUD: second banner label styled like the radar one (below the radar banner) reading `.tracking/.seconds_left` off zones — both banners can be live at once. Visual: translucent red cylinder — this is a volume *gizmo*, not a prop, so code-built like `mission_target.gd::_build_marker` is fine (props are Blender-authored, gizmos/markers stay code-built).

### Payload physics
While attached there is **no separate physics body** (jointed body under a 2 kg quad = solver pain, zero benefit): on `DroneController`:
```gdscript
@export var payload_mass: float = 0.5
@export var payload_offset: Vector3 = Vector3(0, -0.12, 0)  # belly, local
var has_payload := false
```
- `load_payload()`: guard `is_landed()`; attach the payload GLB mesh as a child at offset; `mass += payload_mass`; `center_of_mass_mode = CUSTOM`, `center_of_mass = payload_offset * (payload_mass / mass)`; `_recompute_hover()`.
- `drop_payload()`: free mesh, restore mass, `center_of_mass_mode = AUTO`, `_recompute_hover()`, spawn `Payload` at world attach point with `linear_velocity = self.linear_velocity` into the drone's parent.
- Rotor-only preserved: nothing pushes the drone, the same four rotor forces just work harder. Doc note: `crash_momentum_threshold` is mass-relative → loaded drone crashes at ~3.2 m/s instead of 4 — physically honest, keep.
- **`_recompute_hover()`** (the critical bit — `hover_throttle` is currently computed once in `_ready` :226 and copied into modes :232/:240):
```gdscript
func _recompute_hover() -> void:
    hover_throttle = (mass * _gravity) / (4.0 * max_thrust)
    _altitude_hold.hover_throttle = hover_throttle
    for m in _flight_modes.values():
        if "hover_throttle" in m:
            m.hover_throttle = hover_throttle
```
The dict loop covers `_stabilized` and any externally installed formation/auto-land mode (`set_flight_mode_object` :803 registers into `_flight_modes`). Followers never carry payloads → no SwarmManager change.
- **`is_landed()`**: no landed state exists on the controller (P6.5 start-landed lives in SwarmManager's transient pilot — wrong home). Add: `_state == State.FLYING and _body_in_contact and linear_velocity.length() < 0.3` (`_body_in_contact` maintained at :410).
- **`Payload`** (RigidBody3D): `contact_monitor = true`, contact + `linear_velocity < 0.5` for 0.3 s → `landed = true`; group `"payloads"`; no signal — DELIVER target scans the group per tick (matches how OBSERVE/CRASH already work).
- **Menu entry** (root, after CALL BACKUP): one action with live Callable label — `DROP PAYLOAD` / `LOAD PAYLOAD` / `LOAD PAYLOAD (land first)`.

### DELIVER target
`mission_target.gd`: add `Type.DELIVER`; convert `_build_marker` if/else (:145-173) to `match` (amber drum marker); in `_physics_process`: not-cleared DELIVER scans group `"payloads"` for `landed` within horizontal `radius` → `_mark_cleared()`.

### main.tscn (editor)
Place 1–2 NoFlyZone instances + 1 DELIVER target.

### Tests (extend `mission_test.gd`)
1. JAMMING zone → `SignalField.get_quality` ≈0 at center, ≈1 beyond rim.
2. SHOOT_DOWN zone, `countdown_time = 0.2`, drone inside → crashed; outside → untouched.
3. `load_payload()` updates mass + hover_throttle pushed into `_stabilized`/`_altitude_hold`/installed modes; drop restores; mid-air load refused.
4. Drop from height → Payload inherits velocity, `landed` on ground after bounded frames.
5. DELIVER clears on landed payload inside radius; not outside.

### Commits
1. `feat:` mission HUD panel + menu toggle → 2. `feat:` NoFlyZone JAMMING (+test 1) → 3. `feat:` SHOOT_DOWN countdown + zone banner (+test 2) → 4. `feat:` payload physics + menu entry (+tests 3–4) → 5. `feat:` DELIVER type (+test 5) → 6. `docs:` P7.1.
New class_names → `godot --headless --path . --import` before `./run_tests.sh`.

---

## PR 7.2 — NPCs (`p7.2-npcs`)

**New:** `scripts/util/vision.gd` (static helper), `scripts/mission/interceptor.gd` + `scenes/mission/interceptor.tscn`, `scripts/mission/sam_site.gd` (+ `scenes/mission/sam_site.tscn`), `scripts/swarm/adversary_pilot.gd`, `scripts/swarm/adversary_spawner.gd`, `scripts/test/npc_test.gd` + scene, wired into `run_tests.sh`.
**Blender geometry:** interceptor missile and SAM launcher get Blender-authored meshes (`assets/models/interceptor.blend`/`sam_site.blend` → GLBs, or one shared blend — decide at impl), inspectable in the editor scenes; adversary drones reuse `drone.tscn` (existing GLB) with a red hostile tint.
**Modified:** `airspace_control.gd`, `no_fly_zone.gd`, `drone_controller.gd`, `crash_effects.gd`, `debug_hud.gd`, `swarm_manager.gd`, `follower_pilot.gd`, `main.tscn`.

### Hostile group split
Verified `"drone"` consumers: `airspace_control.gd:44` (would SAM friendly-fire hostiles — wrong), `mission_target.gd:75` (hostile could clear player objectives — wrong), `crash_effects.gd:21` (dust — wanted), `pad_menu.gd` axes (cosmetic). 3 of 4 must exclude → keep hostiles **out** of `"drone"`: `@export var is_hostile := false`; `_ready` does `add_to_group("hostile" if is_hostile else "drone")`. CrashEffects gets one extra loop over `"hostile"`. SignalField jamming still degrades hostiles for free (per-controller, not group-based).

### Vision helper
```gdscript
class_name Vision
static func can_see(observer, forward, target, fov_deg, max_range) -> bool
static func in_any_no_fly_zone(pos) -> bool  # scan group "no_fly_zones", absent = false
```
Order: range → angle → single `intersect_ray` observer→target excluding both bodies (only when inside cone) — the ray makes "duck under a hill to escape" work (OsmTerrain has colliders; FPV reticle ray proves it). Callers: `in_any_no_fly_zone(player.pos) or can_see(...)` = zone auto-track.

### Interceptor (ground-to-air, proximity kill)
RigidBody3D **rocket**, not a quad, not kinematic: one `apply_force(-basis.z * thrust)` + steering torque toward LOS (reuse the axis-angle restoring-torque shape from `flight_mode_formation.gd::_strike` :194-215) + angular damping. Physically honest in ~30 lines; a hard jink makes it visibly overshoot. Exports: `thrust`, `steer_p_gain`, `steer_d_gain`, `proximity_radius` (~3 m), `fov_deg` (~60), `lock_range` (~250), `lock_memory` (~2 s), `max_flight_time` (~20 s, runaway net). Proximity → `victim.lose_signal()` (fuse-explosion sim; victim's `crash_detected` gives dust for free) + `queue_free()`. Cone lost for `lock_memory` (bypassed while victim in a no-fly zone) → self-destruct. Not in any drone group.

### SamSite + launch trigger
`@tool` ground-snap, group `"sam_sites"`, `reload_time` export, `launch(target)`. Static `SamSite.engage(tree, target) -> bool` (nearest ready site launches; false if none). Swap the two countdown-expiry `drone.lose_signal()` calls — the one in `AirspaceControl._update_drone()` (the slot-in point its class comment reserves) and the one in NoFlyZone SHOOT_DOWN — to `if not SamSite.engage(get_tree(), drone): drone.lose_signal()`. **Absent SAM = old instant behavior.** SAM launch itself needs no cone — the radar/zone countdowns are the "you were warned" trigger; the cone governs the missile in flight.

### Adversary drones (air-to-air, physical ram)
- `AdversarySpawner` (plain Node3D in main.tscn, SwarmManager precedent): exports `count`, `patrol_radius/speed/altitude`, `fov_deg`, `detect_range`, `ram_radius`, `lost_lock_time`; `_spawn_one` mirrors `swarm_manager.gd:153` (position BEFORE add_child; `drone.tscn` with `is_player=false, is_hostile=true`). Optional: red tint in a hostile branch of `_setup_visuals`.
- `AdversaryPilot` (FollowerPilot skeleton, no radio side — all onboard): installs `FlightModeFormation` via `set_flight_mode_object`; states PATROL → CHASE → RAM → DOWN.
  - Detect: zone auto-track OR `Vision.can_see` with nose direction **flattened to horizontal** (airframe pitch shouldn't strobe the cone).
  - CHASE: `target_position = player.global_position`; within `ram_radius` → RAM: existing powered-dive strike aimed at the player — the mid-air collision trips momentum-based crash detection on both airframes, **no magic damage**. Whiffed ram (strike timeout) → back to CHASE (retry, not lose_signal).
  - Cone lost `lost_lock_time` → PATROL. Own `crash_detected` → DOWN, terminal (7.3 attrition free).
- **Killable by the swarm:** debug_hud reticle ray — collider in group `"hostile"` → crosshair alert-red; Square → `swarm.dispatch_hostile(hostile)` → nearest FORMATION pilot rides the existing kamikaze path with `strike_target = _hostile.global_position` per tick (~25-line variant in `follower_pilot.gd`).

### Tests (`npc_test.gd`, new suite)
1. Cone math in/out of angle+range; occlusion via StaticBody box. 2. In-zone target tracked despite cone miss. 3. Interceptor proximity kill → victim crashed, missile freed. 4. Lost lock → self-destruct, target alive. 5. `engage` false with no site (fallback path), Interceptor appears with one. 6. Adversary detect→CHASE, hidden→PATROL. 7. RAM crashes player via real collision (bounded-flight style).

### Commits
1. `feat:` Vision helper (+tests 1–2) → 2. `feat:` hostile group split + dust → 3. `feat:` Interceptor + SamSite + expiry swap (+tests 3–5) → 4. `feat:` adversary spawner + pilot (+tests 6–7) → 5. `feat:` hostile kamikaze dispatch → 6. `docs:` P7.2.

---

## PR 7.3 — Scenario backups (`p7.3-backups`)

**Modified only** (no new files — SwarmManager already owns `call_backup`, MissionTracker owns run end-state):
- `swarm_manager.gd`: `@export var backup_pool := 3` (tests set it explicitly); `call_backup()` refuses at 0 else decrements; leader `crash_detected` → `_leader_down`; leader reset while `_leader_down` consumes one; leader crash at pool 0 → tracker `fail("no backups left")`.
- `mission_tracker.gd`: `signal mission_failed`, `var failed`, `func fail(reason)` — idempotent, no fail after `completed`. Resolved lazily via group `"mission_tracker"`; **absent tracker = sandbox, no fail state**.
- `debug_hud.gd`: `_update_mission_banner` also reads `tracker.failed` → same label, `MISSION FAILED`, `HUDTheme.ALERT`.
- `pad_menu.gd`: CALL BACKUP live label → `CALL BACKUP (2 left)` / `NO BACKUPS`.
- Judgment call: Triangle reset stays allowed at pool 0 (MISSION FAILED is a scoring state, not a lockout — blocking reset would strand the session).
- Adversary attrition: already free (DOWN is terminal) — docs note only.

### Tests (extend `swarm_test.gd`)
1. Pool 1: first `call_backup()` true, second false. 2. Crash→reset consumes pool; clean reset doesn't. 3. Pool 0 + crash → `tracker.failed`, `mission_failed` emitted once.

### Commits
1. `feat:` finite backup pool (+tests 1–2) → 2. `feat:` MISSION FAILED state + banner (+test 3) → 3. `docs:` P7.3 + delete `plans/P7-missions.md` (confirm with user first, per plan-lifecycle convention).

---

## Cross-PR file map (rebase awareness)

| File | 7.1 | 7.2 | 7.3 |
|---|---|---|---|
| `no_fly_zone.gd` | creates | expiry line | — |
| `airspace_control.gd` | — | expiry swap | — |
| `debug_hud.gd` | panel + zone banner | hostile reticle | failed banner |
| `pad_menu.gd` | payload entry | — | backup label |
| `swarm_manager.gd`/`follower_pilot.gd` | — | dispatch_hostile | pool |
| `drone_controller.gd` | payload, is_landed | is_hostile group | — |

7.3 has no hard code dependency on 7.2 (could branch off 7.1 if 7.2 stalls).

## Docs per PR
- **7.1:** AGENTS.md (phase blurb, controller table payload entry, file map), PROJECT_SUMMARY index, `docs/systems/gamification.md` (NoFlyZone, DELIVER, panel, zone banner contract), `flight.md` (payload mass/CoG, `_recompute_hover`, crash-threshold note), `tuning.md`.
- **7.2:** AGENTS.md (blurb, file map, terse invariant: *hostiles are NOT in group "drone"; "drone" consumers assume friendly*), gamification.md (SAM/interceptor/vision cone), swarm.md (AdversaryPilot, hostile dispatch), tuning.md.
- **7.3:** AGENTS.md (blurb, backup label in controller table), gamification.md + swarm.md, PROJECT_SUMMARY index; delete `plans/P7-missions.md` last.
- Gotchas each PR: no bare `[...]` in `##` comments (docs CI); signals past-tense; `--import` after new class_names; ask before any push/PR to `main`.

## Verification & validation gates
- Per feature step: `./run_tests.sh` (after `godot --headless --path . --import` when class_names were added), **then pause for Tim's manual in-editor/controller validation before committing** — every commit in the orders above is gated on his sign-off, not just green tests (payload handling feel, cone evasion, ram/interceptor behavior, HUD readability are his calls). Commit only meaningful validated changes.
- Telemetry JSONL in `user://telemetry/` for post-flight checks.
- Line numbers cited in this plan are orientation hints from exploration, not anchors — locate the actual code by the described function/comment when implementing.
