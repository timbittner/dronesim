class_name DroneController
extends RigidBody3D

## Core drone flight controller.
## Three-layer pipeline: FlightMode → Mixer → Force application.
## Per-rotor thrust vectoring: each rotor applies force at its arm position.
## Mode 2 layout: left stick = throttle/yaw, right stick = pitch/roll.

signal flight_mode_changed(mode_name: String)
signal fpv_toggled(enabled: bool)

# --- Thrust ---
@export var max_thrust: float = 50.0  # Newtons per rotor

# Per-rotor hover throttle: (mass * gravity) / (4 * max_thrust)
var hover_throttle: float = 0.0

# --- Angular damping ---
## Prevents spin-out. Yaw gets higher damping — roll maneuvers can induce
## yaw via natural thumb drift on the stick, and this keeps it in check.
@export var damping_factor: Vector3 = Vector3(0.08, 1.0, 0.08)  # pitch, yaw, roll

# --- Flight modes ---
var _flight_modes: Dictionary = {}
var _current_mode: FlightModeBase = null

# --- State ---
var _throttle_input: float = 0.0
var _pitch_input: float = 0.0
var _roll_input: float = 0.0
var _yaw_input: float = 0.0
var _fpv_enabled: bool = true
var _spawn_transform: Transform3D

var _flight_mode: String = "stabilized"

# --- Rotor visual ---
var _rotor_nodes: Array[MeshInstance3D] = []
var _rotor_idle_meshes: Array[Mesh] = []
var _rotor_idle_materials: Array[Material] = []
var _rotor_spin_mesh: Mesh
var _rotor_spin_material: Material
var _armed: bool = false

# Rotor positions in local body frame.
var _rotor_positions: Array[Vector3] = [
	Vector3(-0.25, 0.07,  0.25),  # FL — left-rear
	Vector3( 0.25, 0.07,  0.25),  # FR — right-rear
	Vector3(-0.25, 0.07, -0.25),  # BL — left-front
	Vector3( 0.25, 0.07, -0.25),  # BR — right-front
]


func _ready() -> void:
	_spawn_transform = global_transform
	gravity_scale = 1.0
	angular_damp = 0.0
	linear_damp = 0.5

	var gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")
	hover_throttle = (mass * gravity) / (4.0 * max_thrust)

	var acro := FlightModeAcro.new()
	acro.hover_throttle = hover_throttle
	_flight_modes["acro"] = acro

	var stabilized := FlightModeStabilized.new()
	stabilized.hover_throttle = hover_throttle
	_flight_modes["stabilized"] = stabilized

	_current_mode = _flight_modes[_flight_mode]

	_setup_rotor_visuals()


func _setup_rotor_visuals() -> void:
	# Collect rotor MeshInstance3D children and snapshot their idle state.
	for child in get_children():
		if child is MeshInstance3D and child.name.begins_with("Rotor"):
			_rotor_nodes.append(child)
			_rotor_idle_meshes.append(child.mesh)
			_rotor_idle_materials.append(child.material_override)

	# Create spinning disc mesh — flat disc, same diameter as cone base.
	var disc := CylinderMesh.new()
	disc.top_radius = 0.08
	disc.bottom_radius = 0.08
	disc.height = 0.01
	_rotor_spin_mesh = disc

	# Translucent material with subtle emission for spinning rotors.
	var spin_mat := StandardMaterial3D.new()
	spin_mat.albedo_color = Color(0.35, 0.5, 0.5, 0.35)
	spin_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	spin_mat.emission_enabled = true
	spin_mat.emission = Color(0.2, 0.3, 0.35)
	spin_mat.emission_energy_multiplier = 0.4
	_rotor_spin_material = spin_mat


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("toggle_flight_mode"):
		_toggle_flight_mode()
	if event.is_action_pressed("toggle_fpv"):
		_toggle_fpv()
	if event.is_action_pressed("reset_drone"):
		reset()


func _physics_process(delta: float) -> void:
	_read_inputs()
	_compute_and_apply_forces(delta)
	_apply_angular_damping()


