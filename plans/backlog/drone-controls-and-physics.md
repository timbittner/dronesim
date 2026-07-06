# Drone Controls & Physics
- **Deeper physics** — motor/prop dynamics, battery sag (prepared, 100% for now), 
  more detailed aerodynamics beyond the current relative-airspeed drag model. Separate
  from [swarm-mechanics.md](swarm-mechanics.md) — both are just features to
  collect, not alternatives.
- **Battery/energy model** — finite flight time, RTH-on-low-battery.
- **Replay scrubbing** — in-sim playback of the telemetry recorded by
  `FlightRecorder` (P3 Phase D ships logging only). Sketch: freeze the
  RigidBody3D (`FREEZE_MODE_STATIC`, via `set_deferred`), scrub a playhead
  through an in-memory frame buffer with D-pad, set transforms kinematically,
  restore the exact live snapshot (incl. `_prev_velocity` and crash `_state`)
  on exit so nothing leaks into live physics. Square + D-pad are free inputs.
- **Weather** — Tim is skeptical this needs to go beyond the wind system
  already shipped in P2 Phase D. Don't expand without a concrete driver
  (a scenario or feature that actually needs rain/fog/etc).
