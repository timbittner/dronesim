class_name FlightModeStabilized
extends FlightModeBase

## Stabilized flight mode with auto-leveling, using per-rotor thrust vectoring.
##
## Control signals: collective hover base + PD-corrected pitch/roll differentials.
## Yaw: direct stick-to-torque mapping (same as acro), no stabilizer intervention.
##
## Auto-level uses a blended P gain below ANGLE_DEADZONE — instead of a hard
## on/off switch, the P gain ramps linearly from 0 at 0° tilt to full strength
## at the deadzone boundary. The D gain is always active. This eliminates the
## limit-cycle oscillation (twitching) that hard deadzones produce.

## Per-rotor hover throttle (set by controller: (mass * g) / (4 * max_thrust)).
var hover_throttle: float = 0.0

# --- Auto-level PD gains ---
@export var stabilize_p_gain: float = 15.0
@export var stabilize_d_gain: float = 4.0

# --- Auto-level angle deadzone (radians) ---
## P gain blends from 0 to full over this range, preventing hard on/off cycling.
const ANGLE_DEADZONE: float = 0.0262  # ~1.5 degrees

# --- Rate control parameters ---
@export var max_pitch_rate: float = 1.5   # rad/s
@export var max_roll_rate: float = 1.5    # rad/s
@export var max_yaw_rate: float = 1.0     # rad/s
@export var rate_p_gain: float = 4.0

# --- Deadzone ---
## Stick must return very near center before auto-level engages.
@export var input_deadzone: float = 0.05

# --- Differential clipping limit ---
@export var max_offset: float = 0.4

## Conversion: torque = max_thrust * δ → δ = torque / max_thrust
const TORQUE_TO_OFFSET: float = 1.0 / 50.0


func compute(
	throttle: float,
	pitch: float,
	roll: float,
	yaw: float,
	basis: Basis,
	angular_velocity: Vector3,
	_delta: float
) -> FlightControl:
	var result := FlightControl.new()

	# Collective hover base (throttle input adjusts altitude).
	result.collective = clampf(hover_throttle + throttle * 0.15, 0.0, 1.0)

	# Convert angular velocity to body frame
	var local_ang_vel: Vector3 = basis.inverse() * angular_velocity

	# Check if any attitude stick is active
	var stick_active: bool = absf(pitch) > input_deadzone \
		or absf(roll) > input_deadzone \
		or absf(yaw) > input_deadzone

	if stick_active:
		# --- Rate mode: stick = target angular velocity, then PD ---
		var target_rate: Vector3 = Vector3(
			pitch * max_pitch_rate,
			yaw * max_yaw_rate,
			-roll * max_roll_rate
		)
		var rate_error: Vector3 = target_rate - local_ang_vel
		var desired_torque: Vector3 = rate_error * rate_p_gain

		result.pitch_diff = desired_torque.x * TORQUE_TO_OFFSET
		result.roll_diff = -desired_torque.z * TORQUE_TO_OFFSET
		# Yaw: direct mapping, same as acro
		result.yaw_torque = yaw * 1.5

	else:
		# --- Auto-level: blended PD on tilt error ---
		var body_up: Vector3 = basis.y
		var world_up: Vector3 = Vector3.UP

		var axis: Vector3 = body_up.cross(world_up)
		var angle: float = acos(clampf(body_up.dot(world_up), -1.0, 1.0))

		var world_restoring: Vector3 = Vector3.ZERO
		if axis.length_squared() > 1.0e-6:
			# Blend P gain from 0 at 0° to full at ANGLE_DEADZONE boundary.
			# This eliminates the limit-cycle jitter that hard deadzones cause.
			var effective_p_gain: float = stabilize_p_gain
			if angle < ANGLE_DEADZONE:
				effective_p_gain *= angle / ANGLE_DEADZONE
			world_restoring = axis.normalized() * angle * effective_p_gain

		# D gain always active — provides damping at all angles
		var world_damping: Vector3 = -angular_velocity * stabilize_d_gain
		var world_torque: Vector3 = world_restoring + world_damping

		# Convert to body frame, zero out yaw (no yaw auto-level)
		var body_torque: Vector3 = basis.inverse() * world_torque
		body_torque.y = 0.0

		result.pitch_diff = body_torque.x * TORQUE_TO_OFFSET
		result.roll_diff = -body_torque.z * TORQUE_TO_OFFSET
		result.yaw_torque = 0.0

	# Clamp individual diffs to max_offset
	result.pitch_diff = clampf(result.pitch_diff, -max_offset, max_offset)
	result.roll_diff = clampf(result.roll_diff, -max_offset, max_offset)

	return result


func get_mode_name() -> String:
	return "Stabilized"
