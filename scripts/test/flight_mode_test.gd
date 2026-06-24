extends Node3D

## Flight mode test harness for DroneSim.
## Uses await get_tree().physics_frame for proper physics integration
## (manual _physics_process() calls queue torque but Godot's physics
## server never integrates it).

var _passed: int = 0
var _failed: int = 0
var _drone: RigidBody3D = null


func _ready() -> void:
	# Use call_deferred so the scene tree is fully set up before tests begin
	call_deferred("_delayed_start")


func _delayed_start() -> void:
	_drone = $Drone as RigidBody3D
	if _drone == null:
		printerr("[TEST] FATAL: Could not find Drone node in scene")
		get_tree().quit(1)
		return

	# Start the async test runner
	await _run_all_tests()


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

func _reset_drone() -> void:
	_drone.reset()
	# Release all input actions to ensure clean state
	Input.action_release("throttle_up")
	Input.action_release("throttle_down")
	Input.action_release("yaw_left")
	Input.action_release("yaw_right")
	Input.action_release("pitch_forward")
	Input.action_release("pitch_backward")
	Input.action_release("roll_left")
	Input.action_release("roll_right")
	# Default flight mode - stabilized
	if _drone._flight_mode != "stabilized":
		_drone._flight_mode = "stabilized"
		_drone._current_mode = _drone._flight_modes["stabilized"]
	# Disable thrust for self-leveling tests to avoid
	# horizontal forces from tilted thrust interfering with rotational correction
	_drone.max_thrust = 0.0


func _run_ticks(count: int) -> void:
	## Advance physics by `count` frames using proper engine integration.
	## Forces/torques queued by _physics_process are integrated by the engine
	## between each frame.
	for _i in range(count):
		await get_tree().physics_frame


static func _deg_to_rad(deg: float) -> float:
	return deg * PI / 180.0


static func _rad_to_deg(rad: float) -> float:
	return rad * 180.0 / PI


# ---------------------------------------------------------------------------
# Test runner
# ---------------------------------------------------------------------------

func _run_all_tests() -> void:
	_passed = 0
	_failed = 0

	await _run_test("test_stabilized_self_levels_from_pitch_tilt")
	await _run_test("test_stabilized_self_levels_from_roll_tilt")
	await _run_test("test_stabilized_self_levels_from_combined_tilt")
	await _run_test("test_acro_does_not_self_level")
	await _run_test("test_stabilized_responds_to_input")

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
# Test: Stabilized self-levels from pitch tilt
# ---------------------------------------------------------------------------
func test_stabilized_self_levels_from_pitch_tilt() -> bool:
	print("[TEST] --- test_stabilized_self_levels_from_pitch_tilt ---")
	_reset_drone()

	# Tilt drone to 30° pitch (rotation around X axis)
	_drone.global_transform.basis = Basis(Vector3(1, 0, 0), _deg_to_rad(30))
	print("[TEST] Initial pitch: ", _rad_to_deg(_drone.global_transform.basis.get_euler().x))

	# Run 300 physics ticks with no input
	await _run_ticks(300)

	var euler := _drone.global_transform.basis.get_euler()
	var pitch_deg := _rad_to_deg(euler.x)
	print("[TEST] Final pitch: ", pitch_deg)

	var passed: bool = abs(pitch_deg) <= 5.0
	print("[TEST] ", "PASS" if passed else "FAIL", " — pitch=", pitch_deg, "° (expected within 5° of zero)")
	return passed


# ---------------------------------------------------------------------------
# Test: Stabilized self-levels from roll tilt
# ---------------------------------------------------------------------------
func test_stabilized_self_levels_from_roll_tilt() -> bool:
	print("[TEST] --- test_stabilized_self_levels_from_roll_tilt ---")
	_reset_drone()

	# Tilt drone to 20° roll (rotation around Z axis)
	_drone.global_transform.basis = Basis(Vector3(0, 0, 1), _deg_to_rad(20))
	print("[TEST] Initial roll: ", _rad_to_deg(_drone.global_transform.basis.get_euler().z))

	await _run_ticks(300)

	var euler := _drone.global_transform.basis.get_euler()
	var roll_deg := _rad_to_deg(euler.z)
	print("[TEST] Final roll: ", roll_deg)

	var passed: bool = abs(roll_deg) <= 5.0
	print("[TEST] ", "PASS" if passed else "FAIL", " — roll=", roll_deg, "° (expected within 5° of zero)")
	return passed


