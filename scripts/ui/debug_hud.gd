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

## Always-on static floor in FPV — it's a radio feed, never perfectly clean.
## Live intensity = baseline + (1 - drone.signal_quality).
@export_range(0.0, 0.3) var fpv_static_baseline: float = 0.05
## Static level over the dead FPV feed after a crash. Heavy, but low enough
## that the frozen last frame stays readable underneath (1.0 = pure snow —
## the shader mixes 90% snow at full intensity, burying the frame).
@export_range(0.0, 1.0) var crash_static_intensity: float = 0.45

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

# Radar-ceiling warning (P5 Phase 4): pulsing amber banner while the
# AirspaceControl node (group "airspace_control", lazily resolved) tracks the
# drone above the radar ceiling. No node in the scene = no banner.
var _radar_label: Label
var _radar_pulse: float = 0.0
var _airspace: Node = null
var _airspace_searched: bool = false

var _gizmo_panel: ColorRect
var _gizmo_canvas: Control
var _coord_label: Label

var _wind_panel: ColorRect
var _wind_canvas: Control
var _wind_label: Label
## Last stable on-screen wind direction — see _on_wind_draw for why this is
## cached instead of renormalized every frame.
var _wind_arrow_dir: Vector2 = Vector2.RIGHT

# Compass tape (P5 Phase 5): PUBG-style heading strip, bottom center. Draws the
# camera's heading (north = −Z, the map's UTM north) with 5° ticks, degree
# numbers every 15°, cardinal letters every 45°, and bearing dots for any
# mission targets (group "mission_targets"). Dims with the rest of the HUD on
# crash. See _on_compass_draw for the cylinder projection.
var _compass_panel: ColorRect
var _compass_canvas: Control

var _gizmo_font: Font
var _gizmo_font_size: int = 14

# The full-screen post shader lives on its own CanvasLayer BELOW this HUD's
# layer: hint_screen_texture there captures only the lower layers, so telemetry
# panels and banners drawn on the HUD layer are never posterized/distorted.
# Layer stack (bottom to top): 3D render → _feed_layer (dead-feed black/frozen
# frame) → _post_layer (PS2 look + analog static, one shader, both views — its
# screen texture includes the dead feed, so full static renders OVER the crash
# freeze frame) → this HUD layer.
var _feed_layer: CanvasLayer
var _post_layer: CanvasLayer
var _ps2_rect: ColorRect  # PS2 look + signal static, always on


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
	_update_radar_banner(delta)

	var fpv: bool = _drone.is_fpv_enabled()
	var intensity: float = clampf(
		(fpv_static_baseline if fpv else 0.0) + (1.0 - _drone.signal_quality), 0.0, 1.0)
	if fpv and _drone.is_crashed():
		intensity = crash_static_intensity  # dead feed: heavy static, frame readable
	var mat := _ps2_rect.material as ShaderMaterial
	mat.set_shader_parameter("color_levels", ps2_color_levels)
	mat.set_shader_parameter("dither_strength", ps2_dither_strength)
	mat.set_shader_parameter("vignette_strength", ps2_vignette_strength)
	mat.set_shader_parameter("pixel_size", ps2_pixel_size)
	mat.set_shader_parameter("fisheye_strength", ps2_fisheye_strength)
	mat.set_shader_parameter("static_intensity", intensity)

	var telemetry: Dictionary = _gather_telemetry()
	_label.text = _format_telemetry(telemetry)

	var pos: Vector3 = _drone.global_position
	_coord_label.text = "X %+7.2f  Y %+7.2f  Z %+7.2f" % [pos.x, pos.y, pos.z]

	# Ambient wind sampled at the drone, not the drag force applied to it.
	var wind_speed: float = _drone.wind_velocity.length()
	_wind_label.text = "WIND CALM" if wind_speed < 0.3 else "WIND %.1f m/s" % wind_speed

	_gizmo_canvas.queue_redraw()
	_wind_canvas.queue_redraw()
	_compass_canvas.queue_redraw()

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
	_compass_panel.modulate.a = 0.35
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
		_wind_panel.modulate.a = 1.0
		_compass_panel.modulate.a = 1.0
		_update_dead_feed_visibility()


