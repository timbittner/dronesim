class_name DroneController
extends RigidBody3D

## Core drone flight controller.
## Three-layer pipeline: FlightMode → Mixer → Force application.
## Per-rotor thrust vectoring: each rotor applies force at its arm position.
## Mode 2 layout: left stick = throttle/yaw, right stick = pitch/roll.

## Emitted when the pilot toggles between acro and stabilized (L1).
signal flight_mode_changed(mode_name: String)
## Emitted when the pilot toggles the FPV camera (R1).
signal fpv_toggled(enabled: bool)
## Emitted once at the moment a hard impact kills the "signal" (see _crash()).
## Environment-side observers (CrashEffects, HUD) react; the controller itself
## only owns the FLYING → CRASHED state change.
signal crash_detected
## Emitted after a reset() teleports back to spawn — one "flight" ended and a
## new one began (FlightRecorder rotates its log file on this).
signal drone_reset

# --- Pilot ---
## True for the one drone the player flies (joins group "player_drone" —
## resolved by camera/HUD/recorder). False for swarm followers (P6): stick
## input and button handling are skipped entirely; a FollowerPilot drives the
## drone through its flight mode instead. The physics pipeline below is
## identical either way.
@export var is_player: bool = true

## Set while an external autopilot (the auto-land FollowerPilot) is flying the
## PLAYER's drone: stick input and the altitude-hold / brake assists are
## suppressed so a held Shift/L2 can't fight the automated descent. Followers
## (is_player = false) never read input, so this only matters for the player.
var under_autopilot: bool = false

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

# --- Signal degradation (P5) ---
## Radio link quality 0..1 sampled from the SignalField this tick (1 = perfect).
## Read by the HUD to drive FPV static intensity.
var signal_quality: float = 1.0
## Mean control dropouts per second at zero quality; scales linearly with
## (1 - signal_quality). A dropout holds the last inputs stale (not zeroed,
## like a real RC link) for a short random window.
@export var packet_loss_rate: float = 3.0
## Seconds of sustained zero quality before the link dies (lose_signal()).
@export var signal_loss_grace: float = 1.5

var _signal_field: Node = null
var _signal_field_searched: bool = false
var _dropout_timer: float = 0.0
var _zero_quality_time: float = 0.0

# --- Crash detection ---
## Impact momentum (kg·m/s) above which a direct hit counts as a crash.
## 8.0 ≈ a 4 m/s impact at the default mass of 2.0 kg. The free-fall drop from
## the spawn point onto the pad arrives at ~6.1 kg·m/s — the threshold must
## stay above that or the drone crashes on game start.
@export var crash_momentum_threshold: float = 8.0
## Max angle between the (reversed) impact velocity and the contact normal for
## the hit to count as "direct". Grazing contacts beyond this angle only bounce.
@export var crash_max_impact_angle_deg: float = 60.0

# --- Prop obstruction ---
## Prop-disc query radius, m — the real prop's blade-tip sweep (see
## propeller.glb: ~0.09 m blade length, so ~0.09 m from hub to tip; bumped
## a bit further out here for margin). A rotor whose disc overlaps terrain
## or another drone body produces zero thrust that tick. Range roughly 0.09
## to 0.14.
@export var prop_radius: float = 0.12
## Thickness of the prop-disc query shape, m — thin, since a prop is a flat
## sweep, not a ball. Range roughly 0.02 to 0.08.
@export var prop_disc_height: float = 0.04
## Impact speed (m/s, previous-tick velocity) above which a rotor going
## 0→obstructed under commanded throttle latches permanently broken (state 2)
## instead of just transiently blocked. Range roughly 2 to 5.
@export var prop_break_speed: float = 3.0
## Debug-only: draw each rotor's exact prop-disc query shape in the world,
## tinted by state (free/obstructed/broken). Off by default — zero cost when
## false. Toggle in-game via the HUD submenu (PadMenu "PROP DBG").
@export var show_prop_debug: bool = false

