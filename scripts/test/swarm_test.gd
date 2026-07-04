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


## Manager stand-in for the pilot dropout test: a moving leader.
class StubManager extends Node:
	var calls: int = 0
	func get_leader_state() -> Dictionary:
		calls += 1
		return {"position": Vector3(calls, 0, 0), "velocity": Vector3.ZERO, "heading": 0.0}
	func get_slot_offset(_i: int, _heading: float) -> Vector3:
		return Vector3.ZERO


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
	await _run_test("test_formation_integral_trims_drift")
	await _run_test("test_pilot_dropout_freezes_target")
	await _run_test("test_velocity_feed_forward")
	await _run_test("test_pad_menu_navigation")
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
	var inner := (m.get_slot_position(0) - base).length()   # shell 0
	var outer := (m.get_slot_position(2) - base).length()   # shell 1
	# Radii follow the (tunable) shell table — assert structure, not numbers.
	var r_inner: float = m.ring_radius * SwarmManager.BOHR_SHELL_RADII[0]
	var r_outer: float = m.ring_radius * SwarmManager.BOHR_SHELL_RADII[1]
	var bohr_ok: bool = not b_t0.is_equal_approx(b_t1) \
			and absf(inner - r_inner) < 0.01 \
			and absf(outer - r_outer) < 0.01 \
			and r_inner < r_outer

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


# ---------------------------------------------------------------------------
# Position integral: a small persistent error (a stand-in for wind drift the
# controller can't see) winds up a growing tilt command over time, and the
# anti-windup clamp caps it. Big errors (outside integrate_radius) don't wind.
# ---------------------------------------------------------------------------
func test_formation_integral_trims_drift() -> bool:
	print("[TEST] --- test_formation_integral_trims_drift ---")
	var basis := Basis.IDENTITY
	var no_spin := Vector3.ZERO
	var dt := 1.0 / 60.0

	# Persistent 0.2 m error ahead (small enough that the P term alone stays
	# well under the max_offset clamp): the commanded pitch must GROW as the
	# integral accumulates (P alone would hold it constant).
	var mode := _fresh_mode()
	mode.target_position = Vector3(0, 0, -0.2)
	var first := mode.compute(0, 0, 0, 0, basis, no_spin, dt)
	var early := absf(first.pitch_diff)
	for i in range(300):  # 5 s
		mode.compute(0, 0, 0, 0, basis, no_spin, dt)
	var late := absf(mode.compute(0, 0, 0, 0, basis, no_spin, dt).pitch_diff)
	var grows: bool = late > early * 1.2

	# Clamped: integral velocity contribution never exceeds max_i_speed.
	var i_speed: float = (mode._err_integral * mode.pos_i_gain).length()
	var clamped: bool = i_speed <= mode.max_i_speed + 0.001

	# Outside integrate_radius nothing winds up.
	mode = _fresh_mode()
	mode.target_position = Vector3(0, 0, -10)
	for i in range(120):
		mode.compute(0, 0, 0, 0, basis, no_spin, dt)
	var far_clean: bool = mode._err_integral.is_zero_approx()

	print("[TEST] early=%.4f late=%.4f i_speed=%.2f far_clean=%s"
			% [early, late, i_speed, far_clean])
	var passed := grows and clamped and far_clean
	print("[TEST] ", "PASS" if passed else "FAIL",
			" — integral winds near the slot, clamps, ignores far errors")
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
# Pilot radio-side freeze: at zero signal quality every receive attempt becomes
# a dropout (rate 3/s × delta 1.0 ⇒ probability ≥ 1), so the leader state
# stays stale; at full quality it tracks the moving leader every call.
# ---------------------------------------------------------------------------
func test_pilot_dropout_freezes_target() -> bool:
	print("[TEST] --- test_pilot_dropout_freezes_target ---")
	var stub := StubManager.new()
	add_child(stub)
	var pilot := FollowerPilot.new()
	pilot.manager = stub

	# Full quality: the leader state tracks the stub's moving leader.
	pilot._receive_leader_state(1.0, 1.0)
	var first := pilot._leader_pos
	pilot._receive_leader_state(1.0, 1.0)
	var tracks: bool = pilot._leader_pos != first

	# Zero quality: dropout every attempt — the leader state freezes.
	var frozen := pilot._leader_pos
	for i in range(5):
		pilot._receive_leader_state(0.0, 1.0)
	var freezes: bool = pilot._leader_pos == frozen

	pilot.free()
	stub.queue_free()
	print("[TEST] tracks=", tracks, " freezes=", freezes)
	var passed := tracks and freezes
	print("[TEST] ", "PASS" if passed else "FAIL", " — leader state tracks at q=1, freezes at q=0")
	return passed


