class_name DebugHUD
extends CanvasLayer

## On-screen debug HUD for drone telemetry.
## Displays stick inputs, attitude angles, speed, altitude, flight mode, FPV status.
## Also shows a world-axis gizmo (Minecraft F3-style) and drone XYZ in bottom-left.
## Prints a one-line telemetry summary every 60 frames for MCP debug capture.

@export var drone_path: NodePath = NodePath("../Drone")
@export var print_interval: int = 60  # frames between console telemetry prints

var _drone: DroneController
var _frame_count: int = 0

# UI elements
var _label: Label
var _bg: ColorRect

# Crash / signal-loss overlay.
# The FPV feed dies at the crash instant: if the crash happens while in FPV the
# last rendered frame is captured and frozen on screen; if it happens in 3PV no
# frame was ever captured, so entering FPV afterwards shows the plain black
# "no signal" screen. Chase cam always renders live (only the banner shows).
var _feed_black: ColorRect          # black "no signal" backdrop
var _feed_frozen: TextureRect       # frozen last frame (only if crashed in FPV)
var _signal_lost_label: Label
var _frozen_frame: ImageTexture = null
var _pulse_time: float = 0.0
var _drone_connected: bool = false

# Axis gizmo + coords (bottom-left)
var _gizmo_panel: ColorRect
var _gizmo_canvas: Control
var _coord_label: Label

# Cached font for _draw_string
var _gizmo_font: Font
var _gizmo_font_size: int = 14


func _ready() -> void:
	_drone = get_node_or_null(drone_path) as DroneController
	_build_ui()
	_gizmo_font = ThemeDB.fallback_font
	_gizmo_font_size = ThemeDB.fallback_font_size
	_connect_drone_signals()


func _connect_drone_signals() -> void:
	if _drone == null or _drone_connected:
		return
	_drone_connected = true
	_drone.crash_detected.connect(_on_crash_detected)
	_drone.fpv_toggled.connect(_on_fpv_toggled)


func _process(delta: float) -> void:
	if _drone == null:
		_drone = get_node_or_null(drone_path) as DroneController
		if _drone == null:
			return
		_connect_drone_signals()

	_update_crash_overlay(delta)

	var telemetry: Dictionary = _gather_telemetry()
	_label.text = _format_telemetry(telemetry)

	# Update coordinates
	var pos: Vector3 = _drone.global_position
	_coord_label.text = "X %+7.2f  Y %+7.2f  Z %+7.2f" % [pos.x, pos.y, pos.z]

	# Redraw axis gizmo every frame
	_gizmo_canvas.queue_redraw()

	_frame_count += 1
	if _frame_count >= print_interval:
		_frame_count = 0
		print("[HUD] %s" % _format_telemetry_compact(telemetry))


# ---------------------------------------------------------------------------
# Crash / signal-loss overlay
# ---------------------------------------------------------------------------

func _on_crash_detected() -> void:
	# The feed is only being watched (and thus freezable) if the pilot was in
	# FPV at the crash instant. The viewport still holds the last presented
	# frame at this point — that's exactly the "last frame before signal loss".
	if _drone.is_fpv_enabled():
		var img: Image = get_viewport().get_texture().get_image()
		_frozen_frame = ImageTexture.create_from_image(img)
		_feed_frozen.texture = _frozen_frame
	_pulse_time = 0.0
	_signal_lost_label.visible = true
	_label.modulate.a = 0.35
	_update_dead_feed_visibility()


func _on_fpv_toggled(_enabled: bool) -> void:
	_update_dead_feed_visibility()


## The dead-feed layer covers the 3D view whenever the pilot looks through the
## (dead) FPV camera of a crashed drone: frozen frame if one was captured at
## crash time, plain black "no signal" otherwise. Chase cam stays live.
func _update_dead_feed_visibility() -> void:
	var dead_feed: bool = _drone != null and _drone.is_crashed() and _drone.is_fpv_enabled()
	_feed_black.visible = dead_feed
	_feed_frozen.visible = dead_feed and _frozen_frame != null


