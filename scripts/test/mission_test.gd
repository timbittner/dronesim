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
	await _run_test("test_no_fly_zone_jamming_degrades_signal")
	await _run_test("test_no_fly_zone_shootdown_countdown")
	await _run_test("test_lose_signal_enters_crashed")
	await _run_test("test_tracker_completes_when_all_cleared")
	await _run_test("test_payload_load_updates_mass_and_hover")
	await _run_test("test_payload_drop_falls_and_lands")
	await _run_test("test_deliver_target_clears_on_landed_payload")

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
# NoFlyZone (JAMMING mode, polygon footprint): SignalField picks it up via the
# duck-typed signal_quality_at(pos) hook (group "jammers"), same as a
# circular JammingNode. The footprint is a child Path3D named "Footprint"
# with a square curve — this also doubles as the code-built-zone API example.
# Pins: deep-inside jamming saturates, far outside is clear, ~1m inside the
# boundary the soft edge hasn't fully kicked in yet, and contains_2d's
# to_local() still honors the node's rotation (a corner point inside the
# axis-aligned square leaves the polygon once the zone rotates 45°). No
# Terrain node in this test scene, so SignalField never gets bounds — the
# boundary belt term is always 1.0 and can't confound the jamming
# assertions, same as test_jammer_falloff.
# ---------------------------------------------------------------------------
func test_no_fly_zone_jamming_degrades_signal() -> bool:
	print("[TEST] --- test_no_fly_zone_jamming_degrades_signal ---")
	var field := SignalField.new()
	add_child(field)

	var zone := NoFlyZone.new()
	zone.mode = NoFlyZone.Mode.JAMMING
	zone.strength = 1.0
	zone.edge_falloff = 10.0
	var footprint := Path3D.new()
	footprint.name = "Footprint"
	var curve := Curve3D.new()
	curve.add_point(Vector3(-50, 0, -50))
	curve.add_point(Vector3(50, 0, -50))
	curve.add_point(Vector3(50, 0, 50))
	curve.add_point(Vector3(-50, 0, 50))
	footprint.curve = curve
	zone.add_child(footprint)
	add_child(zone)
	zone.global_position = Vector3(300, 0, 300)
	await get_tree().process_frame  # let zone._ready register into group "jammers"

	var center_q := field.get_quality(zone.global_position)  # 50m from every edge >> falloff
	var far_q := field.get_quality(zone.global_position + Vector3(1000, 0, 0))
	var edge_q := field.get_quality(zone.global_position + Vector3(49, 0, 0))  # ~1m inside

	var inside_pt := zone.global_position + Vector3(20, 0, 20)
	var outside_pt := zone.global_position + Vector3(200, 0, 0)
	var inside_ok := zone.contains_2d(inside_pt)
	var outside_ok := not zone.contains_2d(outside_pt)

	# Corner point inside the axis-aligned square; rotating the zone 45° about
	# Y turns the square into a "diamond" in world space, pushing this same
	# point outside it — proves contains_2d's to_local() honors the node's
	# rotation.
	var diag_pt := zone.global_position + Vector3(45, 0, 45)
	var inside_before_rotate := zone.contains_2d(diag_pt)
	zone.rotation_degrees.y = 45.0
	var outside_after_rotate := not zone.contains_2d(diag_pt)

	zone.queue_free()
	field.free()

	print("[TEST] center_q=", center_q, " far_q=", far_q, " edge_q=", edge_q,
			" inside_ok=", inside_ok, " outside_ok=", outside_ok,
			" inside_before_rotate=", inside_before_rotate, " outside_after_rotate=", outside_after_rotate)

	var passed := is_equal_approx(center_q, 0.0) \
			and is_equal_approx(far_q, 1.0) \
			and edge_q > 0.7 \
			and inside_ok and outside_ok \
			and inside_before_rotate and outside_after_rotate
	print("[TEST] ", "PASS" if passed else "FAIL",
			" — no-fly zone: jams deep inside the polygon, clear outside, soft edge, contains_2d respects rotation")
	return passed


