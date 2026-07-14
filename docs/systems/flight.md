# Flight Systems

Part of the DroneSim reference; see [PROJECT_SUMMARY.md](../../PROJECT_SUMMARY.md) for the index.

### Three-Layer Flight Pipeline

```
FlightMode.compute()  →  FlightControl(collective, pitch_diff, roll_diff, yaw_torque)
DroneController._mix_rotors()  →  RotorMix(fl, fr, bl, br)  ← anti-clip scaling
Physics: apply_force() at 4 rotor positions + apply_torque() for yaw
```

### `scripts/drone/drone_controller.gd` — Core Controller

`DroneController extends RigidBody3D`. Physics loop:
```
_read_inputs()           → reads 4 axes + altitude_hold/brake_mode from InputMap
_compute_and_apply_forces(delta)  → mode → altitude-hold filter → brake tilt add-on → mixer → rotor forces + yaw torque
_apply_angular_damping() → per-axis damping (0.08 pitch/roll, 1.0 yaw)
```

Hover throttle per-rotor: `(mass * gravity) / (4 * max_thrust)`.

Static `_mix_rotors(collective, pitch, roll)` handles anti-clip scaling and
MIN_ROTOR (0.02) protection, in two stages (the same approach real flight-
controller mixers use): clip the differential only if `|pitch| + |roll|`
exceeds `min(collective - MIN_ROTOR, (1.0 - MIN_ROTOR) / 2)` — the second
term is the max spread achievable by *shifting*, see next — then, if the
resulting mix's highest rotor still exceeds 1.0 (only possible at high
collective), shift **all four rotors down uniformly** by the overshoot. This
trades a little collective (climb rate) for full pitch/roll authority near
100% throttle, instead of the differential collapsing to zero the instant
any single rotor would exceed 1.0 (the original behavior — full differential
was impossible at 100% throttle because it required equal headroom to raise
*and* lower rotors around the exact commanded collective; shifting only
needs headroom to lower). Shifts only ever go down, never up, so a centered
stick still gets exactly `collective` on all four rotors — max climb rate at
full throttle is unaffected. Early-returns all zeros if collective < 0.001
(throttle cut kills motors).

**Crash / signal loss (Phase C):** two states, `FLYING` / `CRASHED`. Detection
lives in `_integrate_forces` (not `body_entered` — that signal carries no
contact normal): requires `contact_monitor = true` + `max_contacts_reported = 4`
on the RigidBody3D (set in `drone.tscn`, along with `continuous_cd = true` —
without CCD the 0.12m-thin drone tunnels straight through thin geometry above
~10 m/s, which fast dives easily exceed). A contact crashes iff impact momentum
(`_prev_velocity.length() * mass`, previous-tick velocity since the solver has
already absorbed the impact by report time) exceeds `crash_momentum_threshold`
(8 kg·m/s ≈ 4 m/s — the spawn free-fall onto the pad arrives at ~6.1, so the
threshold must stay above that) **and** the hit is direct (angle between
−velocity and contact normal
within `crash_max_impact_angle_deg`, 60°); slow or grazing contacts bounce. A
near-zero-velocity guard covers resting contact on the spawn pad. On crash:
state → CRASHED, `crash_detected` emitted, inputs zeroed, rotor visuals to idle.
While CRASHED, `_physics_process` skips inputs/forces/damping — gravity and
inertia tumble the airframe naturally (no magic forces). Only `reset_drone`
(Triangle) and `toggle_fpv` (R1 — the camera belongs to the pilot, not the dead
drone) are handled; `toggle_flight_mode` is ignored. `reset()` restores FLYING.

