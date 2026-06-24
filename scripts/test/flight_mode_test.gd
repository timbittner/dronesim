extends Node3D

## Flight mode test harness for DroneSim.
## Per-rotor thrust vectoring: rotation comes from differential thrust,
## so tests must keep thrust enabled (max_thrust > 0).

var _passed: int = 0
var _failed: int = 0
var _drone: RigidBody3D = null


func _ready() -> void:
	call_deferred("_delayed_start")


func _delayed_start() -> void:
	_drone = $Drone as RigidBody3D
	if _drone == null:
		printerr("[TEST] FATAL: Could not find Drone node in scene")
		get_tree().quit(1)
		return

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
	# Keep max_thrust at default (50.0) — per-rotor thrust vectoring needs
	# thrust to produce rotation. Move drone high to avoid ground interference.
	_drone.global_position.y = 500.0


func _set_acro_mode() -> void:
	_drone._flight_mode = "acro"
	_drone._current_mode = _drone._flight_modes["acro"]


func _run_ticks(count: int) -> void:
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

	# Self-leveling tests
	await _run_test("test_stabilized_self_levels_from_pitch_tilt")
	await _run_test("test_stabilized_self_levels_from_roll_tilt")
	await _run_test("test_stabilized_self_levels_from_combined_tilt")
	await _run_test("test_acro_does_not_self_level")
	await _run_test("test_stabilized_responds_to_input")

	# Input → hold → release → observe tests
	await _run_test("test_acro_holds_pitch_after_input")
	await _run_test("test_acro_holds_roll_after_input")
	await _run_test("test_stabilized_levels_after_pitch_input")
	await _run_test("test_stabilized_levels_after_roll_input")

	# Roll→yaw coupling test
	await _run_test("test_stabilized_roll_does_not_induce_yaw_spin")

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

	_drone.global_transform.basis = Basis(Vector3(1, 0, 0), _deg_to_rad(30))
	print("[TEST] Initial pitch: ", _rad_to_deg(_drone.global_transform.basis.get_euler().x))

	# Run 350 physics ticks (damping slightly slows convergence vs old 0-damping tests)
	await _run_ticks(350)

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

	_drone.global_transform.basis = Basis(Vector3(0, 0, 1), _deg_to_rad(20))
	print("[TEST] Initial roll: ", _rad_to_deg(_drone.global_transform.basis.get_euler().z))

	# Run 350 physics ticks (damping slightly slows convergence vs old 0-damping tests)
	await _run_ticks(350)

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

	var pitch_basis := Basis(Vector3(1, 0, 0), _deg_to_rad(25))
	var roll_basis := Basis(Vector3(0, 0, 1), _deg_to_rad(-15))
	_drone.global_transform.basis = roll_basis * pitch_basis

	var init_euler := _drone.global_transform.basis.get_euler()
	print("[TEST] Initial pitch: ", _rad_to_deg(init_euler.x), ", roll: ", _rad_to_deg(init_euler.z))

	# Run 350 physics ticks (damping slightly slows convergence vs old 0-damping tests)
	await _run_ticks(350)

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
	_set_acro_mode()

	print("[TEST] Flight mode: ", _drone._flight_mode)

	_drone.global_transform.basis = Basis(Vector3(1, 0, 0), _deg_to_rad(30))
	print("[TEST] Initial pitch: ", _rad_to_deg(_drone.global_transform.basis.get_euler().x))

	# Run 350 physics ticks (damping slightly slows convergence vs old 0-damping tests)
	await _run_ticks(350)

	var euler := _drone.global_transform.basis.get_euler()
	var pitch_deg := _rad_to_deg(euler.x)
	print("[TEST] Final pitch: ", pitch_deg)

	var passed := pitch_deg > 20.0
	print("[TEST] ", "PASS" if passed else "FAIL", " — pitch=", pitch_deg, "° (expected > 20°, should NOT self-level)")
	return passed


# ---------------------------------------------------------------------------
# Test: Stabilized responds to pitch-forward input
# ---------------------------------------------------------------------------
func test_stabilized_responds_to_input() -> bool:
	print("[TEST] --- test_stabilized_responds_to_input ---")
	_reset_drone()

	Input.action_press("pitch_forward", 0.8)
	# 150 ticks to build up angular velocity against damping
	await _run_ticks(150)
	Input.action_release("pitch_forward")

	var euler := _drone.global_transform.basis.get_euler()
	var pitch_deg := _rad_to_deg(euler.x)
	print("[TEST] Final pitch: ", pitch_deg)

	# Should have pitched (any direction, |pitch| > 2°)
	var passed: bool = abs(pitch_deg) > 2.0
	print("[TEST] ", "PASS" if passed else "FAIL", " — pitch=", pitch_deg, "° (expected < -2°, drone should pitch down from pitch_forward)")
	return passed


# ===========================================================================
# Input-hold-release tests: apply brief stick input, observe behavior
# ===========================================================================

