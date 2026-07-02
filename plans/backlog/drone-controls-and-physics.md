# Drone Controls & Physics

- **PID fine-tuning** — open, ongoing. See `AGENTS.md` → Known Issues for
  the current stabilized-mode jitter/stickiness and rate-vs-angle-mode snap
  writeups; likely fix is blending the two control laws across the deadzone
  instead of hard-switching.
- **Deeper physics** — motor/prop dynamics, battery sag, more detailed
  aerodynamics beyond the current relative-airspeed drag model. Separate
  from [swarm-mechanics.md](swarm-mechanics.md) — both are just features to
  collect, not alternatives.
- **Battery/energy model** — finite flight time, RTH-on-low-battery.
- **Weather** — Tim is skeptical this needs to go beyond the wind system
  already shipped in P2 Phase D. Don't expand without a concrete driver
  (a scenario or feature that actually needs rain/fog/etc).
