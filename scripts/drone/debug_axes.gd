@tool
class_name DebugAxes
extends Node3D

## Draws colored axis vectors on the drone to visualize orientation.
## Red   = +X (right)
## Green = +Y (up)
## Blue  = +Z (positive Z direction)
##
## Uses three MeshInstance3D nodes with thin boxes.

@export var axis_length: float = 0.2
@export var axis_thickness: float = 0.008

var _x_axis: MeshInstance3D  # Red   - right (+X)
var _y_axis: MeshInstance3D  # Green - up (+Y)
var _z_axis: MeshInstance3D  # Blue  - +Z

func _ready() -> void:
	_x_axis = _create_axis_box("X_Axis", Color.RED, Vector3.RIGHT)
	_y_axis = _create_axis_box("Y_Axis", Color.GREEN, Vector3.UP)
	_z_axis = _create_axis_box("Z_Axis", Color.BLUE, Vector3.BACK)  # Vector3.BACK = (0,0,1) = +Z

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

## Positions and rotates a box (long axis = local X) so X aligns with one of
## the three fixed world axes this is ever called with, centered at half_length
## along that axis. Basis rows are hardcoded per axis rather than derived via
## cross products, since RIGHT/UP/BACK are the only inputs.
func _align_to_direction(direction: Vector3) -> Transform3D:
	var half_len := axis_length * 0.5
	var b: Basis
	match direction:
		Vector3.RIGHT:
			b = Basis(Vector3.RIGHT, Vector3.UP, Vector3.BACK)
		Vector3.UP:
			b = Basis(Vector3.UP, Vector3.BACK, Vector3.RIGHT)
		Vector3.BACK:
			b = Basis(Vector3.BACK, Vector3.UP, Vector3.LEFT)
		_:
			b = Basis.IDENTITY
	return Transform3D(b, direction * half_len)