func _update_radar_banner(delta: float) -> void:
	if not _airspace_searched:
		_airspace_searched = true
		_airspace = get_tree().get_first_node_in_group("airspace_control")
	if _airspace == null:
		return
	var tracking: bool = _airspace.tracking
	_radar_label.visible = tracking
	if tracking:
		_radar_pulse += delta
		_radar_label.text = "RADAR SIGNATURE DETECTED\nDESCEND — %d" % ceili(_airspace.seconds_left)
		_radar_label.modulate.a = 0.6 + 0.4 * sin(_radar_pulse * 6.0)
	else:
		_radar_pulse = 0.0


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
		"signal_pct": _drone.signal_quality * 100.0,
		# AGL comes from AirspaceControl so it's the exact value the radar
		# compares — NAN (renders as a dash) when the scene has no radar.
		"agl": _airspace.agl if _airspace != null else NAN,
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
		# "Altitude" = above ground level (radar ceiling and wind profile both
		# use it). World Y is already in the bottom-left coord readout.
		+ ("Altitude    : %6.1f m\n" % t["agl"] if not is_nan(t["agl"]) else "Altitude    :    —\n")
		+ "Signal      : %5.1f%%\n" % t["signal_pct"]
	)


func _format_telemetry_compact(t: Dictionary) -> String:
	return (
		"mode=%s fpv=%s alt_hold=%s brake=%s crashed=%s thr=%.0f%% sticks=[p%+.2f r%+.2f y%+.2f t%+.2f] "
		% [t["flight_mode"], t["fpv_enabled"], t["altitude_hold_engaged"], t["brake_engaged"],
		   t["crashed"], t["throttle_pct"], t["pitch_stick"], t["roll_stick"], t["yaw_stick"], t["throttle_stick"]]
		+ "H=%.1f° P=%.1f° R=%.1f° spd=%.1f alt=%.1f sig=%.0f%%"
		% [t["heading_deg"], t["pitch_deg"], t["roll_deg"],
		   t["speed_mps"], t["altitude"], t["signal_pct"]]
	)


func _build_ui() -> void:
	# Layer stack below the HUD layer (see _feed_layer/_post_layer declaration).
	_feed_layer = CanvasLayer.new()
	_feed_layer.layer = layer - 2
	add_child(_feed_layer)

	_feed_black = ColorRect.new()
	_feed_black.color = Color.BLACK
	_feed_black.set_anchors_preset(Control.PRESET_FULL_RECT)
	_feed_black.visible = false
	_feed_layer.add_child(_feed_black)

	_feed_frozen = TextureRect.new()
	_feed_frozen.set_anchors_preset(Control.PRESET_FULL_RECT)
	_feed_frozen.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_feed_frozen.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	_feed_frozen.visible = false
	_feed_layer.add_child(_feed_frozen)

	_post_layer = CanvasLayer.new()
	_post_layer.layer = layer - 1
	add_child(_post_layer)

	_ps2_rect = ColorRect.new()
	_ps2_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	_ps2_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var ps2_mat := ShaderMaterial.new()
	ps2_mat.shader = load("res://assets/shaders/ps2_post.gdshader")
	_ps2_rect.material = ps2_mat
	_post_layer.add_child(_ps2_rect)

	_bg = ColorRect.new()
	_bg.color = Color(0.0, 0.0, 0.0, 0.65)
	_bg.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_bg.offset_right = 280.0
	_bg.offset_bottom = 374.0  # fits the telemetry text incl. AGL + signal lines
	_bg.offset_left = 8.0
	_bg.offset_top = 8.0
	add_child(_bg)

	_label = Label.new()
	_label.add_theme_font_size_override("font_size", 13)
	_label.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_label.offset_left = 14.0
	_label.offset_top = 14.0
	_label.offset_right = 282.0
	_label.offset_bottom = 376.0
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

	# Compass tape, bottom center — clear of the top-center radar / signal-lost
	# banners. Semi-transparent strip; the canvas draws the ticks and labels.
	_compass_panel = ColorRect.new()
	_compass_panel.color = Color(0.0, 0.0, 0.0, 0.5)
	_compass_panel.clip_contents = true  # keep edge labels inside the strip
	_compass_panel.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_compass_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_compass_panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_compass_panel.offset_left = -230.0
	_compass_panel.offset_right = 230.0
	_compass_panel.offset_top = -40.0
	_compass_panel.offset_bottom = -14.0
	add_child(_compass_panel)

	_compass_canvas = Control.new()
	_compass_canvas.set_anchors_preset(Control.PRESET_FULL_RECT)
	_compass_canvas.draw.connect(_on_compass_draw)
	_compass_panel.add_child(_compass_canvas)

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

	# Radar warning: same styling family as SIGNAL LOST, amber, upper center
	# so it doesn't collide with the crash banner.
	_radar_label = Label.new()
	_radar_label.text = "RADAR SIGNATURE DETECTED — 10s"
	_radar_label.add_theme_font_size_override("font_size", 28)
	_radar_label.add_theme_color_override("font_color", Color(1.0, 0.72, 0.1))
	_radar_label.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	_radar_label.add_theme_constant_override("outline_size", 5)
	_radar_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_radar_label.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_radar_label.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_radar_label.offset_top = 70.0
	_radar_label.visible = false
	add_child(_radar_label)


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


