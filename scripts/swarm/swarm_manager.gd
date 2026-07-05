class_name SwarmManager
extends Node3D

## Spawns and owns the swarm followers (P6). Same environment-node convention
## as WindField: group "swarm_manager", lazily resolved by consumers, absent
## node = no swarm. Thin by design — per-drone behavior lives in each
## FollowerPilot; this node only owns the roster and the formation slot table.
##
## Followers spawn airborne, already in their slots above the leader's pad.
## ponytail: no grounded takeoff sequencing yet — follow-up once the formation
## mode is trusted. No inter-follower collision avoidance either; the slot
## tables keep spacing, physics sorts out the rest.

## Number of follower drones to spawn.
@export var follower_count: int = 5
## Nearest-neighbor spacing in the slot tables, meters.
@export var spacing: float = 1.5
## RING / BOHR orbit radius, meters.
@export var ring_radius: float = 4.0
## Followers fly this many meters above the leader (keeps them out of the
## player's face and off the ground when the leader sits on the pad).
@export var altitude_offset: float = 0.0
## BOHR orbital angular speed, rad/s.
@export var bohr_speed: float = 1.2
## Seconds between backup spawns (menu: CALL BACKUP).
@export var backup_cooldown: float = 15.0
## Terrain node with get_height(x, z) — auto-land ground reference (same
## duck-typed contract as WindField's). Missing node = ground at y 0.
@export var terrain_path: NodePath = NodePath("../Terrain")

enum Formation { LINE, V, RING, BOHR }

@export var formation: Formation = Formation.LINE

## Pushed into every pilot's FlightModeFormation each physics tick, so they
## are live-tunable in the remote inspector while flying.
@export_group("Formation Gains")
## m of position error → m/s of desired velocity (snappiness of small moves).
@export var pos_p_gain: float = 2.0
## Integral trim — bleeds out persistent drift (wind) near the slot.
@export var pos_i_gain: float = 0.4
## m/s of velocity error → m/s² of desired acceleration.
@export var vel_p_gain: float = 3.0
## Max commanded speed toward the slot, m/s.
@export var max_speed: float = 40.0
## Max thrust-direction tilt, rad — sets the terminal speed against drag
## (v = g·tan(max_tilt)·mass/drag_c ≈ 30 m/s at 1.0), not just agility.
@export var max_tilt: float = 1.0

## Pushed into every pilot each physics tick, like the gains — pilots are
## built in code, so these are their only inspector knobs.
@export_group("Pilot Tuning")
## Dispatched runs cruise at dispatch-time AGL until this close (horizontal
## m) to the goal, then descend/dive onto it.
@export var dive_radius: float = 12.0
## Hover height above OBSERVE dispatch points / bare ground points, m.
@export var observe_altitude: float = 5.0
## Seconds a dispatched drone loiters over a bare point before rejoining.
@export var loiter_time: float = 5.0
## Auto-land descent rate, m/s (keep well under the 4 m/s crash threshold).
@export var descent_rate: float = 1.5
## Player take-off: hand the sticks back this many m above the ground.
@export var release_altitude: float = 5.0

const DRONE_SCENE: PackedScene = preload("res://scenes/drone/drone.tscn")

var pilots: Array[FollowerPilot] = []

var _leader: DroneController = null
var _leader_searched: bool = false
var _time: float = 0.0
var _hud: Node = null
var _hud_searched: bool = false


## Console print + on-screen event log (group "debug_hud", lazily resolved —
## absent HUD = console only, same convention as every other lookup here).
func _log(msg: String) -> void:
	print(msg)
	if not _hud_searched:
		_hud_searched = true
		var h := get_tree().get_first_node_in_group("debug_hud")
		if h != null and h.has_method("log_line"):
			_hud = h
	if _hud != null:
		_hud.log_line(msg)


func _ready() -> void:
	add_to_group("swarm_manager")
	# Spawn deferred: the leader joins "player_drone" in its own _ready and
	# tree order isn't guaranteed for future scenes.
	call_deferred("_spawn_followers")


func _physics_process(delta: float) -> void:
	_time += delta
	for pilot in pilots:
		pilot.apply_gains(pos_p_gain, pos_i_gain, vel_p_gain, max_speed, max_tilt)
		pilot.dive_radius = dive_radius
		pilot.observe_altitude = observe_altitude
		pilot.loiter_time = loiter_time
		pilot.descent_rate = descent_rate


func _spawn_followers() -> void:
	_log("[Swarm] All Systems Ready")
	var leader := _get_leader()
	for i in range(follower_count):
		var slot := get_slot_position(i) if leader != null \
				else global_position + Vector3(i * spacing, altitude_offset, 0)
		_spawn_one(i, slot)
	_log("[Swarm] spawned %d followers (%s formation)"
			% [follower_count, Formation.keys()[formation]])


