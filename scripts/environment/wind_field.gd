class_name WindField
extends Node3D

## Terrain-aware prevailing wind field (P2 Phase D). Environment-side, like
## CrashEffects — not an autoload. Self-registers into group "wind_field";
## DroneController discovers it lazily and samples get_wind() as a relative-
## airspeed drag input (see drone_controller.gd). No WindField in a scene
## (e.g. the flight-mode test scene) simply means zero wind everywhere.

## Heading the wind blows TOWARD, in degrees. 0° = −Z (matches the project's
## forward convention), 90° = +X — i.e. compass-style, clockwise from −Z.
@export var wind_direction_deg: float = 70.0
@export var base_speed: float = 6.0
## Altitude (AGL) above which terrain stops influencing the wind at all.
@export var boundary_layer_height: float = 35.0
## Fraction of base_speed retained right at ground level (before shelter/ridge).
@export var ground_wind_fraction: float = 0.35
## How strongly a sheltering ridge cuts wind speed in its lee (0..1).
@export var shelter_strength: float = 0.95
## Upwind crests within this elevation angle of a query point cast "shadow".
@export var shadow_angle_deg: float = 22.0
## Distances (m) upwind to sample for sheltering crests.
@export var upwind_sample_distances: Array[float] = [15.0, 35.0, 65.0]
## How strongly wind steers horizontally away from windward slopes.
@export var deflection_strength: float = 1.2
## How strongly windward slopes divert horizontal wind into an updraft.
@export var updraft_strength: float = 0.6
## How much taller terrain (relative to ridge_reference_height) speeds up wind.
@export var ridge_boost: float = 0.35
@export var ridge_reference_height: float = 12.0
## Gust strength as a fraction of speed.
@export var turbulence_strength: float = 0.25
@export var turbulence_frequency: float = 0.15
@export var gust_spatial_scale: float = 0.02
## Prevailing direction wobble amplitude.
@export var direction_wobble_deg: float = 12.0
## Protected calm zone around the origin (spawn pad), independent of terrain.
@export var calm_radius: float = 18.0
@export var calm_falloff: float = 12.0
@export var noise_seed: int = 7

@export var terrain_path: NodePath = NodePath("../Terrain")

var _terrain: Node = null
var _gust_noise: FastNoiseLite
var _dir_noise: FastNoiseLite
var _time: float = 0.0


func _ready() -> void:
	add_to_group("wind_field")
	_terrain = get_node_or_null(terrain_path)
	_ensure_noise()


func _physics_process(delta: float) -> void:
	_time += delta


## Noise setup is independent of the scene tree (unlike _ready()), so a bare
## WindField.new() used directly in tests (never added to a tree) still works.
func _ensure_noise() -> void:
	if _gust_noise != null:
		return
	_gust_noise = FastNoiseLite.new()
	_gust_noise.seed = noise_seed
	_gust_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_gust_noise.fractal_octaves = 2

	_dir_noise = FastNoiseLite.new()
	_dir_noise.seed = noise_seed + 1
	_dir_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_dir_noise.fractal_octaves = 1


## World-space wind velocity (m/s) at `pos`. Duck-types the terrain node on
## get_height(x, z) so it degrades to flat ground (0.0) with no Terrain node.
func get_wind(pos: Vector3) -> Vector3:
	_ensure_noise()
	var spawn_t := smoothstep(calm_radius, calm_radius + calm_falloff, pos.length())
	if spawn_t <= 0.0:
		return Vector3.ZERO

	var ground_h := _terrain_height(pos.x, pos.z)
	var agl := pos.y - ground_h
	var t := clampf(agl / boundary_layer_height, 0.0, 1.0)
	var speed := base_speed * lerpf(ground_wind_fraction, 1.0, t)
	var terrain_influence := 1.0 - t

	# Gusts.
	speed *= 1.0 + turbulence_strength * _gust_noise.get_noise_3d(
		pos.x * gust_spatial_scale, pos.z * gust_spatial_scale, _time * turbulence_frequency
	)

	# Shelter: check for upwind crests casting a wind "shadow" over pos.
	var dir_h := _prevailing_dir_h(pos)
	var shelter := 0.0
	var shadow_tan := tan(deg_to_rad(shadow_angle_deg))
	for d in upwind_sample_distances:
		var upwind_pos := Vector2(pos.x, pos.z) - dir_h * d
		var h_upwind := _terrain_height(upwind_pos.x, upwind_pos.y)
		var candidate := clampf((h_upwind - pos.y) / (d * shadow_tan), 0.0, 1.0)
		shelter = maxf(shelter, candidate)
	shelter *= terrain_influence
	speed *= 1.0 - shelter_strength * shelter

	# Ridge boost: higher ground (that isn't itself sheltered) speeds wind up.
	speed *= 1.0 + ridge_boost * clampf(ground_h / ridge_reference_height, 0.0, 1.0) \
			* (1.0 - shelter) * terrain_influence

	# Direction: deflect around windward slopes, preserving magnitude, plus an
	# updraft component proportional to how "into the slope" the wind blows.
	var step := 4.0
	var h_e := _terrain_height(pos.x + step, pos.z)
	var h_w := _terrain_height(pos.x - step, pos.z)
	var h_s := _terrain_height(pos.x, pos.z + step)
	var h_n := _terrain_height(pos.x, pos.z - step)
	var grad := Vector2((h_e - h_w) / (2.0 * step), (h_s - h_n) / (2.0 * step))
	var updraft := 0.0
	if grad.length() > 0.0001:
		var grad_norm := grad.normalized()
		var windward := dir_h.dot(grad_norm)
		if windward > 0.0:
			var along := grad_norm * windward
			var away_raw := dir_h - along
			var away := away_raw.normalized() if away_raw.length() > 0.0001 else dir_h
			var deflect_amount := clampf(windward * deflection_strength, 0.0, 1.0)
			dir_h = dir_h.lerp(away, deflect_amount).normalized()
			updraft = windward * updraft_strength * speed * terrain_influence

	var wind := Vector3(dir_h.x, 0.0, dir_h.y) * speed
	wind.y += updraft
	return wind * spawn_t


## Prevailing horizontal wind direction (unit vector, XZ as (x, z)) at `pos`,
## with a slow spatial+temporal wobble around the base heading.
func _prevailing_dir_h(pos: Vector3) -> Vector2:
	var wobble_noise := _dir_noise.get_noise_3d(
		pos.x * gust_spatial_scale, pos.z * gust_spatial_scale, _time * turbulence_frequency
	)
	var heading := wind_direction_deg + direction_wobble_deg * wobble_noise
	var rad := deg_to_rad(heading)
	return Vector2(sin(rad), -cos(rad))


func _terrain_height(x: float, z: float) -> float:
	if _terrain != null and _terrain.has_method("get_height"):
		return _terrain.get_height(x, z)
	return 0.0
