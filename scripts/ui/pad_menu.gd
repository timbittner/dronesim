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
## Entries are data, two kinds:
## - cycle: {label, options: Callable -> Array of names, getter: Callable ->
##   int, setter: Callable(int)} — left/right stages a value, Cross applies.
## - action: {label, kind: "action", action: Callable} — Cross fires it (only
##   the SELECTED action) and closes; left/right does nothing on it.
## Later features (targeting mode, payload) extend this array.

## Degrees per second of FPV tilt sweep while holding dpad up/down.
@export var fpv_pitch_rate: float = 30.0

var is_open: bool = false
var selected: int = 0
## {label: String, options: Callable, getter: Callable, setter: Callable}
var entries: Array[Dictionary] = []
## Staged (not yet applied) option index per entry, valid while open.
var staged: Array[int] = []

var _panel: ColorRect
var _rows: Array[Label] = []
var _hint: Label
var _player: DroneController = null
var _manager: Node = null
var _manager_searched: bool = false


func _ready() -> void:
	layer = 2  # above the DebugHUD layer
	_build_entries()
	_build_ui()


func _build_entries() -> void:
	entries = [
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
		# ponytail: stubs — real behaviors land in P6 step 4 (auto-land,
		# recall); until then they only prove out the menu navigation.
		{
			"label": "AUTO-LAND",
			"kind": "action",
			"action": func() -> void: print("[Swarm] AUTO-LAND (stub — step 4)"),
		},
		{
			"label": "RECALL",
			"kind": "action",
			"action": func() -> void: print("[Swarm] RECALL (stub — step 4)"),
		},
	]


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
		staged.append(0 if _is_action(e) else (e.getter as Callable).call())
	selected = 0
	is_open = true
	_panel.visible = true
	_hint.visible = false
	_refresh()


func _navigate(dir: int) -> void:
	if entries.is_empty():
		return
	selected = wrapi(selected + dir, 0, entries.size())
	_refresh()


## Cycle the selected entry's staged value — nothing applies until confirm.
## No-op on action entries (they have no value to cycle).
func _cycle(dir: int) -> void:
	if entries.is_empty() or _is_action(entries[selected]):
		return
	var options: Array = (entries[selected].options as Callable).call()
	staged[selected] = wrapi(staged[selected] + dir, 0, options.size())
	_refresh()


## Cross: apply every staged value change, fire the selected entry if it is
## an action, then close.
func _apply_and_close() -> void:
	for i in entries.size():
		if not _is_action(entries[i]):
			(entries[i].setter as Callable).call(staged[i])
	if not entries.is_empty() and _is_action(entries[selected]):
		(entries[selected].action as Callable).call()
	_close()


func _is_action(e: Dictionary) -> bool:
	return e.get("kind", "") == "action"


## Circle: close, staged changes discarded.
func _abort() -> void:
	_close()


func _close() -> void:
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
	_panel.color = Color(0.0, 0.0, 0.0, 0.65)  # same panel black as the HUD
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

	var title := Label.new()
	title.text = "SWARM COMMAND"
	title.position = Vector2(10, 6)
	title.add_theme_font_size_override("font_size", 13)
	title.add_theme_color_override("font_color", Color(0.35, 1.0, 0.35))
	_panel.add_child(title)

	for i in entries.size():
		var row := Label.new()
		row.position = Vector2(10, 28 + i * 24)
		row.add_theme_font_size_override("font_size", 14)
		_panel.add_child(row)
		_rows.append(row)

	var legend := Label.new()
	legend.text = "▲▼ select  ◀▶ change  ✕ apply  ○ abort"
	legend.position = Vector2(10, 28 + entries.size() * 24 + 8)
	legend.add_theme_font_size_override("font_size", 10)
	legend.add_theme_color_override("font_color", Color(0.35, 1.0, 0.35, 0.5))
	_panel.add_child(legend)

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
	_hint.add_theme_color_override("font_color", Color(0.35, 1.0, 0.35, 0.55))
	add_child(_hint)


func _refresh() -> void:
	# mini() guard: tests inject entries after _ready without rebuilding rows.
	for i in mini(entries.size(), _rows.size()):
		var e := entries[i]
		var cursor: String = "▶" if i == selected else " "
		if _is_action(e):
			_rows[i].text = "%s %s" % [cursor, e.label]
		else:
			var options: Array = (e.options as Callable).call()
			var current: int = (e.getter as Callable).call()
			var name_s: String = str(options[staged[i]])
			if staged[i] != current:
				name_s += " *"  # staged, not yet applied
			_rows[i].text = "%s %s   ◀ %s ▶" % [cursor, e.label, name_s]
		_rows[i].add_theme_color_override("font_color",
				Color(1.0, 0.72, 0.1) if i == selected else Color(0.35, 1.0, 0.35, 0.85))
