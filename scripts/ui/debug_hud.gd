class_name DebugHUD
extends CanvasLayer

## On-screen debug HUD for drone telemetry.
## Displays stick inputs, attitude angles, speed, altitude, flight mode, FPV status.
## Also shows a world-axis gizmo (Minecraft F3-style) and drone XYZ in bottom-left.
## Prints a one-line telemetry summary every 60 frames for MCP debug capture.

@export var drone_path: NodePath = NodePath("../Drone")
@export var print_interval: int = 60  # frames between console telemetry prints

## PS2-look tuning, mirrored onto the shader every frame — the ShaderMaterial
## is built in code, and the remote inspector can't edit runtime sub-resources,
## so these exports are the live-tunable knobs (select DebugHud remotely).
@export_group("PS2 Look")
@export_range(4.0, 64.0) var ps2_color_levels: float = 16.0
@export_range(0.0, 2.0) var ps2_dither_strength: float = 1.0
@export_range(0.0, 1.0) var ps2_vignette_strength: float = 0.8
@export_range(1.0, 6.0) var ps2_pixel_size: float = 2.0
@export_range(0.0, 0.5) var ps2_fisheye_strength: float = 0.1

var _drone: DroneController
var _frame_count: int = 0

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

var _gizmo_panel: ColorRect
var _gizmo_canvas: Control
var _coord_label: Label

var _wind_panel: ColorRect
var _wind_canvas: Control
var _wind_label: Label
## Last stable on-screen wind direction — see _on_wind_draw for why this is
## cached instead of renormalized every frame.
var _wind_arrow_dir: Vector2 = Vector2.RIGHT

var _gizmo_font: Font
var _gizmo_font_size: int = 14

# Full-screen post shaders live on their own CanvasLayer BELOW this HUD's
# layer: hint_screen_texture there captures only the 3D render, so telemetry
# panels and banners drawn on the HUD layer are never posterized/distorted.
var _post_layer: CanvasLayer
var _ps2_rect: ColorRect  # PS2-era look, 3PV only


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

	if _ps2_rect.visible:
		var mat := _ps2_rect.material as ShaderMaterial
		mat.set_shader_parameter("color_levels", ps2_color_levels)
		mat.set_shader_parameter("dither_strength", ps2_dither_strength)
		mat.set_shader_parameter("vignette_strength", ps2_vignette_strength)
		mat.set_shader_parameter("pixel_size", ps2_pixel_size)
		mat.set_shader_parameter("fisheye_strength", ps2_fisheye_strength)

	var telemetry: Dictionary = _gather_telemetry()
	_label.text = _format_telemetry(telemetry)

	var pos: Vector3 = _drone.global_position
	_coord_label.text = "X %+7.2f  Y %+7.2f  Z %+7.2f" % [pos.x, pos.y, pos.z]

	# Ambient wind sampled at the drone, not the drag force applied to it.
	var wind_speed: float = _drone.wind_velocity.length()
	_wind_label.text = "WIND CALM" if wind_speed < 0.3 else "WIND %.1f m/s" % wind_speed

	_gizmo_canvas.queue_redraw()
	_wind_canvas.queue_redraw()

	_frame_count += 1
	if _frame_count >= print_interval:
		_frame_count = 0
		print("[HUD] %s" % _format_telemetry_compact(telemetry))


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
	_wind_panel.modulate.a = 0.35
	_update_dead_feed_visibility()


