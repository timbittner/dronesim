class_name FlightRecorder
extends Node

## Streams one JSONL line of drone telemetry per physics tick to
## user://telemetry/flight_<timestamp>_<n>.jsonl, for post-flight debugging and
## for agents inspecting a run without watching it live (the absolute path is
## printed at startup so headless runs can find it from stdout).
##
## Environment-side observer, same pattern as CrashEffects/WindField: reads
## drone state, never writes it — nothing here can leak into the flight
## pipeline. Lives only in main.tscn; scenes without a FlightRecorder log
## nothing. In-sim replay/scrubbing is deliberately out of scope (see
## plans/backlog/drone-controls-and-physics.md).

@export var drone_path: NodePath = NodePath("../Drone")

## user:// path of the file currently being written (new one per flight).
var log_path: String = ""

var _drone: DroneController
var _file: FileAccess
var _t: float = 0.0
var _last_flush: float = 0.0
var _flight_index: int = 0


func _ready() -> void:
	_drone = get_node_or_null(drone_path) as DroneController
	if _drone == null:
		printerr("[FlightRecorder] no drone at ", drone_path, " — recording disabled")
		set_physics_process(false)
		return
	_drone.drone_reset.connect(_open_new_file)
	_open_new_file()


## One file per flight: called at startup and again on every drone reset.
func _open_new_file() -> void:
	if _file:
		_file.close()
	DirAccess.make_dir_recursive_absolute("user://telemetry")
	_flight_index += 1
	var stamp: String = Time.get_datetime_string_from_system().replace(":", "-")
	log_path = "user://telemetry/flight_%s_%d.jsonl" % [stamp, _flight_index]
	_file = FileAccess.open(log_path, FileAccess.WRITE)
	if _file == null:
		printerr("[FlightRecorder] cannot open ", log_path, " — recording disabled")
		set_physics_process(false)
		return
	_t = 0.0
	_last_flush = 0.0
	_file.store_line(JSON.stringify({
		"meta": {
			"version": 1,
			"tick_hz": Engine.physics_ticks_per_second,
			"mass": _drone.mass,
		}
	}))
	print("[FlightRecorder] logging to ", ProjectSettings.globalize_path(log_path))


func _physics_process(delta: float) -> void:
	_t += delta
	var p: Vector3 = _drone.global_position
	var q: Quaternion = _drone.global_transform.basis.get_rotation_quaternion()
	var v: Vector3 = _drone.linear_velocity
	var av: Vector3 = _drone.angular_velocity
	var m: Array[float] = _drone.last_mix
	var w: Vector3 = _drone.wind_velocity
	# Hand-built format string: fixed 3-decimal fields, no per-tick Dictionary
	# + JSON.stringify garbage.
	_file.store_line(
		"{\"t\":%.3f,\"pos\":[%.3f,%.3f,%.3f],\"quat\":[%.4f,%.4f,%.4f,%.4f],\"vel\":[%.3f,%.3f,%.3f],\"angvel\":[%.3f,%.3f,%.3f],\"mix\":[%.3f,%.3f,%.3f,%.3f],\"sticks\":[%.3f,%.3f,%.3f,%.3f],\"ah\":%s,\"brake\":%s,\"mode\":\"%s\",\"wind\":[%.3f,%.3f,%.3f],\"crashed\":%s}" % [
			_t, p.x, p.y, p.z, q.x, q.y, q.z, q.w, v.x, v.y, v.z,
			av.x, av.y, av.z, m[0], m[1], m[2], m[3],
			_drone._pitch_input, _drone._roll_input, _drone._yaw_input, _drone._throttle_input,
			_drone._altitude_hold_engaged, _drone._brake_engaged,
			_drone.get_flight_mode(), w.x, w.y, w.z, _drone.is_crashed(),
		]
	)
	# flush ~1/s: live-tailable and survives a killed process without
	# paying an fsync every tick.
	if _t - _last_flush >= 1.0:
		_file.flush()
		_last_flush = _t


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_PREDELETE:
		if _file:
			_file.close()
			_file = null
