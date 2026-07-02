extends Node3D

## Headless test harness for WindField (P2 Phase D). Complements
## flight_mode_test.gd — covers the terrain-aware wind field's math (spawn
## calm, altitude profile, shelter, ridge boost, deflection) and its physical
## effect on the drone (relative-airspeed drag causing downwind drift).

var _passed: int = 0
var _failed: int = 0
var _drone: RigidBody3D = null
var _wind_field: WindField = null


func _ready() -> void:
	call_deferred("_delayed_start")


func _delayed_start() -> void:
	_drone = $Drone as RigidBody3D
	_wind_field = $WindField as WindField
	if _drone == null or _wind_field == null:
		printerr("[TEST] FATAL: Could not find Drone/WindField node in scene")
		get_tree().quit(1)
		return

	await _run_all_tests()


func _run_ticks(count: int) -> void:
	for _i in range(count):
		await get_tree().physics_frame


func _run_all_tests() -> void:
	_passed = 0
	_failed = 0

	await _run_test("test_spawn_zone_calm")
	await _run_test("test_wind_grows_with_agl")
	await _run_test("test_ridge_windier_than_valley")
	await _run_test("test_wind_deflects_around_hill")
	await _run_test("test_null_terrain_fallback")
	await _run_test("test_hover_drifts_downwind")

	var total := _passed + _failed
	print("[TEST] ========================================")
	print("[TEST] Results: ", _passed, " passed, ", _failed, " failed out of ", total)
	print("[TEST] ========================================")

	if _failed > 0:
		get_tree().quit(1)
	else:
		get_tree().quit(0)


func _run_test(test_name: String) -> void:
	var result: bool = await call(test_name)
	if result:
		_passed += 1
		print("[TEST] PASS: ", test_name)
	else:
		_failed += 1
		print("[TEST] FAIL: ", test_name)


# ---------------------------------------------------------------------------
# Test: spawn pad + immediate surroundings are calm; wind picks up outside it
# ---------------------------------------------------------------------------
func test_spawn_zone_calm() -> bool:
	print("[TEST] --- test_spawn_zone_calm ---")
	var w_center := _wind_field.get_wind(Vector3(0, 3, 0))
	var w_near := _wind_field.get_wind(Vector3(10, 5, 5))
	var w_outside := _wind_field.get_wind(Vector3(40, 3, 0))
	print("[TEST] center=", w_center.length(), " near=", w_near.length(), " outside=", w_outside.length())

	var passed := w_center.length() < 0.05 and w_near.length() < 0.05 and w_outside.length() > 1.0
	print("[TEST] ", "PASS" if passed else "FAIL", " — calm inside spawn zone, windy outside")
	return passed


# ---------------------------------------------------------------------------
# Test: wind speed grows with altitude-above-ground on flat terrain
# ---------------------------------------------------------------------------
func test_wind_grows_with_agl() -> bool:
	print("[TEST] --- test_wind_grows_with_agl ---")
	var w_low := _wind_field.get_wind(Vector3(-150, 2, 0))
	var w_mid := _wind_field.get_wind(Vector3(-150, 15, 0))
	var w_high := _wind_field.get_wind(Vector3(-150, 40, 0))
	print("[TEST] low=", w_low.length(), " mid=", w_mid.length(), " high=", w_high.length())

	var passed := w_low.length() < w_mid.length() and w_mid.length() < w_high.length() \
			and absf(w_high.length() - _wind_field.base_speed) < 0.5
	print("[TEST] ", "PASS" if passed else "FAIL", " — wind speed should grow with altitude, approaching base_speed")
	return passed


