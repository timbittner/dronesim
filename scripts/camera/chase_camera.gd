class_name ChaseCamera
extends Camera3D

## Chase camera that follows the drone.
## FPV: rigidly locked to drone - no lerp, no lag.
## Chase: follows behind based on drone yaw only, looks directly at drone.

@export var target_path: NodePath = ""  # Set to the drone node
@export var chase_distance: float = 4.0
@export var chase_height: float = 1.5
@export var follow_speed: float = 8.0

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
		_update_fpv()
	else:
		_update_chase(delta)


func _update_fpv() -> void:
	# FPV: camera is rigidly locked to the drone. No lerp, no lag.
	# Drone forward is -Z (arrow nose), Camera3D also looks down -Z by default.
	# Camera sits at the nose tip so the body doesn't obstruct the view.
	var fpv_offset: Vector3 = _target.global_transform.basis * Vector3(0, 0.02, -0.28)
	global_position = _target.global_position + fpv_offset
	global_transform.basis = _target.global_transform.basis


func _update_chase(delta: float) -> void:
	# Chase: follow behind the drone based on yaw only (ignore pitch/roll tilt).
	# Drone forward is -Z, so behind = +Z direction.
	var drone_yaw: float = _target.global_rotation.y
	var offset_dir: Vector3 = Vector3(sin(drone_yaw), 0, cos(drone_yaw))
	var target_pos: Vector3 = _target.global_position + Vector3(0, chase_height, 0) + offset_dir * chase_distance
	global_position = global_position.lerp(target_pos, follow_speed * delta)
	# Look directly at the drone - no look lerping
	look_at(_target.global_position, Vector3.UP)


func _on_fpv_toggled(enabled: bool) -> void:
	_fpv = enabled
	fov = 90.0 if enabled else 70.0
