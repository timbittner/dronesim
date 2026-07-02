@tool
class_name Scatter
extends Node3D

## Scatters visual-only trees and rocks across the terrain at generation time.
## Trees = cone trunk + sphere/cone canopy, rocks = rough box/sphere meshes.
## No collision bodies yet — visual only.
##
## Transforms are built explicitly as Transform3D(basis, origin). The chained
## Transform3D.translated()/scaled()/rotated() helpers are GLOBAL (they move the
## origin relative to the world origin), which previously flung canopies off
## their trunks and rocks into the air. Do not reintroduce them here.

@export var tree_count: int = 900
@export var rock_count: int = 220
@export var scatter_radius: float = 220.0  # stay inside generated terrain
@export var min_spacing: float = 4.0       # min distance between objects
@export var flat_radius: float = 12.0      # keep spawn area clear
@export var tree_scale_min: float = 1.6    # per-tree size multiplier range
@export var tree_scale_max: float = 3.0

# Shared meshes and materials (created once, reused across instances)
var _trunk_mesh: CylinderMesh
var _pine_trunk_mesh: CylinderMesh
var _canopy_sphere: SphereMesh
var _canopy_pine_top: CylinderMesh  # cone-like layered canopy top
var _canopy_pine_mid: CylinderMesh
var _canopy_pine_low: CylinderMesh
var _dead_trunk: CylinderMesh
var _stub_mesh: CylinderMesh

var _rock_box_mesh: BoxMesh
var _rock_sphere_mesh: SphereMesh

var _trunk_mat: StandardMaterial3D
var _canopy_green_mat: StandardMaterial3D
var _canopy_dark_mat: StandardMaterial3D
var _dead_mat: StandardMaterial3D
var _rock_mat: StandardMaterial3D
var _rock_light_mat: StandardMaterial3D

# RNG for reproducible placement
var _rng: RandomNumberGenerator


func _ready() -> void:
	# Defer to next frame so parent terrain's _ready() sets up noise first.
	call_deferred("_generate")


func _generate() -> void:
	_clear_generated()
	_rng = RandomNumberGenerator.new()
	_rng.seed = 137
	_setup_meshes_and_materials()
	_scatter_trees()
	_scatter_rocks()


## Frees previously-generated preview nodes. Generated meshes are added without
## an owner, so scene-defined children are left untouched and nothing generated
## is persisted into the .tscn.
func _clear_generated() -> void:
	for child in get_children():
		if child.owner == null:
			remove_child(child)
			child.queue_free()


func _setup_meshes_and_materials() -> void:
	# --- Common trunk ---
	_trunk_mesh = CylinderMesh.new()
	_trunk_mesh.top_radius = 0.04
	_trunk_mesh.bottom_radius = 0.06
	_trunk_mesh.height = 1.2

	_pine_trunk_mesh = CylinderMesh.new()
	_pine_trunk_mesh.top_radius = 0.03
	_pine_trunk_mesh.bottom_radius = 0.05
	_pine_trunk_mesh.height = 1.8

	# --- Canopies ---
	_canopy_sphere = SphereMesh.new()
	_canopy_sphere.radius = 0.6
	_canopy_sphere.height = 1.2

	# Pine layers: stacked cones (using cylinders with top_radius=0)
	_canopy_pine_low = CylinderMesh.new()
	_canopy_pine_low.top_radius = 0.0
	_canopy_pine_low.bottom_radius = 0.7
	_canopy_pine_low.height = 0.8

	_canopy_pine_mid = CylinderMesh.new()
	_canopy_pine_mid.top_radius = 0.0
	_canopy_pine_mid.bottom_radius = 0.5
	_canopy_pine_mid.height = 0.6

	_canopy_pine_top = CylinderMesh.new()
	_canopy_pine_top.top_radius = 0.0
	_canopy_pine_top.bottom_radius = 0.3
	_canopy_pine_top.height = 0.5

	# --- Dead stub ---
	_dead_trunk = CylinderMesh.new()
	_dead_trunk.top_radius = 0.03
	_dead_trunk.bottom_radius = 0.07
	_dead_trunk.height = 1.5

	_stub_mesh = CylinderMesh.new()
	_stub_mesh.top_radius = 0.01
	_stub_mesh.bottom_radius = 0.02
	_stub_mesh.height = 0.3

	# --- Rocks ---
	_rock_box_mesh = BoxMesh.new()
	_rock_box_mesh.size = Vector3(0.3, 0.2, 0.25)

	_rock_sphere_mesh = SphereMesh.new()
	_rock_sphere_mesh.radius = 0.2
	_rock_sphere_mesh.height = 0.3

	# --- Materials ---
	_trunk_mat = StandardMaterial3D.new()
	_trunk_mat.albedo_color = Color(0.35, 0.22, 0.12)
	_trunk_mat.roughness = 0.95

	_canopy_green_mat = StandardMaterial3D.new()
	_canopy_green_mat.albedo_color = Color(0.25, 0.45, 0.18)
	_canopy_green_mat.roughness = 0.85

	_canopy_dark_mat = StandardMaterial3D.new()
	_canopy_dark_mat.albedo_color = Color(0.15, 0.3, 0.12)
	_canopy_dark_mat.roughness = 0.85

	_dead_mat = StandardMaterial3D.new()
	_dead_mat.albedo_color = Color(0.3, 0.25, 0.2)
	_dead_mat.roughness = 0.95

	_rock_mat = StandardMaterial3D.new()
	_rock_mat.albedo_color = Color(0.4, 0.38, 0.35)
	_rock_mat.roughness = 0.9

	_rock_light_mat = StandardMaterial3D.new()
	_rock_light_mat.albedo_color = Color(0.5, 0.48, 0.45)
	_rock_light_mat.roughness = 0.9


