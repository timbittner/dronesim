class_name ChaseCamera
extends Camera3D

## Chase camera that follows the drone.
## FPV: camera position rigidly locked to drone nose (no drift). Camera
##       rotation is smoothed via quaternion slerp to mask control-loop
##       jitter without the position-drift bugs of a full spring arm.
## Chase: follows behind based on drone yaw only, looks directly at drone.

@export var target_path: NodePath = ""  # Set to the drone node
@export var chase_distance: float = 4.0
@export var chase_height: float = 1.5
@export var follow_speed: float = 8.0

## FPV rotation smoothing factor (0..1). Higher = more smoothing.
## 0.92 means the camera covers 92% of the gap per frame — ~4 frames to settle.
## This filters out high-frequency control-loop jitter while remaining responsive.
@export var fpv_smoothing: float = 0.92

var _target: Node3D
var _fpv: bool = true  # FPV by default
var _drone_controller: DroneController


func _ready() -> void:
	if not target_path.is_empty():
		_target = get_node(target_path)
	if _target:
		_drone_controller = _target as DroneController
		if _drone_controller:
			_drone_controller.fpv_toggled.connect(_on_fpv_toggled)
	fov = 90.0  # FPV fov


func _physics_process(delta: float) -> void:
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
