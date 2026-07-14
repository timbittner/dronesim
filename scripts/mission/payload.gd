class_name Payload
extends RigidBody3D

## Droppable payload crate (P7.1). Spawned by DroneController.drop_payload();
## a DELIVER MissionTarget clears when one lands inside its radius — that
## consumer lands next commit, this script only tracks whether the crate has
## come to rest.

## True once the crate has come to rest (sustained contact + near-zero speed).
var landed: bool = false

const _MODEL := preload("res://assets/models/payload.glb")
## Matches the authored mesh (~0.24 x 0.15 x 0.23 m); code-built collision
## keeps payload.tscn minimal, same idiom as the drone's prop-debug meshes.
const _COLLISION_SIZE := Vector3(0.24, 0.15, 0.23)
const _LAND_SPEED_THRESHOLD := 0.5
const _LAND_SETTLE_TIME := 0.3
## Seconds after spawn before the drop-drone collision exception clears —
## long enough to clear the spawn overlap (see DroneController.drop_payload())
## without a physics pop.
const _EXCEPTION_CLEAR_TIME := 0.5

var _land_timer: float = 0.0
var _exception_timer: float = 0.0


func _ready() -> void:
	add_to_group("payloads")
	contact_monitor = true
	max_contacts_reported = 4

	var mesh_inst := _MODEL.instantiate()
	mesh_inst.name = "Model"
	add_child(mesh_inst)

	var shape := BoxShape3D.new()
	shape.size = _COLLISION_SIZE
	var cs := CollisionShape3D.new()
	cs.shape = shape
	add_child(cs)


func _physics_process(delta: float) -> void:
	if not landed:
		if get_contact_count() > 0 and linear_velocity.length() < _LAND_SPEED_THRESHOLD:
			_land_timer += delta
			if _land_timer >= _LAND_SETTLE_TIME:
				landed = true
				print("[Payload] landed")
		else:
			_land_timer = 0.0

	if _exception_timer < _EXCEPTION_CLEAR_TIME:
		_exception_timer += delta
		if _exception_timer >= _EXCEPTION_CLEAR_TIME:
			for body in get_collision_exceptions():
				remove_collision_exception_with(body)
