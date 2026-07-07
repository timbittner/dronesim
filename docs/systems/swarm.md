# Swarm (P6)

Part of the DroneSim reference; see [PROJECT_SUMMARY.md](../../PROJECT_SUMMARY.md) for the index.

One player drone plus N physics-based followers flying formation. Everything is
built on the existing single-drone stack: followers are full `DroneController`s
(rotor-only forces, no magic — so future flight-model work applies to the whole
swarm), and the player-vs-follower split is just `@export var is_player` (group
`"player_drone"` for the camera/HUD/recorder; all drones stay in `"drone"` for
mission targets and radar).

### `scripts/swarm/swarm_manager.gd` — Roster + slot tables

WindField-pattern node (group `"swarm_manager"`, absent = no swarm). Spawns
`follower_count` drone+pilot pairs (deferred, after the leader joins its group),
each positioned into its slot **before** `add_child` so the controller captures
the right `_spawn_transform`. Owns:

- **Slot tables** — `get_slot_offset(i, heading)` returns the world-frame offset
  for role `i`: `LINE` (abreast, alternating sides), `V` (45° trailing wings),
  `RING` (evenly spaced circle), `BOHR` (electron-cloud shells 2/8/8/rest, each
  on a tilted orbital plane, inner shells orbiting faster — `_time`-driven, same
  controller). Heading-anchored for LINE/V, heading-independent for RING/BOHR.
- **The radio packet** — `get_leader_state()` returns `{position, velocity,
  heading}`, the **only** radio-side data in the swarm link. That's the design
  spine: pilots freeze this on packet loss (jam), but compute slot offsets
  locally, so a jammed follower keeps orbiting the last-known leader position.
- **Live tuning** — "Formation Gains" + "Pilot Tuning" export groups pushed into
  every pilot each physics tick (`apply_gains` + direct assignment), so the
  remote inspector tunes the swarm while it flies.
- **Commands** — `dispatch(point, target)` (nearest FORMATION follower),
  `land_all()`/`take_off_all()` (auto-land incl. a transient player pilot),
  `call_backup()` (spawn above the pad, `backup_cooldown`-gated),
  `ground_height(x,z)` (terrain duck-type for auto-land / cruise AGL).
- **Ground start (P6.5)** — the first 8 followers (and the player) spawn
  parked on the 2×2 pad (`PAD_CELLS`/`pad_slot()`); beyond that they spawn
  airborne straight in their formation slot (no pad room left). TAKE OFF
  launches everyone; `take_off_all()` first calls `_reassign_slots()`, a
  greedy nearest-(drone, slot) match within the taking-off group so a mass
  launch doesn't route two drones to opposite sides of the ring and crash
  them into each other mid-swap (best-effort, not a guaranteed-optimal
  assignment).

### `scripts/drone/flight_mode_formation.gd` — Follower autopilot

A real `FlightModeBase` computed from a **target pose**, not stick input —
feeding attitude setpoints into stabilized mode breaks down when the leader
flies acro, but a position-target autopilot is stable whenever the target path
is ("player stable ⇒ swarm stable"). Cascade: position error → desired velocity
(P + integral drift-trim + velocity feed-forward) → desired acceleration →
thrust-direction up-vector (tilt-clamped by `max_tilt`, which sets terminal
speed against drag, ~30 m/s at 1.0 rad) → stabilized-style restoring torque;
altitude PD with vertical feed-forward; heading PD → yaw torque. Two bypasses:
`landed` (idle throttle on the ground) and `strike` (kamikaze — see below).

**AGL sink-rate cap (P6.6)** — the altitude PD alone has no ground awareness:
a target far below the follower (e.g. a CALL BACKUP spawn 5 m over the pad
while the formation target sits down in a valley) drives collective to its
0.05 floor and free-falls. `ground_y` (terrain height under the drone,
pushed by `FollowerPilot` every tick from `_ground_below()`) feeds an AGL
figure the PD block doesn't otherwise have. After the PD computes
`result.collective`, a cap kicks in: `sink_cap = max(min_sink_rate, agl *
agl_sink_gain)` — high at altitude (long descents untouched), low near the
ground. If the actual descent rate exceeds the cap, collective is raised
(never lowered) to arrest it: `hover_throttle + (sink - sink_cap) *
sink_arrest_gain`. `landed` and `strike` both return before this block —
still exempt (a kamikaze strike is a deliberate powered dive, not a
free-fall to arrest).

