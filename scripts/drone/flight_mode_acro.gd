class_name FlightModeAcro
extends FlightModeBase

## Acro (rate) mode with per-rotor thrust vectoring.
## Maps stick input directly to rotor differentials — no auto-leveling.
## Left stick Y = collective throttle, right stick = differential speed.

## Per-rotor hover throttle (set by controller: (mass * g) / (4 * max_thrust)).
var hover_throttle: float = 0.0

## Maximum throttle offset per rotor from stick input (fraction of 0..1 range).
## Reduced ~7x from initial value — per-rotor thrust is very direct.
@export var max_differential: float = 0.02

## Fraction of throttle range available to user stick input (added to hover).
# With 4 rotors, total thrust = 4x per-rotor, so range is 1/4 of old central-force value.
@export var throttle_range: float = 0.15

## Yaw torque factor (Nm per unit input).
## Reduced from 5.0 — yaw was way too twitchy.
@export var yaw_torque_factor: float = 1.5


func compute(
	throttle: float,
	pitch: float,
	roll: float,
	yaw: float,
	_basis: Basis,
	_angular_velocity: Vector3,
	_delta: float
) -> FlightControl:
	var result := FlightControl.new()
	result.collective = clampf(hover_throttle + throttle * throttle_range, 0.0, 1.0)
	result.pitch_diff = pitch * max_differential
	result.roll_diff = roll * max_differential
	result.yaw_torque = yaw * yaw_torque_factor
	return result


func get_mode_name() -> String:
	return "Acro"
