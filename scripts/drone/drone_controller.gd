class_name DroneController
extends RigidBody3D

## Core drone flight controller.
## Three-layer pipeline: FlightMode → Mixer → Force application.
## Per-rotor thrust vectoring: each rotor applies force at its arm position.
## Mode 2 layout: left stick = throttle/yaw, right stick = pitch/roll.

signal flight_mode_changed(mode_name: String)
signal fpv_toggled(enabled: bool)
signal crash_detected

# --- Thrust ---
@export var max_thrust: float = 17.5  # Newtons per rotor (35% of previous 50.0)

# --- Wind drag ---
## Relative-airspeed drag: F = air_drag_coefficient * (wind_velocity - linear_velocity).
## Replaces the old body linear_damp (see _ready()); 1.0 N·s/m at mass=2.0 kg
## reproduces the old damp exactly in still air (wind_velocity == 0), on top of
## the untouched engine default physics/3d/default_linear_damp = 0.1.
@export var air_drag_coefficient: float = 1.0
## Ambient wind sampled at the drone's position this tick (read by the HUD).
var wind_velocity: Vector3 = Vector3.ZERO

var _wind_field: Node = null
var _wind_field_searched: bool = false

# --- Crash detection ---
## Impact momentum (kg·m/s) above which a direct hit counts as a crash.
## 8.0 ≈ a 4 m/s impact at the default mass of 2.0 kg. The free-fall drop from
## the spawn point onto the pad arrives at ~6.1 kg·m/s — the threshold must
## stay above that or the drone crashes on game start.
@export var crash_momentum_threshold: float = 8.0
## Max angle between the (reversed) impact velocity and the contact normal for
## the hit to count as "direct". Grazing contacts beyond this angle only bounce.
@export var crash_max_impact_angle_deg: float = 60.0

# Per-rotor hover throttle: (mass * gravity) / (4 * max_thrust)
var hover_throttle: float = 0.0

# --- Assisted flight modes (altitude hold + brake) ---
var _altitude_hold: FlightModeAltitudeHold = null
var _brake: BrakeAssist = null
var _altitude_hold_engaged: bool = false
var _brake_engaged: bool = false
var _gravity: float = 9.8

# --- Angular damping ---
## Prevents spin-out. Yaw gets higher damping — roll maneuvers can induce
## yaw via natural thumb drift on the stick, and this keeps it in check.
@export var damping_factor: Vector3 = Vector3(0.08, 1.0, 0.08)  # pitch, yaw, roll

# --- Flight modes ---
var _flight_modes: Dictionary = {}
var _current_mode: FlightModeBase = null

# --- State ---
enum State { FLYING, CRASHED }

var _state: State = State.FLYING
var _throttle_input: float = 0.0
var _pitch_input: float = 0.0
var _roll_input: float = 0.0
var _yaw_input: float = 0.0
var _fpv_enabled: bool = false
var _spawn_transform: Transform3D

## Velocity at the end of the previous physics tick. Used as the impact velocity
## for crash detection — by the time a contact is reported, the solver has
## already absorbed much of the impact from linear_velocity.
var _prev_velocity: Vector3 = Vector3.ZERO

var _flight_mode: String = "acro"

## Average of the last applied rotor mix (post anti-clip/idle clamping), as a
## 0..100 percentage. This is the actual commanded thrust, not a recomputed
## approximation — read by the HUD instead of re-deriving it independently.
var thrust_percent: float = 0.0

# --- Blender models (GLB) ---
# The drone's body, arms, and propellers are authored in Blender
# (assets/models/drone_parts.blend) and exported as GLB. Each GLB carries one
# representative part mesh; we assign those meshes to the anchor nodes in the
# scene. See AGENTS.md "Coordinate System" for how Blender axes map to Godot.
const BODY_GLB: PackedScene = preload("res://assets/models/drone_body.glb")
const ARM_GLB: PackedScene = preload("res://assets/models/arm.glb")
const PROP_GLB: PackedScene = preload("res://assets/models/propeller.glb")

# --- Rotor visual ---
# Front rotors (FL/FR) and back rotors (BL/BR) use different-colored Blender
# props for at-a-glance orientation. The idle mesh + spin-disc tint are tracked
# per rotor so each keeps its color.
var _rotor_nodes: Array[MeshInstance3D] = []
var _rotor_idle_meshes: Array[Mesh] = []        # per-rotor stopped prop
var _rotor_spin_materials: Array[Material] = []  # per-rotor tinted blur disc
var _rotor_spin_mesh: Mesh                        # shared blur-disc geometry
var _armed: bool = false

