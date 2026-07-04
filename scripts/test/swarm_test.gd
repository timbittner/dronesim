extends Node3D

## Headless test suite for the P6 swarm systems. Numerical where possible
## (slot-table math, formation control-law signs, pilot dropout freeze — no
## physics frames), plus ONE bounded flight test pinning that a follower
## actually holds and re-converges to its slot. Deliberately NOT here (covered
## by in-editor test flights): formation aesthetics, BOHR orbit feel,
## multi-follower separation.

var _passed: int = 0
var _failed: int = 0
var _drone: DroneController = null


## Manager stand-in for the pilot dropout test: a moving slot target.
class StubManager extends Node:
	var calls: int = 0
	func get_slot_position(_i: int) -> Vector3:
		calls += 1
		return Vector3(calls, 0, 0)
	func get_slot_heading(_i: int) -> float:
		return 0.0


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

	await _run_test("test_slot_tables")
	await _run_test("test_formation_control_law_signs")
	await _run_test("test_pilot_dropout_freezes_target")
	await _run_test("test_follower_holds_and_reconverges")

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
# Slot tables: LINE alternates sides at spacing multiples, V trails behind the
# leader, RING sits at ring_radius, BOHR moves over time. Pure math on the
# leader pose (the scene's Drone at (0,1,0), heading 0) — follower_count = 0
# so nothing spawns.
# ---------------------------------------------------------------------------
func test_slot_tables() -> bool:
	print("[TEST] --- test_slot_tables ---")
	var m := SwarmManager.new()
	m.follower_count = 0
	m.spacing = 6.0
	m.ring_radius = 9.0
	m.altitude_offset = 4.0
	add_child(m)

	var base: Vector3 = _drone.global_position + Vector3(0, 4, 0)

	m.formation = SwarmManager.Formation.LINE
	var l0 := m.get_slot_position(0) - base   # right 1 rank
	var l1 := m.get_slot_position(1) - base   # left 1 rank
	var l2 := m.get_slot_position(2) - base   # right 2 ranks
	var line_ok: bool = l0.is_equal_approx(Vector3(6, 0, 0)) \
			and l1.is_equal_approx(Vector3(-6, 0, 0)) \
			and l2.is_equal_approx(Vector3(12, 0, 0))

	m.formation = SwarmManager.Formation.V
	var v0 := m.get_slot_position(0) - base
	# Behind the leader (heading 0 → tail = +Z) and offset to a side, 45°.
	var v_ok: bool = v0.z > 0.1 and absf(absf(v0.x) - v0.z) < 0.01

	m.formation = SwarmManager.Formation.RING
	m.follower_count = 4  # ring divides the circle by the count
	var r0 := m.get_slot_position(0) - base
	var r1 := m.get_slot_position(1) - base
	var ring_ok: bool = absf(r0.length() - 9.0) < 0.01 \
			and absf(r1.length() - 9.0) < 0.01 \
			and not r0.is_equal_approx(r1)

	m.formation = SwarmManager.Formation.BOHR
	m.follower_count = 10  # 2 in shell 0, 8 in shell 1
	m._time = 0.0
	var b_t0 := m.get_slot_position(0)
	m._time = 1.0
	var b_t1 := m.get_slot_position(0)
	var inner := (m.get_slot_position(0) - base).length()   # shell 0: tight
	var outer := (m.get_slot_position(2) - base).length()   # shell 1: ring_radius
	var bohr_ok: bool = not b_t0.is_equal_approx(b_t1) \
			and inner < outer * 0.5 \
			and absf(outer - 9.0) < 0.01

	# The deferred _spawn_followers hasn't fired yet (this test runs
	# synchronously) — zero the count again so this table-only manager never
	# actually spawns drones.
	m.follower_count = 0
	m.queue_free()
	print("[TEST] line=", line_ok, " v=", v_ok, " ring=", ring_ok, " bohr_moves=", bohr_ok)
	var passed := line_ok and v_ok and ring_ok and bohr_ok
	print("[TEST] ", "PASS" if passed else "FAIL", " — slot tables per formation")
	return passed


