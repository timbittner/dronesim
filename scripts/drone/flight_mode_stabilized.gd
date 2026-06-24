class_name FlightModeStabilized
extends FlightModeBase

## Stabilized flight mode with auto-leveling.
##
## When sticks are near center (within deadzone): the drone auto-levels
## using a PD controller. The correction is computed in world frame
## using the cross product of body-up and world-up, then converted to
## body frame for the controller.
##
## When sticks are active: operates as a rate controller — stick input
## maps to a target angular velocity, and a proportional controller
## drives the drone toward that rate.

# --- Auto-level PD gains ---
@export var stabilize_p_gain: float = 15.0
@export var stabilize_d_gain: float = 4.0

# --- Rate control parameters ---
@export var max_pitch_rate: float = 3.0   # rad/s
@export var max_roll_rate: float = 3.0    # rad/s
@export var max_yaw_rate: float = 2.0     # rad/s
@export var rate_p_gain: float = 5.0

# --- Deadzone ---
@export var input_deadzone: float = 0.15


func compute_torque(
	pitch: float,
	roll: float,
	yaw: float,
	basis: Basis,
	angular_velocity: Vector3,
	_delta: float
) -> Vector3:
	# Convert angular velocity from world frame to local (body) frame
	var local_angular_velocity: Vector3 = basis.inverse() * angular_velocity

	# Check if any attitude stick is active (beyond deadzone)
	var stick_active: bool = absf(pitch) > input_deadzone \
		or absf(roll) > input_deadzone \
		or absf(yaw) > input_deadzone

	if stick_active:
		# --- Rate mode: stick input = target angular velocity ---
		# Returns body-frame torque
		var target_rate: Vector3 = Vector3(
			pitch * max_pitch_rate,
			-yaw * max_yaw_rate,
			-roll * max_roll_rate
		)
		return (target_rate - local_angular_velocity) * rate_p_gain

	else:
		# --- Auto-level: world-frame correction then convert to body ---
		# Compute the cross product of body-up (basis.y) and world-up.
		# This gives the world-space rotation axis to align body-up with world-up.
		# Then use the actual angle from acos(dot) for correct torque magnitude.
		var body_up: Vector3 = basis.y
		var world_up: Vector3 = Vector3.UP

		var axis: Vector3 = body_up.cross(world_up)
		var angle: float = acos(clampf(body_up.dot(world_up), -1.0, 1.0))

		var world_restoring: Vector3 = Vector3.ZERO
		if axis.length_squared() > 1.0e-6:
			world_restoring = axis.normalized() * angle * stabilize_p_gain

		# Derivative damping in world frame
		var world_damping: Vector3 = -angular_velocity * stabilize_d_gain

		# Convert world-frame correction to body frame for the controller
		# (controller applies basis * body_torque to get back to world frame)
		var world_torque: Vector3 = world_restoring + world_damping

		# Zero out yaw component in body frame (keep yaw from auto-level)
		var body_torque: Vector3 = basis.inverse() * world_torque
		body_torque.y = 0.0

		return body_torque


func get_mode_name() -> String:
	return "Stabilized"
