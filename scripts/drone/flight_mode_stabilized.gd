class_name FlightModeStabilized
extends FlightModeBase

## Stabilized flight mode with auto-leveling, using per-rotor thrust vectoring.
##
## Control signals: collective hover base + PD-corrected pitch/roll differentials.
## Yaw: direct stick-to-torque mapping (same as acro), no stabilizer intervention.
##
## Auto-level uses a plain linear P term on tilt angle (no deadzone — it
## already tapers to zero as angle approaches 0 on its own) plus a D term on
## a low-pass-filtered gyro reading, to avoid feeding raw per-step angular
## velocity noise straight into torque.

## Per-rotor hover throttle (set by controller: (mass * g) / (4 * max_thrust)).
var hover_throttle: float = 0.0

## Per-rotor max thrust (set by controller), used to convert torque to a
## per-rotor throttle offset.
var max_thrust: float = 50.0

# --- Auto-level PD gains ---
@export var stabilize_p_gain: float = 15.0
@export var stabilize_d_gain: float = 4.0

# --- Gyro low-pass filter ---
## One-pole IIR low-pass on angular velocity before it feeds the D term.
## Lower = more smoothing (and more lag).
@export var gyro_filter_alpha: float = 0.35
var _filtered_ang_vel: Vector3 = Vector3.ZERO

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

## Rate-PD when the stick is deflected, world-frame angle-PD auto-level when
## released (hard switch at input_deadzone — see AGENTS.md Known Issues).
## See FlightModeBase.compute() for the parameter contract.
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

	## Conversion: torque = max_thrust * δ → δ = torque / max_thrust
	var torque_to_offset: float = 1.0 / max_thrust

	# Collective hover base (throttle input adjusts altitude).
	result.collective = clampf(hover_throttle + throttle * 0.15, 0.0, 1.0)

	# Low-pass filter the gyro reading before it feeds any control math.
	_filtered_ang_vel = _filtered_ang_vel.lerp(angular_velocity, gyro_filter_alpha)

	# Convert angular velocity to body frame
	var local_ang_vel: Vector3 = basis.inverse() * _filtered_ang_vel

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

		result.pitch_diff = desired_torque.x * torque_to_offset
		result.roll_diff = -desired_torque.z * torque_to_offset
		# Yaw: direct mapping, same as acro
		result.yaw_torque = yaw * 1.5

	else:
		# --- Auto-level: linear P on tilt angle, D on filtered gyro ---
		var body_up: Vector3 = basis.y
		var world_up: Vector3 = Vector3.UP

		var axis: Vector3 = body_up.cross(world_up)
		var angle: float = acos(clampf(body_up.dot(world_up), -1.0, 1.0))

		var world_restoring: Vector3 = Vector3.ZERO
		if axis.length_squared() > 1.0e-6:
			world_restoring = axis.normalized() * angle * stabilize_p_gain

		# D gain on the filtered gyro reading — provides damping at all angles
		var world_damping: Vector3 = -_filtered_ang_vel * stabilize_d_gain
		var world_torque: Vector3 = world_restoring + world_damping

		# Convert to body frame, zero out yaw (no yaw auto-level)
		var body_torque: Vector3 = basis.inverse() * world_torque
		body_torque.y = 0.0

		result.pitch_diff = body_torque.x * torque_to_offset
		result.roll_diff = -body_torque.z * torque_to_offset
		result.yaw_torque = 0.0

	# Clamp individual diffs to max_offset
	result.pitch_diff = clampf(result.pitch_diff, -max_offset, max_offset)
	result.roll_diff = clampf(result.roll_diff, -max_offset, max_offset)

	return result


## Mode name shown in the HUD.
func get_mode_name() -> String:
	return "Stabilized"
