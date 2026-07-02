class_name WindParticles
extends MultiMeshInstance3D

## Advected wind-streak visualization (P2 Phase D). A custom MultiMesh system
## rather than CPUParticles3D, because each streak needs to sample the wind
## at its own position every few frames — per-particle force sampling isn't
## something CPUParticles3D supports. Child of WindField; reads its parent's
## get_wind(). Streaks spawn/advect/respawn in a box centered on the focus
## (the drone, camera fallback), so the visible field always follows the pilot.

@export var focus_path: NodePath = NodePath("../../Drone")
@export var streak_count: int = 300
@export var volume_extents: Vector3 = Vector3(45.0, 25.0, 45.0)
@export var lifetime_range: Vector2 = Vector2(4.0, 8.0)
## Frames between wind resamples for a given streak (staggered per-index so
## the ~300/interval samples needed per frame spread evenly, not all at once).
@export var resample_interval: int = 4
@export var min_visible_speed: float = 0.4
@export var base_alpha: float = 0.35
@export var length_per_speed: float = 0.25

const FADE_TIME: float = 0.5
const MIN_LENGTH: float = 0.2
const MAX_LENGTH: float = 3.0
const RESPAWN_RADIUS_FACTOR: float = 1.2

var _wind_field: WindField = null
var _focus: Node3D = null
var _positions: PackedVector3Array = PackedVector3Array()
var _velocities: PackedVector3Array = PackedVector3Array()
var _ages: PackedFloat32Array = PackedFloat32Array()
var _lifetimes: PackedFloat32Array = PackedFloat32Array()
var _frame: int = 0
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	_wind_field = get_parent() as WindField
	_focus = get_node_or_null(focus_path)
	_rng.randomize()

	var box := BoxMesh.new()
	box.size = Vector3(0.02, 0.02, 1.0)

	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(0.9, 0.92, 0.95, 1.0)
	mat.vertex_color_use_as_albedo = true
	mat.disable_receive_shadows = true
	# MultiMesh instances aren't depth-sorted back-to-front, so overlapping
	# transparent streaks z-fight (visible as flicker/crossing "X" patterns,
	# most noticeable when the camera rotates quickly, e.g. during brake tilt).
	# Disabling the depth *write* (keeping the depth *test*) lets streaks
	# blend with each other while still being occluded by opaque geometry.
	mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	box.material = mat

	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = box
	mm.instance_count = streak_count
	multimesh = mm

	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Streaks roam a box around a moving focus — no fixed local bounds, so use
	# a generously oversized static AABB rather than per-frame recomputation.
	custom_aabb = AABB(-volume_extents * 1.5, volume_extents * 3.0)

	_positions.resize(streak_count)
	_velocities.resize(streak_count)
	_ages.resize(streak_count)
	_lifetimes.resize(streak_count)
	for i in streak_count:
		_respawn(i, _focus_pos())


func _process(delta: float) -> void:
	if _wind_field == null:
		return
	_frame += 1
	var focus_pos := _focus_pos()

	for i in streak_count:
		_ages[i] += delta
		var expired: bool = _ages[i] >= _lifetimes[i]
		var strayed: bool = _positions[i].distance_to(focus_pos) > volume_extents.length() * RESPAWN_RADIUS_FACTOR
		if expired or strayed:
			_respawn(i, focus_pos)
			continue

		if (_frame + i) % resample_interval == 0:
			_velocities[i] = _wind_field.get_wind(_positions[i])

		_positions[i] += _velocities[i] * delta
		_write_instance(i)


func _write_instance(i: int) -> void:
	var speed := _velocities[i].length()

	if speed < 0.05:
		multimesh.set_instance_transform(i, Transform3D(Basis().scaled(Vector3.ZERO), _positions[i]))
		multimesh.set_instance_color(i, Color(1.0, 1.0, 1.0, 0.0))
		return

	var fade := clampf(minf(_ages[i], _lifetimes[i] - _ages[i]) / FADE_TIME, 0.0, 1.0)
	var speed_vis := clampf((speed - min_visible_speed) / maxf(min_visible_speed, 0.001), 0.0, 1.0)
	var alpha := base_alpha * fade * speed_vis

	var length := clampf(speed * length_per_speed, MIN_LENGTH, MAX_LENGTH)
	var dir := _velocities[i] / speed
	var up_guess := Vector3.RIGHT if absf(dir.dot(Vector3.UP)) > 0.99 else Vector3.UP
	var streak_basis := Basis.looking_at(dir, up_guess).scaled(Vector3(1.0, 1.0, length))

	multimesh.set_instance_transform(i, Transform3D(streak_basis, _positions[i]))
	multimesh.set_instance_color(i, Color(1.0, 1.0, 1.0, alpha))


func _respawn(i: int, focus_pos: Vector3) -> void:
	_positions[i] = focus_pos + Vector3(
		_rng.randf_range(-volume_extents.x, volume_extents.x),
		_rng.randf_range(-volume_extents.y, volume_extents.y),
		_rng.randf_range(-volume_extents.z, volume_extents.z)
	)
	_velocities[i] = _wind_field.get_wind(_positions[i]) if _wind_field else Vector3.ZERO
	_ages[i] = 0.0
	_lifetimes[i] = _rng.randf_range(lifetime_range.x, lifetime_range.y)


func _focus_pos() -> Vector3:
	if _focus:
		return _focus.global_position
	var cam := get_viewport().get_camera_3d()
	return cam.global_position if cam else Vector3.ZERO