# Rotor positions in local body frame. Order is [FL, FR, BL, BR] and MUST match
# the mixer output order. Forward (nose) = −Z, right = +X. See AGENTS.md
# "Coordinate System" — this array is the ground truth the names describe.
var _rotor_positions: Array[Vector3] = [
	Vector3(-0.25, 0.07, -0.25),  # FL — front-left  (nose = −Z, left = −X)
	Vector3( 0.25, 0.07, -0.25),  # FR — front-right
	Vector3(-0.25, 0.07,  0.25),  # BL — back-left   (tail = +Z)
	Vector3( 0.25, 0.07,  0.25),  # BR — back-right
]


func _ready() -> void:
	_spawn_transform = global_transform
	gravity_scale = 1.0
	angular_damp = 0.0
	linear_damp = 0.0  # replaced by explicit relative-airspeed drag below; engine default 0.1 remains

	_gravity = ProjectSettings.get_setting("physics/3d/default_gravity")
	hover_throttle = (mass * _gravity) / (4.0 * max_thrust)

	var acro := FlightModeAcro.new()
	_flight_modes["acro"] = acro

	var stabilized := FlightModeStabilized.new()
	stabilized.hover_throttle = hover_throttle
	stabilized.max_thrust = max_thrust
	_flight_modes["stabilized"] = stabilized

	_current_mode = _flight_modes[_flight_mode]

	_altitude_hold = FlightModeAltitudeHold.new()
	_altitude_hold.hover_throttle = hover_throttle

	_brake = BrakeAssist.new()
	_brake.max_thrust = max_thrust

	_setup_visuals()


func _setup_visuals() -> void:
	# The body, arms, and rotors are bare Node3D markers positioned in drone.tscn
	# (markers, not MeshInstance3D, so the editor shows no "missing mesh"
	# warnings). Geometry comes from the Blender GLB models, attached as a
	# MeshInstance3D child of each marker at runtime.
	_attach_mesh(get_node_or_null("Body"), _mesh_from_glb(BODY_GLB))

	var arm_mesh := _mesh_from_glb(ARM_GLB)
	for arm_name in ["ArmFL", "ArmFR", "ArmBL", "ArmBR"]:
		_attach_mesh(get_node_or_null(arm_name), arm_mesh)

	# Propeller: propeller.glb exports a front-colored prop (PropFL) and a
	# back-colored prop (PropBL). Front rotors get the front prop, back the back.
	var front := _part_from_glb(PROP_GLB, "PropFL")
	var back := _part_from_glb(PROP_GLB, "PropBL")

	# Shared blur-disc geometry (prop spans ~0.18, so radius ~0.09).
	var disc := CylinderMesh.new()
	disc.top_radius = 0.09
	disc.bottom_radius = 0.09
	disc.height = 0.006
	_rotor_spin_mesh = disc

	# Attach the matching stopped prop to each rotor marker and build the
	# per-rotor spin disc, colored in code from the prop's color.
	for rotor_name in ["RotorFL", "RotorFR", "RotorBL", "RotorBR"]:
		var marker := get_node_or_null(rotor_name) as Node3D
		if marker == null:
			continue
		var part: Dictionary = front if rotor_name.begins_with("RotorF") else back
		var part_mesh: Mesh = part.get("mesh")
		_rotor_nodes.append(_attach_mesh(marker, part_mesh))
		_rotor_idle_meshes.append(part_mesh)
		_rotor_spin_materials.append(_make_spin_material(part.get("color")))


## Add a MeshInstance3D child holding `mesh` to a marker node. Returns the new
## MeshInstance3D (or null if the marker is missing).
func _attach_mesh(marker: Node, mesh: Mesh) -> MeshInstance3D:
	if marker == null:
		return null
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	marker.add_child(mi)
	return mi


