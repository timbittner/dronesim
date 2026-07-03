@tool
class_name OsmTerrain
extends Node3D

## Real-world terrain loaded from baked map assets (heightmap + land-class
## grid + building footprints) produced by tools/bake_map.py from LGLN DGM1
## elevation tiles and an OSM extract. Duck-type compatible with
## TerrainGenerator: exposes get_height(x, z) for WindField and friends.
##
## Local frame: origin = spawn point (flattened pad, like the procedural
## terrain), x = east, z = south. Heights are meters above the spawn pad.
## @tool for in-editor inspection: the terrain mesh alone is ~1M triangles
## (mesh_step 4m over the full grid), so expect a beat of lag whenever this
## scene (re)opens in the editor. Bump mesh_step if that gets annoying.

@export var map_dir: String = "res://assets/maps/sebexen"
## Meters between terrain mesh vertices. Snapped to a whole number of grid
## cells. Collision always uses the full-resolution grid.
@export var mesh_step: float = 4.0
## Spawn pad flatten radius, matching TerrainGenerator (blend ends +8 m).
@export var flat_radius: float = 10.0
## Coarse far-terrain ring continuing the edge heights outward, so the map
## doesn't end in a hard silhouette cut against the sky — it fades into the
## distance fog instead. Purely visual (no collision). 0 disables.
@export var apron_width: float = 2000.0
## Meters between apron vertices. It's distant filler — keep it coarse.
@export var apron_step: float = 64.0
@export var tree_density_per_km2: float = 10000.0
@export var tree_seed: int = 137
## Trunk-only physics colliders (canopies stay non-solid — flying through
## foliage feels better than an invisible cone wall). Gameplay-only: skipped
## in the editor since @tool rebuilds happen outside a running physics world.
@export var tree_collision: bool = true
## Beyond this distance, per-chunk forest detail (trunk + species canopy)
## swaps for a single merged low-poly cone per chunk — full detail on every
## one of ~20k+ trees out to render distance is wasted GPU work on triangles
## that don't cover a pixel. See _build_forest().
@export var forest_lod_near_distance: float = 300.0
## Crossfade width (both directions) at the near/far LOD switch.
@export var forest_lod_fade_margin: float = 30.0
## Trees are bucketed into square chunks so each chunk can carry its own
## near/far MultiMeshInstance3D pair — visibility_range is a per-node
## property, so LOD granularity is chunk-sized, not per-tree.
@export var forest_chunk_size: float = 128.0

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
var _meta: Dictionary

## PhysicsServer3D static bodies carrying trunk colliders, batched
## TREE_COLLIDER_BATCH shapes per body (thousands of CollisionShape3D nodes
## would bloat the scene tree; RIDs skip that overhead). Neither extreme
## works at 20k+ trunks: one body holding every shape measured ~30x slower
## to build (each body_add_shape call seems to cost more than O(1) — likely
## a per-add bounds/broadphase rebuild that scales with the body's existing
## shape count); one body per single shape builds fast but blows past
## Jolt's default max-bodies limit (10240). Batching keeps both the
## per-body shape count and the total body count small. _tree_shape is a
## single CylinderShape3D resource reused (not copied) across every body.
const TREE_COLLIDER_BATCH := 200

var _tree_bodies: Array[RID] = []
var _tree_shape: CylinderShape3D


func _ready() -> void:
	# Editor re-enters _ready on every reload; clear last run's generated
	# children first or they'd stack up as duplicate overlapping meshes.
	for c in get_children():
		remove_child(c)
		c.free()
	var t0 := Time.get_ticks_msec()
	_load_map()
	_flatten_spawn_pad()
	_build_terrain_mesh()
	_build_apron()
	_build_collision()
	_build_forest()
	_build_buildings()
	print("OsmTerrain '%s': %dx%d grid, %d buildings, built in %d ms" % [
		_meta.get("name", "?"), _w, _h, _meta.get("buildings", []).size(),
		Time.get_ticks_msec() - t0])


func _exit_tree() -> void:
	_free_tree_colliders()


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


## Map extent in world XZ (position = the north-west corner). Duck-typed like
## get_height — SignalField uses it for the boundary belt; no get_bounds means
## infinite bounds (perfect signal everywhere).
func get_bounds() -> Rect2:
	return Rect2(_origin_x, _origin_z, (_w - 1) * _cell, (_h - 1) * _cell)


## Land class (CLASS_*) at world (x, z), nearest cell.
func get_land_class(x: float, z: float) -> int:
	var ci := clampi(roundi((x - _origin_x) / _cell), 0, _w - 1)
	var ri := clampi(roundi((z - _origin_z) / _cell), 0, _h - 1)
	return _classes[ri * _w + ci]


