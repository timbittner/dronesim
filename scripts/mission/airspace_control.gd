class_name AirspaceControl
extends Node

## Radar ceiling (P5 Phase 4). Climbing above radar_altitude meters AGL
## paints the drone on air-defense radar and starts a countdown (the HUD
## shows a pulsing amber banner via group "airspace_control"); descending
## below cancels it. Expiry is the shoot-down — currently a single
## drone.lose_signal() call, kept that way so the visible P6 interceptor can
## slot in behind the same trigger. AGL needs no raycast: Terrain exposes
## get_height(x, z) (same duck-typed contract WindField uses); no terrain
## node means ground level 0.

@export var drone_path: NodePath = NodePath("../Drone")
@export var terrain_path: NodePath = NodePath("../Terrain")
## Radar floor in meters above ground level.
@export var radar_altitude: float = 100.0
## Seconds painted on radar before the shoot-down.
@export var countdown_time: float = 10.0

## True while the drone is above the ceiling and the countdown runs.
var tracking: bool = false
## Countdown remaining in seconds (only meaningful while tracking).
var seconds_left: float = 0.0
## Current height above ground level in meters — the exact value the radar
## compares against radar_altitude. Read by the HUD so the pilot sees the
## same number the radar does (world Y is height above the spawn pad, which
## diverges from AGL over the valley's ridges and dips).
var agl: float = 0.0

var _drone: DroneController = null
var _terrain: Node = null


func _ready() -> void:
	add_to_group("airspace_control")
	_drone = get_node_or_null(drone_path) as DroneController
	_terrain = get_node_or_null(terrain_path)


func _physics_process(delta: float) -> void:
	if _drone == null:
		return

	var pos := _drone.global_position
	var ground := 0.0
	if _terrain != null and _terrain.has_method("get_height"):
		ground = _terrain.get_height(pos.x, pos.z)
	agl = pos.y - ground

	if _drone.is_crashed():
		tracking = false
		return

	if agl > radar_altitude:
		if not tracking:
			tracking = true
			seconds_left = countdown_time
			print("[Airspace] RADAR SIGNATURE — %.0fs to descend" % countdown_time)
		seconds_left -= delta
		if seconds_left <= 0.0:
			tracking = false
			print("[Airspace] Shoot-down — drone above radar ceiling too long")
			_drone.lose_signal()  # P6: spawn the interceptor here instead
	elif tracking:
		tracking = false
		print("[Airspace] Radar track lost — descended below ceiling")
