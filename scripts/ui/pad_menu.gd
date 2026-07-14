class_name PadMenu
extends CanvasLayer

## DPad-driven command menu (P6), Forza-pit-menu style, lower-left corner.
## Dpad left/right (or Tab) opens it; up/down selects an entry; left/right
## cycles the selected entry's value (staged, not yet applied); Cross (Enter)
## APPLIES everything and closes; Circle (Esc) aborts, discarding staged
## changes. While the menu is CLOSED, dpad up/down adjusts the FPV camera
## tilt, and a one-line hint in the corner shows both controls (hidden while
## the menu is open). Dead while the player drone is CRASHED.
##
## Entries are data, four kinds (distinguished by which keys they carry):
## - cycle: {label, options: Callable -> Array of names, getter: Callable ->
##   int, setter: Callable(int)} — left/right stages a value, Cross applies.
## - action: {label, kind: "action", action: Callable} — Cross fires it (only
##   the SELECTED action), applies the current level's staged cycles, and
##   closes the whole menu; left/right does nothing on it.
## - submenu: {label, kind: "submenu", entries: Array[Dictionary]} — Cross
##   descends into `entries` (pushing the current level) instead of closing.
## - back: {label: "BACK", kind: "back"} — Cross applies the current level's
##   staged cycles, then pops back to the parent level (auto-appended to every
##   submenu's entry list, no need to add it by hand).
## Later features (targeting mode, payload) extend this array.

## Degrees per second of FPV tilt sweep while holding dpad up/down.
@export var fpv_pitch_rate: float = 30.0

var is_open: bool = false
var selected: int = 0
## {label: String, options: Callable, getter: Callable, setter: Callable}
var entries: Array[Dictionary] = []
## Staged (not yet applied) option index per entry, valid while open.
var staged: Array[int] = []
## Parent levels above the current one — each frame is {entries, staged,
## selected} for a submenu descent (see _enter_submenu / _exit_submenu).
var _stack: Array[Dictionary] = []

var _panel: ColorRect
var _rows: Array[Label] = []
var _legend: Label
var _hint: Label
var _player: DroneController = null
var _manager: Node = null
var _manager_searched: bool = false
var _hud_node: Node = null
var _hud_searched: bool = false


## The engine's embedded default font (Open Sans) lacks the ▲▼◀▶✕○ menu
## glyphs; on desktop the OS font stack fills them in, but the web export has no
## OS fallback and renders tofu. Register a tiny DejaVu subset (just those six
## glyphs) as a global fallback on the default font so both platforms match,
## without changing the primary UI font. See assets/fonts/.
const GLYPH_FONT: FontFile = preload("res://assets/fonts/ui_glyphs.ttf")


func _ready() -> void:
	layer = 2  # above the DebugHUD layer
	_install_glyph_fallback()
	_build_entries()
	_build_ui()


func _install_glyph_fallback() -> void:
	var base := ThemeDB.fallback_font
	if base == null:
		return
	var fallbacks := base.get_fallbacks()
	if not fallbacks.has(GLYPH_FONT):
		base.set_fallbacks(fallbacks + [GLYPH_FONT])


func _build_entries() -> void:
	entries = [
		{
			# Toggles: lands the whole swarm (player included) in place, or
			# sends everyone back up. Label is a Callable — resolved on refresh.
			# First entry: it's used far more often than FORMATION.
			"label": func() -> String:
				var m := _swarm_manager()
				return "TAKE OFF" if m != null and m.swarm_landing() else "AUTO-LAND",
			"kind": "action",
			"action": func() -> void:
				var m := _swarm_manager()
				if m == null:
					return
				if m.swarm_landing():
					m.take_off_all()
				else:
					m.land_all(),
		},
		{
			"label": "FORMATION",
			"options": func() -> Array: return SwarmManager.Formation.keys(),
			"getter": func() -> int:
				var m := _swarm_manager()
				return m.formation if m != null else 0,
			"setter": func(v: int) -> void:
				var m := _swarm_manager()
				if m != null:
					m.formation = v as SwarmManager.Formation
					print("[Swarm] formation: %s" % SwarmManager.Formation.keys()[v]),
		},
		{
			"label": func() -> String:
				var m := _swarm_manager()
				var left: float = m.backup_cooldown_left() if m != null else 0.0
				return "CALL BACKUP" if left <= 0.0 else "CALL BACKUP (%ds)" % ceili(left),
			"kind": "action",
			"action": func() -> void:
				var m := _swarm_manager()
				if m != null:
					m.call_backup(),
		},
		{
			"label": func() -> String:
				if _player == null:
					_player = get_tree().get_first_node_in_group("player_drone") as DroneController
				if _player == null:
					return "LOAD PAYLOAD"
				if _player.has_payload:
					return "DROP PAYLOAD"
				return "LOAD PAYLOAD" if _player.is_landed() else "LOAD PAYLOAD (land first)",
			"kind": "action",
			"action": func() -> void:
				if _player == null:
					_player = get_tree().get_first_node_in_group("player_drone") as DroneController
				if _player == null:
					return
				var h := _hud()
				if _player.has_payload:
					if _player.drop_payload() and h != null:
						h.log_line("payload dropped")
				elif _player.load_payload():
					if h != null:
						h.log_line("payload loaded")
				elif h != null:
					h.log_line("payload: land first"),
		},
		{
			"label": "HUD",
			"kind": "submenu",
			"entries": _build_hud_entries(),
		},
	]


