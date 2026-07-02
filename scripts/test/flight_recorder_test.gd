extends Node3D

## Headless test harness for FlightRecorder (P3 Phase D). Covers the JSONL
## telemetry stream: one frame per physics tick, parseable lines with the
## expected keys, meta header, and file rotation on drone reset.

var _passed: int = 0
var _failed: int = 0
var _drone: DroneController = null
var _recorder: FlightRecorder = null


func _ready() -> void:
	call_deferred("_delayed_start")


func _delayed_start() -> void:
	_drone = $Drone as DroneController
	_recorder = $FlightRecorder as FlightRecorder
	if _drone == null or _recorder == null:
		printerr("[TEST] FATAL: Could not find Drone/FlightRecorder node in scene")
		get_tree().quit(1)
		return

	await _run_all_tests()


func _run_ticks(count: int) -> void:
	for _i in range(count):
		await get_tree().physics_frame


func _run_all_tests() -> void:
	_passed = 0
	_failed = 0

	await _run_test("test_records_one_frame_per_tick")
	await _run_test("test_jsonl_valid_with_meta_header")
	await _run_test("test_reset_rotates_log_file")

	var total := _passed + _failed
	print("[TEST] ========================================")
	print("[TEST] Results: ", _passed, " passed, ", _failed, " failed out of ", total)
	print("[TEST] ========================================")

	if _failed > 0:
		get_tree().quit(1)
	else:
		get_tree().quit(0)


func _run_test(test_name: String) -> void:
	var result: bool = await call(test_name)
	if result:
		_passed += 1
		print("[TEST] PASS: ", test_name)
	else:
		_failed += 1
		print("[TEST] FAIL: ", test_name)


## Read the current log back (flushing first so everything is on disk).
func _read_log_lines() -> PackedStringArray:
	_recorder._file.flush()
	var text := FileAccess.get_file_as_string(_recorder.log_path)
	var lines := text.split("\n", false)
	return lines


# ---------------------------------------------------------------------------
# Test: N physics ticks append ≈N frames to the log
# ---------------------------------------------------------------------------
func test_records_one_frame_per_tick() -> bool:
	print("[TEST] --- test_records_one_frame_per_tick ---")
	Input.action_press("throttle_up")
	var before := _read_log_lines().size()
	await _run_ticks(60)
	Input.action_release("throttle_up")
	var after := _read_log_lines().size()
	var grew := after - before
	print("[TEST] lines before=", before, " after=", after, " (+", grew, ")")

	# await physics_frame resumes mid-pipeline, so the window can be off by a
	# tick on either end — anywhere near 60 proves one-frame-per-tick.
	var passed := grew >= 58 and grew <= 62
	print("[TEST] ", "PASS" if passed else "FAIL", " — ~60 frames for 60 ticks")
	return passed


# ---------------------------------------------------------------------------
# Test: every line parses as JSON; first is the meta header; frames carry the
# expected keys and the throttle we pressed shows up in sticks/mix
# ---------------------------------------------------------------------------
func test_jsonl_valid_with_meta_header() -> bool:
	print("[TEST] --- test_jsonl_valid_with_meta_header ---")
	var lines := _read_log_lines()
	if lines.size() < 2:
		print("[TEST] FAIL — log has fewer than 2 lines")
		return false

	var header: Variant = JSON.parse_string(lines[0])
	var header_ok: bool = header is Dictionary and header.has("meta") \
			and header["meta"]["version"] == 1 \
			and int(header["meta"]["tick_hz"]) == Engine.physics_ticks_per_second

	var expected_keys := ["t", "pos", "quat", "vel", "angvel", "mix", "sticks",
			"ah", "brake", "mode", "wind", "crashed"]
	var frames_ok := true
	var saw_thrust := false
	for i in range(1, lines.size()):
		var frame: Variant = JSON.parse_string(lines[i])
		if frame == null or not frame is Dictionary:
			print("[TEST] line ", i, " failed to parse: ", lines[i].left(80))
			frames_ok = false
			break
		for key in expected_keys:
			if not frame.has(key):
				print("[TEST] line ", i, " missing key '", key, "'")
				frames_ok = false
				break
		if frames_ok and frame["mix"][0] > 0.0:
			saw_thrust = true

	print("[TEST] header_ok=", header_ok, " frames_ok=", frames_ok, " saw_thrust=", saw_thrust)
	var passed := header_ok and frames_ok and saw_thrust
	print("[TEST] ", "PASS" if passed else "FAIL", " — valid JSONL with meta header and live mix data")
	return passed


# ---------------------------------------------------------------------------
# Test: drone reset closes the current file and opens a fresh one
# ---------------------------------------------------------------------------
func test_reset_rotates_log_file() -> bool:
	print("[TEST] --- test_reset_rotates_log_file ---")
	var old_path: String = _recorder.log_path
	_drone.reset()
	await _run_ticks(5)
	var new_path: String = _recorder.log_path
	var new_lines := _read_log_lines()
	print("[TEST] old=", old_path, " new=", new_path, " new_lines=", new_lines.size())

	var passed: bool = new_path != old_path \
			and FileAccess.file_exists(old_path) \
			and new_lines.size() >= 2  # meta header + at least one frame
	print("[TEST] ", "PASS" if passed else "FAIL", " — reset rotates to a new log file")
	return passed