## Per-rotor obstruction state, order matches _rotor_positions (FL, FR, BL, BR).
## 0 = free, 1 = obstructed (transient, recomputed every tick), 2 = broken
## (latched until reset()).
var _prop_state: Array[int] = [0, 0, 0, 0]
var _prop_query_shape: CylinderShape3D = null
var _prop_query_params: PhysicsShapeQueryParameters3D = null

# --- Prop debug visualization (lazily built, only when show_prop_debug) ---
var _prop_debug_meshes: Array[MeshInstance3D] = []
var _prop_debug_built_radius: float = -1.0
var _prop_debug_built_height: float = -1.0
const _PROP_DEBUG_COLORS: Array[Color] = [
	Color(0.3, 1.0, 1.0, 0.35),  # 0 free — cyan
	Color(1.0, 0.65, 0.0, 0.5),  # 1 obstructed — amber
	Color(1.0, 0.15, 0.15, 0.6),  # 2 broken — red
]

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
## Stored so _sync_stabilized_gains() can push the exports below every tick —
## FlightModeStabilized is RefCounted (created via .new()), so its own
## @export vars never surface in any inspector. Same pattern as
## SwarmManager's "Formation Gains" pushed into each FollowerPilot.
var _stabilized: FlightModeStabilized = null

## Pushed into the stabilized mode every physics tick (see
## _sync_stabilized_gains()), so they're live-tunable in the inspector while
## flying — mirrors SwarmManager's "Formation Gains" export group.
@export_group("Stabilized Gains")
## Stick-deflection span over which rate law and auto-level cross-fade, 0.0–0.5.
@export var stabilized_blend_band: float = 0.2
## Rate-loop gyro low-pass, 0.0–1.0 (lower = smoother/laggier, 1.0 = raw).
@export var stabilized_rate_gyro_filter_alpha: float = 0.5
## Auto-level D-term gyro low-pass, 0.0–1.0 (lower = smoother/laggier).
@export var stabilized_gyro_filter_alpha: float = 0.35
## Auto-level tilt-angle P gain.
@export var stabilized_stabilize_p_gain: float = 15.0
## Auto-level D gain (on the filtered gyro reading).
@export var stabilized_stabilize_d_gain: float = 4.0
## Rate-law P gain (target rate vs filtered angular velocity).
@export var stabilized_rate_p_gain: float = 4.0
## Max commanded pitch rate, rad/s.
@export var stabilized_max_pitch_rate: float = 1.5
## Max commanded roll rate, rad/s.
@export var stabilized_max_roll_rate: float = 1.5
## Max commanded yaw rate, rad/s.
@export var stabilized_max_yaw_rate: float = 1.0

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

var _flight_mode: String = "stabilized"

## Average of the last applied rotor mix (post anti-clip/idle clamping), as a
## 0..100 percentage. This is the actual commanded thrust, not a recomputed
## approximation — read by the HUD instead of re-deriving it independently.
var thrust_percent: float = 0.0

## Last applied per-rotor mix in fl, fr, bl, br order (post anti-clip/idle
## clamping), 0..1 each. Same expose-for-observer pattern as thrust_percent —
## read by FlightRecorder; commanded rotor outputs aren't observable outside.
var last_mix: Array[float] = [0.0, 0.0, 0.0, 0.0]

# Authored in Blender (assets/models/drone_parts.blend), exported as GLB.
# See AGENTS.md "Coordinate System" for how Blender axes map to Godot.
const BODY_GLB: PackedScene = preload("res://assets/models/drone_body.glb")
const ARM_GLB: PackedScene = preload("res://assets/models/arm.glb")
const PROP_GLB: PackedScene = preload("res://assets/models/propeller.glb")