## HUD submenu (P6.5 step 2): ON/OFF toggles for individually-hideable HUD
## elements. Player's DebugAxes also stands in for every follower's — one
## flip covers the whole swarm.
func _build_hud_entries() -> Array[Dictionary]:
	var toggle_options := func() -> Array: return ["ON", "OFF"]
	var out: Array[Dictionary] = [
		{
			"label": "LOG",
			"options": toggle_options,
			"getter": func() -> int:
				var h := _hud()
				return 0 if h != null and h.show_log else 1,
			"setter": func(v: int) -> void:
				var h := _hud()
				if h != null:
					h.show_log = (v == 0),
		},
		{
			"label": "TELEMETRY",
			"options": toggle_options,
			"getter": func() -> int:
				var h := _hud()
				return 0 if h != null and h.show_telemetry else 1,
			"setter": func(v: int) -> void:
				var h := _hud()
				if h != null:
					h.show_telemetry = (v == 0),
		},
		{
			"label": "WIND",
			"options": toggle_options,
			"getter": func() -> int:
				var h := _hud()
				return 0 if h != null and h.show_wind else 1,
			"setter": func(v: int) -> void:
				var h := _hud()
				if h != null:
					h.show_wind = (v == 0),
		},
		{
			"label": "MISSIONS",
			"options": toggle_options,
			"getter": func() -> int:
				var h := _hud()
				return 0 if h != null and h.show_missions else 1,
			"setter": func(v: int) -> void:
				var h := _hud()
				if h != null:
					h.show_missions = (v == 0),
		},
		{
			"label": "AXES",
			"options": toggle_options,
			"getter": func() -> int:
				return 0 if _player_axes_visible() else 1,
			"setter": func(v: int) -> void:
				_set_all_axes_visible(v == 0),
		},
		{
			"label": "GIZMO",
			"options": toggle_options,
			"getter": func() -> int:
				var h := _hud()
				return 0 if h != null and h.show_gizmo else 1,
			"setter": func(v: int) -> void:
				var h := _hud()
				if h != null:
					h.show_gizmo = (v == 0),
		},
		{
			"label": "ATTITUDE",
			"options": toggle_options,
			"getter": func() -> int:
				var h := _hud()
				return 0 if h != null and h.show_attitude else 1,
			"setter": func(v: int) -> void:
				var h := _hud()
				if h != null:
					h.show_attitude = (v == 0),
		},
		{
			"label": "PROP DBG",
			"options": toggle_options,
			"getter": func() -> int:
				if _player == null:
					_player = get_tree().get_first_node_in_group("player_drone") as DroneController
				return 0 if _player != null and _player.show_prop_debug else 1,
			"setter": func(v: int) -> void:
				if _player == null:
					_player = get_tree().get_first_node_in_group("player_drone") as DroneController
				if _player != null:
					_player.show_prop_debug = (v == 0),
		},
	]
	return out


func _player_axes_visible() -> bool:
	if _player == null:
		_player = get_tree().get_first_node_in_group("player_drone") as DroneController
	var axes := _player.get_node_or_null("DebugAxes") if _player != null else null
	return axes == null or axes.visible


## ponytail: backups spawned after toggling AXES get default-on axes — reapply
## from here on backup spawn if that ever grates.
func _set_all_axes_visible(on: bool) -> void:
	if _player == null:
		_player = get_tree().get_first_node_in_group("player_drone") as DroneController
	if _player != null:
		var paxes := _player.get_node_or_null("DebugAxes")
		if paxes != null:
			paxes.visible = on
	for d in get_tree().get_nodes_in_group("drone"):
		var axes := (d as Node).get_node_or_null("DebugAxes")
		if axes != null:
			axes.visible = on


