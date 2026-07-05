class_name FlightModeFormation
extends FlightModeBase

## Autopilot flight mode for swarm followers (P6). Computes FlightControl
## directly from a target position + heading instead of stick input — the
## stick args of compute() are ignored. Rationale: feeding attitude setpoints
## into stabilized mode breaks down when the leader flies acro; computing from
## the target position keeps the follower stable whenever the target path is.
##
## Control cascade (PD + a position integral for drift trim):
##   position error → desired velocity → desired acceleration → desired thrust
##   direction (body-up target) → restoring torque (same angle-P / gyro-D law
##   as stabilized auto-level, aimed at the tilted up-vector instead of level)
##   altitude error → collective offset; heading error → yaw torque.
##
## The pilot (FollowerPilot) writes target_* (radio-side: freezes on packet
## loss) and current_* (onboard sensors: always fresh) every physics tick.

# Set once by the pilot at construction (same handoff as FlightModeStabilized —
# overwritten from the drone's actual values, editing these defaults is inert).
var hover_throttle: float = 0.0
var max_thrust: float = 17.5

# --- Radio-side inputs (stale during packet loss) ---
var target_position: Vector3 = Vector3.ZERO
## Desired nose heading in radians around Y (Godot yaw; nose = −Z at 0).
var target_heading: float = 0.0
## Slot velocity feed-forward (leader velocity + local orbital motion): lets
## the follower match a moving slot at zero position error instead of needing
## error as fuel — removes the trailing lag while the leader flies.
var target_velocity: Vector3 = Vector3.ZERO

# --- Onboard state (always fresh) ---
var current_position: Vector3 = Vector3.ZERO
var current_velocity: Vector3 = Vector3.ZERO

# --- Tuning knobs (live-tunable via SwarmManager's Formation Gains exports,
# pushed into every pilot's mode each physics tick) ---
## m of horizontal position error → m/s of desired velocity.
var pos_p_gain: float = 2.0
## Integral: m·s of accumulated position error → m/s of desired velocity.
## Trims out persistent drift (wind) without the controller knowing the wind —
## it only sees that it keeps missing the slot. Anti-windup below.
var pos_i_gain: float = 0.4
## Only integrate within this error radius (m) — approach transients from big
## moves shouldn't wind the trim up.
var integrate_radius: float = 3.0
## Cap on the integral's velocity contribution, m/s (anti-windup clamp).
var max_i_speed: float = 3.0
## Max commanded horizontal speed toward the slot, m/s.
var max_speed: float = 40.0
## m/s of horizontal velocity error → m/s² of desired acceleration.
var vel_p_gain: float = 3.0
## Max tilt of the desired thrust direction from vertical, radians. This sets
## the follower's TERMINAL SPEED against drag, not just agility: sustained
## v = g·tan(max_tilt)·m/c (≈ 30 m/s at 1.0 rad with c=1, m=2). 0.55 rad
## capped them at ~12 m/s.
var max_tilt: float = 1.0
## Attitude restoring gains — same law as stabilized auto-level.
var attitude_p_gain: float = 15.0
var attitude_d_gain: float = 4.0
var gyro_filter_alpha: float = 0.35
var max_offset: float = 0.4
## Altitude PD: collective offset per m of error / per m/s of climb rate.
var alt_p_gain: float = 0.05
var alt_d_gain: float = 0.08
## Heading PD → yaw torque (Nm), clamped to the same ±1.5 sticks command.
var yaw_p_gain: float = 1.2
var yaw_d_gain: float = 0.3

## Set by the pilot at touchdown (auto-land): motors cut, all outputs zero.
## The only sanctioned bypass of the 0.05 collective floor — on the ground.
var landed: bool = false

## Terminal kamikaze strike: the pilot sets this once the drone is close enough
## to commit. The cascade is bypassed — full collective points body-up at the
## target with no tilt clamp. Reckless, but still rotor-only — no applied impulse.
var strike: bool = false
## Live target point for terminal strike; refreshed by FollowerPilot while the
## target exists, otherwise the last value is used.
var strike_target: Vector3 = Vector3.ZERO

var _filtered_ang_vel: Vector3 = Vector3.ZERO
var _err_integral: Vector3 = Vector3.ZERO
var _gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")