func _on_fpv_toggled(enabled: bool) -> void:
	_ps2_rect.visible = not enabled  # PS2 look is the 3PV "game" view only
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
		_wind_panel.modulate.a = 1.0
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
		"=== DRONE TELEMETRY ===\n"
		+ "Flight Mode : %s\n" % t["flight_mode"].to_upper()
		+ "FPV         : %s\n" % ("ON" if t["fpv_enabled"] else "OFF")
		+ "Assist      : %s\n" % (assist if not assist.is_empty() else "-")
		+ "-----------------------\n"
		+ "Throttle    : %5.1f%%\n" % t["throttle_pct"]
		+ "Pitch stick : %+0.2f\n" % t["pitch_stick"]
		+ "Roll stick  : %+0.2f\n" % t["roll_stick"]
		+ "Yaw stick   : %+0.2f\n" % t["yaw_stick"]
		+ "Thr stick   : %+0.2f\n" % t["throttle_stick"]
		+ "-----------------------\n"
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
	# Post-shader layer below the HUD layer (see _post_layer declaration).
	_post_layer = CanvasLayer.new()
	_post_layer.layer = layer - 1
	add_child(_post_layer)

	_ps2_rect = ColorRect.new()
	_ps2_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	_ps2_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var ps2_mat := ShaderMaterial.new()
	ps2_mat.shader = load("res://assets/shaders/ps2_post.gdshader")
	_ps2_rect.material = ps2_mat
	_ps2_rect.visible = true  # game starts in 3PV
	_post_layer.add_child(_ps2_rect)

	# Dead-feed layer added first so it draws under the telemetry panels.
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

	_gizmo_panel = ColorRect.new()
	_gizmo_panel.color = Color(0.0, 0.0, 0.0, 0.65)
	_gizmo_panel.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_gizmo_panel.offset_left = -170.0
	_gizmo_panel.offset_top = 8.0
	_gizmo_panel.offset_right = -8.0
	_gizmo_panel.offset_bottom = 110.0
	add_child(_gizmo_panel)

	_gizmo_canvas = Control.new()
	_gizmo_canvas.set_anchors_preset(Control.PRESET_FULL_RECT)
	_gizmo_canvas.draw.connect(_on_gizmo_draw)
	_gizmo_panel.add_child(_gizmo_canvas)

	_coord_label = Label.new()
	_coord_label.add_theme_font_size_override("font_size", 11)
	_coord_label.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	_coord_label.offset_left = 6.0
	_coord_label.offset_bottom = -6.0
	_coord_label.add_theme_color_override("font_color", Color(0.35, 1.0, 0.35))
	_coord_label.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	_coord_label.add_theme_constant_override("outline_size", 1)
	_coord_label.text = "X    0.00  Y    0.00  Z    0.00"
	_gizmo_panel.add_child(_coord_label)

	_wind_panel = ColorRect.new()
	_wind_panel.color = Color(0.0, 0.0, 0.0, 0.65)
	_wind_panel.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_wind_panel.offset_left = -170.0
	_wind_panel.offset_top = 140.0
	_wind_panel.offset_right = -8.0
	_wind_panel.offset_bottom = 240.0
	add_child(_wind_panel)

	_wind_canvas = Control.new()
	_wind_canvas.set_anchors_preset(Control.PRESET_FULL_RECT)
	_wind_canvas.draw.connect(_on_wind_draw)
	_wind_panel.add_child(_wind_canvas)

	_wind_label = Label.new()
	_wind_label.add_theme_font_size_override("font_size", 11)
	_wind_label.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	_wind_label.offset_left = 6.0
	_wind_label.offset_bottom = -6.0
	_wind_label.add_theme_color_override("font_color", Color(0.35, 1.0, 0.35))
	_wind_label.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	_wind_label.add_theme_constant_override("outline_size", 1)
	_wind_label.text = "WIND CALM"
	_wind_panel.add_child(_wind_label)

	_signal_lost_label = Label.new()
	_signal_lost_label.text = "SIGNAL LOST"
	_signal_lost_label.add_theme_font_size_override("font_size", 48)
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


## Draws a camera-relative arrow for the ambient wind at the drone's position
## (same projection technique as _on_gizmo_draw): drone-relative in FPV,
## intuitive in 3PV. Length + alpha scale with speed; near-calm shows a dim dot.
func _on_wind_draw() -> void:
	if _drone == null:
		return
	var cam := get_viewport().get_camera_3d()
	if not cam or not is_instance_valid(cam):
		return

	var wind: Vector3 = _drone.wind_velocity
	var speed: float = wind.length()

	var panel_size := _wind_canvas.get_size()
	var center := panel_size * Vector2(0.5, 0.45)

	if speed < 0.3:
		_wind_canvas.draw_circle(center, 5.0, Color(0.6, 0.85, 1.0, 0.5))
		return

	var cam_basis := cam.global_transform.basis.inverse()
	var cam_local := cam_basis * wind
	# The in-plane (screen-space) projection, NOT normalized: its magnitude is
	# how much of the wind is visible sideways-on vs. pointing toward/away
	# from the camera. Renormalizing this every frame is what caused the
	# reported 180° flips — as wind points closer to the camera's forward
	# axis, this vector shrinks toward zero, and a tiny gust or FPV rotation-
	# smoothing wobble can flip a near-zero normalized vector by ~180° even
	# though the real 3D wind direction barely changed. (Not gimbal lock —
	# there's no Euler-angle math on this path — but a similar-flavored
	# instability: a 3D→2D projection near its degenerate axis.) Fix: only
	# update the displayed direction when the in-plane component is large
	# enough to be meaningful; otherwise keep the last stable direction and
	# let the arrow shrink toward the center dot instead of snapping.
	var screen_vec := Vector2(cam_local.x, -cam_local.y)
	var screen_speed := screen_vec.length()
	if screen_speed > 0.15:
		_wind_arrow_dir = screen_vec / screen_speed

	var arrow_len: float = 16.0 + 46.0 * clampf(screen_speed / 8.0, 0.0, 1.0)
	var alpha: float = smoothstep(0.3, 1.2, speed)
	var color := Color(0.6, 0.85, 1.0, alpha)
	var outline := Color(0.0, 0.0, 0.0, alpha * 0.9)

	var tip := center + _wind_arrow_dir * arrow_len
	var head_a := tip + _wind_arrow_dir.rotated(deg_to_rad(150.0)) * 18.0
	var head_b := tip + _wind_arrow_dir.rotated(deg_to_rad(-150.0)) * 18.0
	var segments := [[center, tip], [tip, head_a], [tip, head_b]]

	# Bold: dark outline stroke first, colored stroke on top — reads clearly
	# against any background (Wii Sports-style chunky meter, per feedback).
	# Round joints (small filled circles at the tip) mask the notch that
	# three unjoined draw_line segments otherwise leave at their shared vertex.
	for seg in segments:
		_wind_canvas.draw_line(seg[0], seg[1], outline, 9.0, false)
	_wind_canvas.draw_circle(tip, 4.5, outline)
	for seg in segments:
		_wind_canvas.draw_line(seg[0], seg[1], color, 6.0, false)
	_wind_canvas.draw_circle(tip, 3.0, color)
