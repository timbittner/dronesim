class_name MockHillTerrain
extends Node3D

## Deterministic terrain stand-in for wind_field_test.gd: a single 12m
## Gaussian hill centered at (60, 0), flat everywhere else. Duck-typed against
## the same get_height(x, z) API as TerrainGenerator.

## Terrain height at (x, z): the Gaussian hill near (60, 0), else ~0.
func get_height(x: float, z: float) -> float:
	var dx := x - 60.0
	var dz := z
	return 12.0 * exp(-(dx * dx + dz * dz) / 200.0)