## Stick args are ignored — see the class comment.
func compute(
	_throttle: float,
	_pitch: float,
	_roll: float,
	_yaw: float,
	basis: Basis,
	angular_velocity: Vector3,
	delta: float
) -> FlightControl:
	var result := FlightControl.new()
	if landed:
		return result  # parked: zero collective, zero torques
	if strike:
		return _strike(basis, angular_velocity)
	var torque_to_offset: float = 1.0 / max_thrust

	# --- Horizontal position → velocity → acceleration cascade ---
	var err := target_position - current_position
	var err_h := Vector3(err.x, 0.0, err.z)
	# Integral trim: only near the slot (approach transients from big moves
	# don't wind it up), clamped to max_i_speed worth of velocity command.
	if err_h.length() < integrate_radius:
		_err_integral = (_err_integral + err_h * delta) \
				.limit_length(max_i_speed / maxf(pos_i_gain, 0.001))
	var ff_h := Vector3(target_velocity.x, 0.0, target_velocity.z)
	var vel_des := (ff_h + err_h * pos_p_gain + _err_integral * pos_i_gain) \
			.limit_length(max_speed)
	var vel_h := Vector3(current_velocity.x, 0.0, current_velocity.z)
	var accel_des := (vel_des - vel_h) * vel_p_gain

	# --- Desired thrust direction: gravity compensation + lateral accel ---
	# A quad can only accelerate along body-up, so the up-vector target is
	# (a_des + g·ŷ) normalized, tilt-clamped so aggressive slots never demand
	# a tip-over.
	var thrust_vec := accel_des + Vector3(0.0, _gravity, 0.0)
	var target_up := thrust_vec.normalized()
	var tilt := acos(clampf(target_up.dot(Vector3.UP), -1.0, 1.0))
	if tilt > max_tilt:
		# Slerp the up-vector back toward vertical to the tilt limit.
		var axis := Vector3.UP.cross(target_up).normalized()
		target_up = Vector3.UP.rotated(axis, max_tilt)

	# --- Attitude: restoring torque toward target_up (stabilized-mode law) ---
	_filtered_ang_vel = _filtered_ang_vel.lerp(angular_velocity, gyro_filter_alpha)
	var body_up: Vector3 = basis.y
	var axis_r: Vector3 = body_up.cross(target_up)
	var angle: float = acos(clampf(body_up.dot(target_up), -1.0, 1.0))
	var world_torque: Vector3 = -_filtered_ang_vel * attitude_d_gain
	if axis_r.length_squared() > 1.0e-6:
		world_torque += axis_r.normalized() * angle * attitude_p_gain
	var body_torque: Vector3 = basis.inverse() * world_torque
	body_torque.y = 0.0
	result.pitch_diff = clampf(body_torque.x * torque_to_offset, -max_offset, max_offset)
	result.roll_diff = clampf(-body_torque.z * torque_to_offset, -max_offset, max_offset)

	# --- Altitude: PD on height error → collective around hover. The D term
	# damps relative to the target's own climb rate (vertical feed-forward),
	# so a climbing leader isn't fought as if the follower were drifting. ---
	result.collective = clampf(
		hover_throttle + err.y * alt_p_gain
			- (current_velocity.y - target_velocity.y) * alt_d_gain,
		0.05, 1.0)  # floor keeps rotors alive — a follower never throttle-cuts mid-air

	# --- Heading: PD on yaw error → torque ---
	# Y-rotation angle θ: nose = −Z at θ=0, positive θ = counterclockwise from
	# above (Godot right-handed). atan2(sinθ, cosθ) with basis.z = (sinθ,0,cosθ).
	var heading := atan2(basis.z.x, basis.z.z)
	var yaw_err := wrapf(target_heading - heading, -PI, PI)
	var local_ang_vel: Vector3 = basis.inverse() * _filtered_ang_vel
	result.yaw_torque = clampf(
		-(yaw_err * yaw_p_gain - local_ang_vel.y * yaw_d_gain), -1.5, 1.5)

	return result


## Terminal strike: full throttle toward strike_target. Same attitude-restoring
## law as cruise, but aimed at the target vector with no tilt clamp.
func _strike(basis: Basis, angular_velocity: Vector3) -> FlightControl:
	var result := FlightControl.new()
	var torque_to_offset: float = 1.0 / max_thrust

	_filtered_ang_vel = _filtered_ang_vel.lerp(angular_velocity, gyro_filter_alpha)
	var body_up: Vector3 = basis.y
	var target_up := strike_target - current_position
	if target_up.length_squared() < 1.0e-6:
		target_up = Vector3.DOWN
	else:
		target_up = target_up.normalized()
	var axis_r: Vector3 = body_up.cross(target_up)
	var angle: float = acos(clampf(body_up.dot(target_up), -1.0, 1.0))
	var world_torque: Vector3 = -_filtered_ang_vel * attitude_d_gain
	if axis_r.length_squared() > 1.0e-6:
		world_torque += axis_r.normalized() * angle * attitude_p_gain
	var body_torque: Vector3 = basis.inverse() * world_torque
	body_torque.y = 0.0
	result.pitch_diff = clampf(body_torque.x * torque_to_offset, -max_offset, max_offset)
	result.roll_diff = clampf(-body_torque.z * torque_to_offset, -max_offset, max_offset)
	result.collective = 1.0
	return result


func get_mode_name() -> String:
	return "Formation"
