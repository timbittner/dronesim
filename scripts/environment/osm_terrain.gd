class_name OsmTerrain
extends Node3D

## Real-world terrain loaded from baked map assets (heightmap + land-class
## grid + building footprints) produced by tools/bake_map.py from LGLN DGM1
## elevation tiles and an OSM extract. Duck-type compatible with
## TerrainGenerator: exposes get_height(x, z) for WindField and friends.
##
## Local frame: origin = spawn point (flattened pad, like the procedural
## terrain), x = east, z = south. Heights are meters above the spawn pad.
## Not @tool: building ~1M triangles on every editor scene load isn't worth
## the preview; run the scene to see the map.

@export var map_dir: String = "res://assets/maps/sebexen"
## Meters between terrain mesh vertices. Snapped to a whole number of grid
## cells. Collision always uses the full-resolution grid.
@export var mesh_step: float = 4.0
## Spawn pad flatten radius, matching TerrainGenerator (blend ends +8 m).
@export var flat_radius: float = 10.0
@export var tree_density_per_km2: float = 3000.0
@export var tree_seed: int = 137

const CLASS_FIELD := 0
const CLASS_FOREST := 1
const CLASS_WATER := 2
const CLASS_ROAD := 3

var _grid: PackedFloat32Array
var _classes: PackedByteArray
var _w: int
var _h: int
var _cell: float
var _origin_x: float
var _origin_z: float
var _h_min: float
var _h_max: float
var _meta: Dictionary


func _ready() -> void:
	var t0 := Time.get_ticks_msec()
	_load_map()
	_flatten_spawn_pad()
	_build_terrain_mesh()
	_build_collision()
	_build_forest()
	_build_buildings()
	print("OsmTerrain '%s': %dx%d grid, %d buildings, built in %d ms" % [
		_meta.get("name", "?"), _w, _h, _meta.get("buildings", []).size(),
		Time.get_ticks_msec() - t0])


func _load_map() -> void:
	_meta = JSON.parse_string(
		FileAccess.get_file_as_string(map_dir + "/map.json"))
	_w = int(_meta["grid_width"])
	_h = int(_meta["grid_height"])
	_cell = float(_meta["cell_size"])
	_origin_x = float(_meta["origin_x"])
	_origin_z = float(_meta["origin_z"])
	_grid = FileAccess.get_file_as_bytes(map_dir + "/heightmap.bin").to_float32_array()
	_classes = FileAccess.get_file_as_bytes(map_dir + "/classmap.bin")
	assert(_grid.size() == _w * _h and _classes.size() == _w * _h)
	_h_min = INF
	_h_max = -INF
	for v in _grid:
		_h_min = minf(_h_min, v)
		_h_max = maxf(_h_max, v)


## Flattens the grid itself around the origin (same smoothstep profile as
## TerrainGenerator), so mesh, collision and get_height all agree for free.
func _flatten_spawn_pad() -> void:
	var blend_end := flat_radius + 8.0
	var ci_min := maxi(0, int((-blend_end - _origin_x) / _cell))
	var ci_max := mini(_w - 1, int(ceilf((blend_end - _origin_x) / _cell)))
	var ri_min := maxi(0, int((-blend_end - _origin_z) / _cell))
	var ri_max := mini(_h - 1, int(ceilf((blend_end - _origin_z) / _cell)))
	for ri in range(ri_min, ri_max + 1):
		for ci in range(ci_min, ci_max + 1):
			var x := _origin_x + ci * _cell
			var z := _origin_z + ri * _cell
			var dist := sqrt(x * x + z * z)
			if dist >= blend_end:
				continue
			var t := 0.0
			if dist > flat_radius:
				t = smoothstep(0.0, 1.0, (dist - flat_radius) / (blend_end - flat_radius))
			_grid[ri * _w + ci] *= t


## Terrain height at world (x, z); bilinear, clamped to the map edge outside.
func get_height(x: float, z: float) -> float:
	var gx := clampf((x - _origin_x) / _cell, 0.0, _w - 1.001)
	var gz := clampf((z - _origin_z) / _cell, 0.0, _h - 1.001)
	var ci := int(gx)
	var ri := int(gz)
	var fx := gx - ci
	var fz := gz - ri
	var i := ri * _w + ci
	var h00 := _grid[i]
	var h10 := _grid[i + 1]
	var h01 := _grid[i + _w]
	var h11 := _grid[i + _w + 1]
	return lerpf(lerpf(h00, h10, fx), lerpf(h01, h11, fx), fz)


## Land class (CLASS_*) at world (x, z), nearest cell.
func get_land_class(x: float, z: float) -> int:
	var ci := clampi(roundi((x - _origin_x) / _cell), 0, _w - 1)
	var ri := clampi(roundi((z - _origin_z) / _cell), 0, _h - 1)
	return _classes[ri * _w + ci]