# Front rotors (FL/FR) and back rotors (BL/BR) use different-colored Blender
# props for at-a-glance orientation; idle mesh + spin-disc tint tracked per rotor.
var _rotor_nodes: Array[MeshInstance3D] = []
var _rotor_idle_meshes: Array[Mesh] = []        # per-rotor stopped prop
var _rotor_spin_materials: Array[Material] = []  # per-rotor tinted blur disc
var _rotor_spin_mesh: Mesh                        # shared blur-disc geometry
var _armed: bool = false
## Set each tick from _integrate_forces' contact count — the body hitbox is
## already monitored for crash detection, so we reuse it to gate the per-prop
## shape casts: no body contact this tick ⇒ nothing can be clipping a prop.
var _body_in_contact: bool = false

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
	add_to_group("drone")  # resolved by mission targets / tracker (P5)
	if is_player:
		add_to_group("player_drone")  # resolved by camera / HUD / recorder (P6)
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
	_stabilized = stabilized

	_current_mode = _flight_modes[_flight_mode]

	_altitude_hold = FlightModeAltitudeHold.new()
	_altitude_hold.hover_throttle = hover_throttle

	_brake = BrakeAssist.new()
	_brake.max_thrust = max_thrust

	_prop_query_shape = CylinderShape3D.new()
	_prop_query_shape.radius = prop_radius
	_prop_query_shape.height = prop_disc_height
	_prop_query_params = PhysicsShapeQueryParameters3D.new()
	_prop_query_params.shape = _prop_query_shape
	_prop_query_params.exclude = [get_rid()]

	_setup_visuals()


func _setup_visuals() -> void:
	# Body/arms/rotors are bare Node3D markers in drone.tscn (not MeshInstance3D,
	# so the editor shows no "missing mesh" warnings); GLB meshes attach here.
	_attach_mesh(get_node_or_null("Body"), _mesh_from_glb(BODY_GLB))

	var arm_mesh := _mesh_from_glb(ARM_GLB)
	for arm_name in ["ArmFL", "ArmFR", "ArmBL", "ArmBR"]:
		_attach_mesh(get_node_or_null(arm_name), arm_mesh)

	var front := _part_from_glb(PROP_GLB, "PropFL")
	var back := _part_from_glb(PROP_GLB, "PropBL")

	# Blur-disc geometry (prop spans ~0.18, so radius ~0.09).
	var disc := CylinderMesh.new()
	disc.top_radius = 0.09
	disc.bottom_radius = 0.09
	disc.height = 0.006
	_rotor_spin_mesh = disc

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
	if not is_player:
		return
	# While CRASHED the signal is lost: only reset (Triangle) and the camera
	# toggle (R1 — the camera belongs to the pilot, not the dead drone) work.
	if event.is_action_pressed("toggle_flight_mode") and _state == State.FLYING \
			and not under_autopilot:
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

	signal_quality = _sample_signal_quality()

	if _state == State.FLYING:
		if signal_quality <= 0.01:
			_zero_quality_time += delta
			if _zero_quality_time >= signal_loss_grace:
				lose_signal()
		else:
			_zero_quality_time = 0.0

	if _state == State.FLYING:
		# Packet loss: freeze the current inputs for a short window with a
		# probability that grows as signal quality drops.
		if _dropout_timer > 0.0:
			_dropout_timer -= delta
		else:
			_read_inputs()
			if randf() < (1.0 - signal_quality) * packet_loss_rate * delta:
				_dropout_timer = randf_range(0.1, 0.4)
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
	if is_player and Input.is_action_just_pressed("reset_drone"):
		reset()


func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	# Crash detection. Contacts require contact_monitor = true and
	# max_contacts_reported > 0 on the RigidBody3D (set in drone.tscn).
	# Record contact presence first — the prop-obstruction gate reuses it.
	_body_in_contact = state.get_contact_count() > 0
	if _state == State.CRASHED or not _body_in_contact:
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
	_enter_crashed()
	print("[%s] CRASH — signal lost (impact momentum %.1f kg·m/s)" % [name, momentum])


## Kill the radio link without an impact: same CRASHED transition as a crash
## (rotors cut, inputs dead, physics tumbles the airframe — no magic forces).
## Called on sustained-zero signal quality and by the radar shoot-down (P5);
## reset() recovers as usual.
func lose_signal() -> void:
	if _state == State.CRASHED:
		return
	_enter_crashed()
	print("[%s] SIGNAL LOST — radio link dead" % name)


