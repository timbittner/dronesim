class_name FollowerPilot
extends Node

## One autopilot per swarm follower (P6). Owns the follower's behavior state
## and drives its FlightModeFormation every physics tick. Individual pilots
## (not a monolithic manager loop) so behaviors can be primed per drone.
##
## Radio vs. onboard split: the LEADER STATE packet (position, velocity,
## heading) is RADIO data — packet loss freezes it stale, mirroring how player
## packet loss freezes stick inputs. Everything else is follower-side: the
## slot offset is formation math on the pilot's own clock (a jammed follower
## keeps orbiting the last-known leader position — the orbit doesn't jam), and
## current position/velocity are ONBOARD sensors, always fresh. The frozen
## leader velocity feeds forward into the mode, so followers match leader
## speed without needing position error as fuel. Sustained-zero signal still
## kills the drone through the controller's own lose_signal() path, unchanged.

enum Behavior { FORMATION, DISPATCHED, LANDING, LANDED, TAKEOFF, DOWN }

## Mean target-update dropouts per second at zero signal quality — same
## semantics (and default) as DroneController.packet_loss_rate.
@export var packet_loss_rate: float = 3.0

var drone: DroneController = null
## The swarm manager that owns this pilot's slot (set at spawn).
var manager: Node = null
## This pilot's slot index in the manager's formation table.
var slot_index: int = 0

var behavior: Behavior = Behavior.FORMATION

var _mode: FlightModeFormation = null
var _dropout_timer: float = 0.0
## Last-received leader state packet — stale during dropouts.
var _leader_pos: Vector3 = Vector3.ZERO
var _leader_vel: Vector3 = Vector3.ZERO
var _leader_heading: float = 0.0
var _has_leader_state: bool = false
## Previous tick's slot offset, for the local orbital-velocity derivative.
var _prev_offset: Vector3 = Vector3.ZERO
var _offset_primed: bool = false

## Dispatch order (P6 step 4) — stored ONBOARD once received, so a jam after
## the order doesn't revoke it (fire-and-forget); the controller's own
## lose_signal() still applies en route.
var _dispatch_point: Vector3 = Vector3.ZERO
var _dispatch_target: MissionTarget = null
var _dispatch_dwell: float = 0.0

## Hover height above the dispatch point for OBSERVE / bare-point orders, m.
var observe_altitude: float = 5.0
## Seconds to loiter over a bare point (no target) before rejoining.
var loiter_time: float = 5.0
## Pilot tuning — plain vars, not exports: pilots are built in code, so the
## inspector knobs live on SwarmManager ("Pilot Tuning"), pushed like gains.
## Dispatched runs descend onto the goal this close (horizontal m) — before
## that they cruise at their dispatch-time AGL, terrain-following.
var dive_radius: float = 12.0
## Auto-land (P6 step 4): flown descent at this rate, m/s — well under the
## 4 m/s crash threshold — then a motor cut on touchdown. Rotor-only, no magic.
var descent_rate: float = 1.5
## Player take-off: hand the sticks back this many m above the ground — a
## ground-level handoff dumped player and followers into each other.
var release_altitude: float = 5.0

## Auto-land target: frozen horizontal position, ramping y.
var _land_pos: Vector3 = Vector3.ZERO
## Dispatch cruise height above ground — captured at dispatch time (AGL).
var _cruise_agl: float = 0.0
## Kamikaze terminal phase latched (survives skimming back out of the radius).
var _plunging: bool = false
## Seconds since the strike began — bounds the run so a botched flip can't fly
## off powered forever.
var _strike_time: float = 0.0
## Cut the link if the strike hasn't crashed within this long (safety net for
## a dive that skims past instead of impacting).
const STRIKE_TIMEOUT: float = 3.0