# ---------------------------------------------------------------------------
# Test: a ridge crest is far windier than its sheltered downwind wake
# ---------------------------------------------------------------------------
func test_ridge_windier_than_valley() -> bool:
	print("[TEST] --- test_ridge_windier_than_valley ---")
	var w_crest := _wind_field.get_wind(Vector3(60, 14, 0))
	var w_wake := _wind_field.get_wind(Vector3(80, 3, 0))
	print("[TEST] crest=", w_crest.length(), " wake=", w_wake.length())

	var passed := w_crest.length() > 2.0 * w_wake.length()
	print("[TEST] ", "PASS" if passed else "FAIL", " — ridge crest should be far windier than the sheltered wake")
	return passed


# ---------------------------------------------------------------------------
# Test: wind deflects to opposite sides on either flank of a hill, magnitude
# preserved (rotation, not attenuation)
# ---------------------------------------------------------------------------
func test_wind_deflects_around_hill() -> bool:
	print("[TEST] --- test_wind_deflects_around_hill ---")
	var w_pos_z := _wind_field.get_wind(Vector3(45, 3, 6))
	var w_neg_z := _wind_field.get_wind(Vector3(45, 3, -6))
	print("[TEST] +z flank=", w_pos_z, " -z flank=", w_neg_z)

	var opposite_z := w_pos_z.z > 0.1 and w_neg_z.z < -0.1
	var speed_ratio := w_pos_z.length() / maxf(w_neg_z.length(), 0.001)
	var similar_speed := speed_ratio > 0.9 and speed_ratio < 1.1
	var passed := opposite_z and similar_speed
	print("[TEST] ", "PASS" if passed else "FAIL", " — wind should deflect to opposite sides around the hill, magnitude preserved")
	return passed


# ---------------------------------------------------------------------------
# Test: a WindField with no terrain reference degrades to dir * base_speed
# ---------------------------------------------------------------------------
func test_null_terrain_fallback() -> bool:
	print("[TEST] --- test_null_terrain_fallback ---")
	var field := WindField.new()
	field.turbulence_strength = 0.0
	field.direction_wobble_deg = 0.0

	var pos := Vector3(0, 100, 0)
	var wind: Vector3 = field.get_wind(pos)
	var rad := deg_to_rad(field.wind_direction_deg)
	var expected := Vector3(sin(rad), 0, -cos(rad)) * field.base_speed
	print("[TEST] wind=", wind, " expected=", expected)

	var finite := is_finite(wind.x) and is_finite(wind.y) and is_finite(wind.z)
	var passed := finite and wind.distance_to(expected) < 0.5
	print("[TEST] ", "PASS" if passed else "FAIL", " — no-terrain WindField should reduce to dir * base_speed")
	field.free()
	return passed


# ---------------------------------------------------------------------------
# Test: a hovering drone drifts downwind under relative-airspeed drag
# ---------------------------------------------------------------------------
func test_hover_drifts_downwind() -> bool:
	print("[TEST] --- test_hover_drifts_downwind ---")
	_drone.reset()
	Input.action_release("throttle_up")
	Input.action_release("throttle_down")
	Input.action_release("yaw_left")
	Input.action_release("yaw_right")
	Input.action_release("pitch_forward")
	Input.action_release("pitch_backward")
	Input.action_release("roll_left")
	Input.action_release("roll_right")
	Input.action_release("altitude_hold")
	Input.action_release("brake_mode")
	if _drone._flight_mode != "stabilized":
		_drone._flight_mode = "stabilized"
		_drone._current_mode = _drone._flight_modes["stabilized"]
	_drone.global_position = Vector3(-120, 40, 0)
	_drone.linear_velocity = Vector3.ZERO

	var initial_x: float = _drone.global_position.x
	await _run_ticks(300)

	var final_x: float = _drone.global_position.x
	var final_vel_x: float = _drone.linear_velocity.x
	print("[TEST] initial_x=", initial_x, " final_x=", final_x, " final_vel_x=", final_vel_x)

	var passed: bool = final_vel_x > 0.5 and (final_x - initial_x) > 3.0
	print("[TEST] ", "PASS" if passed else "FAIL", " — hovering drone should drift downwind")
	return passed
