class_name DroneBodyMesh
extends MeshInstance3D

## Builds a simple, robust drone body from axis-aligned boxes so orientation is
## unambiguous at a glance:
##   - Flat fuselage box (the main body).
##   - A "nose beak" protruding forward (-Z): tells front from back.
##   - A vertical tail fin at the rear (+Z) sticking up: marks back AND up,
##     which fixes left/right by implication.
##
## Boxes are emitted with correct outward (CCW-from-outside) winding, so no
## faces get back-culled. Flat normals are generated before indexing so each
## facet stays crisply lit.

func _ready() -> void:
	mesh = _build_mesh()

func _build_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	# Fuselage: wide in X, flat in Y, medium in Z.
	_add_box(st, Vector3(0.0, 0.0, 0.0), Vector3(0.36, 0.10, 0.30))

	# Nose beak: narrow box protruding forward (-Z).
	_add_box(st, Vector3(0.0, 0.0, -0.22), Vector3(0.10, 0.06, 0.16))

	# Tail fin: thin vertical box at the rear (+Z), standing up.
	_add_box(st, Vector3(0.0, 0.09, 0.17), Vector3(0.04, 0.14, 0.06))

	st.generate_normals()
	st.index()
	return st.commit()

func _add_box(st: SurfaceTool, center: Vector3, size: Vector3) -> void:
	## Emits an axis-aligned box (12 triangles) with outward-facing normals.
	var h := size * 0.5
	# 8 corners
	var p000 := center + Vector3(-h.x, -h.y, -h.z)
	var p100 := center + Vector3( h.x, -h.y, -h.z)
	var p110 := center + Vector3( h.x,  h.y, -h.z)
	var p010 := center + Vector3(-h.x,  h.y, -h.z)
	var p001 := center + Vector3(-h.x, -h.y,  h.z)
	var p101 := center + Vector3( h.x, -h.y,  h.z)
	var p111 := center + Vector3( h.x,  h.y,  h.z)
	var p011 := center + Vector3(-h.x,  h.y,  h.z)

	# Each face wound CCW when viewed from outside.
	_quad(st, p010, p110, p100, p000)  # front  (-Z)
	_quad(st, p101, p111, p011, p001)  # back   (+Z)
	_quad(st, p011, p010, p000, p001)  # left   (-X)
	_quad(st, p110, p111, p101, p100)  # right  (+X)
	_quad(st, p010, p011, p111, p110)  # top    (+Y)
	_quad(st, p000, p100, p101, p001)  # bottom (-Y)

func _quad(st: SurfaceTool, v0: Vector3, v1: Vector3, v2: Vector3, v3: Vector3) -> void:
	st.add_vertex(v0)
	st.add_vertex(v1)
	st.add_vertex(v2)
	st.add_vertex(v0)
	st.add_vertex(v2)
	st.add_vertex(v3)
