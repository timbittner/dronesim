class_name FollowerPilot
extends Node

## One autopilot per swarm follower (P6). Owns the follower's behavior state
## and drives its FlightModeFormation every physics tick. Individual pilots
## (not a monolithic manager loop) so behaviors can be primed per drone.
##
## Radio vs. onboard split: the LEADER STATE packet (position, velocity,
## heading) is RADIO data — packet loss freezes it stale, mirroring how player
## packet loss freezes stick inputs. Everything else is follower-side: the
## slot offset is formation math on the pilot's own clock (a jammed follower
## keeps orbiting the last-known leader position — the orbit doesn't jam), and
## current position/velocity are ONBOARD sensors, always fresh. The frozen
## leader velocity feeds forward into the mode, so followers match leader
## speed without needing position error as fuel. Sustained-zero signal still
## kills the drone through the controller's own lose_signal() path, unchanged.

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
## Last-received leader state packet — stale during dropouts.
var _leader_pos: Vector3 = Vector3.ZERO
var _leader_vel: Vector3 = Vector3.ZERO
var _leader_heading: float = 0.0
var _has_leader_state: bool = false
## Previous tick's slot offset, for the local orbital-velocity derivative.
var _prev_offset: Vector3 = Vector3.ZERO
var _offset_primed: bool = false


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
	_mode.target_position = drone.global_position


## Live gain push from the SwarmManager's Formation Gains exports (each tick,
## so remote-inspector tuning takes effect immediately).
func apply_gains(pos_p: float, pos_i: float, vel_p: float, speed: float, tilt: float) -> void:
	if _mode == null:
		return
	_mode.pos_p_gain = pos_p
	_mode.pos_i_gain = pos_i
	_mode.vel_p_gain = vel_p
	_mode.max_speed = speed
	_mode.max_tilt = tilt


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

	if behavior != Behavior.FORMATION:
		_mode.target_velocity = Vector3.ZERO  # HOLD: park on the frozen target
		return

	_receive_leader_state(drone.signal_quality, delta)
	if not _has_leader_state:
		return

	# Follower-side formation math on the pilot's own clock — runs against the
	# (possibly stale) radio state, so orbits keep turning during a jam.
	var offset: Vector3 = manager.get_slot_offset(slot_index, _leader_heading)
	_mode.target_position = _leader_pos + offset
	_mode.target_heading = _leader_heading
	# Feed-forward: frozen leader velocity + local orbital motion (derivative
	# of the offset — nonzero for BOHR, zero for static formations).
	if not _offset_primed:
		_offset_primed = true
		_prev_offset = offset  # no derivative spike on the very first tick
	_mode.target_velocity = _leader_vel + (offset - _prev_offset) / delta
	_prev_offset = offset


## Radio side: receive this tick's leader state packet unless a dropout
## freezes the previous one. Split out (and quality passed in) so the freeze
## behavior is unit-testable without a SignalField in the scene.
func _receive_leader_state(quality: float, delta: float) -> void:
	if _dropout_timer > 0.0:
		_dropout_timer -= delta
		return  # stale leader state — the jammer is winning
	if randf() < (1.0 - quality) * packet_loss_rate * delta:
		_dropout_timer = randf_range(0.1, 0.4)
		return
	if manager == null:
		return
	var state: Dictionary = manager.get_leader_state()
	if state.is_empty():
		return
	_leader_pos = state.position
	_leader_vel = state.velocity
	_leader_heading = state.heading
	_has_leader_state = true


func _on_drone_crashed() -> void:
	set_behavior(Behavior.DOWN)