func _enter_crashed() -> void:
	_state = State.CRASHED
	_throttle_input = 0.0
	_pitch_input = 0.0
	_roll_input = 0.0
	_yaw_input = 0.0
	_altitude_hold_engaged = false
	_brake_engaged = false
	thrust_percent = 0.0
	last_mix = [0.0, 0.0, 0.0, 0.0]
	_set_armed(false)  # motors dead — props stop
	crash_detected.emit()


func _read_inputs() -> void:
	if not is_player:
		return  # followers: the pilot drives the flight mode's target directly
	if under_autopilot:
		# Auto-land owns the drone: zero the sticks and drop the assists so held
		# Shift/L2 can't override the descent (the only inputs still live are the
		# menu's take-off and Triangle reset, both handled elsewhere).
		_throttle_input = 0.0
		_yaw_input = 0.0
		_pitch_input = 0.0
		_roll_input = 0.0
		_altitude_hold_engaged = false
		_brake_engaged = false
		return
	_throttle_input = Input.get_action_strength("throttle_up") - Input.get_action_strength("throttle_down")
	_yaw_input = Input.get_action_strength("yaw_right") - Input.get_action_strength("yaw_left")
	_pitch_input = Input.get_action_strength("pitch_backward") - Input.get_action_strength("pitch_forward")
	_roll_input = Input.get_action_strength("roll_right") - Input.get_action_strength("roll_left")
	_altitude_hold_engaged = Input.get_action_strength("altitude_hold") > 0.5
	_brake_engaged = Input.get_action_strength("brake_mode") > 0.5


## Pushes the "Stabilized Gains" export block into the stored FlightModeStabilized
## instance every physics tick — same live-tuning pattern as SwarmManager's
## "Formation Gains" push into each FollowerPilot.
func _sync_stabilized_gains() -> void:
	if _stabilized == null:
		return
	_stabilized.blend_band = stabilized_blend_band
	_stabilized.rate_gyro_filter_alpha = stabilized_rate_gyro_filter_alpha
	_stabilized.gyro_filter_alpha = stabilized_gyro_filter_alpha
	_stabilized.stabilize_p_gain = stabilized_stabilize_p_gain
	_stabilized.stabilize_d_gain = stabilized_stabilize_d_gain
	_stabilized.rate_p_gain = stabilized_rate_p_gain
	_stabilized.max_pitch_rate = stabilized_max_pitch_rate
	_stabilized.max_roll_rate = stabilized_max_roll_rate
	_stabilized.max_yaw_rate = stabilized_max_yaw_rate


func _compute_and_apply_forces(delta: float) -> void:
	if _current_mode == null:
		return

	_sync_stabilized_gains()

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
	var armed: bool = control.collective >= 0.001
	_set_armed(armed)

	var throttles: Array[float] = [mix.fl, mix.fr, mix.bl, mix.br]
	# Prop obstruction runs only when armed AND the body is actually touching
	# something (flag from _integrate_forces): a swarm cruising mid-air does
	# zero shape casts — the cost only lands on the tick something collides.
	# No body contact ⇒ nothing clips a prop, so clear transient obstruction
	# (state 1) but keep permanent breaks (state 2). Disarmed clears everything.
	if armed and _body_in_contact:
		_update_prop_obstruction(throttles)
	elif armed:
		for i in range(4):
			if _prop_state[i] == 1:
				_prop_state[i] = 0
	else:
		_prop_state = [0, 0, 0, 0]

	# Also enter when the flag is off but meshes still exist, so toggling off
	# actually frees them (otherwise the free path never runs). Steady-state
	# cost when off is zero: once freed, both conditions are false.
	if show_prop_debug or not _prop_debug_meshes.is_empty():
		_update_prop_debug()

	var up: Vector3 = global_transform.basis.y
	var live_rotors: int = 0
	for i in range(4):
		if _prop_state[i] != 0:
			throttles[i] = 0.0
			continue
		live_rotors += 1
		var force: Vector3 = up * throttles[i] * max_thrust
		var global_pos: Vector3 = global_transform.basis * _rotor_positions[i]
		apply_force(force, global_pos)
	last_mix = throttles

	if control.yaw_torque != 0.0 and live_rotors > 0:
		# A dead prop also degrades yaw authority — scale by the fraction of
		# rotors still live (4/4 = full authority, 0/4 = none).
		var yaw_scale: float = live_rotors / 4.0
		apply_torque(global_transform.basis * Vector3(0.0, -control.yaw_torque * yaw_scale, 0.0))


