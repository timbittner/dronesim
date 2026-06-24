class_name DroneController
extends RigidBody3D

## Core drone flight controller.
## P0: direct thrust + torque, no flight mode logic yet.
## Mode 2 layout: left stick = throttle/yaw, right stick = pitch/roll.

signal flight_mode_changed(mode_name: String)
signal fpv_toggled(enabled: bool)

# --- Thrust ---
# Drone mass = 2.0kg, gravity = 9.8 m/s^2, so weight = 19.6N.
# hover_throttle must produce ~19.6N to cancel gravity.
@export var max_thrust: float = 50.0  # Newtons - 2.5x weight for aggressive climbing
var hover_throttle: float = 0.0  # Computed dynamically in _ready() to exactly cancel gravity

# --- Flight modes ---
var _flight_modes: Dictionary = {}
var _current_mode: FlightModeBase = null

# --- Angular damping (simulates air resistance on rotors) ---
@export var angular_damping_factor: float = 0.5

# --- State ---
var _throttle_input: float = 0.0  # -1..1
var _pitch_input: float = 0.0
var _roll_input: float = 0.0
var _yaw_input: float = 0.0
var _fpv_enabled: bool = true
var _spawn_transform: Transform3D

# Flight mode: "stabilized" or "acro". P0 just uses stabilized (direct control).
var _flight_mode: String = "stabilized"

# Node refs
@onready var camera_rig: Node3D = get_node_or_null("CameraRig")


func _ready() -> void:
	_spawn_transform = global_transform
	gravity_scale = 1.0
	# Custom angular damping in _physics_process instead of built-in
	angular_damp = 0.0
	linear_damp = 0.5  # gentle air resistance to prevent drift accumulation
	# Compute hover throttle dynamically so it exactly cancels gravity.
	# hover_force = mass * gravity, and hover_force = max_thrust * hover_throttle,
	# therefore hover_throttle = (mass * gravity) / max_thrust.
	var gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")
	hover_throttle = (mass * gravity) / max_thrust
	body_entered.connect(_on_body_entered)

	# Initialize flight modes
	_flight_modes["stabilized"] = FlightModeStabilized.new()
	_flight_modes["acro"] = FlightModeAcro.new()
	_current_mode = _flight_modes[_flight_mode]


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("toggle_flight_mode"):
		_toggle_flight_mode()
	if event.is_action_pressed("toggle_fpv"):
		_toggle_fpv()
	if event.is_action_pressed("reset_drone"):
		reset()


func _physics_process(delta: float) -> void:
	_read_inputs()
	_apply_thrust()
	_apply_torque(delta)
	_apply_angular_damping()
	_update_camera_rig()


func _read_inputs() -> void:
	# Throttle: up = positive, down = negative. get_vector gives us -1..1 on each axis.
	# Use get_action_strength (applies deadzone) so non-centered sticks don't drift.
	_throttle_input = Input.get_action_strength("throttle_up") - Input.get_action_strength("throttle_down")
	_yaw_input = Input.get_action_strength("yaw_right") - Input.get_action_strength("yaw_left")
	_pitch_input = Input.get_action_strength("pitch_backward") - Input.get_action_strength("pitch_forward")
	_roll_input = Input.get_action_strength("roll_right") - Input.get_action_strength("roll_left")


func _apply_thrust() -> void:
	# Total throttle = hover offset + user input, clamped 0..1
	var total_throttle: float = clampf(hover_throttle + _throttle_input * 0.6, 0.0, 1.0)
	var thrust_force: float = max_thrust * total_throttle
	# Thrust is along the drone's local up vector (rotors push up relative to body)
	var up: Vector3 = global_transform.basis.y
	apply_central_force(up * thrust_force)


func _apply_torque(delta: float) -> void:
	if _current_mode == null:
		return
	var torque_vec: Vector3 = _current_mode.compute_torque(
		_pitch_input,
		_roll_input,
		_yaw_input,
		global_transform.basis,
		angular_velocity,
		delta
	)
	# Convert local torque to world-space and apply
	apply_torque(global_transform.basis * torque_vec)


func _apply_angular_damping() -> void:
	# Simple angular damping: opposes current angular velocity
	# This simulates rotor drag / air resistance stabilizing the drone
	var ang_vel: Vector3 = angular_velocity
	apply_torque(-ang_vel * angular_damping_factor)


func _update_camera_rig() -> void:
	if camera_rig == null:
		return
	# Camera rig follows the drone. FPV toggle switches the camera position.
	# Actual camera logic lives in the CameraRig script (P1), here we just
	# keep the rig centered on the drone.
	pass


func _toggle_flight_mode() -> void:
	_flight_mode = "acro" if _flight_mode == "stabilized" else "stabilized"
	_current_mode = _flight_modes[_flight_mode]
	flight_mode_changed.emit(_flight_mode)
	print("[Drone] Flight mode: ", _flight_mode)


func _toggle_fpv() -> void:
	_fpv_enabled = not _fpv_enabled
	fpv_toggled.emit(_fpv_enabled)
	print("[Drone] FPV: ", _fpv_enabled)


func reset() -> void:
	# Reset to spawn position and zero all velocities
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	global_transform = _spawn_transform
	print("[Drone] Reset to spawn")


func _on_body_entered(_body: Node) -> void:
	# Crash detection placeholder - P2 will add proper crash logic
	pass


func get_flight_mode() -> String:
	return _flight_mode


func is_fpv_enabled() -> bool:
	return _fpv_enabled
