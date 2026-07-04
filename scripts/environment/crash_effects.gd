class_name CrashEffects
extends Node3D

## Environment-side crash effects, currently a dust burst at the impact point.
## Listens to the drone's crash_detected signal: the drone controller owns only
## the flight/crash logic (cutting rotors, ignoring inputs) — what the world
## does in response lives here.

var _dust: CPUParticles3D
## Drones whose crash_detected is already connected (P6: followers spawn at
## runtime, so the group is re-scanned each tick — a handful of nodes, cheap).
var _connected: Dictionary = {}


func _ready() -> void:
	_dust = _make_dust_cloud()
	add_child(_dust)


func _physics_process(_delta: float) -> void:
	for drone in get_tree().get_nodes_in_group("drone"):
		if not _connected.has(drone):
			_connected[drone] = true
			drone.crash_detected.connect(_on_crash_detected.bind(drone))


func _on_crash_detected(drone: DroneController) -> void:
	# crash_detected is emitted synchronously from the crash, so the drone is
	# still at the impact point.
	# ponytail: one shared dust node — simultaneous crashes share a burst;
	# per-drone emitters if that ever reads wrong.
	_dust.global_position = drone.global_position
	_dust.restart()


## One-shot dust burst: soft billboarded puffs, white-sand colored. The puffs
## kick out fast (~1.5s, high initial velocity against high damping coasts them
## to a stop at a ~5m radius), then the cloud hangs and slowly fades over
## ~10-13s. Emits in world space and the node is top_level, so the cloud stays
## at the impact point instead of following the tumbling wreck.
func _make_dust_cloud() -> CPUParticles3D:
	var p := CPUParticles3D.new()
	p.emitting = false
	p.one_shot = true
	p.explosiveness = 1.0
	p.amount = 64
	p.lifetime = 13.0
	p.lifetime_randomness = 0.25
	p.local_coords = false
	p.top_level = true
	p.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	p.emission_sphere_radius = 0.4
	p.direction = Vector3.UP
	p.spread = 85.0  # near-hemisphere: mostly outward, a little billow upward
	p.initial_velocity_min = 5.0
	p.initial_velocity_max = 9.0
	p.damping_min = 4.5  # stop distance v²/2d: ~3m (slow puffs) to ~6m (fast)
	p.damping_max = 7.0
	p.gravity = Vector3(0.0, -0.2, 0.0)  # dust hangs, settles only slightly
	p.scale_amount_min = 1.0
	p.scale_amount_max = 2.0
	# Billow up quickly while the puff expands, then keep growing gently.
	var grow := Curve.new()
	grow.add_point(Vector2(0.0, 0.35))
	grow.add_point(Vector2(0.2, 0.85))
	grow.add_point(Vector2(1.0, 1.0))
	p.scale_amount_curve = grow

	# White-sand tint: dense (80%) through the hang, fading out at the end.
	var sand := Color(0.87, 0.82, 0.7)
	var ramp := Gradient.new()
	ramp.set_color(0, Color(sand.r, sand.g, sand.b, 0.8))
	ramp.set_color(1, Color(sand.r, sand.g, sand.b, 0.0))
	ramp.add_point(0.6, Color(sand.r, sand.g, sand.b, 0.6))
	p.color_ramp = ramp

	# Soft circular puff: radial white→transparent gradient on a billboard quad.
	var tex_grad := Gradient.new()
	tex_grad.set_color(0, Color(1, 1, 1, 1))
	tex_grad.set_color(1, Color(1, 1, 1, 0))
	var tex := GradientTexture2D.new()
	tex.gradient = tex_grad
	tex.fill = GradientTexture2D.FILL_RADIAL
	tex.fill_from = Vector2(0.5, 0.5)
	tex.fill_to = Vector2(0.5, 0.0)
	tex.width = 64
	tex.height = 64

	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	mat.vertex_color_use_as_albedo = true
	mat.albedo_texture = tex

	var quad := QuadMesh.new()
	quad.size = Vector2(1.0, 1.0)
	quad.material = mat
	p.mesh = quad
	return p
