extends Node3D

## Scatters visual-only trees and rocks across the terrain at generation time.
## Trees = cone trunk + sphere canopy, rocks = rough box/sphere meshes.
## No collision bodies yet — visual only.

@export var tree_count: int = 300
@export var rock_count: int = 150
@export var scatter_radius: float = 220.0  # stay inside generated terrain
@export var min_spacing: float = 3.0       # min distance between objects
@export var flat_radius: float = 12.0      # keep spawn area clear

# Shared meshes and materials (created once, reused across instances)
var _trunk_mesh: CylinderMesh
var _pine_trunk_mesh: CylinderMesh
var _canopy_sphere: SphereMesh
var _canopy_pine_top: CylinderMesh  # cone-like layered canopy top
var _canopy_pine_mid: CylinderMesh
var _canopy_pine_low: CylinderMesh
var _dead_trunk: CylinderMesh

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
	_rng = RandomNumberGenerator.new()
	_rng.seed = 137
	_setup_meshes_and_materials()
	_scatter_trees()
	_scatter_rocks()


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

		var tree_type := _rng.randi_range(0, 2)
		match tree_type:
			0: _spawn_deciduous(pos)
			1: _spawn_pine(pos)
			2: _spawn_dead_tree(pos)


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


func _spawn_deciduous(pos: Vector3) -> void:
	# Trunk
	var trunk := MeshInstance3D.new()
	trunk.mesh = _trunk_mesh
	trunk.material_override = _trunk_mat
	trunk.transform = Transform3D.IDENTITY.translated(pos + Vector3(0.0, 0.6, 0.0))
	add_child(trunk)

	# Canopy sphere (slightly randomized scale)
	var canopy := MeshInstance3D.new()
	canopy.mesh = _canopy_sphere
	canopy.material_override = _canopy_green_mat if _rng.randf() < 0.6 else _canopy_dark_mat
	var scale_var := 1.0 + _rng.randf_range(-0.2, 0.2)
	canopy.transform = Transform3D.IDENTITY.translated(pos + Vector3(0.0, 1.6, 0.0)) \
		.scaled(Vector3(scale_var, scale_var, scale_var))
	add_child(canopy)


func _spawn_pine(pos: Vector3) -> void:
	# Trunk
	var trunk := MeshInstance3D.new()
	trunk.mesh = _pine_trunk_mesh
	trunk.material_override = _trunk_mat
	trunk.transform = Transform3D.IDENTITY.translated(pos + Vector3(0.0, 0.9, 0.0))
	add_child(trunk)

	# Pine canopy: 3 stacked cone layers
	var layers := [
		{ "mesh": _canopy_pine_low, "y_offset": 1.2 },
		{ "mesh": _canopy_pine_mid, "y_offset": 1.8 },
		{ "mesh": _canopy_pine_top, "y_offset": 2.3 },
	]
	for layer in layers:
		var inst := MeshInstance3D.new()
		inst.mesh = layer["mesh"]
		inst.material_override = _canopy_dark_mat
		inst.transform = Transform3D.IDENTITY.translated(pos + Vector3(0.0, layer["y_offset"], 0.0))
		add_child(inst)


func _spawn_dead_tree(pos: Vector3) -> void:
	var trunk := MeshInstance3D.new()
	trunk.mesh = _dead_trunk
	trunk.material_override = _dead_mat
	trunk.transform = Transform3D.IDENTITY.translated(pos + Vector3(0.0, 0.75, 0.0))
	add_child(trunk)

	# Add a tiny branch stub
	var stub := MeshInstance3D.new()
	var stub_mesh := CylinderMesh.new()
	stub_mesh.top_radius = 0.01
	stub_mesh.bottom_radius = 0.02
	stub_mesh.height = 0.3
	stub.mesh = stub_mesh
	stub.material_override = _dead_mat
	stub.transform = Transform3D.IDENTITY.translated(pos + Vector3(0.2, 1.4, 0.0)) \
		.rotated(Vector3.FORWARD, 0.5)
	add_child(stub)


func _spawn_boulder(pos: Vector3) -> void:
	var rock := MeshInstance3D.new()
	rock.mesh = _rock_box_mesh
	rock.material_override = _rock_mat if _rng.randf() < 0.6 else _rock_light_mat

	var scale_var := 0.6 + _rng.randf_range(0.0, 0.8)
	var rot_y := _rng.randf_range(0.0, TAU)
	var rot_x := _rng.randf_range(-0.3, 0.3)
	var rot_z := _rng.randf_range(-0.3, 0.3)
	rock.transform = Transform3D.IDENTITY.translated(pos + Vector3(0.0, scale_var * 0.1, 0.0)) \
		.scaled(Vector3(scale_var, scale_var, scale_var)) \
		.rotated(Vector3.UP, rot_y) \
		.rotated(Vector3.RIGHT, rot_x) \
		.rotated(Vector3.FORWARD, rot_z)
	add_child(rock)


func _spawn_rubble(pos: Vector3) -> void:
	var rock := MeshInstance3D.new()
	rock.mesh = _rock_sphere_mesh
	rock.material_override = _rock_mat if _rng.randf() < 0.5 else _rock_light_mat

	var scale_var := 0.5 + _rng.randf_range(0.0, 0.6)
	rock.transform = Transform3D.IDENTITY.translated(pos + Vector3(0.0, scale_var * 0.15, 0.0)) \
		.scaled(Vector3(scale_var, scale_var * 0.7, scale_var * 0.8))
	add_child(rock)