## Adds one mesh part at an explicit world origin with an explicit basis.
## Building the Transform3D directly avoids the global translated()/scaled()/
## rotated() helpers, which would displace the origin.
func _add_part(mesh: Mesh, mat: Material, origin: Vector3, part_basis: Basis) -> void:
	var inst := MeshInstance3D.new()
	inst.mesh = mesh
	inst.material_override = mat
	inst.transform = Transform3D(part_basis, origin)
	add_child(inst)


func _scatter_trees() -> void:
	var placed_positions: Array[Vector2] = []

	for _i in range(tree_count):
		var pos := _random_terrain_position()
		if pos == Vector3.ZERO and _i > 0:
			continue

		var pos2d := Vector2(pos.x, pos.z)
		if _too_close(pos2d, placed_positions):
			continue
		placed_positions.append(pos2d)

		var s := _rng.randf_range(tree_scale_min, tree_scale_max)
		var tree_type := _rng.randi_range(0, 2)
		match tree_type:
			0: _spawn_deciduous(pos, s)
			1: _spawn_pine(pos, s)
			2: _spawn_dead_tree(pos, s)


func _scatter_rocks() -> void:
	var placed_positions: Array[Vector2] = []

	for _i in range(rock_count):
		var pos := _random_terrain_position()
		if pos == Vector3.ZERO and _i > 0:
			continue

		var pos2d := Vector2(pos.x, pos.z)
		if _too_close(pos2d, placed_positions):
			continue
		placed_positions.append(pos2d)

		if _rng.randf() < 0.5:
			_spawn_boulder(pos)
		else:
			_spawn_rubble(pos)


func _random_terrain_position() -> Vector3:
	# Try up to 20 times to find a valid position
	for _attempt in 20:
		var x := _rng.randf_range(-scatter_radius, scatter_radius)
		var z := _rng.randf_range(-scatter_radius, scatter_radius)

		# Keep spawn area clear
		var dist := sqrt(x * x + z * z)
		if dist < flat_radius:
			continue

		var h := _get_terrain_height(x, z)
		if h < 0.5 or h > 14.0:
			continue  # skip water or peak tops

		return Vector3(x, h, z)
	return Vector3.ZERO


func _too_close(pos: Vector2, existing: Array[Vector2]) -> bool:
	for other in existing:
		if pos.distance_squared_to(other) < min_spacing * min_spacing:
			return true
	return false


func _get_terrain_height(x: float, z: float) -> float:
	var parent = get_parent()
	if parent and parent.has_method("get_height"):
		return parent.get_height(x, z)
	return 0.0


