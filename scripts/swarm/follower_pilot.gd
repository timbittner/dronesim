class_name FollowerPilot
extends Node

## One autopilot per swarm follower (P6). Owns the follower's behavior state
## and drives its FlightModeFormation every physics tick. Individual pilots
## (not a monolithic manager loop) so behaviors can be primed per drone.
##
## Radio vs. onboard split: the slot target (leader-derived) is RADIO data —
## packet loss freezes it stale, mirroring how player packet loss freezes
## stick inputs — while current position/velocity are ONBOARD sensors and
## always fresh. Sustained-zero signal still kills the drone through the
## controller's own lose_signal() path, unchanged.

## Emitted on every behavior change — the swarm manager and (later) the HUD
## listen; also the hook for priming behaviors externally.
signal behavior_changed(new_behavior: Behavior)

enum Behavior { FORMATION, HOLD, DISPATCHED, LANDING, DOWN }

## Mean target-update dropouts per second at zero signal quality — same
## semantics (and default) as DroneController.packet_loss_rate.
@export var packet_loss_rate: float = 3.0

var drone: DroneController = null
## The swarm manager that owns this pilot's slot (set at spawn).
var manager: Node = null
## This pilot's slot index in the manager's formation table.
var slot_index: int = 0

var behavior: Behavior = Behavior.FORMATION

var _mode: FlightModeFormation = null
var _dropout_timer: float = 0.0
## Target held during HOLD / stale during dropouts.
var _target_position: Vector3 = Vector3.ZERO
var _target_heading: float = 0.0


## Wire the pilot to its drone: installs a FlightModeFormation and listens for
## crashes. Called by the swarm manager after spawning both.
func setup(follower: DroneController, swarm_manager: Node, index: int) -> void:
	drone = follower
	manager = swarm_manager
	slot_index = index
	_mode = FlightModeFormation.new()
	_mode.hover_throttle = drone.hover_throttle
	_mode.max_thrust = drone.max_thrust
	drone.set_flight_mode_object("formation", _mode)
	drone.crash_detected.connect(_on_drone_crashed)
	_target_position = drone.global_position
	_target_heading = 0.0


func set_behavior(b: Behavior) -> void:
	if b == behavior:
		return
	behavior = b
	behavior_changed.emit(b)


func _physics_process(delta: float) -> void:
	if drone == null or _mode == null:
		return
	if behavior == Behavior.DOWN:
		return  # wreck; recall (P6 step 4) resets and re-enters FORMATION

	# Onboard sensors: always fresh, packet loss does not touch these.
	_mode.current_position = drone.global_position
	_mode.current_velocity = drone.linear_velocity

	if behavior == Behavior.FORMATION:
		_update_target_from_slot(drone.signal_quality, delta)

	_mode.target_position = _target_position
	_mode.target_heading = _target_heading


## Radio side: pull this tick's slot target from the manager unless a packet
## dropout freezes the previous one. Split out (and quality passed in) so the
## freeze behavior is unit-testable without a SignalField in the scene.
func _update_target_from_slot(quality: float, delta: float) -> void:
	if _dropout_timer > 0.0:
		_dropout_timer -= delta
		return  # stale target — the jammer is winning
	if randf() < (1.0 - quality) * packet_loss_rate * delta:
		_dropout_timer = randf_range(0.1, 0.4)
		return
	if manager == null:
		return
	_target_position = manager.get_slot_position(slot_index)
	_target_heading = manager.get_slot_heading(slot_index)


func _on_drone_crashed() -> void:
	set_behavior(Behavior.DOWN)
