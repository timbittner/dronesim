class_name FlightModeAcro
extends FlightModeBase

## Acro (rate) mode with per-rotor thrust vectoring.
## Maps stick input directly to rotor differentials — no auto-leveling, no
## hover assist. Left stick Y = collective throttle, right stick =
## differential speed.
##
## The stick is self-centering (no true 0-detent throttle slider), so it
## snaps back to 0 the instant the pilot lets go. Cutting thrust to literally
## 0% there would kill all rotor authority whenever the stick isn't actively
## held — instead, neutral and above idle the rotors at `idle_throttle` (spin
## enough for differential thrust to still steer/level the drone) and only
## let thrust drop below idle when the pilot explicitly pulls the stick past
## center into throttle-down.

## Rotor idle floor (fraction of 0..1 thrust) held at neutral stick and above,
## so the drone keeps attitude authority instead of losing all rotor thrust
## whenever the self-centering stick returns to 0.
@export var idle_throttle: float = 0.08

## Maximum throttle offset per rotor from stick input (fraction of 0..1 range).
## Scaled by 1/0.35 to preserve absolute rotational torque after max_thrust
## was cut to 35% of its previous value — this is a fraction of max_thrust,
## not torque-based, so it doesn't auto-compensate the way hover_throttle does.
@export var max_differential: float = 0.057

## Yaw torque factor (Nm per unit input).
## Reduced from 5.0 — yaw was way too twitchy.
@export var yaw_torque_factor: float = 1.5

## Expo curve on pitch/roll stick input (0 = linear, 1 = maximum softening
## near center). Softens the twitchy small-stick-movement response around
## center while leaving full-deflection response unchanged, unlike a flat
## damping factor which would blunt aggressive full-stick flicks too.
@export_range(0.0, 1.0) var pitch_roll_expo: float = 0.3


func _apply_expo(x: float) -> float:
	return pitch_roll_expo * x * x * x + (1.0 - pitch_roll_expo) * x


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
	if throttle >= 0.0:
		result.collective = idle_throttle + throttle * (1.0 - idle_throttle)
	else:
		# Pilot explicitly pulled throttle-down past center — let thrust drop
		# below idle, down to a full cutoff at throttle = -1.
		result.collective = idle_throttle * (1.0 + throttle)
	result.collective = clampf(result.collective, 0.0, 1.0)
	result.pitch_diff = _apply_expo(pitch) * max_differential
	result.roll_diff = _apply_expo(roll) * max_differential
	result.yaw_torque = yaw * yaw_torque_factor
	return result


func get_mode_name() -> String:
	return "Acro"