func _spawn_one(i: int, spawn_pos: Vector3) -> FollowerPilot:
	var drone := DRONE_SCENE.instantiate() as DroneController
	drone.is_player = false
	drone.name = "Follower%d" % (i + 1)
	# Position BEFORE add_child: the controller captures _spawn_transform
	# (its reset target) in _ready, which fires on entering the tree.
	drone.position = to_local(spawn_pos)
	add_child(drone)
	var pilot := FollowerPilot.new()
	pilot.name = "Pilot%d" % (i + 1)
	add_child(pilot)
	pilot.setup(drone, self, i)
	pilots.append(pilot)
	return pilot


## Dispatch the FORMATION follower nearest to `point` at it (P6 step 4).
## Returns the chosen pilot, or null if the whole swarm is busy/down.
func dispatch(point: Vector3, target: MissionTarget) -> FollowerPilot:
	var best: FollowerPilot = null
	var best_d := INF
	for pilot in pilots:
		if pilot.behavior != FollowerPilot.Behavior.FORMATION:
			continue
		var d: float = pilot.drone.global_position.distance_to(point)
		if d < best_d:
			best_d = d
			best = pilot
	if best == null:
		_log("[Swarm] dispatch refused — no follower in formation")
		return null
	best.dispatch(point, target)
	_log("[Swarm] %s dispatched (%s)" % [best.drone.name,
			"target" if target != null else "point"])
	return best


var _backup_ready_at: float = 0.0
var _terrain: Node = null
var _terrain_searched: bool = false
## Transient player auto-land pilot — exists only between AUTO-LAND and
## TAKE OFF / Triangle reset (it frees itself on release).
var _player_pilot: FollowerPilot = null


## Spawn a replacement follower on the pad (this node's position, ground
## start) — the formation mode flies it to its slot on its own. Cooldown-gated.
func call_backup() -> bool:
	if backup_cooldown_left() > 0.0:
		_log("[Swarm] backup on cooldown — %.0fs left" % backup_cooldown_left())
		return false
	_backup_ready_at = _time + backup_cooldown
	var i := pilots.size()
	# 5 m above the pad — spawning ON it wedged drones against the platform.
	_spawn_one(i, global_position + Vector3.UP * 5.0)
	follower_count = maxi(follower_count, i + 1)  # keep RING/BOHR slot math consistent
	_log("[Swarm] backup follower launched from pad (%d in swarm)" % pilots.size())
	return true


## Seconds until CALL BACKUP is available again (0 = ready) — menu countdown.
func backup_cooldown_left() -> float:
	return maxf(0.0, _backup_ready_at - _time)


## Terrain height under (x, z) for auto-land; y 0 without a terrain node.
func ground_height(x: float, z: float) -> float:
	if not _terrain_searched:
		_terrain_searched = true
		var t := get_node_or_null(terrain_path)
		if t != null and t.has_method("get_height"):
			_terrain = t
	if _terrain == null:
		return 0.0
	return _terrain.get_height(x, z)


## True while any part of the swarm (player included) is landing or parked —
## drives the menu's AUTO-LAND ↔ TAKE OFF toggle.
func swarm_landing() -> bool:
	if is_instance_valid(_player_pilot):
		return true
	for pilot in pilots:
		if pilot.behavior == FollowerPilot.Behavior.LANDING \
				or pilot.behavior == FollowerPilot.Behavior.LANDED:
			return true
	return false


## AUTO-LAND: everything lands in place — formation followers AND the player
## (a transient pilot takes the sticks; Triangle reset gives them back).
## ponytail: dispatched runners finish their mission first and then rejoin
## (they hover at their slot over the landed leader) — land-on-rejoin if that
## ever grates.
func land_all() -> void:
	for pilot in pilots:
		if pilot.behavior == FollowerPilot.Behavior.FORMATION:
			pilot.land()
	var leader := _get_leader()
	if leader != null and not leader.is_crashed() and not is_instance_valid(_player_pilot):
		_player_pilot = FollowerPilot.new()
		_player_pilot.name = "PlayerAutoLand"
		_player_pilot.descent_rate = descent_rate
		_player_pilot.release_altitude = release_altitude
		add_child(_player_pilot)
		_player_pilot.setup_landing(leader, self)
	_log("[Swarm] AUTO-LAND — swarm landing in place")


## TAKE OFF: landed followers fly back to their slots; the player is flown up
## to release_altitude first, then handed the sticks in stabilized (the pilot
## frees itself at the handoff — no reference to clear).
func take_off_all() -> void:
	for pilot in pilots:
		pilot.takeoff()
	if is_instance_valid(_player_pilot) \
			and _player_pilot.behavior != FollowerPilot.Behavior.TAKEOFF:
		_player_pilot.begin_takeoff()
	_log("[Swarm] TAKE OFF — resuming formation")


