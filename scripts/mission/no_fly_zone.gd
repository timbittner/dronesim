@tool
class_name NoFlyZone
extends Node3D

## Polygonal no-fly zone (P7.1). The footprint is a child Path3D named
## "Footprint" — its curve point positions, flattened to local X/Z in order,
## are the polygon corners (implicitly closed, last→first; straight edges
## only, bezier in/out handles are ignored). JAMMING mode self-registers into
## groups "no_fly_zones" and "jammers" — SignalField degrades signal quality
## inside via the duck-typed signal_quality_at(pos) hook, with a soft edge
## instead of a hard wall. SHOOT_DOWN mode tracks any drone inside the
## polygon and shoots it down after countdown_time, mirroring
## AirspaceControl's per-drone countdown + HUD tracking/seconds_left contract.
##
## @tool so the column marker renders and ground-snaps in the editor, and so
## dragging a Footprint point handle rebuilds the marker live; authored Y is
## irrelevant.

enum Mode { JAMMING, SHOOT_DOWN }

@export var mode: Mode = Mode.JAMMING
## JAMMING: signal reduction at any point inside the zone, 0..1 (also the
## value SignalField reads via signal_quality_at).
@export_range(0.0, 1.0) var strength: float = 1.0
## Meters inside the boundary over which jamming eases in — signal is clean
## AT the boundary and reaches the full `strength` reduction this far inside
## (a realistic power falloff instead of a hard wall).
@export var edge_falloff: float = 10.0
@export var countdown_time: float = 10.0
@export var terrain_path: NodePath = NodePath("../Terrain")

# ponytail: side walls only, no top/bottom caps — an open column reads as
# "infinite height" without exporting one. Buried base + a top well above the
# radar ceiling covers any slope in the valley; containment itself is a 2D
# test regardless of what the marker looks like.
const COLUMN_BURY := 60.0
const COLUMN_TOP := 240.0

## Polygon corners in local X/Z, cached from the Footprint child's curve.
## Empty = degenerate zone (neutral: contains_2d always false, no marker).
var _poly: PackedVector2Array = PackedVector2Array()

## True while the PLAYER drone is tracked in SHOOT_DOWN mode and its
## countdown runs — the HUD banner contract, mirrors AirspaceControl.
var tracking: bool = false
## Player countdown remaining in seconds (only meaningful while tracking).
var seconds_left: float = 0.0

var _mesh: MeshInstance3D
## Per-drone countdown remaining, keyed by DroneController instance
## (SHOOT_DOWN only). A drone is "tracked" iff it has an entry.
var _tracks: Dictionary = {}


func _ready() -> void:
	_cache_footprint()
	_connect_footprint_signal()
	_build_marker()
	_snap_to_ground()
	if Engine.is_editor_hint():
		set_notify_transform(true)
		return
	add_to_group("no_fly_zones")
	if mode == Mode.JAMMING:
		add_to_group("jammers")
	if _poly.is_empty():
		print("[NoFlyZone] %s has no valid Footprint child (need a Path3D named Footprint with >= 3 points) — zone is neutral" % name)


func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSFORM_CHANGED and Engine.is_editor_hint():
		_snap_to_ground()


# ponytail: only the node origin is snapped to terrain height, so on a slope
# the polygon corners float or sink — fine for a gizmo, same limitation
# MissionTarget has.
func _snap_to_ground() -> void:
	var terrain := get_node_or_null(terrain_path)
	if terrain == null or not terrain.has_method("get_height"):
		return
	var h: float = terrain.get_height(global_position.x, global_position.z)
	# Guard the write: setting global_position re-fires TRANSFORM_CHANGED, so
	# only correct when it's actually off — otherwise it recurses forever.
	if absf(global_position.y - h) > 0.01:
		global_position.y = h


## Reads the Footprint child's curve point positions in order, flattened to
## local X/Z. Bezier in/out handles are ignored — straight edges only.
func _cache_footprint() -> void:
	_poly = PackedVector2Array()
	var footprint := get_node_or_null("Footprint") as Path3D
	if footprint == null or footprint.curve == null:
		return
	var curve := footprint.curve
	if curve.point_count < 3:
		return
	for i in curve.point_count:
		var p := curve.get_point_position(i)
		_poly.append(Vector2(p.x, p.z))


## Live-editing support: dragging a Footprint point handle in the editor
## rebuilds the polygon + marker immediately. Connected to the Path3D NODE's
## curve_changed (not the curve resource's `changed`) — the editor replaces
## the curve instance when creating the editable-children/local-to-scene
## override copy, which would orphan a resource-level connection and leave
## the marker stale until a scene reload.
func _connect_footprint_signal() -> void:
	if not Engine.is_editor_hint():
		return
	var footprint := get_node_or_null("Footprint") as Path3D
	if footprint == null:
		return
	if not footprint.curve_changed.is_connected(_on_footprint_changed):
		footprint.curve_changed.connect(_on_footprint_changed)