# ---------------------------------------------------------------------------
# NoFlyZone (SHOOT_DOWN mode): instantiates the SHIPPED scene (proving the
# hand-authored Footprint Curve3D in no_fly_zone.tscn actually loads and
# contains the default 200x200 square), positions it over the test scene's
# $Drone, and pins the AirspaceControl-style per-drone countdown: lingering
# inside past countdown_time shoots the drone down via lose_signal(), and
# moving the zone away afterward doesn't phantom-retrack it.
# ---------------------------------------------------------------------------
func test_no_fly_zone_shootdown_countdown() -> bool:
	print("[TEST] --- test_no_fly_zone_shootdown_countdown ---")
	_drone.reset()

	var zone := preload("res://scenes/mission/no_fly_zone.tscn").instantiate() as NoFlyZone
	zone.mode = NoFlyZone.Mode.SHOOT_DOWN
	zone.countdown_time = 0.2
	add_child(zone)
	# Default 200x200 footprint (±100) centered right on the drone's spawn XZ.
	zone.global_position = Vector3(_drone.global_position.x, 0.0, _drone.global_position.z)

	var frames := 0
	while not _drone.is_crashed() and frames < 60:
		await get_tree().physics_frame
		frames += 1
	var crashed := _drone.is_crashed()
	print("[TEST] crashed=", crashed, " after ", frames, " physics frames")

	# Recover, then move the zone far away — a drone that was tracked and shot
	# down must not get silently re-tracked once it's clearly outside.
	_drone.reset()
	zone.global_position = Vector3(5000, 0, 5000)
	frames = 0
	while frames < 10:
		await get_tree().physics_frame
		frames += 1
	var still_clear := not _drone.is_crashed()

	zone.queue_free()
	_drone.reset()  # leave a clean slate for the tests that follow
	print("[TEST] still_clear=", still_clear)

	var passed := crashed and still_clear
	print("[TEST] ", "PASS" if passed else "FAIL",
			" — shoot-down: countdown crashes the drone inside the zone, no phantom re-track once moved away")
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


# ---------------------------------------------------------------------------
# Payload (P7.1) helpers — the test scene has no ground (unlike
# flight_mode_test_scene.tscn), so a thin StaticBody3D floor is built in code,
# right under the drone's spawn point, and torn down at the end of each test.
# ---------------------------------------------------------------------------
func _make_floor() -> StaticBody3D:
	var floor_body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(10, 0.1, 10)
	shape.shape = box
	floor_body.add_child(shape)
	add_child(floor_body)
	floor_body.position = Vector3(0, -0.05, 0)  # top face at y = 0
	return floor_body


func _free_payloads() -> void:
	for p in get_tree().get_nodes_in_group("payloads"):
		(p as Node).queue_free()


## Forces the player drone down onto whatever's below it and waits for
## is_landed(). The default stabilized-mode hover (collective ≈
## hover_throttle) roughly cancels gravity, so a passive drone never
## descends on its own — switch to acro and hold throttle-down (idle_throttle
## * (1 + throttle) hits a true zero-thrust cutoff at throttle = -1, unlike
## stabilized's collective floor) until it settles, then restore input/mode.
func _land_drone(budget: int = 120) -> bool:
	_drone.select_flight_mode("acro")
	Input.action_press("throttle_down", 1.0)
	var frames := 0
	while not _drone.is_landed() and frames < budget:
		await get_tree().physics_frame
		frames += 1
	Input.action_release("throttle_down")
	_drone.select_flight_mode("stabilized")
	return _drone.is_landed()


# ---------------------------------------------------------------------------
# load_payload() adds payload_mass to the airframe, re-derives hover_throttle,
# and pushes it into the modes that cached it at _ready (stabilized,
# altitude hold); drop_payload() restores both and returns CoM to AUTO.
# Refuses mid-air (not is_landed()) — pinned right after reset(), before the
# drone has touched the floor.
# ---------------------------------------------------------------------------
func test_payload_load_updates_mass_and_hover() -> bool:
	print("[TEST] --- test_payload_load_updates_mass_and_hover ---")
	var floor_body := _make_floor()
	_drone.reset()
	await get_tree().physics_frame  # let _integrate_forces see "not touching yet"

	var midair_refused: bool = not _drone.load_payload()

	var landed: bool = await _land_drone()

	var baseline_mass: float = _drone.mass
	var baseline_hover: float = _drone.hover_throttle

	var loaded: bool = _drone.load_payload()
	var mass_after_load: float = _drone.mass
	var expected_hover: float = (mass_after_load * 9.8) / (4.0 * _drone.max_thrust)
	var hover_ok: bool = is_equal_approx(_drone.hover_throttle, expected_hover) \
			and is_equal_approx((_drone._flight_modes["stabilized"] as FlightModeStabilized).hover_throttle, expected_hover) \
			and is_equal_approx(_drone._altitude_hold.hover_throttle, expected_hover)

	var dropped: bool = _drone.drop_payload()
	var mass_restored: bool = is_equal_approx(_drone.mass, baseline_mass)
	var hover_restored: bool = is_equal_approx(_drone.hover_throttle, baseline_hover)
	var com_auto: bool = _drone.center_of_mass_mode == RigidBody3D.CENTER_OF_MASS_MODE_AUTO

	_free_payloads()
	floor_body.queue_free()
	_drone.reset()

	print("[TEST] midair_refused=", midair_refused, " landed=", landed, " loaded=", loaded,
			" mass_after_load=", mass_after_load, " hover_ok=", hover_ok, " dropped=", dropped,
			" mass_restored=", mass_restored, " hover_restored=", hover_restored, " com_auto=", com_auto)

	var passed := midair_refused and landed and loaded \
			and is_equal_approx(mass_after_load, baseline_mass + _drone.payload_mass) \
			and hover_ok and dropped and mass_restored and hover_restored and com_auto
	print("[TEST] ", "PASS" if passed else "FAIL",
			" — payload load/drop updates mass + hover_throttle (incl. cached modes), refuses mid-air")
	return passed


