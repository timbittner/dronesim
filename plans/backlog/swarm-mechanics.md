# Swarm Mechanics

**Core swarm promoted to P6** (`../2026-07-04_P6-swarm.md`): N physics-based
followers, formation flight mode (LINE/V/RING/BOHR), dispatch, auto-land.

Still here:

- **NPC/AI traffic** — other drones/vehicles as obstacles.
- **Visible air-defense interceptor** — **P7 candidate** (pushed from P6);
  the first NPC aircraft. P5 shipped the radar shoot-down as a stub: exceeding
  the `AirspaceControl` (`scripts/mission/airspace_control.gd`) ceiling for the
  countdown just calls `drone.lose_signal()`. The expiry was deliberately kept
  a single method call so a visible interceptor can slot in behind the same
  trigger and physically fly at / down the drone instead.
- **Adversary drones** — **P7 candidate**: hostile swarm/aircraft beyond the
  interceptor, pairs with quest upgrades.
- **Better kamikaze autopilot** — P6 shipped a working-but-blunt strike
  (`flight_mode_formation.gd::_strike()` + `follower_pilot.gd` arming): the
  dispatched drone settles directly overhead the CRASH target, cuts throttle to
  idle, and free-falls onto it — gravity is the weapon, since a quad can't
  power-dive a ground target (thrust points up). Reliable, but it circles a beat
  to settle and can arm slightly off-centre, so it's weak against small or
  moving targets. Improve it: optimise for the drone's own local up-vector
  (commit to an inverted power-dive without the tumble the naive PD-restoring
  attempt produced — likely needs a momentum-managed flip), and/or a smarter
  approach trajectory (a curved run-in that arrives already descending, so it
  never has to null horizontal speed overhead first).
- **Backup drone / swarm respawn** — **shipped in P6** (menu CALL BACKUP:
  spawns a replacement follower above the pad on a cooldown; the formation mode
  flies it to its slot from the ground start). Left here as the anchor for the
  P7 extensions: respawn tied to quest/backup inventory, adversary attrition.
- Hunter-Predator-style single-drone takeover: swarm goes standby on button,
  player controls one drone directly (MW2 style). The BOHR orbit half of this
  ships in P6; the takeover mechanic stays backlog.