func _class_color(cls: int, normalized_h: float, slope: float) -> Color:
	match cls:
		CLASS_FOREST:
			return Color(0.13, 0.24, 0.10)
		CLASS_WATER:
			return Color(0.15, 0.30, 0.50)
		CLASS_ROAD:
			return Color(0.32, 0.31, 0.30)
	# Fields: greens drying out with altitude, rock on steep slopes.
	var c := Color(0.30, 0.45, 0.18).lerp(Color(0.52, 0.48, 0.26), normalized_h)
	if slope > 0.3:
		c = c.lerp(Color(0.55, 0.52, 0.48), clampf((slope - 0.3) / 0.4, 0.0, 1.0))
	return c


func _build_terrain_mesh() -> void:
	var stride := maxi(1, roundi(mesh_step / _cell))
	var step := stride * _cell
	@warning_ignore("integer_division")
	var nx := (_w - 1) / stride + 1
	@warning_ignore("integer_division")
	var nz := (_h - 1) / stride + 1

	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	verts.resize(nx * nz)
	normals.resize(nx * nz)
	colors.resize(nx * nz)

	var h_span := maxf(_h_max - _h_min, 1.0)
	for zi in nz:
		var ri := zi * stride
		var z := _origin_z + ri * _cell
		for xi in nx:
			var ci := xi * stride
			var x := _origin_x + ci * _cell
			var i := ri * _w + ci
			var height := _grid[i]
			# Central-difference gradient from the full-res grid.
			var dhdx := (_grid[i + mini(stride, _w - 1 - ci)] \
				- _grid[i - mini(stride, ci)]) / (2.0 * step)
			var dhdz := (_grid[i + mini(stride, _h - 1 - ri) * _w] \
				- _grid[i - mini(stride, ri) * _w]) / (2.0 * step)
			var vi := zi * nx + xi
			var slope := clampf(atan(sqrt(dhdx * dhdx + dhdz * dhdz)) / (PI / 4.0), 0.0, 1.0)
			# Max class over the cells this vertex represents, not a point
			# sample: thin features (roads are ~2 cells wide) would otherwise
			# alias into dashes on the coarser mesh lattice. Class values are
			# ordered by draw priority, so max() picks road > water > forest.
			var cls := int(_classes[i])
			if stride > 1:
				for wr in range(maxi(0, ri - stride + 1), mini(_h - 1, ri + stride - 1) + 1):
					for wc in range(maxi(0, ci - stride + 1), mini(_w - 1, ci + stride - 1) + 1):
						cls = maxi(cls, _classes[wr * _w + wc])
			if cls == CLASS_WATER:
				height -= 0.4  # visible channel; collision keeps DEM height
			verts[vi] = Vector3(x, height, z)
			normals[vi] = Vector3(-dhdx, 1.0, -dhdz).normalized()
			colors[vi] = _class_color(cls, (height - _h_min) / h_span, slope)

	var indices := PackedInt32Array()
	indices.resize((nx - 1) * (nz - 1) * 6)
	var n := 0
	for zi in nz - 1:
		for xi in nx - 1:
			var i00 := zi * nx + xi
			indices[n] = i00
			indices[n + 1] = i00 + 1
			indices[n + 2] = i00 + nx
			indices[n + 3] = i00 + 1
			indices[n + 4] = i00 + nx + 1
			indices[n + 5] = i00 + nx
			n += 6

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 0.9
	mesh.surface_set_material(0, mat)

	var mi := MeshInstance3D.new()
	mi.name = "TerrainMesh"
	mi.mesh = mesh
	add_child(mi)


## Same HeightMapShape3D pattern as TerrainGenerator, fed the full-res grid.
func _build_collision() -> void:
	var shape := HeightMapShape3D.new()
	shape.map_width = _w
	shape.map_depth = _h
	shape.map_data = _grid

	var body := StaticBody3D.new()
	body.name = "TerrainBody"
	body.collision_layer = 1
	body.collision_mask = 1
	add_child(body)

	var col := CollisionShape3D.new()
	col.name = "TerrainCollision"
	col.shape = shape
	# Heightmap cells are 1x1; scale to cell size and center on the map rect
	# (the shape is XZ-centered on its node, and our origin is the spawn, not
	# the map center).
	col.scale = Vector3(_cell, 1.0, _cell)
	col.position = Vector3(
		_origin_x + (_w - 1) * _cell * 0.5, 0.0,
		_origin_z + (_h - 1) * _cell * 0.5)
	body.add_child(col)


