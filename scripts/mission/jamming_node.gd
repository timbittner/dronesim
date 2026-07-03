@tool
class_name JammingNode
extends Node3D

## Radio jammer (P5 Phase 7). Self-registers into group "jammers"; SignalField
## reads `strength` + `radius` and degrades signal quality within radius (full
## `strength` reduction at the center, smooth falloff to none at the rim), which
## feeds FPV static, control packet loss, and — if you loiter in a strong core —
## signal loss. Doubles as the backlog's no-fly-zone primitive.
##
## Visual is jammer.glb (a utility EW truck), instanced at runtime. @tool so it
## renders in the editor and ground-snaps as you drag it, same as MissionTarget;
## authored Y is irrelevant.

## Signal reduction at the jammer's center, 0..1 (1 = link fully dead at core).
@export_range(0.0, 1.0) var strength: float = 1.0
## Radius in meters over which the jamming fades to nothing.
@export var radius: float = 180.0
@export var terrain_path: NodePath = NodePath("../Terrain")

const _MODEL := preload("res://assets/models/jammer.glb")


func _ready() -> void:
	if get_node_or_null("Model") == null:
		var m := _MODEL.instantiate()
		m.name = "Model"
		add_child(m)  # runtime child, not owned -> not serialized into the scene
	_snap_to_ground()
	if Engine.is_editor_hint():
		set_notify_transform(true)
		return
	add_to_group("jammers")


func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSFORM_CHANGED and Engine.is_editor_hint():
		_snap_to_ground()


func _snap_to_ground() -> void:
	var terrain := get_node_or_null(terrain_path)
	if terrain == null or not terrain.has_method("get_height"):
		return
	var h: float = terrain.get_height(global_position.x, global_position.z)
	# Guard the write: setting global_position re-fires TRANSFORM_CHANGED.
	if absf(global_position.y - h) > 0.01:
		global_position.y = h