## Ground color is baked into albedo.png (see tools/bake_map.py::build_albedo,
## PALETTE/FIELD_LOW/FIELD_HIGH/ROCK) — this mesh only carries UVs for it.
func _build_terrain_mesh() -> void:
	var stride := maxi(1, roundi(mesh_step / _cell))
	var step := stride * _cell
	@warning_ignore("integer_division")
	var nx := (_w - 1) / stride + 1
	@warning_ignore("integer_division")
	var nz := (_h - 1) / stride + 1

	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	verts.resize(nx * nz)
	normals.resize(nx * nz)
	uvs.resize(nx * nz)

	var map_w := (_w - 1) * _cell
	var map_h := (_h - 1) * _cell
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
			uvs[vi] = Vector2((x - _origin_x) / map_w, (z - _origin_z) / map_h)

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
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var mat := StandardMaterial3D.new()
	# load(), not Image.load_from_file(): the latter reads the raw file and
	# doesn't work in exports (Godot warns at runtime). load() goes through
	# the normal import pipeline (mipmaps included — see the .import file;
	# minification aliasing on thin road stripes was mip-less filtering, not
	# geometry density).
	mat.albedo_texture = load(map_dir + "/albedo.png") as Texture2D
	mat.roughness = 0.9
	mesh.surface_set_material(0, mat)

	var mi := MeshInstance3D.new()
	mi.name = "TerrainMesh"
	mi.mesh = mesh
	add_child(mi)


## Visual-only ring around the map: get_height() edge-clamps, so heights just
## continue flat outward from the boundary, and the albedo material samples
## with texture_repeat off, smearing the edge pixels outward. Sits 0.5 m below
## the real terrain and starts one step inside the map edge, so the real mesh
## covers the seam from above. Fades into the distance fog long before its own
## outer edge matters.
func _build_apron() -> void:
	if apron_width <= 0.0:
		return
	var inner := get_bounds().grow(-apron_step)
	var outer := inner.grow(apron_width + apron_step)
	var nx := int(ceilf(outer.size.x / apron_step)) + 1
	var nz := int(ceilf(outer.size.y / apron_step)) + 1

	var map_w := (_w - 1) * _cell
	var map_h := (_h - 1) * _cell
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	verts.resize(nx * nz)
	normals.resize(nx * nz)
	uvs.resize(nx * nz)
	for zi in nz:
		var z := outer.position.y + zi * apron_step
		for xi in nx:
			var x := outer.position.x + xi * apron_step
			var vi := zi * nx + xi
			verts[vi] = Vector3(x, get_height(x, z) - 0.5, z)
			normals[vi] = Vector3.UP  # distant filler; flat lighting is fine
			uvs[vi] = Vector2(
				clampf((x - _origin_x) / map_w, 0.0, 1.0),
				clampf((z - _origin_z) / map_h, 0.0, 1.0))

	var indices := PackedInt32Array()
	for zi in nz - 1:
		for xi in nx - 1:
			# Skip quads over the map interior — the real mesh covers them.
			var center := Vector2(
				outer.position.x + (xi + 0.5) * apron_step,
				outer.position.y + (zi + 0.5) * apron_step)
			if inner.has_point(center):
				continue
			var i00 := zi * nx + xi
			indices.append_array(PackedInt32Array([
				i00, i00 + 1, i00 + nx, i00 + 1, i00 + nx + 1, i00 + nx]))

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = load(map_dir + "/albedo.png") as Texture2D
	mat.texture_repeat = false  # clamp: smears edge pixels across the ring
	mat.roughness = 0.9
	mesh.surface_set_material(0, mat)

	var mi := MeshInstance3D.new()
	mi.name = "TerrainApron"
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


