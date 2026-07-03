extends Node3D

## Headless test suite for the P5 mission / signal systems. Lean by design —
## pure-function assertions where possible (SignalField quality math), and the
## two behaviours worth pinning: lose_signal() reaches CRASHED without an
## impact, and MissionTracker completes only once every target is cleared.
## Deliberately NOT here (covered by per-phase test flights): dwell/countdown
## timing, packet-loss statistics, all shader/HUD visuals.

var _passed: int = 0
var _failed: int = 0
var _drone: DroneController = null


func _ready() -> void:
	call_deferred("_delayed_start")


func _delayed_start() -> void:
	_drone = $Drone as DroneController
	if _drone == null:
		printerr("[TEST] FATAL: Could not find Drone node in scene")
		get_tree().quit(1)
		return
	await _run_all_tests()


func _run_all_tests() -> void:
	_passed = 0
	_failed = 0

	await _run_test("test_boundary_belt_ramp")
	await _run_test("test_jammer_falloff")
	await _run_test("test_lose_signal_enters_crashed")
	await _run_test("test_tracker_completes_when_all_cleared")

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


# ---------------------------------------------------------------------------
# SignalField boundary belt: quality is 1 inside the map, ramps linearly across
# boundary_margin, and hits 0 well outside. Pure math — the bounds are set
# directly so no terrain/tree is needed.
# ---------------------------------------------------------------------------
func test_boundary_belt_ramp() -> bool:
	print("[TEST] --- test_boundary_belt_ramp ---")
	var field := SignalField.new()
	field.boundary_margin = 150.0
	field._has_bounds = true
	field._bounds = Rect2(-50, -50, 100, 100)  # x,z in [-50, 50]

	var inside := field._boundary_quality(Vector3(0, 5, 0))
	var mid := field._boundary_quality(Vector3(125, 5, 0))   # 75 m outside -> 0.5
	var outside := field._boundary_quality(Vector3(250, 5, 0))  # 200 m out -> 0
	field.free()
	print("[TEST] inside=", inside, " mid=", mid, " outside=", outside)

	var passed := is_equal_approx(inside, 1.0) \
			and absf(mid - 0.5) < 0.02 \
			and is_equal_approx(outside, 0.0)
	print("[TEST] ", "PASS" if passed else "FAIL", " — belt: 1 inside, ~0.5 mid-belt, 0 outside")
	return passed


# ---------------------------------------------------------------------------
# SignalField jammer falloff: full strength reduction at the core, fading
# smoothly to none at the rim. Calls _jammer_quality directly with a JammingNode
# stand-in (never entered the tree, so no GLB/group side effects).
# ---------------------------------------------------------------------------
func test_jammer_falloff() -> bool:
	print("[TEST] --- test_jammer_falloff ---")
	var field := SignalField.new()
	var jammer := JammingNode.new()
	jammer.strength = 0.8
	jammer.radius = 100.0
	add_child(jammer)  # in-tree so global_position resolves cleanly
	jammer.global_position = Vector3.ZERO

	var core := field._jammer_quality(jammer, Vector3(0, 0, 0))
	var half := field._jammer_quality(jammer, Vector3(50, 0, 0))
	var rim := field._jammer_quality(jammer, Vector3(100, 0, 0))
	var beyond := field._jammer_quality(jammer, Vector3(200, 0, 0))
	jammer.queue_free()
	field.free()
	print("[TEST] core=", core, " half=", half, " rim=", rim, " beyond=", beyond)

	var passed := absf(core - 0.2) < 0.01 \
			and half > core and half < rim \
			and is_equal_approx(rim, 1.0) \
			and is_equal_approx(beyond, 1.0)
	print("[TEST] ", "PASS" if passed else "FAIL", " — jammer: 1-strength at core, 1.0 at/beyond rim, monotonic")
	return passed


# ---------------------------------------------------------------------------
# lose_signal() reaches the CRASHED state with no impact, and reset() recovers.
# This is the one safety-critical transition (radar shoot-down / sustained-zero
# signal both route through it).
# ---------------------------------------------------------------------------
func test_lose_signal_enters_crashed() -> bool:
	print("[TEST] --- test_lose_signal_enters_crashed ---")
	_drone.reset()
	var before := _drone.is_crashed()
	_drone.lose_signal()
	var after := _drone.is_crashed()
	# Idempotent: a second call must not error or change state.
	_drone.lose_signal()
	_drone.reset()
	var recovered := not _drone.is_crashed()
	print("[TEST] before=", before, " after=", after, " recovered=", recovered)

	var passed := not before and after and recovered
	print("[TEST] ", "PASS" if passed else "FAIL", " — lose_signal crashes without impact, reset recovers")
	return passed


# ---------------------------------------------------------------------------
# MissionTracker fires mission_completed exactly once, only after every target
# is cleared. Targets are placed far from the drone so the OBSERVE dwell logic
# can't clear them on its own — only the explicit _mark_cleared() calls do.
# ---------------------------------------------------------------------------
func test_tracker_completes_when_all_cleared() -> bool:
	print("[TEST] --- test_tracker_completes_when_all_cleared ---")
	var t1 := MissionTarget.new()
	var t2 := MissionTarget.new()
	t1.position = Vector3(2000, 0, 0)
	t2.position = Vector3(2000, 0, 50)
	add_child(t1)
	add_child(t2)
	var tracker := MissionTracker.new()
	add_child(tracker)

	var completed_count := [0]
	tracker.mission_completed.connect(func() -> void: completed_count[0] += 1)

	# Let the tracker's deferred _collect wire up to both targets.
	await get_tree().process_frame
	await get_tree().process_frame

	t1._mark_cleared()
	var after_one := tracker.completed
	t2._mark_cleared()
	var after_all := tracker.completed
	print("[TEST] after_one=", after_one, " after_all=", after_all, " emits=", completed_count[0])

	var passed: bool = not after_one and after_all and completed_count[0] == 1
	t1.queue_free()
	t2.queue_free()
	tracker.queue_free()
	print("[TEST] ", "PASS" if passed else "FAIL", " — completes once, only after all targets cleared")
	return passed
