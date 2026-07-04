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
@export var max_speed: float = 20.0

const DRONE_SCENE: PackedScene = preload("res://scenes/drone/drone.tscn")

var pilots: Array[FollowerPilot] = []

var _leader: DroneController = null
var _leader_searched: bool = false
var _time: float = 0.0


func _ready() -> void:
	add_to_group("swarm_manager")
	# Spawn deferred: the leader joins "player_drone" in its own _ready and
	# tree order isn't guaranteed for future scenes.
	call_deferred("_spawn_followers")


func _physics_process(delta: float) -> void:
	_time += delta
	for pilot in pilots:
		pilot.apply_gains(pos_p_gain, pos_i_gain, vel_p_gain, max_speed)


func _spawn_followers() -> void:
	var leader := _get_leader()
	for i in range(follower_count):
		var drone := DRONE_SCENE.instantiate() as DroneController
		drone.is_player = false
		drone.name = "Follower%d" % (i + 1)
		# Position BEFORE add_child: the controller captures _spawn_transform
		# (its reset target) in _ready, which fires on entering the tree.
		var slot := get_slot_position(i) if leader != null \
				else global_position + Vector3(i * spacing, altitude_offset, 0)
		drone.position = to_local(slot)
		add_child(drone)
		var pilot := FollowerPilot.new()
		pilot.name = "Pilot%d" % (i + 1)
		add_child(pilot)
		pilot.setup(drone, self, i)
		pilots.append(pilot)
	print("[Swarm] spawned %d followers (%s formation)"
			% [follower_count, Formation.keys()[formation]])


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


## World-space slot target for follower `i` in the current formation,
## relative to the leader's position and heading. Pure math on the leader
## pose — unit-testable without physics.
func get_slot_position(i: int) -> Vector3:
	var leader := _get_leader()
	var origin := global_position if leader == null else leader.global_position
	return origin + Vector3(0.0, altitude_offset, 0.0) + _slot_offset(i)


## All formation slots face the leader's heading.
func get_slot_heading(_i: int) -> float:
	return _leader_heading()


## Horizontal slot offset for follower `i`, world frame. LINE and V are
## anchored to the leader's heading; RING and BOHR are heading-independent.
func _slot_offset(i: int) -> Vector3:
	match formation:
		Formation.LINE:
			# Line abreast, alternating right/left of the leader:
			# i=0 → +1, i=1 → −1, i=2 → +2, i=3 → −2, ...
			@warning_ignore("integer_division")
			var rank := (i / 2) + 1
			var side := 1.0 if i % 2 == 0 else -1.0
			return _heading_basis() * Vector3(side * rank * spacing, 0.0, 0.0)
		Formation.V:
			# Two trailing wings at 45° behind the leader (tail = +Z locally).
			@warning_ignore("integer_division")
			var rank_v := (i / 2) + 1
			var side_v := 1.0 if i % 2 == 0 else -1.0
			return _heading_basis() * Vector3(
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


## Basis rotating a leader-local offset (right = +X, tail = +Z) into world.
func _heading_basis() -> Basis:
	return Basis(Vector3.UP, _leader_heading())


## Cycle to the next formation (menu entry, P6 step 4).
func cycle_formation() -> void:
	formation = ((formation + 1) % Formation.size()) as Formation
	print("[Swarm] formation: %s" % Formation.keys()[formation])