func _read_inputs() -> void:
	_throttle_input = Input.get_action_strength("throttle_up") - Input.get_action_strength("throttle_down")
	_yaw_input = Input.get_action_strength("yaw_right") - Input.get_action_strength("yaw_left")
	_pitch_input = Input.get_action_strength("pitch_backward") - Input.get_action_strength("pitch_forward")
	_roll_input = Input.get_action_strength("roll_right") - Input.get_action_strength("roll_left")


func _compute_and_apply_forces(delta: float) -> void:
	if _current_mode == null:
		return

	var control: FlightModeBase.FlightControl = _current_mode.compute(
		_throttle_input, _pitch_input, _roll_input, _yaw_input,
		global_transform.basis, angular_velocity, delta
	)

	var mix := _mix_rotors(control.collective, control.pitch_diff, control.roll_diff)

	# Rotor visual: swap between cone (idle) and disc (spinning) based on throttle cut.
	var armed := control.collective >= 0.001
	if armed != _armed:
		_armed = armed
		for i in _rotor_nodes.size():
			if _armed:
				_rotor_nodes[i].mesh = _rotor_spin_mesh
				_rotor_nodes[i].material_override = _rotor_spin_material
			else:
				_rotor_nodes[i].mesh = _rotor_idle_meshes[i]
				_rotor_nodes[i].material_override = _rotor_idle_materials[i]

	var up: Vector3 = global_transform.basis.y
	var throttles: Array[float] = [mix.fl, mix.fr, mix.bl, mix.br]
	for i in range(4):
		var force: Vector3 = up * throttles[i] * max_thrust
		var global_pos: Vector3 = global_transform.basis * _rotor_positions[i]
		apply_force(force, global_pos)

	if control.yaw_torque != 0.0:
		apply_torque(global_transform.basis * Vector3(0.0, -control.yaw_torque, 0.0))


## Minimum rotor throttle fraction. Prevents any rotor from fully cutting out
## during aggressive maneuvers (when collective is positive). Does NOT prevent
## throttle cut — if the user commands zero collective, all rotors go to zero.
const MIN_ROTOR: float = 0.02

## Convert collective + differentials to per-rotor throttles with anti-clip scaling.
static func _mix_rotors(collective: float, pitch: float, roll: float) -> FlightModeBase.RotorMix:
	# Throttle cut: user commanded zero power, all rotors off.
	if collective < 0.001:
		var cut_result := FlightModeBase.RotorMix.new()
		cut_result.fl = 0.0
		cut_result.fr = 0.0
		cut_result.bl = 0.0
		cut_result.br = 0.0
		return cut_result

	# Anti-clip scaling: prevent differentials from pushing any rotor below
	# MIN_ROTOR (or above 1.0) while preserving the pitch/roll ratio.
	var total_correction: float = absf(pitch) + absf(roll)
	var headroom: float = minf(collective - MIN_ROTOR, 1.0 - collective)
	var clipped_pitch: float = pitch
	var clipped_roll: float = roll
	if total_correction > headroom and total_correction > 0.001:
		var clip_scale: float = headroom / total_correction
		clipped_pitch *= clip_scale
		clipped_roll *= clip_scale

	var result := FlightModeBase.RotorMix.new()
	result.fl = collective - clipped_pitch + clipped_roll
	result.fr = collective - clipped_pitch - clipped_roll
	result.bl = collective + clipped_pitch + clipped_roll
	result.br = collective + clipped_pitch - clipped_roll
	# Final clamp: MIN_ROTOR only applies when collective is on (throttle not cut)
	result.fl = clampf(result.fl, MIN_ROTOR, 1.0)
	result.fr = clampf(result.fr, MIN_ROTOR, 1.0)
	result.bl = clampf(result.bl, MIN_ROTOR, 1.0)
	result.br = clampf(result.br, MIN_ROTOR, 1.0)
	return result


func _apply_angular_damping() -> void:
	var local_ang_vel: Vector3 = global_transform.basis.inverse() * angular_velocity
	var damp_torque_local: Vector3 = -local_ang_vel * damping_factor
	apply_torque(global_transform.basis * damp_torque_local)


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
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	global_transform = _spawn_transform
	print("[Drone] Reset to spawn")


func get_flight_mode() -> String:
	return _flight_mode


func is_fpv_enabled() -> bool:
	return _fpv_enabled