### `scripts/swarm/follower_pilot.gd` — Per-follower behavior

One pilot node per follower (individual pilots, not a manager loop, so behaviors
prime per drone). Behavior enum `FORMATION / HOLD / DISPATCHED / LANDING /
LANDED / TAKEOFF / DOWN`. Each physics tick it writes the mode's onboard sensors
(always fresh) and, in FORMATION, the radio-side target (leader state + local
slot offset + offset-derivative feed-forward). `_receive_leader_state` runs the
same packet-loss dropout as the player's stick input, freezing the leader packet
stale. `_on_drone_crashed → DOWN` (a wreck; CALL BACKUP replaces it).

- **Dispatch** — cruise to the target at the dispatch-time AGL (terrain-
  following, floored at `observe_altitude` so it clears obstacles), then per
  type: OBSERVE / bare point → hover and loiter, then rejoin; CRASH → **kamikaze
  strike**.
- **Kamikaze glideslope run-in (P6.6)** — `_dispatch_aim()`'s cruise altitude
  for a live CRASH target is `min(cruise_alt, target.y + horiz * tan(dive_angle_deg))`,
  floored at `target.y + strike_altitude`: identical to the old flat cruise
  beyond the slope-intercept distance, but inside it the aim point drops onto
  a descending slope toward the target while still horizontally closing — no
  more flying directly overhead and nulling speed before the dive
  verticalizes. The floor means the glideslope now levels off at
  `strike_altitude` above the target instead of running down to its ground
  level, and a follower dispatched low climbs up to that floor first. Once
  the aim point is actually on the slope (not the flat cruise), `_fly_dispatch`
  also feeds the horizontal approach direction into `_mode.target_velocity`
  (vertical left at zero — the altitude PD's own D term against
  `current_velocity.y` already handles descent; guessing a vertical rate here
  would fight it) so the position cascade doesn't brake to a hover at the aim
  point.
- **Climb-to-strike-altitude gate (P6.6 fix)** — the terminal strike
  (`_strike()`) aims thrust straight AT the target with no tilt clamp; from
  low AGL and short range that vector is near-horizontal or even downward,
  so the attitude law rolls toward inverted with no room to recover and the
  drone tumbles into the ground. `_fly_dispatch` now requires
  `drone.global_position.y - target.y >= strike_altitude - 2.0` (a ~2 m
  tolerance) before EITHER commit path (the base `horiz_dist < dive_radius`
  or the earlier descending-and-aligned path below) is allowed to latch
  `_plunging` — a follower dispatched too low keeps flying the (now
  climbing) aim instead of committing until it has genuine vertical room.
- **Earlier strike commit (P6.6)** — `_fly_dispatch` still commits to the
  terminal dive inside `dive_radius` (once the altitude gate above is
  satisfied), but also commits earlier, out to `2 * dive_radius`, when
  velocity is already descending (`vel.y < -0.5`) and points within ~25° of
  the straight line to the target
  (`vel.normalized().dot(over.normalized()) > cos(25°)`) — lets the powered
  dive pick up exactly where the glideslope run-in left off instead of always
  waiting to cross inside `dive_radius`.
- **Kamikaze strike (powered dive, P6.5)** — once committed, `_mode.strike`
  aims the body-up vector straight at `strike_target` (refreshed live while
  the target exists) and holds full collective — no tilt clamp, deliberately
  reckless. Impact momentum clears the CRASH target on hit; `lose_signal()`
  after `STRIKE_TIMEOUT` remains a safety net for a dive that skims past
  instead of connecting. Still rotor-only — thrust is the weapon, not an
  applied impulse.
- **Auto-land** — `LANDING` freezes horizontal position + heading and ramps the
  target down at `descent_rate` to `ground_height`, cuts motors on touchdown
  (`LANDED`). The player lands too via a transient pilot (`setup_landing`) that
  saves nothing and hands the sticks back in **stabilized** at
  `release_altitude` AGL (a ground-level handoff dumped the player into the
  converging swarm); Triangle reset also releases it.
