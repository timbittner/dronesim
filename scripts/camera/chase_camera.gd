class_name ChaseCamera
extends Camera3D

## Chase camera that follows the drone.
## FPV: camera position rigidly locked to drone nose (no drift). Camera
##       rotation is smoothed via quaternion slerp to mask control-loop
##       jitter without the position-drift bugs of a full spring arm.
## Chase: follows behind based on drone yaw only, looks directly at drone.

## Explicit drone override; empty = lazily resolve group "player_drone" (P6).
@export var target_path: NodePath = ""
@export var chase_distance: float = 2.2
@export var chase_height: float = 0.9
@export var follow_speed: float = 8.0
## Mousewheel zoom bounds for the 3PV chase distance.
@export var chase_distance_min: float = 1.2
@export var chase_distance_max: float = 18.0

## FPV rotation smoothing factor (0..1). Higher = more smoothing.
## 0.92 means the camera covers 92% of the gap per frame — ~4 frames to settle.
## This filters out high-frequency control-loop jitter while remaining responsive.
@export var fpv_smoothing: float = 0.92

var _target: Node3D
var _fpv: bool = false  # 3PV by default
var _drone_controller: DroneController


func _ready() -> void:
	if not target_path.is_empty():
		_set_target(get_node(target_path))
	fov = 90.0  # FPV fov


func _set_target(node: Node) -> void:
	_target = node as Node3D
	_drone_controller = _target as DroneController
	if _drone_controller:
		_drone_controller.fpv_toggled.connect(_on_fpv_toggled)


## Mousewheel zooms the 3PV chase distance (multiplicative steps so it feels
## even across the whole range). No effect in FPV.
func _unhandled_input(event: InputEvent) -> void:
	if _fpv or not event is InputEventMouseButton or not event.pressed:
		return
	var mb := event as InputEventMouseButton
	if mb.button_index == MOUSE_BUTTON_WHEEL_UP:
		chase_distance = clampf(chase_distance * 0.9, chase_distance_min, chase_distance_max)
	elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		chase_distance = clampf(chase_distance / 0.9, chase_distance_min, chase_distance_max)


func _physics_process(delta: float) -> void:
	if _target == null:
		# Lazy player-drone discovery, same pattern as WindField consumers.
		_set_target(get_tree().get_first_node_in_group("player_drone"))
		if _target == null:
			return

	if _fpv:
		_update_fpv(delta)
	else:
		_update_chase(delta)


func _update_fpv(delta: float) -> void:
	# Position: rigidly locked to drone nose — no lerp, no drift.
	var fpv_offset: Vector3 = _target.global_transform.basis * Vector3(0, 0.02, -0.28)
	global_position = _target.global_position + fpv_offset

	# Rotation: smoothed via quaternion slerp to mask control-loop jitter.
	# The position is rigid, so there's no drift bug.
	var target_quat: Quaternion = _target.global_transform.basis.get_rotation_quaternion()
	var current_quat: Quaternion = global_transform.basis.get_rotation_quaternion()
	# Use delta-adjusted lerp for frame-rate independence
	var lerp_factor: float = 1.0 - pow(1.0 - fpv_smoothing, 60.0 * delta)
	var smoothed: Quaternion = current_quat.slerp(target_quat, lerp_factor)
	global_transform.basis = Basis(smoothed)


func _update_chase(delta: float) -> void:
	# Chase: follow behind the drone based on yaw only (ignore pitch/roll tilt).
	var drone_yaw: float = _target.global_rotation.y
	var offset_dir: Vector3 = Vector3(sin(drone_yaw), 0, cos(drone_yaw))
	var target_pos: Vector3 = _target.global_position + Vector3(0, chase_height, 0) + offset_dir * chase_distance
	global_position = global_position.lerp(target_pos, follow_speed * delta)
	# Look directly at the drone - no look lerping
	look_at(_target.global_position, Vector3.UP)


func _on_fpv_toggled(enabled: bool) -> void:
	_fpv = enabled
	fov = 90.0 if enabled else 70.0