## Per-rotor prop-disc shape query — a rotor overlapping terrain or another
## drone body produces zero thrust that tick (rotor-only, no magic: the
## remaining rotors' asymmetric thrust tumbles the airframe naturally).
## ponytail: 4 shape casts, but only on ticks where the body hitbox reports a
## contact (see the _body_in_contact gate at the call site) — a mid-air swarm
## does zero casts, so cost scales with collisions, not drone count. Trade-off:
## a prop tip clipping a thin object the body misses won't register that tick,
## but it self-corrects as the drone sinks into fuller contact.
func _update_prop_obstruction(throttles: Array[float]) -> void:
	var space := get_world_3d().direct_space_state
	for i in range(4):
		if _prop_state[i] == 2:
			continue  # already broken — no need to re-query
		var world_pos: Vector3 = global_transform * _rotor_positions[i]
		# Cylinder axis is +Y (Godot convention); orienting with the airframe
		# basis (not identity) tilts the disc's flat faces with the prop plane
		# as the drone banks, instead of always querying straight down.
		_prop_query_params.transform = Transform3D(global_transform.basis, world_pos)
		var hits: Array = space.intersect_shape(_prop_query_params, 1)
		var was_free: bool = _prop_state[i] == 0
		if hits.is_empty():
			_prop_state[i] = 0
			continue
		_prop_state[i] = 1
		if was_free and throttles[i] > 0.5 and _prev_velocity.length() > prop_break_speed:
			_prop_state[i] = 2
			_break_rotor_visual(i)
			_log_prop_out(i)


## Swap a broken rotor's blur disc back to the idle Blender prop — same
## mechanism as _set_armed(), but per-rotor and permanent until reset().
func _break_rotor_visual(i: int) -> void:
	if i >= _rotor_nodes.size() or _rotor_nodes[i] == null:
		return
	_rotor_nodes[i].mesh = _rotor_idle_meshes[i]
	_rotor_nodes[i].material_override = null


## Builds/tears down and updates the 4 debug prop-disc meshes. Zero cost when
## show_prop_debug is false (called only from behind that flag; also frees any
## already-built meshes the moment it flips off, via the guard below).
func _update_prop_debug() -> void:
	if not show_prop_debug:
		_free_prop_debug()
		return
	if _prop_debug_meshes.is_empty():
		_build_prop_debug()
	elif _prop_debug_built_radius != prop_radius or _prop_debug_built_height != prop_disc_height:
		_free_prop_debug()
		_build_prop_debug()
	for i in range(4):
		var mat := _prop_debug_meshes[i].material_override as StandardMaterial3D
		var color: Color = _PROP_DEBUG_COLORS[_prop_state[i]]
		mat.albedo_color = color
		mat.emission = color


## Lazily create the 4 debug MeshInstance3D children — CylinderMesh sized
## exactly like _prop_query_shape, so what's drawn IS the query hitbox.
func _build_prop_debug() -> void:
	_prop_debug_built_radius = prop_radius
	_prop_debug_built_height = prop_disc_height
	for i in range(4):
		var mesh := CylinderMesh.new()
		mesh.top_radius = prop_radius
		mesh.bottom_radius = prop_radius
		mesh.height = prop_disc_height
		var mi := MeshInstance3D.new()
		mi.mesh = mesh
		var mat := StandardMaterial3D.new()
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.emission_enabled = true
		mat.emission_energy_multiplier = 0.5
		mi.material_override = mat
		mi.position = _rotor_positions[i]
		add_child(mi)
		_prop_debug_meshes.append(mi)