## Wire the pilot to its drone: installs a FlightModeFormation and listens for
## crashes. Called by the swarm manager after spawning both.
func setup(follower: DroneController, swarm_manager: Node, index: int) -> void:
	drone = follower
	manager = swarm_manager
	slot_index = index
	_mode = FlightModeFormation.new()
	_mode.hover_throttle = drone.hover_throttle
	_mode.max_thrust = drone.max_thrust
	drone.set_flight_mode_object("formation", _mode)
	drone.crash_detected.connect(_on_drone_crashed)
	_mode.target_position = drone.global_position


## Live gain push from the SwarmManager's Formation Gains exports (each tick,
## so remote-inspector tuning takes effect immediately).
func apply_gains(pos_p: float, pos_i: float, vel_p: float, speed: float, tilt: float) -> void:
	if _mode == null:
		return
	_mode.pos_p_gain = pos_p
	_mode.pos_i_gain = pos_i
	_mode.vel_p_gain = vel_p
	_mode.max_speed = speed
	_mode.max_tilt = tilt


## Fire-and-forget dispatch order: fly to `point`; `target` (may be null) is
## the MissionTarget picked under the reticle. CRASH targets are hit kamikaze
## (impact clears them, drone stays DOWN); OBSERVE / bare points are loitered
## over until cleared (or loiter_time), then the pilot rejoins the formation.
func dispatch(point: Vector3, target: MissionTarget) -> void:
	_dispatch_point = point
	_dispatch_target = target
	_dispatch_dwell = 0.0
	_plunging = false
	_strike_time = 0.0
	# Cruise at the dispatch-time AGL, floored at observe_altitude — a runner
	# dispatched from a low hover would otherwise cruise along the dirt.
	_cruise_agl = maxf(drone.global_position.y - _ground_below(), observe_altitude)
	set_behavior(Behavior.DISPATCHED)


## Where a dispatched pilot aims: two-phase for every order — cruise at the
## dispatch-time AGL (terrain-following via the onboard ground reference)
## until dive_radius from the goal, then descend onto it (straight at a live
## CRASH target; hover height above everything else). A low direct line
## clipped trees/buildings en route.
func _dispatch_aim() -> Vector3:
	var kamikaze := is_instance_valid(_dispatch_target) \
			and _dispatch_target.type == MissionTarget.Type.CRASH \
			and not _dispatch_target.cleared
	var goal: Vector3 = _dispatch_target.global_position if kamikaze \
			else _dispatch_point + Vector3.UP * observe_altitude
	var to := goal - drone.global_position
	var horiz := Vector2(to.x, to.z).length()
	if kamikaze:
		# Hold station directly ABOVE the target at cruise altitude until settled
		# (the position controller kills horizontal speed as it arrives), then
		# _fly_dispatch hands off to the free-fall strike. Latched once armed.
		return Vector3(goal.x, _ground_below() + _cruise_agl, goal.z)
	if horiz > dive_radius:
		return Vector3(goal.x, maxf(_ground_below() + _cruise_agl, goal.y), goal.z)
	return goal


## Terrain height under the drone (0 without a manager/terrain — flat-world
## fallback, same as auto-land's).
func _ground_below() -> float:
	if manager == null or not manager.has_method("ground_height"):
		return 0.0
	return manager.ground_height(drone.global_position.x, drone.global_position.z)


## Auto-land in place: freeze the horizontal position AND heading (the mode's
## default target_heading of 0 yawed everyone to north), fly the target down.
func land() -> void:
	if behavior == Behavior.DOWN:
		return
	_land_pos = drone.global_position
	_mode.target_heading = _current_heading()
	set_behavior(Behavior.LANDING)


## Ground-start park (spawn time, not a flown landing): motors cut, latched
## LANDED immediately — takeoff() flies it to the slot from here same as an
## auto-land touchdown.
func park() -> void:
	_mode.landed = true
	_mode.strike = false
	_plunging = false
	_strike_time = 0.0
	set_behavior(Behavior.LANDED)


