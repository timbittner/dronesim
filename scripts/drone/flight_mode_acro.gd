class_name FlightModeAcro
extends FlightModeBase

## Acro (rate) flight mode.
## Maps stick input directly to torque with no auto-leveling.
## Preserves the exact behavior from the original drone_controller.gd's _apply_torque().

@export var pitch_torque: float = 8.0
@export var roll_torque: float = 8.0
@export var yaw_torque: float = 5.0


func compute_torque(
	_pitch: float,
	_roll: float,
	_yaw: float,
	_basis: Basis,
	_angular_velocity: Vector3,
	_delta: float
) -> Vector3:
	# Coordinate system: X+ = right, Y+ = up, Z+ = back, -Z = forward.
	#
	# Pitch (X axis): stick forward (_pitch < 0) should nose down (-Z dips).
	#   Negative _pitch * positive torque = negative X torque = nose down.
	#
	# Roll (Z axis): stick left (_roll < 0) should roll left (counterclockwise from behind).
	#   In Godot right-hand system, positive Z rotation = counterclockwise when viewed from +Z (behind).
	#   So roll_left needs negative _roll mapped to positive Z torque => negate.
	#
	# Yaw (Y axis): stick right (_yaw > 0) should rotate clockwise (turn right).
	#   Positive Y rotation = counterclockwise from above, so negate for right turn.
	return Vector3(
		_pitch * pitch_torque,
		-_yaw * yaw_torque,
		-_roll * roll_torque
	)


func get_mode_name() -> String:
	return "Acro"