func _spawn_deciduous(pos: Vector3, s: float) -> void:
	# A small random lean makes the grove feel less uniform.
	var lean := _rng.randf_range(-0.05, 0.05)
	var lean_basis := Basis.from_euler(Vector3(lean, _rng.randf_range(0.0, TAU), lean))
	var trunk_basis := lean_basis * Basis.from_scale(Vector3(s, s, s))

	# Trunk: height 1.2 → centre sits half a (scaled) height above ground.
	_add_part(_trunk_mesh, _trunk_mat, pos + Vector3(0.0, 0.6 * s, 0.0), trunk_basis)

	# Main canopy sphere — bottom overlaps the trunk top so they stay joined.
	var cvar := 1.0 + _rng.randf_range(-0.2, 0.35)
	var canopy_mat := _canopy_green_mat if _rng.randf() < 0.6 else _canopy_dark_mat
	_add_part(_canopy_sphere, canopy_mat, pos + Vector3(0.0, 1.6 * s, 0.0),
		Basis.from_scale(Vector3(s * cvar, s * cvar, s * cvar)))

	# A second, smaller offset blob for a fuller, less perfectly-round crown.
	var off := Vector3(_rng.randf_range(-0.25, 0.25), 1.95, _rng.randf_range(-0.25, 0.25)) * s
	_add_part(_canopy_sphere, canopy_mat, pos + off,
		Basis.from_scale(Vector3(s * 0.7, s * 0.7, s * 0.7)))


func _spawn_pine(pos: Vector3, s: float) -> void:
	var scale_basis := Basis.from_scale(Vector3(s, s, s))

	# Trunk (height 1.8 → centre at 0.9).
	_add_part(_pine_trunk_mesh, _trunk_mat, pos + Vector3(0.0, 0.9 * s, 0.0), scale_basis)

	# Pine canopy: 3 stacked cone layers, each overlapping the one below.
	var layers := [
		{ "mesh": _canopy_pine_low, "y": 1.2 },
		{ "mesh": _canopy_pine_mid, "y": 1.8 },
		{ "mesh": _canopy_pine_top, "y": 2.3 },
	]
	for layer in layers:
		_add_part(layer["mesh"], _canopy_dark_mat,
			pos + Vector3(0.0, layer["y"] * s, 0.0), scale_basis)


func _spawn_dead_tree(pos: Vector3, s: float) -> void:
	var scale_basis := Basis.from_scale(Vector3(s, s, s))

	# Trunk (height 1.5 → centre at 0.75).
	_add_part(_dead_trunk, _dead_mat, pos + Vector3(0.0, 0.75 * s, 0.0), scale_basis)

	# A tiny angled branch stub near the top. Rotation is baked into the basis
	# (local), so the stub stays attached to the trunk.
	var stub_basis := Basis(Vector3.FORWARD, 0.9) * scale_basis
	_add_part(_stub_mesh, _dead_mat, pos + Vector3(0.18 * s, 1.35 * s, 0.0), stub_basis)


func _spawn_boulder(pos: Vector3) -> void:
	var mat := _rock_mat if _rng.randf() < 0.6 else _rock_light_mat
	var scale_var := 0.6 + _rng.randf_range(0.0, 0.9)

	# Random orientation, baked into the basis so it never moves the origin.
	var rot := Basis.from_euler(Vector3(
		_rng.randf_range(-0.3, 0.3),
		_rng.randf_range(0.0, TAU),
		_rng.randf_range(-0.3, 0.3)))
	var rock_basis := rot * Basis.from_scale(Vector3(scale_var, scale_var, scale_var))

	# Sit the boulder in the ground (centre near the surface → half-buried look)
	# so it always reads as resting on the terrain, never floating.
	_add_part(_rock_box_mesh, mat, pos + Vector3(0.0, scale_var * 0.05, 0.0), rock_basis)


func _spawn_rubble(pos: Vector3) -> void:
	var mat := _rock_mat if _rng.randf() < 0.5 else _rock_light_mat
	var sx := 0.5 + _rng.randf_range(0.0, 0.7)
	var rock_basis := Basis(Vector3.UP, _rng.randf_range(0.0, TAU)) \
		* Basis.from_scale(Vector3(sx, sx * 0.7, sx * 0.85))

	# Flattened stone embedded in the ground.
	_add_part(_rock_sphere_mesh, mat, pos + Vector3(0.0, sx * 0.05, 0.0), rock_basis)