# ---------------------------------------------------------------------------
# Formation control law: correct signs for each error axis, level hover at
# zero error. Pure compute() calls on a fresh mode, identity basis, no tree.
# ---------------------------------------------------------------------------
func test_formation_control_law_signs() -> bool:
	print("[TEST] --- test_formation_control_law_signs ---")
	var basis := Basis.IDENTITY
	var no_spin := Vector3.ZERO

	# Zero error → hover collective, no differentials, no yaw.
	var mode := _fresh_mode()
	var c := mode.compute(0, 0, 0, 0, basis, no_spin, 1.0 / 60.0)
	var level_ok: bool = absf(c.collective - mode.hover_throttle) < 0.001 \
			and absf(c.pitch_diff) < 0.001 and absf(c.roll_diff) < 0.001 \
			and absf(c.yaw_torque) < 0.001

	# Target ahead (−Z, the nose direction) → pitch nose-down (negative diff).
	mode = _fresh_mode()
	mode.target_position = Vector3(0, 0, -10)
	c = mode.compute(0, 0, 0, 0, basis, no_spin, 1.0 / 60.0)
	var pitch_ok: bool = c.pitch_diff < -0.001

	# Target to the right (+X) → roll right (positive diff).
	mode = _fresh_mode()
	mode.target_position = Vector3(10, 0, 0)
	c = mode.compute(0, 0, 0, 0, basis, no_spin, 1.0 / 60.0)
	var roll_ok: bool = c.roll_diff > 0.001

	# Target above → collective above hover; below → under hover.
	mode = _fresh_mode()
	mode.target_position = Vector3(0, 5, 0)
	c = mode.compute(0, 0, 0, 0, basis, no_spin, 1.0 / 60.0)
	var up_ok: bool = c.collective > mode.hover_throttle
	mode = _fresh_mode()
	mode.target_position = Vector3(0, -5, 0)
	c = mode.compute(0, 0, 0, 0, basis, no_spin, 1.0 / 60.0)
	var down_ok: bool = c.collective < mode.hover_throttle

	# Positive heading error (turn counterclockwise/left) → negative yaw_torque
	# (the controller applies torque about −Y per unit of positive yaw_torque).
	mode = _fresh_mode()
	mode.target_heading = 0.5
	c = mode.compute(0, 0, 0, 0, basis, no_spin, 1.0 / 60.0)
	var yaw_ok: bool = c.yaw_torque < -0.001

	print("[TEST] level=", level_ok, " pitch=", pitch_ok, " roll=", roll_ok,
			" up=", up_ok, " down=", down_ok, " yaw=", yaw_ok)
	var passed := level_ok and pitch_ok and roll_ok and up_ok and down_ok and yaw_ok
	print("[TEST] ", "PASS" if passed else "FAIL", " — control-law signs per error axis")
	return passed


func _fresh_mode() -> FlightModeFormation:
	var mode := FlightModeFormation.new()
	mode.hover_throttle = 0.28
	mode.max_thrust = 17.5
	# Everything at the origin: zero error unless a test moves the target.
	mode.target_position = Vector3.ZERO
	mode.current_position = Vector3.ZERO
	mode.current_velocity = Vector3.ZERO
	return mode


# ---------------------------------------------------------------------------
# Pilot radio-side freeze: at zero signal quality every update attempt becomes
# a dropout (rate 3/s × delta 1.0 ⇒ probability ≥ 1), so the slot target stays
# stale; at full quality it tracks the manager every call.
# ---------------------------------------------------------------------------
func test_pilot_dropout_freezes_target() -> bool:
	print("[TEST] --- test_pilot_dropout_freezes_target ---")
	var stub := StubManager.new()
	add_child(stub)
	var pilot := FollowerPilot.new()
	pilot.manager = stub

	# Full quality: target follows the stub's moving slot.
	pilot._update_target_from_slot(1.0, 1.0)
	var first := pilot._target_position
	pilot._update_target_from_slot(1.0, 1.0)
	var tracks: bool = pilot._target_position != first

	# Zero quality: dropout every attempt — the target freezes.
	var frozen := pilot._target_position
	for i in range(5):
		pilot._update_target_from_slot(0.0, 1.0)
	var freezes: bool = pilot._target_position == frozen

	pilot.free()
	stub.queue_free()
	print("[TEST] tracks=", tracks, " freezes=", freezes)
	var passed := tracks and freezes
	print("[TEST] ", "PASS" if passed else "FAIL", " — target tracks at q=1, freezes at q=0")
	return passed


# ---------------------------------------------------------------------------
# The one flight test: a single follower spawned in its slot HOLDS it while
# hovering (3 s), then re-converges after being shoved 6 m off (4 s). Pins the
# whole pipeline: manager spawn → pilot tick → formation mode → mixer → rotors.
# ---------------------------------------------------------------------------
func test_follower_holds_and_reconverges() -> bool:
	print("[TEST] --- test_follower_holds_and_reconverges ---")
	var m := SwarmManager.new()
	m.follower_count = 1
	add_child(m)
	await get_tree().physics_frame  # deferred spawn
	await get_tree().physics_frame
	if m.pilots.size() != 1:
		printerr("[TEST] no follower spawned")
		m.queue_free()
		return false
	var follower: DroneController = m.pilots[0].drone

	# Hold: 3 s of hover in the slot.
	for i in range(180):
		await get_tree().physics_frame
	var hold_err: float = (follower.global_position - m.get_slot_position(0)).length()
	var holds: bool = hold_err < 2.0

	# Shove 6 m sideways (teleport, keep velocities) and let it fly back.
	follower.global_position += Vector3(6, 0, 0)
	for i in range(240):
		await get_tree().physics_frame
	var back_err: float = (follower.global_position - m.get_slot_position(0)).length()
	var reconverges: bool = back_err < 2.0

	print("[TEST] hold_err=%.2f back_err=%.2f" % [hold_err, back_err])
	m.queue_free()
	var passed := holds and reconverges
	print("[TEST] ", "PASS" if passed else "FAIL",
			" — follower holds slot and re-converges after a 6 m shove")
	return passed