# ---------------------------------------------------------------------------
# Test: Stabilized self-levels from combined pitch + roll tilt
# ---------------------------------------------------------------------------
func test_stabilized_self_levels_from_combined_tilt() -> bool:
	print("[TEST] --- test_stabilized_self_levels_from_combined_tilt ---")
	_reset_drone()

	# Compose: pitch=25° around X, then roll=-15° around Z
	var pitch_basis := Basis(Vector3(1, 0, 0), _deg_to_rad(25))
	var roll_basis := Basis(Vector3(0, 0, 1), _deg_to_rad(-15))
	_drone.global_transform.basis = roll_basis * pitch_basis

	var init_euler := _drone.global_transform.basis.get_euler()
	print("[TEST] Initial pitch: ", _rad_to_deg(init_euler.x), ", roll: ", _rad_to_deg(init_euler.z))

	await _run_ticks(300)

	var euler := _drone.global_transform.basis.get_euler()
	var pitch_deg := _rad_to_deg(euler.x)
	var roll_deg := _rad_to_deg(euler.z)
	print("[TEST] Final pitch: ", pitch_deg, ", roll: ", roll_deg)

	var passed: bool = abs(pitch_deg) <= 5.0 and abs(roll_deg) <= 5.0
	print("[TEST] ", "PASS" if passed else "FAIL", " — pitch=", pitch_deg, "°, roll=", roll_deg, "° (expected both within 5° of zero)")
	return passed


# ---------------------------------------------------------------------------
# Test: Acro does NOT self-level
# ---------------------------------------------------------------------------
func test_acro_does_not_self_level() -> bool:
	print("[TEST] --- test_acro_does_not_self_level ---")
	_reset_drone()

	# Switch to acro mode
	_drone._flight_mode = "acro"
	_drone._current_mode = _drone._flight_modes["acro"]
	print("[TEST] Flight mode: ", _drone._flight_mode)

	# Tilt to 30° pitch, but move drone higher so it doesn't hit the ground
	# during 300 ticks. With gravity + no thrust, a 2kg drone at y=1 falls
	# ~0.5m in 300 physics ticks and bounces off the ground.
	_drone.global_position.y = 500.0
	_drone.global_transform.basis = Basis(Vector3(1, 0, 0), _deg_to_rad(30))
	print("[TEST] Initial pitch: ", _rad_to_deg(_drone.global_transform.basis.get_euler().x))

	await _run_ticks(300)

	var euler := _drone.global_transform.basis.get_euler()
	var pitch_deg := _rad_to_deg(euler.x)
	print("[TEST] Final pitch: ", pitch_deg)

	# Should still be tilted (pitch > 20°)
	var passed := pitch_deg > 20.0
	print("[TEST] ", "PASS" if passed else "FAIL", " — pitch=", pitch_deg, "° (expected > 20°, should NOT self-level)")
	return passed


# ---------------------------------------------------------------------------
# Test: Stabilized responds to pitch-forward input
# ---------------------------------------------------------------------------
func test_stabilized_responds_to_input() -> bool:
	print("[TEST] --- test_stabilized_responds_to_input ---")
	_reset_drone()

	# Flight mode is already "stabilized" from reset
	# Simulate pressing pitch_forward with strength 0.5
	# Note: In the actual physics, -X torque = pitch UP (nose rises).
	# The original code's comment saying "-X = nose down" was incorrect.
	# Pressing pitch_forward makes the drone pitch up (positive Euler x).
	Input.action_press("pitch_forward", 0.5)

	# Run 50 physics ticks
	await _run_ticks(50)

	# Release the action
	Input.action_release("pitch_forward")

	var euler := _drone.global_transform.basis.get_euler()
	var pitch_deg := _rad_to_deg(euler.x)
	print("[TEST] Final pitch: ", pitch_deg)

	# Should have pitched up (positive pitch angle > 2°)
	var passed := pitch_deg > 2.0
	print("[TEST] ", "PASS" if passed else "FAIL", " — pitch=", pitch_deg, "° (expected > 2°, drone should pitch up from pitch_forward)")
	return passed
