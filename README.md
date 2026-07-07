# DroneSim

A 3D quadcopter flight simulator built in **Godot 4.7** with **Jolt Physics**.
Low-poly procedural terrain, realistic per-rotor thrust physics, terrain-aware
wind, crashes with signal loss — flyable with a PS5 DualSense controller or
keyboard.

<!-- screenshot/GIF placeholder: docs/media/flight.gif -->

Every force on the drone comes from its four rotors (plus gravity and air
drag) — no faked movement. Flight modes range from raw acro to stabilized
auto-level, with assisted altitude hold and brake.

## Play

Play in your browser on itch.io: [bitona.itch.io/dronesim](https://bitona.itch.io/dronesim). On macOS, a Bluetooth DualSense needs the browser allowed in its per-app permission list under System Settings — see `docs/publishing.md`.

## Run locally

Requires [Godot 4.7](https://godotengine.org/download) (the standard build —
Jolt Physics is included).

```sh
godot --path .        # or open the project in the editor and press F6
```

## Controls (DualSense, Mode 2)

| Input | Action |
|---|---|
| Left stick | Throttle (up/down) / Yaw (left/right) |
| Right stick | Pitch (up/down) / Roll (left/right) |
| L1 | Toggle flight mode (acro ↔ stabilized) |
| R1 | Toggle FPV / chase camera |
| L2 (hold) | Altitude hold |
| R2 (hold) | Brake |
| Triangle | Reset drone (also recovers from a crash) |

Keyboard fallback: arrows/WASD-style bindings for sticks, Shift = altitude
hold, Ctrl = brake — see `project.godot` InputMap for the full set.

## Tests

Headless test suites (flight modes, wind field):

```sh
./run_tests.sh
```

The same suites run in CI (`.github/workflows/ci.yml`) on every push.

## Project docs

- [PROJECT_SUMMARY.md](PROJECT_SUMMARY.md) — architecture + system index
  (per-script detail and the full tuning table live under `docs/systems/`)
- [AGENTS.md](AGENTS.md) — project guide / conventions (agent-oriented)
- `plans/` — implementation plans and long-term backlog

## License

[MIT](LICENSE)
