class_name FlightModeBase
extends RefCounted

## Abstract base class for all flight modes.
## Subclasses must implement compute_torque() and get_mode_name().


## Compute the torque vector (in local/body frame) that the controller should apply.
## Parameters:
##   pitch: float       — pitch input (-1..1, positive = stick back = nose up)
##   roll: float        — roll input (-1..1, positive = stick right)
##   yaw: float         — yaw input (-1..1, positive = stick right = clockwise)
##   basis: Basis       — current global basis of the drone
##   angular_velocity: Vector3 — current angular velocity (world frame)
##   delta: float       — physics tick delta
## Returns: Vector3     — torque in local body frame (X = pitch, Y = yaw, Z = roll)
func compute_torque(
	_pitch: float,
	_roll: float,
	_yaw: float,
	_basis: Basis,
	_angular_velocity: Vector3,
	_delta: float
) -> Vector3:
	assert(false, "FlightModeBase.compute_torque() is abstract — subclass must override.")
	return Vector3.ZERO


## Return a human-readable name for this mode (e.g. "Acro", "Stabilized").
func get_mode_name() -> String:
	assert(false, "FlightModeBase.get_mode_name() is abstract — subclass must override.")
	return ""