**Prop obstruction (P6.6)** — a rotor whose prop disc is clipped by terrain or
another drone body loses thrust, so the remaining rotors' asymmetric forces
tumble the airframe naturally (still rotor-only, no magic torque). State
machine per rotor, `_prop_state` (order `[FL, FR, BL, BR]`, matching
`_rotor_positions`): `0` free, `1` obstructed (transient — recomputed every
tick from the query), `2` broken (latched until `reset()`). Only queried
while armed AND flying (`_compute_and_apply_forces` skips the whole query when
`control.collective < 0.001` — a parked/landed pad drone does zero shape
casts, not just zero-force rotors). Each armed tick, a shared `CylinderShape3D`
(radius `prop_radius`, default 0.12 m; thickness `prop_disc_height`, default
0.04 m — Godot's cylinder axis is +Y, matching the prop disc's body-up
normal) is cast via `PhysicsShapeQueryParameters3D.intersect_shape` at each
rotor's world position (`global_transform * _rotor_positions[i]`), oriented
with the drone's own basis (`Transform3D(global_transform.basis, world_pos)`)
so the thin disc tilts with the airframe instead of always querying straight
down — a banked drone catches the ground/an obstacle at the disc's rim, not
through an isotropic sphere's vertical over-reach. Excludes the drone's own
RID. A rotor with any hit → state 1 that tick (thrust zeroed in the force
loop, `last_mix` zeroed to match so telemetry reflects reality); no hit →
state 0. Yaw torque is scaled by the fraction of still-live rotors
(`live_rotors / 4.0`), so a dead prop also degrades yaw authority, not just
lift. **Permanent break** — a rotor transitioning 0→1 while its commanded
throttle exceeds 0.5 AND the previous-tick impact speed
(`_prev_velocity.length()`) exceeds `prop_break_speed` (default 3.0 m/s)
latches state 2: the blur-disc visual swaps back to the idle Blender prop
(same mechanism as `_set_armed()`, but per-rotor and permanent) and, if a HUD
(group `"debug_hud"`) is reachable, logs `"PROP <FL/FR/BL/BR> OUT"` to both
console and the on-screen event log. `reset()` clears the whole array to 0
and restores all rotor visuals. ponytail: the query is 4 shape casts per
armed drone per physics tick — O(4·N_armed) for the whole swarm; intentional
for now given how cheap sphere casts are, with two upgrade paths if
profiling ever flags it: gate on a has-contacts flag set from
`_integrate_forces`, or a coarse broad-phase pass before the per-rotor query.
Known limitation: this is a single thin-cylinder approximation of the whole
disc's sweep (not a per-blade check), centered at the rotor hub.