# ---------------------------------------------------------------------------
# drop_payload() spawns a Payload (group "payloads") inheriting the drone's
# velocity (no impulse — rotor-only physics untouched), which then free-falls
# onto the floor and settles.
# ---------------------------------------------------------------------------
func test_payload_drop_falls_and_lands() -> bool:
	print("[TEST] --- test_payload_drop_falls_and_lands ---")
	var floor_body := _make_floor()
	_drone.reset()
	await _land_drone()

	_drone.load_payload()
	_drone.global_position.y += 3.0  # lift off the floor so the crate free-falls
	var vel_before: Vector3 = _drone.linear_velocity

	var dropped: bool = _drone.drop_payload()
	# Skip anything still queued from a prior test's _free_payloads() —
	# queue_free() defers, so a stale instance can still be in the group.
	var payload: Payload = null
	for p in get_tree().get_nodes_in_group("payloads"):
		if not (p as Node).is_queued_for_deletion():
			payload = p as Payload
			break
	var inherited_velocity: bool = payload != null \
			and payload.linear_velocity.distance_to(vel_before) < 0.01

	var frames := 0
	while payload != null and not payload.landed and frames < 120:
		await get_tree().physics_frame
		frames += 1
	var landed: bool = payload != null and payload.landed

	print("[TEST] dropped=", dropped, " inherited_velocity=", inherited_velocity,
			" landed=", landed, " frames=", frames)

	_free_payloads()
	floor_body.queue_free()
	_drone.reset()

	var passed := dropped and payload != null and inherited_velocity and landed
	print("[TEST] ", "PASS" if passed else "FAIL",
			" — dropped payload inherits drone velocity, free-falls, and lands")
	return passed


# ---------------------------------------------------------------------------
# DELIVER MissionTarget (P7.1): clears only once a landed payload sits inside
# radius. Payloads are frozen (RigidBody3D.freeze) so gravity can't move them
# off their assigned test position between frames — `landed` is set directly,
# unit-style, no drop physics needed. Order matters: outside-landed, then
# inside-not-landed, both must NOT clear, only the final inside-landed case
# clears.
# ---------------------------------------------------------------------------
func test_deliver_target_clears_on_landed_payload() -> bool:
	print("[TEST] --- test_deliver_target_clears_on_landed_payload ---")
	var floor_body := _make_floor()
	var target := MissionTarget.new()
	target.type = MissionTarget.Type.DELIVER
	target.radius = 20.0
	target.position = Vector3.ZERO
	add_child(target)
	await get_tree().physics_frame

	var outside := Payload.new()
	outside.freeze = true
	add_child(outside)
	outside.global_position = Vector3(50, 0, 0)
	outside.landed = true
	await get_tree().physics_frame
	await get_tree().physics_frame
	var not_cleared_outside := not target.cleared

	var inside_unsettled := Payload.new()
	inside_unsettled.freeze = true
	add_child(inside_unsettled)
	inside_unsettled.global_position = Vector3(5, 0, 0)
	inside_unsettled.landed = false
	await get_tree().physics_frame
	await get_tree().physics_frame
	var not_cleared_unsettled := not target.cleared

	var inside_landed := Payload.new()
	inside_landed.freeze = true
	add_child(inside_landed)
	inside_landed.global_position = Vector3(5, 0, 0)
	inside_landed.landed = true
	await get_tree().physics_frame
	await get_tree().physics_frame
	var cleared := target.cleared

	print("[TEST] not_cleared_outside=", not_cleared_outside,
			" not_cleared_unsettled=", not_cleared_unsettled, " cleared=", cleared)

	_free_payloads()
	target.queue_free()
	floor_body.queue_free()

	var passed := not_cleared_outside and not_cleared_unsettled and cleared
	print("[TEST] ", "PASS" if passed else "FAIL",
			" — DELIVER target only clears once a landed payload is inside radius")
	return passed