func _get_leader() -> DroneController:
	if not _leader_searched:
		_leader_searched = true
		_leader = get_tree().get_first_node_in_group("player_drone") as DroneController
	return _leader


## Leader Y-rotation angle θ (nose = −Z at 0) — same convention as
## FlightModeFormation.compute()'s heading.
func _leader_heading() -> float:
	var leader := _get_leader()
	if leader == null:
		return 0.0
	return atan2(leader.global_basis.z.x, leader.global_basis.z.z)


## The leader's broadcast state packet — the ONLY radio-side data in the
## swarm link (position, velocity, heading, like real swarm telemetry).
## Followers freeze this on packet loss; formation math stays follower-side.
## Empty dictionary = no leader in the scene.
func get_leader_state() -> Dictionary:
	var leader := _get_leader()
	if leader == null:
		return {}
	return {
		"position": leader.global_position,
		"velocity": leader.linear_velocity,
		"heading": _leader_heading(),
	}


## Follower-side formation math: the slot offset for role `i` given a leader
## heading (passed in, not read live, so a pilot can compute against its
## frozen radio state during a dropout). Includes the altitude offset.
func get_slot_offset(i: int, heading: float) -> Vector3:
	return Vector3(0.0, altitude_offset, 0.0) + _slot_offset(i, heading)


## Convenience composition (live leader state) — spawn placement and tests.
func get_slot_position(i: int) -> Vector3:
	var leader := _get_leader()
	var origin := global_position if leader == null else leader.global_position
	return origin + get_slot_offset(i, _leader_heading())


## Horizontal slot offset for follower `i`, world frame. LINE and V are
## anchored to the given leader heading; RING and BOHR are heading-independent.
func _slot_offset(i: int, heading: float) -> Vector3:
	var hbasis := Basis(Vector3.UP, heading)
	match formation:
		Formation.LINE:
			# Line abreast, alternating right/left of the leader:
			# i=0 → +1, i=1 → −1, i=2 → +2, i=3 → −2, ...
			@warning_ignore("integer_division")
			var rank := (i / 2) + 1
			var side := 1.0 if i % 2 == 0 else -1.0
			return hbasis * Vector3(side * rank * spacing, 0.0, 0.0)
		Formation.V:
			# Two trailing wings at 45° behind the leader (tail = +Z locally).
			@warning_ignore("integer_division")
			var rank_v := (i / 2) + 1
			var side_v := 1.0 if i % 2 == 0 else -1.0
			return hbasis * Vector3(
					side_v * rank_v * spacing * 0.7071, 0.0, rank_v * spacing * 0.7071)
		Formation.RING:
			var a := TAU * i / maxf(follower_count, 1)
			return Vector3(cos(a), 0.0, sin(a)) * ring_radius
		Formation.BOHR:
			return _bohr_offset(i)
	return Vector3.ZERO


## Electron-cloud slot: shells of 2 / 8 / 8 / rest (Bohr occupancy), the
## innermost hugging the leader, each shell on its own tilted orbital plane,
## inner shells orbiting faster (electrons do too).
const BOHR_SHELL_SIZES: Array[int] = [2, 8, 8]
const BOHR_SHELL_RADII: Array[float] = [0.8, 1.5, 2.0, 3]  # × ring_radius
#const BOHR_SHELL_INCL: Array[float] = [0.0, -0.35, 0.3, -0.25]  # plane tilt, rad
const BOHR_SHELL_INCL: Array[float] = [0.0, -1, 2, 1]  # plane tilt, rad


func _bohr_offset(i: int) -> Vector3:
	var shell := 0
	var idx := i
	while shell < BOHR_SHELL_SIZES.size() and idx >= BOHR_SHELL_SIZES[shell]:
		idx -= BOHR_SHELL_SIZES[shell]
		shell += 1
	var members: int = BOHR_SHELL_SIZES[shell] if shell < BOHR_SHELL_SIZES.size() \
			else maxi(follower_count - 18, 1)
	members = mini(members, maxi(follower_count - _shell_start(shell), 1))
	var r: float = ring_radius * BOHR_SHELL_RADII[mini(shell, BOHR_SHELL_RADII.size() - 1)]
	var speed: float = bohr_speed * sqrt(ring_radius / r)
	var phase := TAU * idx / members + _time * speed
	var incl: float = BOHR_SHELL_INCL[mini(shell, BOHR_SHELL_INCL.size() - 1)]
	return Vector3(cos(phase), 0.0, sin(phase)).rotated(Vector3.RIGHT, incl) * r


## First follower index belonging to `shell` (0, 2, 10, 18, ...).
func _shell_start(shell: int) -> int:
	var start := 0
	for s in range(mini(shell, BOHR_SHELL_SIZES.size())):
		start += BOHR_SHELL_SIZES[s]
	return start