**Debug visualization** — `show_prop_debug` (default off, inspector or the
HUD submenu's "PROP DBG" toggle via `PadMenu`, group `"player_drone"`) draws
the exact query shape at each rotor as a child `MeshInstance3D` with a
`CylinderMesh` sized identically to `_prop_query_shape` (so what's drawn IS
the hitbox), tinted by `_prop_state[i]` each tick (free = cyan, obstructed =
amber, broken = red). Meshes are lazily built on first enable and freed the
moment the flag goes false — zero cost while off, since `_update_prop_debug`
is only ever called from behind `if show_prop_debug`.

**Payload (P7.1)** — `payload_mass` (0.5 kg) and `payload_offset` (belly,
local, `(0, -0.12, 0)`) exports; `has_payload: bool` survives `reset()` (a
reset is loadout, not damage — only `drop_payload()` clears it). While
attached there is **no separate physics body** — a jointed body under a 2 kg
quad is solver pain for zero benefit — it's mass + CoM math on the airframe
itself:
- `is_landed()` — `_state == FLYING and _body_in_contact and
  linear_velocity.length() < 0.3`. `_body_in_contact` is already maintained
  by the crash-detection contact monitor above; this just reads it.
- `load_payload()` — refuses if `has_payload` or not `is_landed()` (no
  clipping a crate onto a mid-air drone with a magic force to hold it there).
  Attaches the payload GLB as a child at `payload_offset`, adds `payload_mass`
  to `mass`, switches `center_of_mass_mode` to `CUSTOM` with `center_of_mass =
  payload_offset * (payload_mass / mass)` — the airframe's own CoM is ≈origin,
  so this is just the payload's lever arm scaled by its share of the new
  total mass — then calls `_recompute_hover()`.
- `drop_payload()` — frees the mesh, restores `mass` and `center_of_mass_mode
  = AUTO`, calls `_recompute_hover()`, and spawns a free `Payload` RigidBody
  (`scripts/mission/payload.gd`) at the world attach point with
  `linear_velocity = self.linear_velocity` — it just falls, no impulse,
  rotor-only physics stays intact — plus a brief collision exception against
  this body so it doesn't spawn-overlap-pop.
- **`_recompute_hover()`** — the critical bit, since `hover_throttle` is
  normally computed once in `_ready` and copied into each mode at
  construction:
  ```gdscript
  func _recompute_hover() -> void:
      hover_throttle = (mass * _gravity) / (4.0 * max_thrust)
      _altitude_hold.hover_throttle = hover_throttle
      for m in _flight_modes.values():
          if "hover_throttle" in m:
              m.hover_throttle = hover_throttle
  ```
  The dict loop covers every installed mode, including externally-registered
  ones like `FlightModeFormation` (`set_flight_mode_object` registers into
  `_flight_modes`) — followers never carry payloads, so `SwarmManager` needed
  no changes.
- **Crash threshold, deliberately mass-relative** — `crash_momentum_threshold`
  is a fixed kg·m/s value, so a loaded drone (more `mass`) crosses it at a
  lower impact *speed* than an unloaded one (~3.2 m/s vs. ~4 m/s at the
  default `payload_mass`). This is physically honest — a heavier airframe
  really does hit harder at the same speed — and left as-is, not compensated.

### `scripts/drone/flight_mode_base.gd` — Abstract Base

`FlightModeBase extends RefCounted`. Virtual method:
- `compute(throttle, pitch, roll, yaw, basis, angular_velocity, delta) -> FlightControl`
- `get_mode_name() -> String`

Inner classes: `FlightControl` (collective, pitch_diff, roll_diff, yaw_torque)
and `RotorMix` (fl, fr, bl, br).

### `scripts/drone/flight_mode_acro.gd` — Acro/Rate Mode

Stick-to-differential mapping. No auto-leveling. Collective isn't a flat
`hover + stick * range`: at and above center stick, throttle floors at
`idle_throttle` (0.08) so the self-centering stick never zeros rotor
authority on release; only an explicit throttle-down past center lets thrust
drop below idle, down to a full cutoff at -1. Pitch/roll get an expo curve
(`pitch_roll_expo = 0.3`) to soften twitchiness near center without blunting
full-deflection response.
- `idle_throttle = 0.08` — rotor floor at neutral stick and above
- `max_differential = 0.057` — rotor throttle offset per unit (expo'd) stick input
- `yaw_torque_factor = 1.5` — Nm per unit yaw input

### `scripts/drone/flight_mode_stabilized.gd` — Stabilized (P6.6: compute-both-and-blend)

Both control laws are computed every frame and cross-faded by stick
deflection, rather than hard-switched at the deadzone:
- **Rate law:** stick maps to target angular velocity (max 1.5 rad/s
  pitch/roll, 1.0 rad/s yaw), PD drives toward target with `rate_p_gain =
  4.0`. Feedback uses its **own** lightly-filtered `angular_velocity`
  (`_filtered_ang_vel_rate`, one-pole low-pass with `rate_gyro_filter_alpha =
  0.5`), converted to body frame — separate from the auto-level D filter
  below. Raw gyro noise × `rate_p_gain` produced high-frequency attitude
  jitter (FPV camera shake at medium stick / hard yaw); this filter is light
  enough to kill that without reintroducing the old near-center lag. Yaw uses
  direct stick-to-torque (same as acro), no rate PD, scaled by the blend
  weight.
- **Auto-level law:** PD auto-level using world-frame cross product (body_up
  × world_up) → angle → linear P gain (no deadzone needed — it tapers to zero
  as angle approaches 0 on its own). D gain driven off a separate, more
  heavily one-pole low-pass-filtered gyro reading (`_filtered_ang_vel`,
  `gyro_filter_alpha = 0.35`) to kill PD limit-cycle jitter — this heavier
  filter would make the rate loop feel laggy, hence the two filters.
  `stabilize_p_gain = 15.0`, `stabilize_d_gain = 4.0`. Contributes zero yaw.
- **Blend:** `s = max(|pitch|, |roll|, |yaw|)`, `w = smoothstep(input_deadzone,
  input_deadzone + blend_band, s)` with `blend_band = 0.2`. Final
  `pitch_diff`/`roll_diff` = `lerp(level_value, rate_value, w)`; `yaw_torque =
  w * yaw * 1.5`.
- **"Jump" when releasing stick near level** — rate-PD (`rate_p_gain = 4.0`)
  and angle-PD (`stabilize_p_gain = 15.0`, ~4× stronger gain-equivalent at the
  same tilt) were hard-switched at `input_deadzone = 0.05` with no blending,
  so releasing the stick while still tilted produced a torque discontinuity.
  Now the two are cross-faded across `blend_band`, so there's no discontinuity
  to snap through.
- **"Sticky" near level under active stick** — the rate-mode branch used to
  read the same low-pass-filtered gyro as the auto-level D-term, adding ~1–2
  frames of lag that was proportionally worse for the small commanded rates
  near level. Rate-mode feedback now reads its own lightly-filtered
  `_filtered_ang_vel_rate` (`rate_gyro_filter_alpha = 0.5`); the heavier
  `gyro_filter_alpha = 0.35` filter is reserved for the auto-level D-term only.
  (Reading fully raw `angular_velocity` was tried first and fixed the
  stickiness, but produced audible/visible FPV jitter from per-tick gyro
  noise — the lighter dedicated filter above is the fix that stuck.)

### `scripts/drone/flight_mode_altitude_hold.gd` — Altitude Hold (assist, not a mode)

`FlightModeAltitudeHold extends RefCounted`. Not selectable like acro/stabilized —
`DroneController` calls `update()` after the active mode's `compute()` and, while
`altitude_hold` (L2 / Shift) is held, replaces `control.collective` wholesale with
classic PD-on-altitude: `hover_throttle + P * (target_altitude - current_y) -
D * linear_velocity.y`, target altitude captured on engage. Pitch/roll/yaw pass
through untouched. On release, blends from the last hold collective back to the
pilot's live collective over 0.3s (internal state machine: IDLE → HOLDING →
BLENDING → IDLE).

An earlier version instead did P on velocity-error (target rate = 0) with a
finite-differenced "acceleration" D-term (RigidBody3D has no acceleration
signal). Dividing that finite difference by the ~1/60s physics delta amplified
per-tick noise ~20x, causing a bang-bang oscillation between 0% and ~50%
thrust (visible as HUD throttle flicker and the prop mesh flipping between
idle/spin-disc every frame). PD-on-altitude needs no differentiation at all —
`linear_velocity.y` is already the natural derivative of altitude — so this
class of instability can't happen, and it holds the engaged altitude against
disturbance rather than merely zeroing climb rate wherever the drone is.

### `scripts/drone/brake_assist.gd` — Brake (assist, not a mode, not a magic force)

`BrakeAssist extends RefCounted`. Rotor-thrust-only — no `apply_central_force`
shortcut. While `brake_mode` (R2 / Ctrl) is held, computes the horizontal
deceleration needed (`-horizontal_vel / brake_time`), converts it to a target
airframe tilt via the small-angle relation `a ≈ g·tan(θ)` (solved with
`atan2` so it saturates instead of diverging, clamped to `max_tilt_deg`), then
reuses stabilized mode's exact auto-level technique — restoring torque from
`body_up.cross(target_up)` — pointed at that tilted target instead of literal
world-up. This reuses the already-tested pitch/roll sign conventions instead
of re-deriving them. The resulting `(pitch_diff, roll_diff)` is **added** to
whatever the active flight mode already computed (blends with pilot stick
input and stabilized's own auto-level, doesn't override them — the drone
brakes by tilting into the wind and letting real rotor thrust do the work,
same as a real quad). Vertical velocity untouched; composes with altitude
hold (brake owns horizontal, altitude hold owns vertical).

### `scripts/drone/drone_controller.gd` — Wind Drag (Phase D)

Relative-airspeed drag, `F = air_drag_coefficient * (wind_velocity -
linear_velocity)`, applied as a central force **before** the `FLYING` state
gate in `_physics_process` (so it also acts while `CRASHED` — the wreck
drifts downwind, same as the old engine damping did). This replaced the old
body `linear_damp = 0.5`, which is now `0.0`; `air_drag_coefficient = 1.0`
N·s/m at `mass = 2.0` kg reproduces the old damping exactly in still air
(`wind_velocity == 0`), on top of the untouched engine default
`physics/3d/default_linear_damp = 0.1` — this is why the existing 15
flight-mode tests stay green unmodified. **Do not re-add body `linear_damp`**
to "fix" drift or damping feel — tune `air_drag_coefficient` instead, or the
parity with the old feel breaks silently.

### `scripts/test/flight_mode_test.gd` — Headless Test Harness

17 tests using `Input.action_press/release` + `await get_tree().physics_frame`:

| Test | Input | Verification |
|---|---|---|
| Pitch self-level | 30° tilt, 350 ticks | Within 5° of level |
| Roll self-level | 20° tilt, 350 ticks | Within 5° of level |
| Combined self-level | 25° pitch + -15° roll, 350 ticks | Both within 5° |
| Acro stays tilted | 30° pitch, 350 ticks | Still > 20° |
| Input response | pitch_forward @ 80%, 150 ticks | |pitch| > 2° |
| Acro holds pitch | 15% pitch, 15 ticks + 300 settle | |pitch| > 5° |
| Acro holds roll | 15% roll, 15 ticks + 300 settle | |roll| > 5° |
| Stabilized levels pitch | 15% pitch, 15 ticks + 300 settle | |pitch| < 5° |
| Stabilized levels roll | 15% roll, 15 ticks + 300 settle | |roll| < 5° |
| Roll→yaw coupling | 60% roll + 30% throttle, 30 ticks | heading delta < 45° |
| Altitude hold | Engage at 500m with -3 m/s sink, 200 ticks | Within 0.5m of engage altitude, |vel| < 1 m/s |
| Brake | Inject (5, 0, 3) m/s, brake 180 ticks (~3s, tilt-based) | Speed < 50% of initial |
| Crash on hard impact | Drop at -12 m/s onto ground | is_crashed() true |
| Gentle landing | Acro throttle-cut settle at ~1.7 m/s | No crash |
| Reset clears crash | Crash, reset(), 5 ticks | FLYING, near spawn |
| Obstructed prop tumbles (P6.6) | StaticBody3D box on the FL rotor's world position, 60 ticks at 50% throttle | Angular speed > 0.3 rad/s AND > 3x a clean control run at the same throttle |
| Broken prop survives until reset (P6.6) | Force `_prop_state[1] = 2`, 30 ticks, then `reset()` | Stays state 2 across ticks; reset() clears the whole array to 0 |

Run: `godot --headless --path . scenes/test/flight_mode_test_scene.tscn`
(or `./run_tests.sh`)