func _hud() -> Node:
	if not _hud_searched:
		_hud_searched = true
		_hud_node = get_tree().get_first_node_in_group("debug_hud")
	return _hud_node


func _unhandled_input(event: InputEvent) -> void:
	if not event.is_pressed() or event.is_echo():
		return
	if _player_crashed():
		if is_open:
			_abort()
		return
	if not is_open:
		if event.is_action_pressed("menu_open") \
				or event.is_action_pressed("menu_left") \
				or event.is_action_pressed("menu_right"):
			_open()
			get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed("menu_up"):
		_navigate(-1)
	elif event.is_action_pressed("menu_down"):
		_navigate(1)
	elif event.is_action_pressed("menu_left"):
		_cycle(-1)
	elif event.is_action_pressed("menu_right"):
		_cycle(1)
	elif event.is_action_pressed("menu_confirm"):
		_apply_and_close()
	elif event.is_action_pressed("menu_back"):
		_abort()
	else:
		return
	get_viewport().set_input_as_handled()


func _process(delta: float) -> void:
	if is_open:
		_refresh()  # live labels: cooldown countdown, land/take-off toggle
		return
	# Menu closed: dpad up/down sweeps the FPV camera tilt.
	var cam := get_viewport().get_camera_3d() as ChaseCamera
	var sweep := Input.get_action_strength("menu_up") - Input.get_action_strength("menu_down")
	if sweep != 0.0 and cam != null and not _player_crashed():
		cam.fpv_pitch_deg = clampf(cam.fpv_pitch_deg + sweep * fpv_pitch_rate * delta,
				-30.0, 60.0)
	_hint.text = "◀▶ menu    ▲▼ cam tilt %+.0f°" % (cam.fpv_pitch_deg if cam != null else 0.0)


# --- Menu state machine (pure, unit-tested without input events) ---

func _open() -> void:
	staged.clear()
	for e in entries:
		staged.append((e.getter as Callable).call() if e.has("getter") else 0)
	selected = 0
	is_open = true
	_panel.visible = true
	_hint.visible = false
	_sync_rows()
	_refresh()


func _navigate(dir: int) -> void:
	if entries.is_empty():
		return
	selected = wrapi(selected + dir, 0, entries.size())
	_refresh()


## Cycle the selected entry's staged value — nothing applies until confirm.
## No-op on entries with no value (action / submenu / back).
func _cycle(dir: int) -> void:
	if entries.is_empty() or not entries[selected].has("setter"):
		return
	var options: Array = (entries[selected].options as Callable).call()
	staged[selected] = wrapi(staged[selected] + dir, 0, options.size())
	_refresh()


## Cross: descend into a submenu, apply-and-pop out of one via BACK, or apply
## the current level's staged values and (action → fire it, then) close.
func _apply_and_close() -> void:
	if entries.is_empty():
		_close()
		return
	var e: Dictionary = entries[selected]
	var kind: String = e.get("kind", "")
	if kind == "submenu":
		_enter_submenu(e.entries)
		return
	_apply_staged()
	if kind == "back":
		_exit_submenu()
		return
	if kind == "action":
		(e.action as Callable).call()
	_close()


func _apply_staged() -> void:
	for i in entries.size():
		if entries[i].has("setter"):
			(entries[i].setter as Callable).call(staged[i])


## Push the current level and switch to `sub_entries` (a BACK entry is
## auto-appended so every submenu can pop back without defining one).
func _enter_submenu(sub_entries: Array) -> void:
	_stack.append({"entries": entries, "staged": staged, "selected": selected})
	var next: Array[Dictionary] = []
	for e in sub_entries:
		next.append(e)
	next.append({"label": "BACK", "kind": "back"})
	entries = next
	staged = []
	for e in entries:
		staged.append((e.getter as Callable).call() if e.has("getter") else 0)
	selected = 0
	_sync_rows()
	_refresh()


func _exit_submenu() -> void:
	if _stack.is_empty():
		return
	var frame: Dictionary = _stack.pop_back()
	entries = frame.entries
	staged = frame.staged
	selected = frame.selected
	_sync_rows()
	_refresh()


## Circle: abort the current level's staged changes; any submenu descent is
## unwound back to the root level (its own BACK/Cross already applied whatever
## the player confirmed on the way in).
func _abort() -> void:
	_close()


func _close() -> void:
	while not _stack.is_empty():
		var frame: Dictionary = _stack.pop_back()
		entries = frame.entries
	is_open = false
	_panel.visible = false
	_hint.visible = true