func _update_crash_overlay(delta: float) -> void:
	if _drone.is_crashed():
		_pulse_time += delta
		_signal_lost_label.modulate.a = 0.6 + 0.4 * sin(_pulse_time * 6.0)
	elif _signal_lost_label.visible:
		# Drone was reset — restore the live HUD and drop the captured frame.
		_signal_lost_label.visible = false
		_frozen_frame = null
		_feed_frozen.texture = null
		_label.modulate.a = 1.0
		_update_dead_feed_visibility()


func _gather_telemetry() -> Dictionary:
	var euler: Vector3 = _drone.global_transform.basis.get_euler()
	var heading_deg: float = rad_to_deg(euler.y)
	while heading_deg < 0.0:
		heading_deg += 360.0
	while heading_deg >= 360.0:
		heading_deg -= 360.0

	var pitch_deg: float = rad_to_deg(euler.x)
	var roll_deg: float = rad_to_deg(euler.z)
	var speed_mps: float = _drone.linear_velocity.length()
	var altitude: float = _drone.global_position.y
	var throttle_pct: float = _drone.thrust_percent

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
		"altitude_hold_engaged": _drone._altitude_hold_engaged,
		"brake_engaged": _drone._brake_engaged,
		"crashed": _drone.is_crashed(),
	}


func _format_telemetry(t: Dictionary) -> String:
	var assist: String = ""
	if t["altitude_hold_engaged"]:
		assist += "ALT HOLD  "
	if t["brake_engaged"]:
		assist += "BRAKE"
	return (
		"═══ DRONE TELEMETRY ═══\n"
		+ "Flight Mode : %s\n" % t["flight_mode"].to_upper()
		+ "FPV         : %s\n" % ("ON" if t["fpv_enabled"] else "OFF")
		+ "Assist      : %s\n" % (assist if not assist.is_empty() else "—")
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
		"mode=%s fpv=%s alt_hold=%s brake=%s crashed=%s thr=%.0f%% sticks=[p%+.2f r%+.2f y%+.2f t%+.2f] "
		% [t["flight_mode"], t["fpv_enabled"], t["altitude_hold_engaged"], t["brake_engaged"],
		   t["crashed"], t["throttle_pct"], t["pitch_stick"], t["roll_stick"], t["yaw_stick"], t["throttle_stick"]]
		+ "H=%.1f° P=%.1f° R=%.1f° spd=%.1f alt=%.1f"
		% [t["heading_deg"], t["pitch_deg"], t["roll_deg"],
		   t["speed_mps"], t["altitude"]]
	)