## Resume formation flight from LANDING / LANDED (motors back on; the
## formation mode flies to the slot from a ground start on its own).
func takeoff() -> void:
	if behavior != Behavior.LANDING and behavior != Behavior.LANDED:
		return
	_mode.landed = false
	set_behavior(Behavior.FORMATION)


## Player auto-land variant of setup(): installs the same formation mode;
## release() hands the sticks back in stabilized mode. Triangle reset releases
## too (drone_reset), so a reset never leaves the player stuck in the autopilot.
func setup_landing(player: DroneController, swarm_manager: Node) -> void:
	drone = player
	manager = swarm_manager
	_mode = FlightModeFormation.new()
	_mode.hover_throttle = player.hover_throttle
	_mode.max_thrust = player.max_thrust
	player.set_flight_mode_object("autoland", _mode)
	player.under_autopilot = true  # suppress the player's sticks + assists
	player.crash_detected.connect(_on_drone_crashed)
	player.drone_reset.connect(release)
	land()


## Player take-off: climb straight up to release_altitude AGL first, THEN
## release — handing the sticks over on the ground put the player inside the
## converging follower swarm.
func begin_takeoff() -> void:
	_mode.landed = false
	_land_pos = drone.global_position
	var ground_h: float = manager.ground_height(_land_pos.x, _land_pos.z) \
			if manager != null and manager.has_method("ground_height") else 0.0
	_mode.target_position = Vector3(_land_pos.x, ground_h + release_altitude, _land_pos.z)
	_mode.target_velocity = Vector3.ZERO
	_mode.target_heading = _current_heading()
	set_behavior(Behavior.TAKEOFF)


## Hand the player their sticks back — always in stabilized (the safe hover
## law for a mid-air handoff) — and retire.
func release() -> void:
	if drone != null:
		drone.under_autopilot = false  # sticks + assists live again
		drone.select_flight_mode("stabilized")
	queue_free()


func _current_heading() -> float:
	return atan2(drone.global_basis.z.x, drone.global_basis.z.z)


func set_behavior(b: Behavior) -> void:
	if b == behavior:
		return
	behavior = b
	if b == Behavior.FORMATION:
		_offset_primed = false  # stale _prev_offset would spike the derivative
	if b != Behavior.DISPATCHED and _mode != null:
		_mode.strike = false  # leaving a run disarms the strike law


func _physics_process(delta: float) -> void:
	if drone == null or _mode == null:
		return
	if behavior == Behavior.DOWN:
		return  # wreck stays down; CALL BACKUP spawns a replacement at the pad

	# Onboard sensors: always fresh, packet loss does not touch these.
	_mode.current_position = drone.global_position
	_mode.current_velocity = drone.linear_velocity

	if behavior == Behavior.DISPATCHED:
		_fly_dispatch(delta)
		return
	if behavior == Behavior.LANDING:
		_fly_landing(delta)
		return
	if behavior == Behavior.LANDED:
		return  # parked, motors cut (_mode.landed) until takeoff()
	if behavior == Behavior.TAKEOFF:
		# Climbing to the release altitude — hand over once it's reached.
		if drone.global_position.y >= _mode.target_position.y - 0.5:
			release()
		return

	# Only FORMATION remains (DOWN returned at the top; the rest handled above).
	_receive_leader_state(drone.signal_quality, delta)
	if not _has_leader_state:
		return

	# Follower-side formation math on the pilot's own clock — runs against the
	# (possibly stale) radio state, so orbits keep turning during a jam.
	var offset: Vector3 = manager.get_slot_offset(slot_index, _leader_heading)
	_mode.target_position = _leader_pos + offset
	_mode.target_heading = _leader_heading
	# Feed-forward: frozen leader velocity + local orbital motion (derivative
	# of the offset — nonzero for BOHR, zero for static formations).
	if not _offset_primed:
		_offset_primed = true
		_prev_offset = offset  # no derivative spike on the very first tick
	_mode.target_velocity = _leader_vel + (offset - _prev_offset) / delta
	_prev_offset = offset


