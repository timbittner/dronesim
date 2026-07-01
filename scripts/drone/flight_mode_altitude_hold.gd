class_name FlightModeAltitudeHold
extends RefCounted

## Altitude-hold filter stage — NOT a selectable flight mode. DroneController
## calls update() after the active mode's compute() and, while engaged,
## substitutes the returned value for control.collective wholesale. Pitch/
## roll/yaw diffs from the active mode pass through untouched.
##
## Control law: classic PD on ALTITUDE error. On engage, captures the current
## Y position as the target; each tick, collective = hover_throttle (gravity-
## cancelling baseline, set by the controller) + P * (target - current) -
## D * vertical_velocity. The D-term is world-frame linear_velocity.y used
## directly — no differentiation needed, since velocity is already the
## natural derivative of altitude.
##
## An earlier version did P on velocity-error (target rate = 0) with a
## finite-differenced "acceleration" D-term. Dividing that finite difference
## by the ~1/60s physics delta amplified per-tick noise ~20x, which fed back
## into the P output and caused a bang-bang oscillation between 0% and ~50%
## thrust. PD-on-altitude avoids this entirely (no differentiation of a noisy
## signal) and, as a bonus, genuinely holds the altitude it was engaged at
## against disturbance, rather than just zeroing climb rate wherever the
## drone happens to be.

@export var p_gain: float = 0.15
@export var d_gain: float = 0.3
@export var release_blend_time: float = 0.3

## Per-rotor hover throttle (set by controller: (mass * g) / (4 * max_thrust)).
var hover_throttle: float = 0.0

enum _State { IDLE, HOLDING, BLENDING }
var _state: int = _State.IDLE

var _target_altitude: float = 0.0
var _last_hold_collective: float = 0.0
var _blend_timer: float = 0.0


## Call every physics tick. `engaged` = altitude_hold action held this frame.
## `current_altitude`/`vertical_velocity` = world-frame Y position and
## linear_velocity.y. `pilot_collective` = whatever the active flight mode
## computed this tick (used as the release-blend target). Returns the
## collective to actually apply.
func update(
	engaged: bool,
	current_altitude: float,
	vertical_velocity: float,
	pilot_collective: float,
	delta: float
) -> float:
	if engaged:
		if _state != _State.HOLDING:
			_target_altitude = current_altitude
		_state = _State.HOLDING

		var altitude_error: float = _target_altitude - current_altitude
		_last_hold_collective = clampf(
			hover_throttle + p_gain * altitude_error - d_gain * vertical_velocity, 0.0, 1.0
		)
		return _last_hold_collective

	if _state == _State.HOLDING:
		_state = _State.BLENDING
		_blend_timer = 0.0

	if _state == _State.BLENDING:
		_blend_timer += delta
		if _blend_timer >= release_blend_time:
			_state = _State.IDLE
			return pilot_collective
		return lerp(_last_hold_collective, pilot_collective, _blend_timer / release_blend_time)

	return pilot_collective


## True while holding or still blending back to pilot control after release.
func is_active() -> bool:
	return _state != _State.IDLE