## Low-poly pine forest on CLASS_FOREST cells, plus deciduous roadside/garden
## trees from map.json (positions computed at bake time — road polylines and
## residential landuse polygons only exist there; see
## tools/bake_map.py::collect_roadside_trees/collect_garden_trees). Trees are
## bucketed into forest_chunk_size chunks, each getting near-tier MultiMeshes
## (real trunk + species canopy, visible out to forest_lod_near_distance) and
## a far-tier MultiMesh (one merged low-poly cone per tree, no trunk, picking
## up from there) — full per-tree detail at any distance the camera can see
## is wasted GPU work on sub-pixel triangles. Trunk colliders are built from
## the complete unchunked transform lists; physics has no LOD.
func _build_forest() -> void:
	_free_tree_colliders()

	var trunk_mat := StandardMaterial3D.new()
	trunk_mat.albedo_color = Color(0.35, 0.22, 0.12)
	trunk_mat.roughness = 0.95
	# Radius at the default 1.0 scale factor (per-tree scale varies 0.7-1.4,
	# see _scatter_pine_transforms/_load_deciduous_transforms) averages ~1m
	# diameter, ranging ~0.7-1.4m — at least drone-width, largest well above.
	var trunk := CylinderMesh.new()
	trunk.top_radius = 0.3
	trunk.bottom_radius = 0.5
	trunk.height = 6.0
	trunk.radial_segments = 5
	trunk.material = trunk_mat

	var pine_canopy := CylinderMesh.new()
	pine_canopy.top_radius = 0.0
	pine_canopy.bottom_radius = 2.2
	pine_canopy.height = 7.0
	pine_canopy.radial_segments = 6
	var pine_canopy_mat := StandardMaterial3D.new()
	pine_canopy_mat.albedo_color = Color(0.16, 0.30, 0.13)
	pine_canopy_mat.roughness = 0.9
	pine_canopy.material = pine_canopy_mat

	# Sphere canopy reads as the roadside lindens/oaks actually lining these
	# roads — a cone here would look like an escaped conifer plantation.
	var deciduous_canopy := SphereMesh.new()
	deciduous_canopy.radius = 2.4
	deciduous_canopy.height = 4.8
	deciduous_canopy.radial_segments = 8
	deciduous_canopy.rings = 6
	var deciduous_canopy_mat := StandardMaterial3D.new()
	deciduous_canopy_mat.albedo_color = Color(0.22, 0.38, 0.14)
	deciduous_canopy_mat.roughness = 0.9
	deciduous_canopy.material = deciduous_canopy_mat

	# Far tier: species/trunks are imperceptible past forest_lod_near_distance,
	# so one cheap cone shape in a color blended from both canopies stands in
	# for the whole chunk.
	var far_cone := CylinderMesh.new()
	far_cone.top_radius = 0.0
	far_cone.bottom_radius = 2.0
	far_cone.height = 5.0
	far_cone.radial_segments = 5
	var far_cone_mat := StandardMaterial3D.new()
	far_cone_mat.albedo_color = (pine_canopy_mat.albedo_color + deciduous_canopy_mat.albedo_color) / 2.0
	far_cone_mat.roughness = 0.9
	far_cone.material = far_cone_mat

	var pine_transforms := _scatter_pine_transforms()
	var deciduous_transforms := _load_deciduous_transforms()

	var pine_chunks := _chunk_transforms(pine_transforms)
	var deciduous_chunks := _chunk_transforms(deciduous_transforms)
	var chunk_keys := {}
	for key in pine_chunks:
		chunk_keys[key] = true
	for key in deciduous_chunks:
		chunk_keys[key] = true

	var near_end := forest_lod_near_distance
	var margin := forest_lod_fade_margin
	for key: Vector2i in chunk_keys:
		var pine_c: Array[Transform3D] = pine_chunks.get(key, [] as Array[Transform3D])
		var deciduous_c: Array[Transform3D] = deciduous_chunks.get(key, [] as Array[Transform3D])
		var tag := "_%d_%d" % [key.x, key.y]
		# Godot's visibility_range camera-distance check uses the center of
		# the MultiMeshInstance3D's world-space AABB (computed from the
		# per-instance transforms), so this anchor isn't load-bearing for
		# that check — it's set anyway so each chunk's node sits at its
		# actual location rather than parked at local (0,0,0), which is what
		# you'd see/select in the editor otherwise.
		var anchor_x := (key.x + 0.5) * forest_chunk_size
		var anchor_z := (key.y + 0.5) * forest_chunk_size
		var anchor := Vector3(anchor_x, get_height(anchor_x, anchor_z), anchor_z)

		_add_tree_multimesh("PineTrunks" + tag, trunk, 3.0, pine_c, anchor, 0.0, near_end, 0.0, margin)
		_add_tree_multimesh("PineCanopies" + tag, pine_canopy, 9.0, pine_c, anchor, 0.0, near_end, 0.0, margin)
		_add_tree_multimesh("DeciduousTrunks" + tag, trunk, 3.0, deciduous_c, anchor, 0.0, near_end, 0.0, margin)
		_add_tree_multimesh("DeciduousCanopies" + tag, deciduous_canopy, 7.9, deciduous_c, anchor,
			0.0, near_end, 0.0, margin)
		_add_tree_multimesh("FarCanopies" + tag, far_cone, 8.0, pine_c + deciduous_c, anchor,
			near_end, 0.0, margin, 0.0)

	if tree_collision and not Engine.is_editor_hint():
		_build_tree_colliders(pine_transforms + deciduous_transforms)

	print("OsmTerrain forest: %d pine, %d deciduous, %d LOD chunks (~%d m)" % [
		pine_transforms.size(), deciduous_transforms.size(), chunk_keys.size(),
		forest_chunk_size])