func _build_ui() -> void:
	# ——— Dead-feed layer (added first = drawn under the telemetry panels) ———
	_feed_black = ColorRect.new()
	_feed_black.color = Color.BLACK
	_feed_black.set_anchors_preset(Control.PRESET_FULL_RECT)
	_feed_black.visible = false
	add_child(_feed_black)

	_feed_frozen = TextureRect.new()
	_feed_frozen.set_anchors_preset(Control.PRESET_FULL_RECT)
	_feed_frozen.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_feed_frozen.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	_feed_frozen.visible = false
	add_child(_feed_frozen)

	# ——— Top-left telemetry panel ———
	_bg = ColorRect.new()
	_bg.color = Color(0.0, 0.0, 0.0, 0.65)
	_bg.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_bg.offset_right = 280.0
	_bg.offset_bottom = 356.0
	_bg.offset_left = 8.0
	_bg.offset_top = 8.0
	add_child(_bg)

	_label = Label.new()
	_label.add_theme_font_size_override("font_size", 13)
	_try_load_monospace_font(_label)
	_label.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_label.offset_left = 14.0
	_label.offset_top = 14.0
	_label.offset_right = 282.0
	_label.offset_bottom = 358.0
	_label.add_theme_color_override("font_color", Color(0.35, 1.0, 0.35))
	_label.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	_label.add_theme_constant_override("outline_size", 2)
	_label.text = "Waiting for drone..."
	add_child(_label)

	# ——— Top-right axis gizmo + coords ———
	_gizmo_panel = ColorRect.new()
	_gizmo_panel.color = Color(0.0, 0.0, 0.0, 0.65)
	_gizmo_panel.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_gizmo_panel.offset_left = -170.0
	_gizmo_panel.offset_top = 8.0
	_gizmo_panel.offset_right = -8.0
	_gizmo_panel.offset_bottom = 110.0
	add_child(_gizmo_panel)

	# Custom Control that draws the axis cross
	_gizmo_canvas = Control.new()
	_gizmo_canvas.set_anchors_preset(Control.PRESET_FULL_RECT)
	_gizmo_canvas.draw.connect(_on_gizmo_draw)
	_gizmo_panel.add_child(_gizmo_canvas)

	# XYZ coordinate label below the gizmo
	_coord_label = Label.new()
	_coord_label.add_theme_font_size_override("font_size", 11)
	_try_load_monospace_font(_coord_label)
	_coord_label.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	_coord_label.offset_left = 6.0
	_coord_label.offset_bottom = -6.0
	_coord_label.add_theme_color_override("font_color", Color(0.35, 1.0, 0.35))
	_coord_label.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	_coord_label.add_theme_constant_override("outline_size", 1)
	_coord_label.text = "X    0.00  Y    0.00  Z    0.00"
	_gizmo_panel.add_child(_coord_label)

	# ——— Centered SIGNAL LOST banner (added last = drawn on top) ———
	_signal_lost_label = Label.new()
	_signal_lost_label.text = "⚠ SIGNAL LOST"
	_signal_lost_label.add_theme_font_size_override("font_size", 48)
	_try_load_monospace_font(_signal_lost_label)
	_signal_lost_label.add_theme_color_override("font_color", Color(1.0, 0.15, 0.1))
	_signal_lost_label.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	_signal_lost_label.add_theme_constant_override("outline_size", 6)
	_signal_lost_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_signal_lost_label.set_anchors_preset(Control.PRESET_CENTER)
	_signal_lost_label.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_signal_lost_label.grow_vertical = Control.GROW_DIRECTION_BOTH
	_signal_lost_label.visible = false
	add_child(_signal_lost_label)


func _on_gizmo_draw() -> void:
	## Draws X (red), Y (green), Z (blue) world axes as seen from the camera.
	var cam := get_viewport().get_camera_3d()
	if not cam or not is_instance_valid(cam):
		return

	var gizmo_size := _gizmo_canvas.get_size()
	var center := gizmo_size * Vector2(0.5, 0.4)
	var arm_len := 26.0
	var cam_basis := cam.global_transform.basis.inverse()

	var axes := {
		"X": Vector3.RIGHT,
		"Y": Vector3.UP,
		"Z": Vector3.BACK,
	}
	var colors := {
		"X": Color(1.0, 0.25, 0.25),
		"Y": Color(0.25, 1.0, 0.25),
		"Z": Color(0.3, 0.5, 1.0),
	}

	for label in ["X", "Y", "Z"]:
		var world_dir := axes[label] as Vector3
		# Transform to camera-local space, then to 2D screen
		var cam_local := cam_basis * world_dir
		var screen_dir := Vector2(cam_local.x, -cam_local.y) * arm_len
		var tip := center + screen_dir

		# Draw the line
		_gizmo_canvas.draw_line(center, tip, colors[label], 2.0, false)

		# Draw the label slightly past the tip
		_gizmo_canvas.draw_string(
			_gizmo_font, tip + Vector2(3, -3), label,
			HORIZONTAL_ALIGNMENT_LEFT, -1, _gizmo_font_size, colors[label]
		)

	# Small dot at center
	_gizmo_canvas.draw_circle(center, 2.0, Color(1, 1, 1, 0.6))


func _try_load_monospace_font(label: Label) -> void:
	for font_path in ["res://assets/fonts/mono.woff2", "res://assets/fonts/mono.ttf", "res://assets/fonts/monospace.ttf"]:
		if not FileAccess.file_exists(font_path):
			continue
		var mono_font := FontFile.new()
		mono_font.load_dynamic_font(font_path)
		if not mono_font.data.is_empty():
			label.add_theme_font_override("font", mono_font)
			return