const _CARDINALS := ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
## Degrees visible from center to each edge of the tape.
const COMPASS_HALF_FOV: float = 75.0
const COMPASS_FONT_SIZE: int = 11


## PUBG-style compass tape. Heading is the camera's forward bearing projected
## onto the ground plane: 0° = north = −Z (the map's UTM north), increasing
## clockwise through east (+X). Marks are placed with a cylinder projection
## (x ∝ sin(angle-from-center)) so the tape reads like the rim of a rotating
## ring — compressed and fading toward the edges — rather than a flat strip.
## Mission targets show as bearing dots, pinned to the nearest edge when their
## bearing is off-tape (green once cleared).
func _on_compass_draw() -> void:
	var cam := get_viewport().get_camera_3d()
	if not cam or not is_instance_valid(cam):
		return

	var size := _compass_canvas.get_size()
	var mid_x := size.x * 0.5
	var tick_bottom := size.y - 2.0
	var label_y := float(COMPASS_FONT_SIZE)
	# Radius that maps the edge FOV exactly to the panel edge.
	var radius := mid_x / sin(deg_to_rad(COMPASS_HALF_FOV))

	var fwd := -cam.global_transform.basis.z
	var heading := fposmod(rad_to_deg(atan2(fwd.x, -fwd.z)), 360.0)

	# Ticks + labels: walk the 5° marks in the visible window, each placed by its
	# signed angular distance from the heading, fading out toward the edges.
	var first := int(floor((heading - COMPASS_HALF_FOV) / 5.0)) * 5
	var last := int(ceil((heading + COMPASS_HALF_FOV) / 5.0)) * 5
	for d in range(first, last + 1, 5):
		var delta := _wrap180(float(d) - heading)
		if absf(delta) > COMPASS_HALF_FOV:
			continue
		var x := mid_x + sin(deg_to_rad(delta)) * radius
		var fade := smoothstep(COMPASS_HALF_FOV, COMPASS_HALF_FOV - 25.0, absf(delta))
		var nb := int(fposmod(float(d), 360.0))
		if nb % 45 == 0:
			_compass_canvas.draw_line(Vector2(x, tick_bottom), Vector2(x, tick_bottom - 9.0),
				Color(0.35, 1.0, 0.35, fade), 2.0)
			_draw_centered(_CARDINALS[roundi(nb / 45.0)], Vector2(x, label_y),
				Color(0.35, 1.0, 0.35, fade))
		elif nb % 15 == 0:
			_compass_canvas.draw_line(Vector2(x, tick_bottom), Vector2(x, tick_bottom - 7.0),
				Color(0.35, 1.0, 0.35, fade), 1.5)
			_draw_centered("%d" % nb, Vector2(x, label_y), Color(0.35, 1.0, 0.35, fade * 0.7))
		else:
			_compass_canvas.draw_line(Vector2(x, tick_bottom), Vector2(x, tick_bottom - 4.0),
				Color(0.35, 1.0, 0.35, fade * 0.5), 1.0)

	# Mission-target bearing dots (group is empty until Phase 6 — safe no-op).
	if _drone != null:
		var origin := _drone.global_position
		var dot_y := size.y * 0.5
		for t in get_tree().get_nodes_in_group("mission_targets"):
			if not is_instance_valid(t):
				continue
			var to: Vector3 = (t as Node3D).global_position - origin
			var bearing := fposmod(rad_to_deg(atan2(to.x, -to.z)), 360.0)
			# Clamp to the FOV so an off-tape target sticks to the nearest edge
			# instead of vanishing.
			var tdelta := clampf(_wrap180(bearing - heading), -COMPASS_HALF_FOV, COMPASS_HALF_FOV)
			var tx := mid_x + sin(deg_to_rad(tdelta)) * radius
			# ponytail: cleared→green, else amber; per-type colors when Phase 6
			# gives targets a type enum.
			var cleared: bool = ("cleared" in t) and t.cleared
			var dot := Color(0.3, 1.0, 0.3) if cleared else Color(1.0, 0.72, 0.1)
			_compass_canvas.draw_circle(Vector2(tx, dot_y), 3.0, dot)


func _wrap180(deg: float) -> float:
	return fposmod(deg + 180.0, 360.0) - 180.0


## Draws text horizontally centered on pos.x, with its baseline near pos.y.
func _draw_centered(text: String, pos: Vector2, color: Color) -> void:
	var w := _gizmo_font.get_string_size(
		text, HORIZONTAL_ALIGNMENT_LEFT, -1, COMPASS_FONT_SIZE).x
	_compass_canvas.draw_string(
		_gizmo_font, Vector2(pos.x - w * 0.5, pos.y), text,
		HORIZONTAL_ALIGNMENT_LEFT, -1, COMPASS_FONT_SIZE, color)
