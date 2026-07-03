# Swarm Mechanics

Open fork, not yet decided vs. investing further in single-drone physics
depth (see [drone-controls-and-physics.md](drone-controls-and-physics.md)).

- Scene is already built to instance `Drone` for a swarm later (see
  AGENTS.md → Extension Points).
- Unscoped: how many drones, shared vs. independent flight modes, formation
  or autonomous routing behavior, whether the player still pilots one drone
  directly or supervises the swarm.
- **NPC/AI traffic** — other drones/vehicles as obstacles; a lighter step
  before full swarm autonomy.
- **Visible air-defense interceptor** — deferred out of P5 to P6; the first
  NPC aircraft. P5 shipped the radar shoot-down as a stub: exceeding the
  `AirspaceControl` (`scripts/mission/airspace_control.gd`) ceiling for the
  countdown just calls `drone.lose_signal()`. The expiry was deliberately kept
  a single method call so a visible interceptor can slot in behind the same
  trigger and physically fly at / down the drone instead.
- Drone swarm that builds into Bohr-Model like electron cloud orbits. 
  Player steers entire swarm cloud. On button cloud goes into standby and
  Player starts controlling a single drone (Hunter-Predetor style MW2)
