class_name DebugHUD
extends CanvasLayer

## On-screen debug HUD for drone telemetry.
## Displays stick inputs, attitude angles, speed, altitude, flight mode, FPV status.
## Also prints a one-line telemetry summary every 60 frames for MCP debug capture.

@export var drone_path: NodePath = NodePath("../Drone")
@export var print_interval: int = 60  # frames between console telemetry prints

var _drone: DroneController
var _frame_count: int = 0

# UI elements
var _label: Label
var _bg: ColorRect


func _ready() -> void:
	_drone = get_node_or_null(drone_path) as DroneController
	_build_ui()


func _process(_delta: float) -> void:
	if _drone == null:
		_drone = get_node_or_null(drone_path) as DroneController
		if _drone == null:
			return

	var telemetry: Dictionary = _gather_telemetry()
	_label.text = _format_telemetry(telemetry)

	_frame_count += 1
	if _frame_count >= print_interval:
		_frame_count = 0
		print("[HUD] %s" % _format_telemetry_compact(telemetry))


func _gather_telemetry() -> Dictionary:
	var euler: Vector3 = _drone.global_transform.basis.get_euler()
	var heading_deg: float = rad_to_deg(euler.y)
	# Normalize heading to 0..360
	while heading_deg < 0.0:
		heading_deg += 360.0
	while heading_deg >= 360.0:
		heading_deg -= 360.0

	var pitch_deg: float = rad_to_deg(euler.x)
	var roll_deg: float = rad_to_deg(euler.z)
	var speed_mps: float = _drone.linear_velocity.length()
	var altitude: float = _drone.global_position.y
	var throttle_pct: float = clampf(
		_drone.hover_throttle + _drone._throttle_input * 0.6, 0.0, 1.0
	) * 100.0

	return {
		"throttle_pct": throttle_pct,
		"pitch_stick": _drone._pitch_input,
		"roll_stick": _drone._roll_input,
		"yaw_stick": _drone._yaw_input,
		"throttle_stick": _drone._throttle_input,
		"heading_deg": heading_deg,
		"pitch_deg": pitch_deg,
		"roll_deg": roll_deg,
		"speed_mps": speed_mps,
		"altitude": altitude,
		"flight_mode": _drone._flight_mode,
		"fpv_enabled": _drone._fpv_enabled,
	}


func _format_telemetry(t: Dictionary) -> String:
	return (
		"═══ DRONE TELEMETRY ═══\n"
		+ "Flight Mode : %s\n" % t["flight_mode"].to_upper()
		+ "FPV         : %s\n" % ("ON" if t["fpv_enabled"] else "OFF")
		+ "─────────────────────\n"
		+ "Throttle    : %5.1f%%\n" % t["throttle_pct"]
		+ "Pitch stick : %+0.2f\n" % t["pitch_stick"]
		+ "Roll stick  : %+0.2f\n" % t["roll_stick"]
		+ "Yaw stick   : %+0.2f\n" % t["yaw_stick"]
		+ "Thr stick   : %+0.2f\n" % t["throttle_stick"]
		+ "─────────────────────\n"
		+ "Heading     : %6.1f°\n" % t["heading_deg"]
		+ "Pitch angle : %+6.1f°\n" % t["pitch_deg"]
		+ "Roll angle  : %+6.1f°\n" % t["roll_deg"]
		+ "Speed       : %5.1f m/s\n" % t["speed_mps"]
		+ "Altitude    : %+6.1f m\n" % t["altitude"]
	)


func _format_telemetry_compact(t: Dictionary) -> String:
	return (
		"mode=%s fpv=%s thr=%.0f%% sticks=[p%+.2f r%+.2f y%+.2f t%+.2f] "
		% [t["flight_mode"], t["fpv_enabled"], t["throttle_pct"],
		   t["pitch_stick"], t["roll_stick"], t["yaw_stick"], t["throttle_stick"]]
		+ "H=%.1f° P=%.1f° R=%.1f° spd=%.1f alt=%.1f"
		% [t["heading_deg"], t["pitch_deg"], t["roll_deg"],
		   t["speed_mps"], t["altitude"]]
	)


func _build_ui() -> void:
	# Semi-transparent background
	_bg = ColorRect.new()
	_bg.color = Color(0.0, 0.0, 0.0, 0.65)
	_bg.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_bg.offset_right = 280.0
	_bg.offset_bottom = 340.0
	_bg.offset_left = 8.0
	_bg.offset_top = 8.0
	add_child(_bg)

	# Monospace label
	_label = Label.new()
	_label.add_theme_font_size_override("font_size", 13)
	# Try to use a monospace font; falls back to default if not available
	_try_load_monospace_font(_label)
	_label.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_label.offset_left = 14.0
	_label.offset_top = 14.0
	_label.offset_right = 282.0
	_label.offset_bottom = 342.0
	# Green text for that classic HUD look
	_label.add_theme_color_override("font_color", Color(0.35, 1.0, 0.35))
	_label.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	_label.add_theme_constant_override("outline_size", 2)
	_label.text = "Waiting for drone..."
	add_child(_label)


func _try_load_monospace_font(label: Label) -> void:
	# Attempt to load a monospace font from common locations; silently fall back
	# to the engine default if no font file is found.
	for font_path in ["res://assets/fonts/mono.woff2", "res://assets/fonts/mono.ttf", "res://assets/fonts/monospace.ttf"]:
		if not FileAccess.file_exists(font_path):
			continue
		var mono_font := FontFile.new()
		mono_font.load_dynamic_font(font_path)
		if not mono_font.data.is_empty():
			label.add_theme_font_override("font", mono_font)
			return
