@tool
class_name MissionTarget
extends Node3D

## Editor-placeable mission objective (P5 Phase 6). Drop an instance of
## mission_target.tscn into a scene, pick its type and tune radius/dwell in the
## inspector, and slide it around in the viewport — @tool renders the marker and
## snaps it onto the terrain as you move it, so you only place X/Z. Two types
## share one scene:
##
## - OBSERVE: fly into the capture volume (a cylinder of `radius` × `height`
##   above the ground) and stay for `dwell_time` continuous seconds.
## - CRASH: crash the drone within `radius` of the marker (listens to the
##   drone's crash_detected; a Triangle reset afterwards keeps the run going).
## - DELIVER: drop a payload crate within `radius`; clears when the crate
##   comes to rest inside.
##
## The Y coordinate is irrelevant: the marker is snapped onto the terrain at
## _ready (and on every editor move), and the capture volume is ground-anchored.
## Clearing emits target_cleared and turns the marker green. ALL drones in
## group "drone" count (P6): the player or any swarm follower can observe or
## crash a target. No collision — a trigger volume plus a visual.

signal target_cleared(target: MissionTarget)

enum Type { OBSERVE, CRASH, DELIVER }

@export var type: Type = Type.OBSERVE: set = _set_type
## Horizontal capture radius in meters.
@export var radius: float = 20.0: set = _set_radius
## OBSERVE only: height of the capture cylinder above the ground, in meters.
@export var height: float = 40.0: set = _set_height
## OBSERVE only: continuous seconds inside the volume needed to clear.
@export var dwell_time: float = 3.0
@export var terrain_path: NodePath = NodePath("../Terrain")

## True once the objective is met — read by the HUD compass for its dot color.
var cleared: bool = false

## Drones whose crash_detected is already connected (followers spawn at
## runtime, so the group is re-scanned each tick).
var _crash_connected: Dictionary = {}
var _dwell: float = 0.0
var _mesh: MeshInstance3D
var _mat: StandardMaterial3D
var _base_color: Color


func _ready() -> void:
	_build_marker()
	_snap_to_ground()
	if Engine.is_editor_hint():
		set_notify_transform(true)  # re-snap while dragging in the viewport
		return
	add_to_group("mission_targets")


func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSFORM_CHANGED and Engine.is_editor_hint():
		_snap_to_ground()


func _snap_to_ground() -> void:
	var terrain := get_node_or_null(terrain_path)
	if terrain == null or not terrain.has_method("get_height"):
		return
	var h: float = terrain.get_height(global_position.x, global_position.z)
	# Guard the write: setting global_position re-fires TRANSFORM_CHANGED, so
	# only correct when it's actually off — otherwise it recurses forever.
	if absf(global_position.y - h) > 0.01:
		global_position.y = h


func _physics_process(delta: float) -> void:
	if Engine.is_editor_hint():
		return
	var drones := get_tree().get_nodes_in_group("drone")
	if type == Type.CRASH:
		for drone in drones:
			if not _crash_connected.has(drone):
				_crash_connected[drone] = true
				drone.crash_detected.connect(_on_drone_crashed.bind(drone))

	if cleared:
		return

	if type == Type.DELIVER:
		for p in get_tree().get_nodes_in_group("payloads"):
			var payload := p as Payload
			if payload.is_queued_for_deletion() or not payload.landed:
				continue
			var d: Vector3 = payload.global_position - global_position
			if Vector2(d.x, d.z).length() <= radius:
				_mark_cleared()
				break
		return

	if type != Type.OBSERVE:
		return

	# Cylinder test: within radius horizontally AND inside the height band above
	# the grounded marker. Dwell must be continuous — leaving resets it. Any one
	# drone inside keeps the dwell alive (player or follower).
	var inside := false
	for drone in drones:
		var d: Vector3 = (drone as Node3D).global_position - global_position
		if Vector2(d.x, d.z).length() <= radius and d.y >= 0.0 and d.y <= height:
			inside = true
			break
	if inside:
		_dwell += delta
		# Pulse the volume toward white while the pilot holds inside — a visible
		# "keep waiting" cue driven off the dwell timer.
		var k := 0.5 + 0.5 * sin(_dwell * 8.0)
		_mat.albedo_color = _base_color.lerp(Color(1.0, 1.0, 1.0, 0.55), k)
		if _dwell >= dwell_time:
			_mark_cleared()
	else:
		_dwell = 0.0
		_mat.albedo_color = _base_color


func _on_drone_crashed(drone: DroneController) -> void:
	# crash_detected fires while the drone is still at the impact point.
	if cleared:
		return
	var d := drone.global_position - global_position
	if Vector2(d.x, d.z).length() <= radius:
		_mark_cleared()


func _mark_cleared() -> void:
	cleared = true
	_mat.albedo_color = Color(0.15, 1.0, 0.35, 0.32)  # green + dim
	target_cleared.emit(self)
	print("[Mission] target cleared (%s)" % Type.keys()[type])


func _set_type(v: Type) -> void:
	type = v
	_rebuild()


func _set_radius(v: float) -> void:
	radius = v
	_rebuild()


func _set_height(v: float) -> void:
	height = v
	_rebuild()


## Rebuild the marker after an inspector edit (skipped until _ready has built
## it once — setters also fire during scene load, before the node is ready).
func _rebuild() -> void:
	if is_node_ready():
		_build_marker()


func _build_marker() -> void:
	if is_instance_valid(_mesh):
		_mesh.queue_free()

	_mat = StandardMaterial3D.new()
	_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_mat.cull_mode = BaseMaterial3D.CULL_DISABLED  # visible from inside the volume

	_mesh = MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = radius
	cyl.bottom_radius = radius
	match type:
		Type.OBSERVE:
			cyl.height = height
			cyl.radial_segments = 24
			_mesh.position.y = height * 0.5
			_mat.albedo_color = Color(0.15, 0.75, 1.0, 0.28)  # cyan "observe here" volume
		Type.CRASH:
			# A low translucent drum, not a flat disc: on uneven terrain a
			# ground-flush disc clips into slopes and vanishes, so give it
			# vertical presence.
			cyl.height = 8.0
			cyl.radial_segments = 32
			_mesh.position.y = 4.0
			_mat.albedo_color = Color(1.0, 0.18, 0.12, 0.4)  # red crash zone
		Type.DELIVER:
			# Same low-drum shape as CRASH, amber instead of red.
			cyl.height = 8.0
			cyl.radial_segments = 32
			_mesh.position.y = 4.0
			_mat.albedo_color = Color(1.0, 0.72, 0.1, 0.4)  # amber deliver zone
	cyl.material = _mat
	_mesh.mesh = cyl
	_base_color = _mat.albedo_color
	add_child(_mesh)