func _chunk_transforms(transforms: Array[Transform3D]) -> Dictionary:
	var chunks := {}
	for t in transforms:
		var key := Vector2i(floori(t.origin.x / forest_chunk_size), floori(t.origin.z / forest_chunk_size))
		if not chunks.has(key):
			chunks[key] = [] as Array[Transform3D]
		chunks[key].append(t)
	return chunks


func _scatter_pine_transforms() -> Array[Transform3D]:
	var forest_cells := PackedInt32Array()
	for i in _classes.size():
		if _classes[i] == CLASS_FOREST:
			forest_cells.append(i)
	var transforms: Array[Transform3D] = []
	if forest_cells.is_empty():
		return transforms
	var area_km2 := forest_cells.size() * _cell * _cell / 1e6
	var count := int(area_km2 * tree_density_per_km2)
	var rng := RandomNumberGenerator.new()
	rng.seed = tree_seed
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
	return transforms


## map.json's "trees" entries are (x, z, scale) triples; rotation is free
## (not baked) so it's assigned here from tree_seed like the pine scatter.
func _load_deciduous_transforms() -> Array[Transform3D]:
	var transforms: Array[Transform3D] = []
	var rng := RandomNumberGenerator.new()
	rng.seed = tree_seed + 1
	for entry in _meta.get("trees", []):
		var x: float = entry[0]
		var z: float = entry[1]
		var s: float = entry[2]
		var b := Basis(Vector3.UP, rng.randf_range(0.0, TAU)) \
			* Basis.from_scale(Vector3(s, s, s))
		transforms.append(Transform3D(b, Vector3(x, get_height(x, z), z)))
	return transforms


## anchor becomes the MultiMeshInstance3D node's own position (see the
## comment at the call site for why); per-instance transforms are rebased
## into anchor-local space so the final world position is unchanged.
## vis_begin/vis_end (both 0.0 = always visible) are GeometryInstance3D's
## visibility_range_begin/end — Godot evaluates them against camera distance
## at render time, no per-frame LOD logic needed here.
func _add_tree_multimesh(mmi_name: String, mesh: Mesh, y: float,
		transforms: Array[Transform3D], anchor: Vector3,
		vis_begin: float = 0.0, vis_end: float = 0.0,
		vis_begin_margin: float = 0.0, vis_end_margin: float = 0.0) -> void:
	if transforms.is_empty():
		return
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.instance_count = transforms.size()
	for i in transforms.size():
		var t: Transform3D = transforms[i]
		var y_off: float = y * t.basis.get_scale().y
		mm.set_instance_transform(i,
			Transform3D(t.basis, t.origin - anchor + Vector3(0.0, y_off, 0.0)))
	var mmi := MultiMeshInstance3D.new()
	mmi.name = mmi_name
	mmi.multimesh = mm
	mmi.position = anchor
	if vis_begin > 0.0 or vis_end > 0.0:
		mmi.visibility_range_begin = vis_begin
		mmi.visibility_range_end = vis_end
		mmi.visibility_range_begin_margin = vis_begin_margin
		mmi.visibility_range_end_margin = vis_end_margin
		mmi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	add_child(mmi)


## One PhysicsServer3D static body carrying every trunk (pine + deciduous) as
## a cylinder shape instance — thousands of CollisionShape3D nodes would
## bloat the scene tree, the server API skips that overhead. Canopies stay
## non-solid (flying through foliage feels better than an invisible cone
## wall).
func _build_tree_colliders(transforms: Array[Transform3D]) -> void:
	_tree_shape = CylinderShape3D.new()
	# Matches the trunk mesh (top_radius 0.3, bottom_radius 0.5, height 6.0)
	# closely enough with one uniform radius — a taper isn't worth a second
	# shape per trunk.
	_tree_shape.radius = 0.4
	_tree_shape.height = 6.0
	var shape_rid := _tree_shape.get_rid()
	var space := get_world_3d().space
	var i := 0
	while i < transforms.size():
		var batch_end := mini(i + TREE_COLLIDER_BATCH, transforms.size())
		var body := PhysicsServer3D.body_create()
		PhysicsServer3D.body_set_space(body, space)
		PhysicsServer3D.body_set_mode(body, PhysicsServer3D.BODY_MODE_STATIC)
		PhysicsServer3D.body_set_collision_layer(body, 1)
		PhysicsServer3D.body_set_collision_mask(body, 1)
		for j in range(i, batch_end):
			var t: Transform3D = transforms[j]
			var y_off: float = 3.0 * t.basis.get_scale().y
			PhysicsServer3D.body_add_shape(body, shape_rid,
				Transform3D(t.basis, t.origin + Vector3(0.0, y_off, 0.0)))
		_tree_bodies.append(body)
		i = batch_end


