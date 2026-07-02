extends Node3D

## Headless tests for OsmTerrain (P4): baked map loads with the advertised
## dimensions, the spawn pad is flat at y=0, get_height matches the raw baked
## grid, all land classes are present, and the physics heightmap agrees with
## get_height (guards the collision-shape centering/scale math).

var _passed: int = 0
var _failed: int = 0
var _terrain: OsmTerrain = null


func _ready() -> void:
	call_deferred("_delayed_start")


func _delayed_start() -> void:
	_terrain = $Terrain as OsmTerrain
	if _terrain == null:
		printerr("[TEST] FATAL: Could not find Terrain node in scene")
		get_tree().quit(1)
		return
	await _run_all_tests()


func _run_all_tests() -> void:
	await _run_test("test_map_loads_with_expected_dims")
	await _run_test("test_spawn_pad_flat_at_zero")
	await _run_test("test_get_height_matches_baked_grid")
	await _run_test("test_all_land_classes_present")
	await _run_test("test_collision_matches_get_height")
	await _run_test("test_buildings_built_with_collision")

	var total := _passed + _failed
	print("[TEST] ========================================")
	print("[TEST] Results: ", _passed, " passed, ", _failed, " failed out of ", total)
	print("[TEST] ========================================")
	get_tree().quit(1 if _failed > 0 else 0)


func _run_test(test_name: String) -> void:
	var result: bool = await call(test_name)
	if result:
		_passed += 1
		print("[TEST] PASS: ", test_name)
	else:
		_failed += 1
		print("[TEST] FAIL: ", test_name)


func test_map_loads_with_expected_dims() -> bool:
	print("[TEST] --- test_map_loads_with_expected_dims ---")
	var meta: Dictionary = JSON.parse_string(
		FileAccess.get_file_as_string(_terrain.map_dir + "/map.json"))
	var w := int(meta["grid_width"])
	var h := int(meta["grid_height"])
	var dims_ok: bool = _terrain._w == w and _terrain._h == h \
		and _terrain._grid.size() == w * h and _terrain._classes.size() == w * h
	var nodes_ok := _terrain.has_node("TerrainMesh") \
		and _terrain.has_node("TerrainBody") and _terrain.has_node("Buildings")
	print("[TEST] dims ", w, "x", h, " dims_ok=", dims_ok, " nodes_ok=", nodes_ok)
	return dims_ok and nodes_ok


func test_spawn_pad_flat_at_zero() -> bool:
	print("[TEST] --- test_spawn_pad_flat_at_zero ---")
	var max_abs := 0.0
	for x in range(-8, 9, 4):
		for z in range(-8, 9, 4):
			if Vector2(x, z).length() <= _terrain.flat_radius:
				max_abs = maxf(max_abs, absf(_terrain.get_height(x, z)))
	print("[TEST] max |height| within pad radius: ", max_abs)
	return max_abs < 0.01


func test_get_height_matches_baked_grid() -> bool:
	print("[TEST] --- test_get_height_matches_baked_grid ---")
	# Raw file, before the spawn-pad flatten — compare far from the pad.
	var raw := FileAccess.get_file_as_bytes(
		_terrain.map_dir + "/heightmap.bin").to_float32_array()
	var ok := true
	for probe in [Vector2i(100, 100), Vector2i(800, 300), Vector2i(1500, 1000)]:
		var x: float = _terrain._origin_x + probe.x * _terrain._cell
		var z: float = _terrain._origin_z + probe.y * _terrain._cell
		var expected: float = raw[probe.y * _terrain._w + probe.x]
		var got := _terrain.get_height(x, z)
		if absf(got - expected) > 0.001:
			print("[TEST] mismatch at ", probe, ": got ", got, " expected ", expected)
			ok = false
	return ok


func test_all_land_classes_present() -> bool:
	print("[TEST] --- test_all_land_classes_present ---")
	var seen := {}
	for i in range(0, _terrain._classes.size(), 97):
		seen[_terrain._classes[i]] = true
	print("[TEST] classes seen: ", seen.keys())
	return seen.has(OsmTerrain.CLASS_FIELD) and seen.has(OsmTerrain.CLASS_FOREST) \
		and seen.has(OsmTerrain.CLASS_WATER) and seen.has(OsmTerrain.CLASS_ROAD)


func test_collision_matches_get_height() -> bool:
	print("[TEST] --- test_collision_matches_get_height ---")
	await get_tree().physics_frame
	await get_tree().physics_frame
	var space := get_world_3d().direct_space_state
	var ok := true
	# Spread across the map, away from buildings' trimesh (open field/forest).
	for pos in [Vector2(0, 0), Vector2(300, 400), Vector2(-800, -500),
			Vector2(1200, 900), Vector2(-1400, 1300)]:
		var expected: float = _terrain.get_height(pos.x, pos.y)
		var query := PhysicsRayQueryParameters3D.create(
			Vector3(pos.x, expected + 200.0, pos.y),
			Vector3(pos.x, expected - 200.0, pos.y))
		var hit := space.intersect_ray(query)
		if hit.is_empty():
			print("[TEST] no hit at ", pos)
			ok = false
			continue
		var delta: float = absf(hit["position"].y - expected)
		if delta > 0.5:
			print("[TEST] at ", pos, " ray hit y=", hit["position"].y,
				" but get_height=", expected, " (delta ", delta, ")")
			ok = false
	return ok


func test_buildings_built_with_collision() -> bool:
	print("[TEST] --- test_buildings_built_with_collision ---")
	var mesh_node := _terrain.get_node("Buildings") as MeshInstance3D
	var body := _terrain.get_node_or_null("BuildingsBody")
	var aabb := mesh_node.get_aabb()
	var tri_count: int = mesh_node.mesh.surface_get_array_len(0)
	print("[TEST] buildings AABB size=", aabb.size, " verts=", tri_count)
	return body != null and tri_count > 10000 and aabb.size.y > 5.0
