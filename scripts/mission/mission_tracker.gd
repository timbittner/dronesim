class_name MissionTracker
extends Node

## Collects every MissionTarget in the scene (group "mission_targets") and fires
## mission_completed once they are all cleared (P5 Phase 6). Plain Node in
## main.tscn, same environment-side pattern as CrashEffects. The HUD resolves it
## via group "mission_tracker" and shows a MISSION SUCCESS banner off `completed`.
## No persistence — a fresh run just re-instances the scene.

signal mission_completed

## True once every target has been cleared (stays true for the run).
var completed: bool = false

var _total: int = 0
var _cleared_count: int = 0


func _ready() -> void:
	add_to_group("mission_tracker")
	# Targets register in their own _ready; defer a frame so the group is fully
	# populated before we count and wire up.
	call_deferred("_collect")


func _collect() -> void:
	var targets := get_tree().get_nodes_in_group("mission_targets")
	_total = targets.size()
	for t in targets:
		(t as MissionTarget).target_cleared.connect(_on_target_cleared)


func _on_target_cleared(_target: MissionTarget) -> void:
	_cleared_count += 1
	if not completed and _total > 0 and _cleared_count >= _total:
		completed = true
		mission_completed.emit()
		print("[Mission] ALL %d TARGETS CLEARED — mission complete" % _total)