func _player_crashed() -> bool:
	if _player == null:
		_player = get_tree().get_first_node_in_group("player_drone") as DroneController
	return _player != null and _player.is_crashed()


func _swarm_manager() -> SwarmManager:
	if not _manager_searched:
		_manager_searched = true
		_manager = get_tree().get_first_node_in_group("swarm_manager")
	return _manager as SwarmManager


# --- UI (hand-built Controls, debug_hud style, lower-left corner) ---

func _build_ui() -> void:
	var height := 64.0 + entries.size() * 24.0
	_panel = ColorRect.new()
	_panel.color = HUDTheme.PANEL  # same panel black as the HUD
	_panel.anchor_left = 0.0
	_panel.anchor_top = 1.0
	_panel.anchor_right = 0.0
	_panel.anchor_bottom = 1.0
	_panel.offset_left = 12
	_panel.offset_right = 252
	_panel.offset_top = -12.0 - height
	_panel.offset_bottom = -12
	_panel.visible = false
	add_child(_panel)

	# Bracketed green header, matching the telemetry / objectives panel titles.
	var title := Label.new()
	title.text = "=== SWARM COMMAND ==="
	title.position = Vector2(10, 6)
	title.add_theme_font_size_override("font_size", 13)
	title.add_theme_color_override("font_color", HUDTheme.TEXT)
	title.add_theme_color_override("font_outline_color", HUDTheme.OUTLINE)
	title.add_theme_constant_override("outline_size", 2)
	_panel.add_child(title)

	for i in entries.size():
		var row := Label.new()
		row.position = Vector2(10, 28 + i * 24)
		row.add_theme_font_size_override("font_size", 14)
		_panel.add_child(row)
		_rows.append(row)

	_legend = Label.new()
	_legend.text = "▲▼ select  ◀▶ change  ✕ apply/enter  ○ abort"
	_legend.position = Vector2(10, 28 + entries.size() * 24 + 8)
	_legend.add_theme_font_size_override("font_size", 10)
	_legend.add_theme_color_override("font_color", Color(HUDTheme.TEXT.r, HUDTheme.TEXT.g, HUDTheme.TEXT.b, 0.5))
	_panel.add_child(_legend)

	# Closed-state hint line, same corner the panel opens in.
	_hint = Label.new()
	_hint.anchor_left = 0.0
	_hint.anchor_top = 1.0
	_hint.anchor_right = 0.0
	_hint.anchor_bottom = 1.0
	_hint.offset_left = 14
	_hint.offset_top = -30
	_hint.offset_right = 320
	_hint.offset_bottom = -10
	_hint.add_theme_font_size_override("font_size", 11)
	_hint.add_theme_color_override("font_color", Color(HUDTheme.TEXT.r, HUDTheme.TEXT.g, HUDTheme.TEXT.b, 0.55))
	add_child(_hint)


func _refresh() -> void:
	# mini() guard: tests inject entries after _ready without rebuilding rows.
	for i in mini(entries.size(), _rows.size()):
		var e := entries[i]
		var cursor: String = "▶" if i == selected else " "
		# Labels may be a Callable for live text (cooldown countdown, toggles).
		var label: String = (e.label as Callable).call() if e.label is Callable else e.label
		if e.has("setter"):
			var options: Array = (e.options as Callable).call()
			var current: int = (e.getter as Callable).call()
			var name_s: String = str(options[staged[i]])
			if staged[i] != current:
				name_s += " *"  # staged, not yet applied
			_rows[i].text = "%s %s   ◀ %s ▶" % [cursor, e.label, name_s]
		elif e.get("kind", "") == "submenu":
			_rows[i].text = "%s %s   ▶▶" % [cursor, label]
		else:
			_rows[i].text = "%s %s" % [cursor, label]
		_rows[i].add_theme_color_override("font_color",
				HUDTheme.ACCENT if i == selected else Color(HUDTheme.TEXT.r, HUDTheme.TEXT.g, HUDTheme.TEXT.b, 0.85))


## Grow the row pool and panel/legend geometry to fit the current level's
## entry count — submenus can be a different length than the root menu.
func _sync_rows() -> void:
	while _rows.size() < entries.size():
		var row := Label.new()
		row.add_theme_font_size_override("font_size", 14)
		_panel.add_child(row)
		_rows.append(row)
	for i in _rows.size():
		_rows[i].visible = i < entries.size()
		if i < entries.size():
			_rows[i].position = Vector2(10, 28 + i * 24)
	var height := 64.0 + entries.size() * 24.0
	_panel.offset_top = -12.0 - height
	if _legend != null:
		_legend.position = Vector2(10, 28 + entries.size() * 24 + 8)
