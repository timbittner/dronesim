class_name AirspaceControl
extends Node

## Radar ceiling (P5 Phase 4, multi-drone since P6). Climbing above
## radar_altitude meters AGL paints a drone on air-defense radar and starts a
## per-drone countdown (the HUD shows a pulsing amber banner via group
## "airspace_control" for the player drone); descending below cancels it.
## Expiry is the shoot-down — currently a single drone.lose_signal() call,
## kept that way so the visible P7 interceptor can slot in behind the same
## trigger. Every drone in group "drone" is tracked independently, so swarm
## followers get shot down by the same rules as the player. AGL needs no
## raycast: Terrain exposes get_height(x, z) (same duck-typed contract
## WindField uses); no terrain node means ground level 0.

@export var terrain_path: NodePath = NodePath("../Terrain")
## Radar floor in meters above ground level.
@export var radar_altitude: float = 100.0
## Seconds painted on radar before the shoot-down.
@export var countdown_time: float = 10.0

## True while the PLAYER drone is above the ceiling and its countdown runs —
## the HUD banner contract (followers are tracked too, but silently).
var tracking: bool = false
## Player countdown remaining in seconds (only meaningful while tracking).
var seconds_left: float = 0.0
## Player height above ground level in meters — the exact value the radar
## compares against radar_altitude. Read by the HUD so the pilot sees the
## same number the radar does (world Y is height above the spawn pad, which
## diverges from AGL over the valley's ridges and dips).
var agl: float = 0.0

var _terrain: Node = null
## Per-drone countdown remaining, keyed by DroneController instance. A drone
## is "tracked" iff it has an entry.
var _tracks: Dictionary = {}


func _ready() -> void:
	add_to_group("airspace_control")
	_terrain = get_node_or_null(terrain_path)


func _physics_process(delta: float) -> void:
	for drone in get_tree().get_nodes_in_group("drone"):
		_update_drone(drone as DroneController, delta)


func _update_drone(drone: DroneController, delta: float) -> void:
	var pos := drone.global_position
	var ground := 0.0
	if _terrain != null and _terrain.has_method("get_height"):
		ground = _terrain.get_height(pos.x, pos.z)
	var drone_agl := pos.y - ground

	if drone.is_player:
		agl = drone_agl

	if drone.is_crashed():
		_untrack(drone)
		return

	if drone_agl > radar_altitude:
		if not _tracks.has(drone):
			_tracks[drone] = countdown_time
			print("[Airspace] RADAR SIGNATURE (%s) — %.0fs to descend"
					% [drone.name, countdown_time])
		_tracks[drone] -= delta
		if _tracks[drone] <= 0.0:
			_tracks.erase(drone)
			print("[Airspace] Shoot-down — %s above radar ceiling too long" % drone.name)
			drone.lose_signal()  # P7: spawn the interceptor here instead
	elif _tracks.has(drone):
		_tracks.erase(drone)
		print("[Airspace] Radar track lost — %s descended below ceiling" % drone.name)

	if drone.is_player:
		tracking = _tracks.has(drone)
		seconds_left = _tracks.get(drone, 0.0)


func _untrack(drone: DroneController) -> void:
	_tracks.erase(drone)
	if drone.is_player:
		tracking = false
		seconds_left = 0.0