func _free_tree_colliders() -> void:
	for body in _tree_bodies:
		PhysicsServer3D.free_rid(body)
	_tree_bodies.clear()
	_tree_shape = null


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

		# Winding convention (Godot front faces are CLOCKWISE viewed from the
		# front — see the terrain mesh): poly is normalized above to CW seen
		# from +y, so roofs face up as-is and each wall's exterior is LEFT of
		# the a→c walk; the orders below put the front face on that side.
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
			st.add_vertex(v1)
			st.add_vertex(v2)
			st.add_vertex(v0)
			st.add_vertex(v2)
			st.add_vertex(v3)

		var footprint_area := absf(area) * 0.5
		if poly.size() == 4 and footprint_area < 250.0:
			_add_gable_roof(st, poly, top, wall_col, roof_col)
		else:
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


## Gable roof for a 4-corner footprint (small houses; see the area cutoff in
## _build_buildings): the shorter opposite edge pair becomes vertical
## gable-end wall triangles up to the ridge apex, the longer pair becomes
## sloped roof quads down to their eave. `poly` must already be wound per
## the Phase A convention (CW seen from +y, matching the walls beneath).
func _add_gable_roof(st: SurfaceTool, poly: PackedVector2Array, top: float,
		wall_col: Color, roof_col: Color) -> void:
	var e0 := poly[0].distance_to(poly[1])
	var e1 := poly[1].distance_to(poly[2])
	var e2 := poly[2].distance_to(poly[3])
	var e3 := poly[3].distance_to(poly[0])
	# Rotate indices so edges (0,1) and (2,3) are the short "gable end" pair
	# and (1,2)/(3,0) are the long eaves the ridge runs parallel to.
	if e0 + e2 > e1 + e3:
		poly = PackedVector2Array([poly[1], poly[2], poly[3], poly[0]])
		e0 = e1
		e2 = e3

	var ridge_rise := clampf(0.45 * (e0 + e2) * 0.5, 1.5, 3.0)
	var ridge_h := top + ridge_rise
	var r0 := (poly[0] + poly[1]) * 0.5  # ridge apex above the (0,1) gable end
	var r1 := (poly[2] + poly[3]) * 0.5  # ridge apex above the (2,3) gable end
	var rv0 := Vector3(r0.x, ridge_h, r0.y)
	var rv1 := Vector3(r1.x, ridge_h, r1.y)

	# Gable-end triangles: vertical planes directly above wall edges (0,1)
	# and (2,3) (ridge apex sits on that same edge's midline), so they share
	# the walls' outward direction — normal derived the same way as a wall
	# quad's two triangles (see _build_buildings), just one triangle instead
	# of two since the top edge has collapsed to a point.
	st.set_color(wall_col)
	for edge in [[poly[0], poly[1], rv0], [poly[2], poly[3], rv1]]:
		var a: Vector2 = edge[0]
		var c: Vector2 = edge[1]
		var v0 := Vector3(a.x, top, a.y)
		var v1 := Vector3(c.x, top, c.y)
		var v2: Vector3 = edge[2]
		st.set_normal((v2 - v0).cross(v1 - v0).normalized())
		st.add_vertex(v0)
		st.add_vertex(v1)
		st.add_vertex(v2)

	# Sloped roof quads: from each long eave edge (1,2) and (3,0) up to the
	# ridge line, split into two triangles like a wall quad, ridge corners
	# paired with the eave corner on the matching gable end.
	st.set_color(roof_col)
	for eave in [[poly[3], poly[0], rv0, rv1], [poly[1], poly[2], rv1, rv0]]:
		var a: Vector2 = eave[0]
		var c: Vector2 = eave[1]
		var v0 := Vector3(a.x, top, a.y)
		var v1 := Vector3(c.x, top, c.y)
		var v2: Vector3 = eave[2]
		var v3: Vector3 = eave[3]
		st.set_normal((v2 - v0).cross(v1 - v0).normalized())
		st.add_vertex(v0)
		st.add_vertex(v1)
		st.add_vertex(v2)
		st.set_normal((v3 - v0).cross(v2 - v0).normalized())
		st.add_vertex(v0)
		st.add_vertex(v2)
		st.add_vertex(v3)
