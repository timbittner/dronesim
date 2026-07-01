class_name BrakeAssist
extends RefCounted

## Brake filter stage — NOT a selectable flight mode, and NOT an out-of-band
## force. While engaged, ADDS a pitch/roll differential on top of whatever
## the active flight mode already computed (blends with pilot stick input,
## doesn't override it) — the same rotor-thrust-only mechanism pitch/roll
## always uses. The drone brakes the way a real quad does: tilt the airframe
## so a component of rotor thrust opposes horizontal velocity, no magic
## central force.
##
## Reuses flight_mode_stabilized.gd's auto-level technique (restoring torque
## from body_up.cross(target_up)) but points "up" at a computed tilted
## target instead of literal world-up, so the well-tested pitch/roll sign
## conventions carry over unchanged.

@export var p_gain: float = 6.0
@export var d_gain: float = 1.5
@export var max_tilt_deg: float = 25.0
@export var brake_time: float = 1.0

## Per-rotor max thrust (set by controller), used to convert torque to a
## per-rotor throttle offset — same conversion flight_mode_stabilized.gd uses.
var max_thrust: float = 50.0

## Below this horizontal speed, braking authority isn't worth the jitter of
## computing a tilt target from a near-zero (numerically noisy) direction.
const MIN_SPEED: float = 0.05


## Returns (pitch_diff, roll_diff) offsets to ADD to the active mode's
## output. `horizontal_velocity` is world-frame with y = 0. `basis` and
## `angular_velocity` are the drone's current global values. `gravity` is
## the scene's gravity magnitude.
func compute(
	horizontal_velocity: Vector3,
	basis: Basis,
	angular_velocity: Vector3,
	gravity: float
) -> Vector2:
	if horizontal_velocity.length() < MIN_SPEED:
		return Vector2.ZERO

	var desired_accel: Vector3 = -horizontal_velocity / brake_time
	var accel_mag: float = desired_accel.length()
	var decel_dir: Vector3 = desired_accel / accel_mag

	# Small-angle relation a = g * tan(theta), solved for theta via atan2 so
	# it saturates gracefully instead of blowing up as accel_mag grows.
	var max_tilt_rad: float = deg_to_rad(max_tilt_deg)
	var tilt_angle: float = clampf(atan2(accel_mag, gravity), 0.0, max_tilt_rad)

	# World-up tilted by tilt_angle toward the direction we want thrust to
	# push (opposing velocity) — the target thrust axis, not a target that
	# literally means "vertical".
	var target_up: Vector3 = (cos(tilt_angle) * Vector3.UP + sin(tilt_angle) * decel_dir).normalized()

	var body_up: Vector3 = basis.y
	var axis: Vector3 = body_up.cross(target_up)
	var angle: float = acos(clampf(body_up.dot(target_up), -1.0, 1.0))

	var world_restoring: Vector3 = Vector3.ZERO
	if axis.length_squared() > 1.0e-6:
		world_restoring = axis.normalized() * angle * p_gain

	var world_damping: Vector3 = -angular_velocity * d_gain
	var world_torque: Vector3 = world_restoring + world_damping

	var body_torque: Vector3 = basis.inverse() * world_torque
	body_torque.y = 0.0  # no yaw influence

	var torque_to_offset: float = 1.0 / max_thrust
	return Vector2(body_torque.x * torque_to_offset, -body_torque.z * torque_to_offset)