- **Stranded self-destruct (P6.6)** — a follower with all 4 rotors
  non-functional (`DroneController.all_props_disabled()` — every
  `_prop_state[i] != 0`, obstructed or broken; e.g. tumbled upside-down on a
  field after a prop-obstruction tumble) for longer than `stranded_timeout`
  (default 10 s) is immovable dead weight. The timer only runs during active
  flight (FORMATION/DISPATCHED) — it's skipped entirely for
  LANDING/LANDED/TAKEOFF/DOWN, so a parked pad drone never counts toward it,
  and it resets to 0 the instant any rotor recovers. On timeout: `lose_signal()`
  (dead radio, same rotor-only crash path), behavior → `DOWN`, then
  `SwarmManager.remove_follower(pilot)` drops it from `pilots` and frees both
  drone and pilot — no litter wreck sitting on the field, and CALL BACKUP can
  replace the slot. Other pilots' `slot_index` are left as-is (a gap is fine).
  Player auto-land is out of scope (follower-only).

### `scripts/ui/pad_menu.gd` — DPad command menu

Hand-built `CanvasLayer` (Forza-pit-strip style, lower-left, HUD palette). DPad
left/right opens; up/down selects; left/right stages a cycle value; Cross applies
all staged + fires the selected action; Circle aborts. Entries are a data array
of cycle `{label, options, getter, setter}` or action `{label, kind:"action",
action}` dicts — labels may be Callables for live text (backup cooldown
countdown, AUTO-LAND ↔ TAKE OFF toggle). Closed, DPad up/down sweeps the FPV
cam tilt. Dead while the player is CRASHED. **HUD submenu (P6.5)** — one entry
descends into a nested list (LOG/TELEMETRY/WIND/GIZMO/AXES/ATTITUDE toggles);
BACK pops.
A small `_stack` of parent-level frames is the only new state.

### Dispatch reticle — `DebugHUD` (P6 additions)

In FPV, `_physics_process` raycasts from the camera through screen center to the
ground; `_on_reticle_draw` shows a crosshair + distance at the hit, amber with a
ring when a `MissionTarget`'s radius covers it. Square (`dispatch_follower`)
sends `SwarmManager.dispatch(hit, target)`. Periodic `[HUD]` console telemetry is
now behind `console_telemetry` (default off — the FlightRecorder JSONL is the
record). **Dispatch marker (P6.5)** — a cyan triangle tracks any DISPATCHED
follower (apex up/down by altitude relative to the player), pinned to the
screen edge when off-view or behind the camera, labeled with its follower
number. **On-screen event log (P6.5)** — `DebugHUD.log_line()` mirrors
`SwarmManager._log()`'s console prints to a bottom-right panel (last 8 lines)
so web builds without a console can see swarm/dispatch activity. **Attitude
indicator (P6.6)** — `_on_attitude_draw` draws a classic instrument-style
artificial horizon (bare white line work, no panel/background) centered on
screen, FPV-only (`_drone.is_fpv_enabled()` gate, same as the reticle). Reads
the airframe's own pitch/roll from `_drone.global_transform.basis.get_euler()`
directly — camera tilt is deliberately ignored, it's an instrument, not a
world-locked overlay. A fixed center winged-W marks the airframe's boresight;
the horizon + ±10/20/30° pitch ladder rotate with roll and offset vertically
with pitch (`ATTITUDE_PX_PER_DEG = 4.0`, tweakable), clipped to
`ATTITUDE_LADDER_RADIUS` so it stays a compact instrument. Toggle:
`show_attitude` (HUD submenu ATTITUDE entry), on by default, zero draw cost
when off or outside FPV.

### `scripts/test/swarm_test.gd` — Swarm Headless Test Harness (P6)

17 tests: slot-table math per formation, control-law signs, integral drift-trim,
pilot dropout freeze, velocity feed-forward, pad-menu state machine (incl. HUD
submenu descend/back), dispatch selection + per-type aim + powered-dive
arming, backup cooldown, player auto-land handoff, pad-slot spacing, six
bounded flight tests (a follower ground-starts then holds/reconverges;
auto-land settles + takes off; kamikaze impact clears a CRASH target; kamikaze
glideslope arrives already descending on a slope — not just `vel.y < 0` —
before crossing inside `dive_radius`, sampled from a high dispatch altitude so
the slope has room to bite; a follower dispatched from LOW AGL close to a
CRASH target climbs to `strike_altitude` above it — polled via `_plunging`
staying false until the drop is gained — before ever committing to the dive,
and still clears the target), and a stranded-follower self-destruct test
(P6.6 — all 4 rotors force-disabled past a shortened `stranded_timeout` ends
with the pilot removed from `m.pilots`).

Run: `godot --headless --path . scenes/test/swarm_test_scene.tscn`
