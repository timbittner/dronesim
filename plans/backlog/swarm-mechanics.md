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
- **Backup drone / swarm respawn** — **P7 candidate**: a menu action that
  spawns a replacement follower at the spawn pad, with a cooldown. No new
  flight logic needed — the P6 formation mode already flies to its slot from
  anywhere, including a ground start, so the newcomer catches up on its own.
- Hunter-Predator-style single-drone takeover: swarm goes standby on button,
  player controls one drone directly (MW2 style). The BOHR orbit half of this
  ships in P6; the takeover mechanic stays backlog.