## Low-poly pine forest on CLASS_FOREST cells: two MultiMeshes (trunks +
## canopy cones) instead of Scatter's per-node trees — real forest coverage
## here is ~2 km², thousands of trees.
func _build_forest() -> void:
	var forest_cells := PackedInt32Array()
	for i in _classes.size():
		if _classes[i] == CLASS_FOREST:
			forest_cells.append(i)
	if forest_cells.is_empty():
		return
	var area_km2 := forest_cells.size() * _cell * _cell / 1e6
	var count := int(area_km2 * tree_density_per_km2)

	var trunk := CylinderMesh.new()
	trunk.top_radius = 0.15
	trunk.bottom_radius = 0.25
	trunk.height = 3.0
	trunk.radial_segments = 5
	var trunk_mat := StandardMaterial3D.new()
	trunk_mat.albedo_color = Color(0.35, 0.22, 0.12)
	trunk_mat.roughness = 0.95
	trunk.material = trunk_mat

	var canopy := CylinderMesh.new()
	canopy.top_radius = 0.0
	canopy.bottom_radius = 2.2
	canopy.height = 7.0
	canopy.radial_segments = 6
	var canopy_mat := StandardMaterial3D.new()
	canopy_mat.albedo_color = Color(0.16, 0.30, 0.13)
	canopy_mat.roughness = 0.9
	canopy.material = canopy_mat

	var rng := RandomNumberGenerator.new()
	rng.seed = tree_seed
	var transforms: Array[Transform3D] = []
	for _i in count:
		var cell_i := forest_cells[rng.randi_range(0, forest_cells.size() - 1)]
		@warning_ignore("integer_division")
		var row_i := cell_i / _w
		var x := _origin_x + (cell_i % _w) * _cell + rng.randf_range(-_cell, _cell)
		var z := _origin_z + row_i * _cell + rng.randf_range(-_cell, _cell)
		var s := rng.randf_range(0.7, 1.4)
		var b := Basis(Vector3.UP, rng.randf_range(0.0, TAU)) \
			* Basis.from_scale(Vector3(s, s, s))
		transforms.append(Transform3D(b, Vector3(x, get_height(x, z), z)))

	for part in [{"mesh": trunk, "y": 1.5}, {"mesh": canopy, "y": 6.0}]:
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = part["mesh"]
		mm.instance_count = transforms.size()
		for i in transforms.size():
			var t: Transform3D = transforms[i]
			var y_off: float = part["y"] * t.basis.get_scale().y
			mm.set_instance_transform(i,
				Transform3D(t.basis, t.origin + Vector3(0.0, y_off, 0.0)))
		var mmi := MultiMeshInstance3D.new()
		mmi.name = "Forest" + ("Trunks" if part["y"] < 2.0 else "Canopies")
		mmi.multimesh = mm
		add_child(mmi)


## Extrudes all building footprints into one vertex-colored ArrayMesh with a
## single trimesh collision body. Walls run from below ground (slope-proof)
## up to a flat roof.
func _build_buildings() -> void:
	var buildings: Array = _meta.get("buildings", [])
	if buildings.is_empty():
		return
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var wall_colors := [Color(0.82, 0.78, 0.70), Color(0.88, 0.86, 0.80),
		Color(0.72, 0.66, 0.58)]
	var roof_colors := [Color(0.48, 0.26, 0.18), Color(0.38, 0.35, 0.33),
		Color(0.55, 0.32, 0.22)]

	for bi in buildings.size():
		var b: Dictionary = buildings[bi]
		var pts: Array = b["pts"]
		var height := float(b["h"])
		var wall_col: Color = wall_colors[bi % wall_colors.size()]
		var roof_col: Color = roof_colors[bi % roof_colors.size()]

		var base := INF
		var poly := PackedVector2Array()
		for p in pts:
			poly.append(Vector2(p[0], p[1]))
			base = minf(base, get_height(p[0], p[1]))
		base -= 1.5  # embed below ground on slopes
		var top := base + 1.5 + height
		# OSM footprints come in either winding; normalize so walls face
		# outward and the roof faces up (negative shoelace area in x/z).
		var area := 0.0
		for j in poly.size():
			var a2 := poly[j]
			var c2 := poly[(j + 1) % poly.size()]
			area += (c2.x - a2.x) * (c2.y + a2.y)
		if area > 0.0:
			poly.reverse()

		st.set_color(wall_col)
		for j in poly.size():
			var a := poly[j]
			var c := poly[(j + 1) % poly.size()]
			var v0 := Vector3(a.x, base, a.y)
			var v1 := Vector3(c.x, base, c.y)
			var v2 := Vector3(c.x, top, c.y)
			var v3 := Vector3(a.x, top, a.y)
			var normal := Vector3(c.y - a.y, 0.0, -(c.x - a.x)).normalized()
			st.set_normal(normal)
			st.add_vertex(v0)
			st.add_vertex(v2)
			st.add_vertex(v1)
			st.add_vertex(v0)
			st.add_vertex(v3)
			st.add_vertex(v2)

		st.set_color(roof_col)
		st.set_normal(Vector3.UP)
		var tri := Geometry2D.triangulate_polygon(poly)
		for j in range(0, tri.size(), 3):
			for k in 3:
				var p := poly[tri[j + k]]
				st.add_vertex(Vector3(p.x, top, p.y))

	var mesh := st.commit()
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 0.85
	mesh.surface_set_material(0, mat)

	var mi := MeshInstance3D.new()
	mi.name = "Buildings"
	mi.mesh = mesh
	add_child(mi)

	var body := StaticBody3D.new()
	body.name = "BuildingsBody"
	body.collision_layer = 1
	body.collision_mask = 1
	add_child(body)
	var col := CollisionShape3D.new()
	col.shape = mesh.create_trimesh_shape()
	body.add_child(col)