func _free_prop_debug() -> void:
	for mi in _prop_debug_meshes:
		mi.queue_free()
	_prop_debug_meshes.clear()
	_prop_debug_built_radius = -1.0
	_prop_debug_built_height = -1.0


const _ROTOR_NAMES: Array[String] = ["FL", "FR", "BL", "BR"]

## Console + on-screen event log if a HUD is reachable (group "debug_hud",
## same lazily-resolved lookup pattern as SwarmManager._log()); console-only
## otherwise.
func _log_prop_out(i: int) -> void:
	var msg := "[%s] PROP %s OUT" % [name, _ROTOR_NAMES[i]]
	print(msg)
	var hud := get_tree().get_first_node_in_group("debug_hud")
	if hud != null and hud.has_method("log_line"):
		hud.log_line(msg)


## True iff every rotor is non-functional (obstructed or broken) — read by
## FollowerPilot to detect a stranded follower (e.g. tumbled upside-down).
func all_props_disabled() -> bool:
	for state in _prop_state:
		if state == 0:
			return false
	return true


## Minimum rotor throttle fraction. Prevents any rotor from fully cutting out
## during aggressive maneuvers (when collective is positive). Does NOT prevent
## throttle cut — if the user commands zero collective, all rotors go to zero.
const MIN_ROTOR: float = 0.02

## Convert collective + differentials to per-rotor throttles with anti-clip
## scaling AND a uniform-shift ceiling (see the two comments below) — this is
## the same two-stage approach real flight-controller mixers use.
static func _mix_rotors(collective: float, pitch: float, roll: float) -> FlightModeBase.RotorMix:
	# Throttle cut: user commanded zero power, all rotors off.
	if collective < 0.001:
		var cut_result := FlightModeBase.RotorMix.new()
		cut_result.fl = 0.0
		cut_result.fr = 0.0
		cut_result.bl = 0.0
		cut_result.br = 0.0
		return cut_result

	var total_correction: float = absf(pitch) + absf(roll)
	var clipped_pitch: float = pitch
	var clipped_roll: float = roll

	if total_correction > 0.001:
		# Largest achievable |pitch|+|roll| "spread" for ANY uniform downward
		# shift of the whole mix (see below): fitting a symmetric spread into
		# [MIN_ROTOR, 1.0] costs at most half that range's width, however the
		# shift positions it. But a downward-only shift can only ever help
		# the ceiling — it makes the MIN_ROTOR floor worse, never better —
		# so at low/mid collective the floor is still the tighter bound and
		# this reduces to the old symmetric-headroom formula unchanged; only
		# past the crossover (roughly collective > 0.5) does the shift buy
		# more spread than before, which is exactly the case that used to
		# clip all differential to zero at 100% throttle.
		var max_spread: float = minf(collective - MIN_ROTOR, (1.0 - MIN_ROTOR) * 0.5)
		if total_correction > max_spread:
			var clip_scale: float = max_spread / total_correction
			clipped_pitch *= clip_scale
			clipped_roll *= clip_scale

	# FL/FR are at the nose (−Z), BL/BR at the tail (+Z); FL/BL are on the left
	# (−X). Positive pitch = nose up → front rotors get more thrust. Positive
	# roll = roll right → left rotors get more thrust. (See AGENTS.md.)
	var fl: float = collective + clipped_pitch + clipped_roll
	var fr: float = collective + clipped_pitch - clipped_roll
	var bl: float = collective - clipped_pitch + clipped_roll
	var br: float = collective - clipped_pitch - clipped_roll

	# Uniform downward shift: if the differential still pushes the highest
	# rotor past 1.0 (i.e. collective itself was high), bring ALL FOUR down
	# by the overshoot — trading a little collective (climb rate) for full
	# pitch/roll authority, rather than the old behavior of clipping the
	# differential to zero the instant any single rotor would exceed 1.0.
	# Only ever shifts down, never up — never silently adds thrust beyond
	# what was commanded. With zero differential (pitch = roll = 0) the
	# highest rotor is just `collective` itself, which never exceeds 1.0, so
	# this never triggers and max climb rate at full throttle with a
	# centered stick is unaffected.
	var highest: float = maxf(maxf(fl, fr), maxf(bl, br))
	if highest > 1.0:
		var shift: float = highest - 1.0
		fl -= shift
		fr -= shift
		bl -= shift
		br -= shift

	var result := FlightModeBase.RotorMix.new()
	# Final clamp is a safety net — the math above should already land inside
	# [MIN_ROTOR, 1.0], but combined inputs from multiple sources (mode +
	# brake) aren't otherwise bounded before reaching this function.
	result.fl = clampf(fl, MIN_ROTOR, 1.0)
	result.fr = clampf(fr, MIN_ROTOR, 1.0)
	result.bl = clampf(bl, MIN_ROTOR, 1.0)
	result.br = clampf(br, MIN_ROTOR, 1.0)
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