func _on_footprint_changed() -> void:
	_cache_footprint()
	_build_marker()


## Shape predicate — the whole point of this design; SignalField and the
## shoot-down countdown both call it. to_local() handles the node's
## Y-rotation for free, so an angled zone works without extra math. Shape
## lives entirely in _poly + this method + the mesh.
func contains_2d(world_pos: Vector3) -> bool:
	if _poly.size() < 3:
		return false
	var local := to_local(world_pos)
	return Geometry2D.is_point_in_polygon(Vector2(local.x, local.z), _poly)


## Duck-typed jammer contract read by SignalField.get_quality(). Soft edge:
## clean right at the boundary, easing to the full strength reduction
## edge_falloff meters inside. O(edges) per call — fine, one call per drone
## per tick.
func signal_quality_at(pos: Vector3) -> float:
	if not contains_2d(pos):
		return 1.0
	var local := to_local(pos)
	var p := Vector2(local.x, local.z)
	var inward := INF
	var n := _poly.size()
	for i in n:
		var a := _poly[i]
		var b := _poly[(i + 1) % n]
		var closest: Vector2 = Geometry2D.get_closest_point_to_segment(p, a, b)
		inward = minf(inward, p.distance_to(closest))
	return 1.0 - strength * smoothstep(0.0, maxf(edge_falloff, 0.001), inward)


## SHOOT_DOWN tracking, mirrors AirspaceControl's per-drone countdown almost
## verbatim — containment replaces the altitude-ceiling test.
func _physics_process(delta: float) -> void:
	if Engine.is_editor_hint() or mode != Mode.SHOOT_DOWN:
		return
	for drone in get_tree().get_nodes_in_group("drone"):
		_update_drone(drone as DroneController, delta)


func _update_drone(drone: DroneController, delta: float) -> void:
	if drone.is_crashed():
		_untrack(drone)
		return

	if contains_2d(drone.global_position):
		if not _tracks.has(drone):
			_tracks[drone] = countdown_time
			print("[NoFlyZone] RESTRICTED AIRSPACE (%s) — %.0fs to leave"
					% [drone.name, countdown_time])
		_tracks[drone] -= delta
		if _tracks[drone] <= 0.0:
			_tracks.erase(drone)
			print("[NoFlyZone] Shoot-down — %s lingered in the no-fly zone too long" % drone.name)
			drone.lose_signal()  # P7.2: SAM launch slots in here
	elif _tracks.has(drone):
		_tracks.erase(drone)
		print("[NoFlyZone] Track lost — %s left the no-fly zone" % drone.name)

	if drone.is_player:
		tracking = _tracks.has(drone)
		seconds_left = _tracks.get(drone, 0.0)


func _untrack(drone: DroneController) -> void:
	_tracks.erase(drone)
	if drone.is_player:
		tracking = false
		seconds_left = 0.0


## Open column of side walls only (no top/bottom caps) from -COLUMN_BURY to
## +COLUMN_TOP — reads as "infinite height", matching contains_2d's 2D-only
## containment test. Frees the old mesh first (mirrors
## mission_target.gd::_build_marker's is_instance_valid guard).
func _build_marker() -> void:
	if is_instance_valid(_mesh):
		_mesh.queue_free()
	_mesh = null
	if _poly.size() < 3:
		return

	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.albedo_color = Color(1.0, 0.15, 0.1, 0.25)

	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var n := _poly.size()
	for i in n:
		var a := _poly[i]
		var b := _poly[(i + 1) % n]
		var a_bottom := Vector3(a.x, -COLUMN_BURY, a.y)
		var a_top := Vector3(a.x, COLUMN_TOP, a.y)
		var b_bottom := Vector3(b.x, -COLUMN_BURY, b.y)
		var b_top := Vector3(b.x, COLUMN_TOP, b.y)
		var edge := b - a
		var normal := Vector3(edge.y, 0.0, -edge.x).normalized()  # unshaded ignores it; sane outward-ish value
		verts.append_array(PackedVector3Array([a_bottom, b_bottom, b_top]))
		normals.append_array(PackedVector3Array([normal, normal, normal]))
		verts.append_array(PackedVector3Array([a_bottom, b_top, a_top]))
		normals.append_array(PackedVector3Array([normal, normal, normal]))

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals

	var array_mesh := ArrayMesh.new()
	array_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	array_mesh.surface_set_material(0, mat)

	_mesh = MeshInstance3D.new()
	_mesh.mesh = array_mesh
	add_child(_mesh)