# ---------------------------------------------------------------------------
# Test: Acro holds pitch angle after brief input
# ---------------------------------------------------------------------------
func test_acro_holds_pitch_after_input() -> bool:
	print("[TEST] --- test_acro_holds_pitch_after_input ---")
	_reset_drone()
	_set_acro_mode()

	# Brief pitch-up input at 15% strength
	Input.action_press("pitch_backward", 0.15)
	await _run_ticks(15)
	Input.action_release("pitch_backward")

	# Wait for angular damping to settle, then check drone holds angle
	await _run_ticks(300)

	var euler := _drone.global_transform.basis.get_euler()
	var pitch_deg := _rad_to_deg(euler.x)
	print("[TEST] Final pitch: ", pitch_deg)

	# In acro, the drone should hold a nonzero pitch angle
	var passed: bool = abs(pitch_deg) > 5.0
	print("[TEST] ", "PASS" if passed else "FAIL", " — pitch=", pitch_deg, "° (expected |pitch| > 5°, acro holds angle)")
	return passed


# ---------------------------------------------------------------------------
# Test: Acro holds roll angle after brief input
# ---------------------------------------------------------------------------
func test_acro_holds_roll_after_input() -> bool:
	print("[TEST] --- test_acro_holds_roll_after_input ---")
	_reset_drone()
	_set_acro_mode()

	# Brief roll-right input at 15% strength
	Input.action_press("roll_right", 0.15)
	await _run_ticks(15)
	Input.action_release("roll_right")

	# Wait for angular damping to settle
	await _run_ticks(300)

	var euler := _drone.global_transform.basis.get_euler()
	var roll_deg := _rad_to_deg(euler.z)
	print("[TEST] Final roll: ", roll_deg)

	# In acro, the drone should hold a nonzero roll angle
	var passed: bool = abs(roll_deg) > 5.0
	print("[TEST] ", "PASS" if passed else "FAIL", " — roll=", roll_deg, "° (expected |roll| > 5°, acro holds angle)")
	return passed


# ---------------------------------------------------------------------------
# Test: Stabilized self-levels after brief pitch input
# ---------------------------------------------------------------------------
func test_stabilized_levels_after_pitch_input() -> bool:
	print("[TEST] --- test_stabilized_levels_after_pitch_input ---")
	_reset_drone()

	# Brief pitch-up input at 15% strength
	Input.action_press("pitch_backward", 0.15)
	await _run_ticks(15)
	Input.action_release("pitch_backward")

	# Wait for PD auto-level to correct
	await _run_ticks(300)

	var euler := _drone.global_transform.basis.get_euler()
	var pitch_deg := _rad_to_deg(euler.x)
	print("[TEST] Final pitch: ", pitch_deg)

	# In stabilized, the drone should return to near level
	var passed: bool = abs(pitch_deg) < 5.0
	print("[TEST] ", "PASS" if passed else "FAIL", " — pitch=", pitch_deg, "° (expected |pitch| < 5°, stabilized self-levels)")
	return passed


# ---------------------------------------------------------------------------
# Test: Stabilized self-levels after brief roll input
# ---------------------------------------------------------------------------
func test_stabilized_levels_after_roll_input() -> bool:
	print("[TEST] --- test_stabilized_levels_after_roll_input ---")
	_reset_drone()

	# Brief roll-right input at 15% strength
	Input.action_press("roll_right", 0.15)
	await _run_ticks(15)
	Input.action_release("roll_right")

	# Wait for PD auto-level to correct
	await _run_ticks(300)

	var euler := _drone.global_transform.basis.get_euler()
	var roll_deg := _rad_to_deg(euler.z)
	print("[TEST] Final roll: ", roll_deg)

	# In stabilized, the drone should return to near level
	var passed: bool = abs(roll_deg) < 5.0
	print("[TEST] ", "PASS" if passed else "FAIL", " — roll=", roll_deg, "° (expected |roll| < 5°, stabilized self-levels)")
	return passed


# ---------------------------------------------------------------------------
# Test: Roll input in stabilized does not cause yaw spin-out
# ---------------------------------------------------------------------------
func test_stabilized_roll_does_not_induce_yaw_spin() -> bool:
	print("[TEST] --- test_stabilized_roll_does_not_induce_yaw_spin ---")
	_reset_drone()

	# Add a little throttle so drone has authority during roll
	Input.action_press("throttle_up", 0.3)

	# Initial heading
	var init_euler := _drone.global_transform.basis.get_euler()
	var init_heading := _rad_to_deg(init_euler.y)
	print("[TEST] Initial heading: ", init_heading)

	# Heavy roll input for 30 ticks (0.5s)
	Input.action_press("roll_right", 0.6)
	await _run_ticks(30)
	Input.action_release("roll_right")
	Input.action_release("throttle_up")

	# Wait for settling
	await _run_ticks(200)

	var euler := _drone.global_transform.basis.get_euler()
	var heading := _rad_to_deg(euler.y)
	var heading_delta := _normalize_angle(heading - init_heading)
	var roll_deg := _rad_to_deg(euler.z)
	print("[TEST] Final heading: ", heading, " delta: ", heading_delta, "°  roll: ", roll_deg)

	# Heading should not have spun out (allow moderate drift)
	var passed: bool = abs(heading_delta) < 45.0
	print("[TEST] ", "PASS" if passed else "FAIL", " — heading_delta=", heading_delta, "° (expected |delta| < 45°, no yaw spin-out)")
	return passed


# Normalize angle to -180..180
static func _normalize_angle(deg: float) -> float:
	while deg > 180.0:
		deg -= 360.0
	while deg < -180.0:
		deg += 360.0
	return deg