## DISPATCHED tick: no leader state needed — the order is onboard. Rejoin the
## formation when the target clears, or after loiter_time over a bare point.
## A CRASH-target run ends in _on_drone_crashed → DOWN, never here.
func _fly_dispatch(delta: float) -> void:
	var aim := _dispatch_aim()
	_mode.target_position = aim
	_mode.target_velocity = Vector3.ZERO

	if _plunging:
		# Terminal strike: idle throttle, free-fall onto the target. The impact
		# crashes it on physics alone. Safety net — if it somehow drifts off the
		# mark and doesn't hit in time, cut the link (same lose_signal() the
		# radar shoot-down uses, rotor-only) so it never parks alive nearby.
		_mode.strike = true
		_strike_time += delta
		if _strike_time > STRIKE_TIMEOUT and not drone.is_crashed():
			_log("[%s] kamikaze — link cut" % drone.name)
			drone.lose_signal()
		return

	# Arm the drop once settled directly over the target: horizontally on the
	# mark and horizontal speed bled off (else it drifts during the fall).
	if is_instance_valid(_dispatch_target) and _dispatch_target.type == MissionTarget.Type.CRASH:
		var over := _dispatch_target.global_position - drone.global_position
		var h_speed := Vector2(drone.linear_velocity.x, drone.linear_velocity.z).length()
		if Vector2(over.x, over.z).length() < 2.0 and h_speed < 3.0:
			_plunging = true
			return

	var to := _dispatch_point - drone.global_position
	if Vector2(to.x, to.z).length() > 1.0:
		_mode.target_heading = atan2(-to.x, -to.z)  # nose (−Z) toward the point
	if is_instance_valid(_dispatch_target):
		if _dispatch_target.cleared:
			set_behavior(Behavior.FORMATION)
		return
	if drone.global_position.distance_to(aim) < 2.0:
		_dispatch_dwell += delta
		if _dispatch_dwell >= loiter_time:
			set_behavior(Behavior.FORMATION)


## LANDING tick: ramp the target down toward the ground at descent_rate (the
## vertical feed-forward keeps the altitude D term from fighting the descent),
## cut the motors once settled just above it. All onboard — no radio needed.
func _fly_landing(_delta: float) -> void:
	var ground_h: float = manager.ground_height(_land_pos.x, _land_pos.z) \
			if manager != null and manager.has_method("ground_height") else 0.0
	_land_pos.y = move_toward(_land_pos.y, ground_h, descent_rate * _delta)
	_mode.target_position = _land_pos
	_mode.target_velocity = Vector3(0.0, -descent_rate, 0.0) \
			if _land_pos.y > ground_h else Vector3.ZERO
	var agl: float = drone.global_position.y - ground_h
	if agl < 0.4 and absf(drone.linear_velocity.y) < 0.3:
		_mode.landed = true
		set_behavior(Behavior.LANDED)


## Radio side: receive this tick's leader state packet unless a dropout
## freezes the previous one. Split out (and quality passed in) so the freeze
## behavior is unit-testable without a SignalField in the scene.
func _receive_leader_state(quality: float, delta: float) -> void:
	if _dropout_timer > 0.0:
		_dropout_timer -= delta
		return  # stale leader state — the jammer is winning
	if randf() < (1.0 - quality) * packet_loss_rate * delta:
		_dropout_timer = randf_range(0.1, 0.4)
		return
	if manager == null:
		return
	var state: Dictionary = manager.get_leader_state()
	if state.is_empty():
		return
	_leader_pos = state.position
	_leader_vel = state.velocity
	_leader_heading = state.heading
	_has_leader_state = true


func _on_drone_crashed() -> void:
	set_behavior(Behavior.DOWN)
	_log("[Swarm] %s down" % drone.name)


## Route through the manager's console + on-screen log; bare print without one.
func _log(msg: String) -> void:
	if manager != null and manager.has_method("_log"):
		manager._log(msg)
	else:
		print(msg)