## Lazily discovers the SignalField (group "signal_field") — same pattern as
## _sample_wind(). No SignalField in the scene means a perfect link.
func _sample_signal_quality() -> float:
	if not _signal_field_searched:
		_signal_field_searched = true
		_signal_field = get_tree().get_first_node_in_group("signal_field")
	if _signal_field == null:
		return 1.0
	return _signal_field.get_quality(global_position)


func _apply_angular_damping() -> void:
	var local_ang_vel: Vector3 = global_transform.basis.inverse() * angular_velocity
	var damp_torque_local: Vector3 = -local_ang_vel * damping_factor
	apply_torque(global_transform.basis * damp_torque_local)


## Install and activate an externally built flight mode — the P6 follower
## pilot hands its drone a FlightModeFormation this way. The mode joins the
## mode dictionary under `mode_name` (L1 toggling is player-only, so a
## follower stays in this mode until the pilot swaps it).
func set_flight_mode_object(mode_name: String, mode: FlightModeBase) -> void:
	_flight_modes[mode_name] = mode
	_flight_mode = mode_name
	_current_mode = mode
	flight_mode_changed.emit(_flight_mode)


## Switch to an already-installed mode by name — the auto-land pilot restores
## the player's previous mode ("acro"/"stabilized") through this on release.
func select_flight_mode(mode_name: String) -> void:
	if not _flight_modes.has(mode_name):
		return
	_flight_mode = mode_name
	_current_mode = _flight_modes[mode_name]
	flight_mode_changed.emit(_flight_mode)


func _toggle_flight_mode() -> void:
	_flight_mode = "acro" if _flight_mode == "stabilized" else "stabilized"
	_current_mode = _flight_modes[_flight_mode]
	flight_mode_changed.emit(_flight_mode)
	print("[Drone] Flight mode: ", _flight_mode)


func _toggle_fpv() -> void:
	_fpv_enabled = not _fpv_enabled
	fpv_toggled.emit(_fpv_enabled)
	print("[Drone] FPV: ", _fpv_enabled)


## Teleport back to the spawn pad with zeroed velocities (Triangle). Also the
## only way to recover from a CRASHED / SIGNAL LOST state.
func reset() -> void:
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	_prev_velocity = Vector3.ZERO
	global_transform = _spawn_transform
	_state = State.FLYING
	signal_quality = 1.0
	_zero_quality_time = 0.0
	_dropout_timer = 0.0
	_prop_state = [0, 0, 0, 0]
	for i in _rotor_nodes.size():
		_rotor_nodes[i].mesh = _rotor_idle_meshes[i]
		_rotor_nodes[i].material_override = null
	_armed = false  # forces _set_armed's next call to re-apply spin visuals
	drone_reset.emit()
	print("[Drone] Reset to spawn")


## Current mode name as reported by the active FlightModeBase ("Acro"/"Stabilized").
func get_flight_mode() -> String:
	return _flight_mode


## Whether the FPV camera view is active (vs. the chase camera).
func is_fpv_enabled() -> bool:
	return _fpv_enabled


## Whether the drone is in the CRASHED / SIGNAL LOST state (rotors dead,
## inputs ignored except reset and camera toggle).
func is_crashed() -> bool:
	return _state == State.CRASHED
