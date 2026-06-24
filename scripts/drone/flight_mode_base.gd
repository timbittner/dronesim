class_name FlightModeBase
extends RefCounted

## Abstract base class for all flight modes.
## Subclasses must implement compute() and get_mode_name().

## Per-rotor throttle mix: 0.0..1.0 throttle for each rotor.
class RotorMix:
	var fl: float = 0.0
	var fr: float = 0.0
	var bl: float = 0.0
	var br: float = 0.0

## Control signals produced by a flight mode.
## The controller uses these to compute per-rotor throttles via the Mixer
## and to apply yaw torque directly.
class FlightControl:
	var collective: float = 0.0   # 0..1 base throttle for all rotors
	var pitch_diff: float = 0.0   # rotor throttle offset for pitch (positive = front faster)
	var roll_diff: float = 0.0    # rotor throttle offset for roll (positive = left faster)
	var yaw_torque: float = 0.0   # Nm around body Y axis (rotor drag, not force offset)


## Compute control signals from stick input and state.
## Parameters:
##   throttle: float   — user throttle input (-1..1)
##   pitch: float      — pitch input (-1..1, positive = stick back = nose up)
##   roll: float       — roll input (-1..1, positive = stick right)
##   yaw: float        — yaw input (-1..1, positive = stick right = yaw right)
##   basis: Basis      — current global basis of the drone
##   angular_velocity: Vector3 — current angular velocity (world frame)
##   delta: float      — physics tick delta
## Returns: FlightControl  — collective + differentials + yaw torque
func compute(
	_throttle: float,
	_pitch: float,
	_roll: float,
	_yaw: float,
	_basis: Basis,
	_angular_velocity: Vector3,
	_delta: float
) -> FlightControl:
	assert(false, "FlightModeBase.compute() is abstract — subclass must override.")
	return FlightControl.new()


## Return a human-readable name for this mode (e.g. "Acro", "Stabilized").
func get_mode_name() -> String:
	assert(false, "FlightModeBase.get_mode_name() is abstract — subclass must override.")
	return ""
