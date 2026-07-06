class_name FlightModeStabilized
extends FlightModeBase

## Stabilized flight mode with auto-leveling, using per-rotor thrust vectoring.
##
## Control signals: collective hover base + PD-corrected pitch/roll differentials.
## Yaw: direct stick-to-torque mapping (same as acro), no stabilizer intervention
## (scaled by the same blend weight as pitch/roll, so it also fades in with
## stick deflection).
##
## Both control laws are computed every frame and blended by stick deflection
## instead of hard-switching: rate PD (stick-driven target rate vs a lightly
## filtered angular velocity) and world-frame angle-PD auto-level (tilt angle
## P plus a D term on a separately, more heavily low-pass-filtered gyro
## reading). The blend weight ramps via smoothstep from input_deadzone to
## input_deadzone + blend_band, so releasing the stick fades from rate law to
## auto-level instead of snapping between two differently-tuned gains, and
## small stick inputs near center get a continuous response instead of the
## laggier filtered-gyro feedback.
##
## The rate loop and the auto-level D term deliberately use two different
## gyro filters: the rate loop's is light (rate_gyro_filter_alpha, default
## 0.5) so FPV stick response stays crisp; the auto-level D term's is heavy
## (gyro_filter_alpha, default 0.35) for hover-hold smoothness. Sharing one
## filter between them previously caused either laggy rate response or jittery
## auto-level damping, depending on which alpha won.

## Per-rotor hover throttle (set by controller: (mass * g) / (4 * max_thrust)).
var hover_throttle: float = 0.0

## Per-rotor max thrust (set by controller), used to convert torque to a
## per-rotor throttle offset.
var max_thrust: float = 50.0

# --- Auto-level PD gains ---
@export var stabilize_p_gain: float = 15.0
@export var stabilize_d_gain: float = 4.0

# --- Gyro low-pass filter (auto-level D term) ---
## One-pole IIR low-pass on angular velocity before it feeds the auto-level D
## term. Lower = more smoothing (and more lag).
@export var gyro_filter_alpha: float = 0.35
var _filtered_ang_vel: Vector3 = Vector3.ZERO

# --- Gyro low-pass filter (rate loop) ---
## One-pole low-pass on the rate-loop gyro feedback, separate from the
## auto-level D filter above — the rate loop needs a lighter touch or FPV
## stick response gets laggy. Range 0.0 to 1.0, lower = smoother/laggier,
## 1.0 = raw (jittery).
@export var rate_gyro_filter_alpha: float = 0.5
var _filtered_ang_vel_rate: Vector3 = Vector3.ZERO

# --- Rate control parameters ---
@export var max_pitch_rate: float = 1.5   # rad/s
@export var max_roll_rate: float = 1.5    # rad/s
@export var max_yaw_rate: float = 1.0     # rad/s
@export var rate_p_gain: float = 4.0

# --- Deadzone ---
## Stick must return very near center before auto-level engages.
@export var input_deadzone: float = 0.05

## Stick-deflection span (above input_deadzone) over which the two control
## laws are cross-faded via smoothstep. 0 would reproduce the old hard switch.
@export var blend_band: float = 0.2

# --- Differential clipping limit ---
@export var max_offset: float = 0.4

## Computes both control laws every frame and cross-fades them by stick
## deflection (see class doc comment) instead of hard-switching.
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

	# Low-pass filter the gyro reading — feeds ONLY the auto-level D term.
	_filtered_ang_vel = _filtered_ang_vel.lerp(angular_velocity, gyro_filter_alpha)
	# Separate, lighter low-pass — feeds ONLY the rate loop below.
	_filtered_ang_vel_rate = _filtered_ang_vel_rate.lerp(angular_velocity, rate_gyro_filter_alpha)

	# --- Rate law: stick = target angular velocity, PD on lightly-filtered angular velocity ---
	var local_ang_vel: Vector3 = basis.inverse() * _filtered_ang_vel_rate
	var target_rate: Vector3 = Vector3(
		pitch * max_pitch_rate,
		yaw * max_yaw_rate,
		-roll * max_roll_rate
	)
	var rate_error: Vector3 = target_rate - local_ang_vel
	var rate_torque: Vector3 = rate_error * rate_p_gain
	var rate_pitch_diff: float = rate_torque.x * torque_to_offset
	var rate_roll_diff: float = -rate_torque.z * torque_to_offset

	# --- Auto-level law: linear P on tilt angle, D on filtered gyro ---
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

	var level_pitch_diff: float = body_torque.x * torque_to_offset
	var level_roll_diff: float = -body_torque.z * torque_to_offset

	# --- Blend by stick deflection: smoothstep from deadzone to deadzone + band ---
	var s: float = maxf(absf(pitch), maxf(absf(roll), absf(yaw)))
	var w: float = smoothstep(input_deadzone, input_deadzone + blend_band, s)

	result.pitch_diff = lerpf(level_pitch_diff, rate_pitch_diff, w)
	result.roll_diff = lerpf(level_roll_diff, rate_roll_diff, w)
	# Auto-level contributes zero yaw; rate law is direct stick mapping (as acro).
	result.yaw_torque = w * yaw * 1.5

	# Clamp individual diffs to max_offset
	result.pitch_diff = clampf(result.pitch_diff, -max_offset, max_offset)
	result.roll_diff = clampf(result.roll_diff, -max_offset, max_offset)

	return result


## Mode name shown in the HUD.
func get_mode_name() -> String:
	return "Stabilized"
