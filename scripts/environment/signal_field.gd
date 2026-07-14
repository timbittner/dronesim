class_name SignalField
extends Node3D

## Radio signal quality field (P5). Environment-side node like WindField:
## lives in main.tscn, self-registers into group "signal_field", resolved
## lazily by DroneController. No SignalField in a scene = perfect signal.
##
## get_quality(pos) returns 0..1, degraded by two sources:
## - the map-boundary belt: ramps 1 to 0 across boundary_margin meters outside
##   the terrain's get_bounds() rect (duck-typed; no bounds = no belt);
## - jamming nodes (group "jammers", each exposing radius + strength) with a
##   smooth falloff. A jammer may instead expose signal_quality_at(pos) for a
##   non-circular shape (e.g. a rectangular NoFlyZone). Sources combine by
##   taking the minimum.
## Consumers: FPV static intensity, control packet loss, and sustained-zero
## signal loss (DroneController / DebugHUD).

@export var terrain_path: NodePath = NodePath("../Terrain")
## Width of the belt across which quality ramps 1 -> 0, measured from
## boundary_inset meters inside the map edge.
@export var boundary_margin: float = 150.0
## Degradation starts this far INSIDE the map edge, so the belt (and its fog)
## kicks in before the player can see the terrain's clean cut-off.
@export var boundary_inset: float = 50.0
## Existing scene fog doubles as the belt's "fog wall": its density ramps from
## the Environment's own base value up to this as the camera's signal quality
## drops. Free — the Environment already renders exponential distance fog.
@export var edge_fog_max_density: float = 0.02
@export var environment_path: NodePath = NodePath("../WorldEnvironment")

var _has_bounds: bool = false
var _bounds: Rect2
var _env: Environment = null
var _base_fog_density: float = 0.0


func _ready() -> void:
	add_to_group("signal_field")
	var terrain := get_node_or_null(terrain_path)
	if terrain != null and terrain.has_method("get_bounds"):
		_bounds = (terrain.get_bounds() as Rect2).grow(-boundary_inset)
		_has_bounds = true
	var we := get_node_or_null(environment_path) as WorldEnvironment
	if we != null and we.environment != null:
		_env = we.environment
		_base_fog_density = _env.fog_density


func _process(_delta: float) -> void:
	if _env == null:
		return
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	_env.fog_density = lerpf(
		edge_fog_max_density, _base_fog_density, get_quality(cam.global_position))


## Signal quality 0..1 at a world position (1 = perfect link).
func get_quality(pos: Vector3) -> float:
	var q := _boundary_quality(pos)
	# ponytail: linear scan over jammers — a few distance checks per tick beats
	# Area3D broadphase + event bookkeeping; spatial grid if count hits hundreds.
	for jammer in get_tree().get_nodes_in_group("jammers"):
		if jammer.has_method("signal_quality_at"):
			q = minf(q, jammer.signal_quality_at(pos))
		else:
			q = minf(q, _jammer_quality(jammer, pos))
	return q


func _boundary_quality(pos: Vector3) -> float:
	if not _has_bounds:
		return 1.0
	var p := Vector2(pos.x, pos.z)
	var outside := p.distance_to(p.clamp(_bounds.position, _bounds.end))
	return clampf(1.0 - outside / boundary_margin, 0.0, 1.0)


func _jammer_quality(jammer: Node, pos: Vector3) -> float:
	var dist: float = jammer.global_position.distance_to(pos)
	# Full `strength` reduction at the jammer, fading smoothly to none at radius.
	return 1.0 - jammer.strength * (1.0 - smoothstep(0.0, jammer.radius, dist))