## Build a translucent, emissive blur-disc material of the given color.
func _make_spin_material(color: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(color.r, color.g, color.b, 0.4)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = 0.5
	return mat


## Instantiate a GLB PackedScene and return the first MeshInstance3D's mesh.
func _mesh_from_glb(scene: PackedScene) -> Mesh:
	if scene == null:
		return null
	var inst := scene.instantiate()
	var mi := _first_mesh_instance(inst)
	var mesh: Mesh = mi.mesh if mi else null
	inst.free()
	return mesh


## Instantiate a GLB and return {mesh, color} for the named MeshInstance3D
## (falls back to the first one found). Color comes from the mesh's material.
func _part_from_glb(scene: PackedScene, node_name: String) -> Dictionary:
	if scene == null:
		return {"mesh": null, "color": Color.WHITE}
	var inst := scene.instantiate()
	var mi := inst.find_child(node_name, true, false) as MeshInstance3D
	if mi == null:
		mi = _first_mesh_instance(inst)
	var mesh: Mesh = mi.mesh if mi else null
	var color := Color(0.5, 0.5, 0.5)
	if mi:
		var mat := mi.get_active_material(0)
		if mat == null and mi.mesh:
			mat = mi.mesh.surface_get_material(0)
		if mat is StandardMaterial3D:
			color = (mat as StandardMaterial3D).albedo_color
	inst.free()
	return {"mesh": mesh, "color": color}


## Depth-first search for the first MeshInstance3D under a node.
func _first_mesh_instance(node: Node) -> MeshInstance3D:
	if node is MeshInstance3D:
		return node
	for c in node.get_children():
		var found := _first_mesh_instance(c)
		if found:
			return found
	return null


func _unhandled_input(event: InputEvent) -> void:
	# While CRASHED the signal is lost: only reset (Triangle) and the camera
	# toggle (R1 — the camera belongs to the pilot, not the dead drone) work.
	if event.is_action_pressed("toggle_flight_mode") and _state == State.FLYING:
		_toggle_flight_mode()
	if event.is_action_pressed("toggle_fpv"):
		_toggle_fpv()
	if event.is_action_pressed("reset_drone"):
		reset()


func _physics_process(delta: float) -> void:
	# Wind drag acts unconditionally — even while CRASHED, the wreck should
	# drift downwind, same as the old engine linear_damp did.
	wind_velocity = _sample_wind()
	apply_central_force(air_drag_coefficient * (wind_velocity - linear_velocity))

	if _state == State.FLYING:
		_read_inputs()
		_compute_and_apply_forces(delta)
		_apply_angular_damping()
	# While CRASHED: no inputs, no rotor forces, no damping — gravity and
	# inertia carry the airframe until it settles.

	_prev_velocity = linear_velocity

	# Fallback alongside the _unhandled_input edge trigger below: on some
	# controller/OS combinations a quick tap doesn't cross the action's
	# strength threshold in time to register on its own input event (see
	# AGENTS.md "Known Issues" for detail). Polling once per physics tick
	# catches it a tick later even if the discrete event was missed.
	# reset() is idempotent, so double-firing in the same frame is harmless.
	if Input.is_action_just_pressed("reset_drone"):
		reset()


func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	# Crash detection. Contacts require contact_monitor = true and
	# max_contacts_reported > 0 on the RigidBody3D (set in drone.tscn).
	if _state == State.CRASHED or state.get_contact_count() == 0:
		return
	# Zero-velocity guard: resting contact (e.g. sitting on the spawn pad)
	# has no meaningful impact velocity — normalized() would be undefined.
	if _prev_velocity.length() < 0.05:
		return
	var momentum: float = _prev_velocity.length() * mass
	# Contact normal points away from the surface, toward this body, so a
	# head-on impact has velocity anti-parallel to it: alignment = 1.0.
	var normal: Vector3 = state.get_contact_local_normal(0)
	var alignment: float = -_prev_velocity.normalized().dot(normal)
	# Crash needs momentum high AND the hit direct; a slow or grazing contact
	# is just a bounce.
	if momentum > crash_momentum_threshold \
			and alignment > cos(deg_to_rad(crash_max_impact_angle_deg)):
		_crash(momentum)


func _crash(momentum: float) -> void:
	_state = State.CRASHED
	_throttle_input = 0.0
	_pitch_input = 0.0
	_roll_input = 0.0
	_yaw_input = 0.0
	_altitude_hold_engaged = false
	_brake_engaged = false
	thrust_percent = 0.0
	_set_armed(false)  # motors dead — props stop
	crash_detected.emit()
	print("[Drone] CRASH — signal lost (impact momentum %.1f kg·m/s)" % momentum)


func _read_inputs() -> void:
	_throttle_input = Input.get_action_strength("throttle_up") - Input.get_action_strength("throttle_down")
	_yaw_input = Input.get_action_strength("yaw_right") - Input.get_action_strength("yaw_left")
	_pitch_input = Input.get_action_strength("pitch_backward") - Input.get_action_strength("pitch_forward")
	_roll_input = Input.get_action_strength("roll_right") - Input.get_action_strength("roll_left")
	_altitude_hold_engaged = Input.get_action_strength("altitude_hold") > 0.5
	_brake_engaged = Input.get_action_strength("brake_mode") > 0.5


func _compute_and_apply_forces(delta: float) -> void:
	if _current_mode == null:
		return

	var control: FlightModeBase.FlightControl = _current_mode.compute(
		_throttle_input, _pitch_input, _roll_input, _yaw_input,
		global_transform.basis, angular_velocity, delta
	)

	if _altitude_hold_engaged or _altitude_hold.is_active():
		control.collective = _altitude_hold.update(
			_altitude_hold_engaged, global_position.y, linear_velocity.y, control.collective, delta
		)

	if _brake_engaged:
		var horizontal_vel := Vector3(linear_velocity.x, 0.0, linear_velocity.z)
		var brake_offset: Vector2 = _brake.compute(
			horizontal_vel, global_transform.basis, angular_velocity, _gravity
		)
		control.pitch_diff += brake_offset.x
		control.roll_diff += brake_offset.y

	var mix := _mix_rotors(control.collective, control.pitch_diff, control.roll_diff)
	thrust_percent = (mix.fl + mix.fr + mix.bl + mix.br) * 0.25 * 100.0

	# Rotor visual: swap between the Blender prop (idle) and a tinted blur disc
	# (spinning) based on throttle cut.
	_set_armed(control.collective >= 0.001)

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
	# FL/FR are at the nose (−Z), BL/BR at the tail (+Z); FL/BL are on the left
	# (−X). Positive pitch = nose up → front rotors get more thrust. Positive
	# roll = roll right → left rotors get more thrust. (See AGENTS.md.)
	result.fl = collective + clipped_pitch + clipped_roll
	result.fr = collective + clipped_pitch - clipped_roll
	result.bl = collective - clipped_pitch + clipped_roll
	result.br = collective - clipped_pitch - clipped_roll
	# Final clamp: MIN_ROTOR only applies when collective is on (throttle not cut)
	result.fl = clampf(result.fl, MIN_ROTOR, 1.0)
	result.fr = clampf(result.fr, MIN_ROTOR, 1.0)
	result.bl = clampf(result.bl, MIN_ROTOR, 1.0)
	result.br = clampf(result.br, MIN_ROTOR, 1.0)
	return result


## Swap rotor visuals between the tinted blur disc (armed) and the static
## Blender prop (idle). No-op if the state is unchanged.
func _set_armed(armed: bool) -> void:
	if armed == _armed:
		return
	_armed = armed
	for i in _rotor_nodes.size():
		if _armed:
			_rotor_nodes[i].mesh = _rotor_spin_mesh
			_rotor_nodes[i].material_override = _rotor_spin_materials[i]
		else:
			_rotor_nodes[i].mesh = _rotor_idle_meshes[i]
			_rotor_nodes[i].material_override = null


## Lazily discovers the WindField (group "wind_field") on first use — Drone
## precedes WindField in main.tscn's tree order, so _ready() is too early.
## No WindField in the scene (e.g. the flight-mode test scene) means zero wind.
func _sample_wind() -> Vector3:
	if not _wind_field_searched:
		_wind_field_searched = true
		_wind_field = get_tree().get_first_node_in_group("wind_field")
	if _wind_field == null:
		return Vector3.ZERO
	return _wind_field.get_wind(global_position)


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
	_prev_velocity = Vector3.ZERO
	global_transform = _spawn_transform
	_state = State.FLYING
	print("[Drone] Reset to spawn")


func get_flight_mode() -> String:
	return _flight_mode


func is_fpv_enabled() -> bool:
	return _fpv_enabled


func is_crashed() -> bool:
	return _state == State.CRASHED