# ---------------------------------------------------------------------------
# Velocity feed-forward: with ZERO position error but a forward-moving slot,
# the mode must already command nose-down (P alone would command nothing).
# ---------------------------------------------------------------------------
func test_velocity_feed_forward() -> bool:
	print("[TEST] --- test_velocity_feed_forward ---")
	var mode := _fresh_mode()
	mode.target_velocity = Vector3(0, 0, -5)  # slot moving nose-ward at 5 m/s
	var c := mode.compute(0, 0, 0, 0, Basis.IDENTITY, Vector3.ZERO, 1.0 / 60.0)
	var pitches: bool = c.pitch_diff < -0.001

	print("[TEST] pitch_diff=%.3f" % c.pitch_diff)
	print("[TEST] ", "PASS" if pitches else "FAIL",
			" — moving slot at zero error still commands tilt")
	return pitches


# ---------------------------------------------------------------------------
# PadMenu state machine: navigation wraps, left/right stages a value without
# applying, Cross applies + closes, Circle aborts (discards). Pure state — no
# input events needed.
# ---------------------------------------------------------------------------
func test_pad_menu_navigation() -> bool:
	print("[TEST] --- test_pad_menu_navigation ---")
	var menu := PadMenu.new()
	add_child(menu)

	var applied := [-1, -1]  # last value each setter received
	var value := [0, 0]      # backing "live" values
	menu.entries = [
		{"label": "A", "options": func() -> Array: return ["a0", "a1", "a2"],
			"getter": func() -> int: return value[0],
			"setter": func(v: int) -> void:
				applied[0] = v
				value[0] = v},
		{"label": "B", "options": func() -> Array: return ["b0", "b1"],
			"getter": func() -> int: return value[1],
			"setter": func(v: int) -> void:
				applied[1] = v
				value[1] = v},
	]

	# Navigation wraps both ways.
	menu._open()
	var nav_ok: bool = menu.selected == 0
	menu._navigate(1)
	nav_ok = nav_ok and menu.selected == 1
	menu._navigate(1)
	nav_ok = nav_ok and menu.selected == 0
	menu._navigate(-1)
	nav_ok = nav_ok and menu.selected == 1

	# Cycling stages but does NOT apply until Cross.
	menu._cycle(1)  # B: b0 -> b1 (staged)
	var staged_only: bool = menu.staged[1] == 1 and applied[1] == -1
	menu._apply_and_close()
	var applies: bool = applied[1] == 1 and value[1] == 1 and not menu.is_open

	# Abort discards staged changes. (Reset the sentinel — the apply above
	# legitimately wrote ALL entries, including A's unchanged value.)
	applied[0] = -1
	menu._open()
	menu._cycle(1)  # A: a0 -> a1 staged
	menu._abort()
	var aborts: bool = applied[0] == -1 and value[0] == 0 and not menu.is_open

	print("[TEST] nav=", nav_ok, " staged_only=", staged_only,
			" applies=", applies, " aborts=", aborts)
	menu.queue_free()
	var passed := nav_ok and staged_only and applies and aborts
	print("[TEST] ", "PASS" if passed else "FAIL",
			" — wrap nav, stage on cycle, apply on Cross, discard on Circle")
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
