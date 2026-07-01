@tool
class_name TerrainGenerator
extends Node3D

## Procedural noise-based terrain generator for the drone sim.
## Generates a large terrain mesh with vertex coloring and collision.
## A flat area around the origin serves as the spawn pad.

@export var terrain_size: float = 500.0
@export var resolution: int = 250
@export var noise_seed: int = 42
@export var height_scale: float = 15.0
@export var flat_radius: float = 10.0

var _noise: FastNoiseLite
var _mesh_instance: MeshInstance3D
var _static_body: StaticBody3D


func _ready() -> void:
	_generate_terrain()


func _generate_terrain() -> void:
	_clear_generated()
	_setup_noise()
	_build_mesh()
	_build_collision()


## Frees previously-generated preview nodes (mesh + collision) so rebuilds in
## the editor don't stack duplicates. Generated nodes are added without an
## owner, so the scene-defined Scatter child is left untouched and nothing
## generated is persisted into the .tscn.
func _clear_generated() -> void:
	for child in get_children():
		if child is MeshInstance3D or child is StaticBody3D:
			if child.owner == null:
				remove_child(child)
				child.queue_free()


func _setup_noise() -> void:
	_noise = FastNoiseLite.new()
	_noise.seed = noise_seed
	_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_noise.frequency = 0.01
	_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	_noise.fractal_octaves = 4
	_noise.fractal_lacunarity = 2.0
	_noise.fractal_gain = 0.5


## Returns the terrain height at world (x, z), with a flat area near origin.
func get_height(x: float, z: float) -> float:
	var dist := sqrt(x * x + z * z)
	var raw_height := _noise.get_noise_2d(x, z) * height_scale
	# Smooth blend to 0 within flat_radius so the spawn pad area is level.
	var blend_start := flat_radius
	var blend_end := flat_radius + 8.0
	if dist <= blend_start:
		return 0.0
	if dist < blend_end:
		var t := smoothstep(0.0, 1.0, (dist - blend_start) / (blend_end - blend_start))
		return raw_height * t
	return raw_height


## Estimates slope steepness (0.0 = flat, 1.0 = 45°+) by sampling neighbors.
func _get_slope(x: float, z: float, step: float = 1.0) -> float:
	var _h_center := get_height(x, z)
	var h_n := get_height(x, z - step)
	var h_s := get_height(x, z + step)
	var h_e := get_height(x + step, z)
	var h_w := get_height(x - step, z)
	var dx := (h_e - h_w) / (2.0 * step)
	var dz := (h_s - h_n) / (2.0 * step)
	var angle := atan(sqrt(dx * dx + dz * dz))
	# Normalize: tan(0) = 0, tan(~45°) ≈ 1
	return clampf(angle / (PI / 4.0), 0.0, 1.0)


func _get_color(height: float, slope: float = 0.0) -> Color:
	var normalized := (height + height_scale) / (2.0 * height_scale)
	normalized = clamp(normalized, 0.0, 1.0)

	# Base color from height
	var base_color: Color
	if normalized < 0.35:
		base_color = Color(0.20, 0.35, 0.15)  # Low — dark green
	elif normalized < 0.50:
		base_color = Color(0.30, 0.50, 0.20)  # Mid-low — green
	elif normalized < 0.65:
		base_color = Color(0.45, 0.35, 0.20)  # Hills — brown
	elif normalized < 0.80:
		base_color = Color(0.50, 0.45, 0.40)  # Upper slopes — gray-brown
	else:
		base_color = Color(0.70, 0.70, 0.68)  # Peaks — light gray

	# Blend toward rock color on steep slopes
	if slope > 0.3:
		var rock_color := Color(0.55, 0.52, 0.48)  # light grey rock
		var blend := clampf((slope - 0.3) / 0.4, 0.0, 1.0)
		base_color = base_color.lerp(rock_color, blend)

	return base_color


func _build_mesh() -> void:
	_mesh_instance = MeshInstance3D.new()
	_mesh_instance.name = "TerrainMesh"
	add_child(_mesh_instance)

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	var half_size := terrain_size * 0.5
	var step := terrain_size / float(resolution)
	var verts_per_side := resolution + 1

	# Add unique vertices with per-vertex color
	for zi in range(verts_per_side):
		for xi in range(verts_per_side):
			var x := -half_size + xi * step
			var z := -half_size + zi * step
			var h := get_height(x, z)
			var slope := _get_slope(x, z, step)
			st.set_color(_get_color(h, slope))
			st.add_vertex(Vector3(x, h, z))

	# Build triangle indices (CCW winding so normals face +Y)
	for zi in range(resolution):
		for xi in range(resolution):
			var i00 := zi * verts_per_side + xi
			var i10 := zi * verts_per_side + xi + 1
			var i01 := (zi + 1) * verts_per_side + xi
			var i11 := (zi + 1) * verts_per_side + xi + 1

			st.add_index(i00)
			st.add_index(i10)
			st.add_index(i01)

			st.add_index(i10)
			st.add_index(i11)
			st.add_index(i01)

	st.generate_normals()

	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 0.9
	st.set_material(mat)

	var arr_mesh := st.commit()
	_mesh_instance.mesh = arr_mesh


func _build_collision() -> void:
	_static_body = StaticBody3D.new()
	_static_body.name = "TerrainBody"
	# Layer 1 (default world) so the drone's RigidBody3D collides with it.
	_static_body.collision_layer = 1
	_static_body.collision_mask = 1
	add_child(_static_body)

	var col_shape := CollisionShape3D.new()
	col_shape.name = "TerrainCollision"
	_static_body.add_child(col_shape)

	var shape := _build_heightmap_shape()
	col_shape.shape = shape

	# HeightMapShape3D cells are 1 m × 1 m; scale the CollisionShape3D so the
	# heightmap aligns with the terrain mesh (which spans terrain_size metres).
	var step := terrain_size / float(resolution)
	col_shape.scale = Vector3(step, 1.0, step)


## Builds a HeightMapShape3D from the same noise function used for the mesh.
## HeightMapShape3D is reliable with Jolt Physics and far more efficient than
## a trimesh for terrain — it also avoids the 1:1 index limit that can cause
## create_trimesh_shape() to silently fail on large meshes.
func _build_heightmap_shape() -> HeightMapShape3D:
	var verts_per_side := resolution + 1
	var half_size := terrain_size * 0.5
	var step := terrain_size / float(resolution)

	var map_data := PackedFloat32Array()
	map_data.resize(verts_per_side * verts_per_side)

	for zi in range(verts_per_side):
		for xi in range(verts_per_side):
			var x := -half_size + xi * step
			var z := -half_size + zi * step
			map_data[zi * verts_per_side + xi] = get_height(x, z)

	var shape := HeightMapShape3D.new()
	shape.map_width = verts_per_side
	shape.map_depth = verts_per_side
	shape.map_data = map_data

	return shape
