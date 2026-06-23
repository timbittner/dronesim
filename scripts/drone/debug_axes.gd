class_name DebugAxes
extends Node3D

## Draws colored axis vectors on the drone to visualize orientation.
## Red   = +X (right)
## Green = +Y (up)
## Blue  = -Z (forward)
##
## Uses three MeshInstance3D nodes with thin boxes, updated every _process
## frame to follow the parent drone's orientation (though since this is a
## child of the drone, the local axes are inherently correct — we just need
## the meshes to exist in local space).

@export var axis_length: float = 0.2
@export var axis_thickness: float = 0.008

var _x_axis: MeshInstance3D  # Red   - right
var _y_axis: MeshInstance3D  # Green - up
var _z_axis: MeshInstance3D  # Blue  - forward (-Z)

func _ready() -> void:
	_x_axis = _create_axis_box("X_Axis", Color.RED, Vector3.RIGHT)
	_y_axis = _create_axis_box("Y_Axis", Color.GREEN, Vector3.UP)
	_z_axis = _create_axis_box("Z_Axis", Color.BLUE, Vector3.FORWARD)  # Vector3.FORWARD = (0,0,-1) = forward

func _create_axis_box(node_name: String, color: Color, direction: Vector3) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = node_name

	var box := BoxMesh.new()
	# Long along the axis direction, thin in the other two dimensions
	# We'll orient it by rotating the MeshInstance3D so the box's X axis
	# (its longest dimension) aligns with the desired direction.
	box.size = Vector3(axis_length, axis_thickness, axis_thickness)

	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = 0.8
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.no_depth_test = false

	mi.mesh = box
	mi.material_override = mat

	# Position the box so its center is at half_length along the direction
	# (so it starts at origin and extends outward).
	mi.transform = _align_to_direction(direction)

	add_child(mi)
	return mi

func _align_to_direction(direction: Vector3) -> Transform3D:
	## Returns a Transform3D that positions and rotates a box (whose long axis
	## is along its local X) so that local X aligns with `direction`, and the
	## box center sits at half_length along that direction.
	var half_len := axis_length * 0.5

	# Default box long axis is +X. We need to rotate so X maps to `direction`.
	# Use looking_at with up hint to build a basis.
	# We want the X axis to point along `direction`.
	# Construct basis: x = direction.normalized(), choose y and z perpendicular.
	var dir := direction.normalized()
	var up_hint := Vector3.UP
	# If dir is parallel to up_hint, use a different hint
	if absf(dir.dot(up_hint)) > 0.99:
		up_hint = Vector3.FORWARD

	var z_axis := dir.cross(up_hint).normalized()
	var y_axis := z_axis.cross(dir).normalized()

	var b := Basis(dir, y_axis, z_axis)
	# Position center at half_len along direction (in local space)
	var origin := dir * half_len
	return Transform3D(b, origin)
