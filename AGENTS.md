# DroneSim — Project Guide

## What This Is

A 3D drone flight simulator built in Godot 4.7 / GDScript. Started as a vibe-coding
playground with the intent to iterate into a drone swarm simulator with realistic
flight physics, autonomous routing, weather, and threat simulation.

**Current phase:** MVP — single drone, flyable, simple procedural terrain.

## Tech Stack

- **Engine:** Godot 4.7
- **Language:** GDScript
- **Physics:** Jolt Physics (3D)
- **Renderer:** gl_compatibility (low-poly aesthetic, lightweight, VR-friendly later)
- **Controller:** DualSense (PS5) via Godot input system
- **Godot MCP:** `@coding-solo/godot-mcp` available for editor automation

## MVP Scope

- One drone, RigidBody3D-based, flyable with gamepad
- Two flight modes: **Stabilized** (auto-levels on stick release) and **Acro** (full manual rate control)
- Procedural noise terrain (seed-based, flat spawn pad)
- Chase camera with FPV toggle
- DualSense controller input (Mode 2: left stick = throttle/yaw, right stick = pitch/roll)

### Out of Scope (Future Layers)

| Feature | Notes |
|---|---|
| Swarm simulation | Multiple drones, formation flying, swarm behaviors |
| OSM terrain | Real-world terrain from OpenStreetMap data |
| Weather | Wind, rain, visibility degradation |
| Threat simulation | Obstacles, no-fly zones, detection systems |
| AI input enhancement | Computer-assisted steering, PID tuning assist |
| VR mode | Stereo rendering, head tracking |
| DualSense features | Tilt steering, haptic feedback, adaptive triggers |

## Architecture

```
scenes/          Godot scene files (.tscn)
  main.tscn      Root scene — loads environment + drone + camera
  drone/         Drone scene and sub-scenes
  environment/   Terrain, sky, lighting
scripts/         GDScript files (.gd)
  drone/         Drone controller, flight mode logic
  environment/   Terrain generator, tree placement
  camera/        Camera rig, mode switching
  util/          Shared utilities (noise helpers, math)
assets/          Art resources
  materials/     .material files
  models/        .glb / .gltf meshes
  textures/      Image files
```

### Extension Points

- **Flight modes:** New modes implement a common interface (stabilized, acro, future: AI-assisted)
- **Terrain generator:** Pluggable backend (noise-based now, OSM-based later)
- **Drone scene:** Single drone now, instanced for swarm later
- **Input mapping:** Godot InputMap actions, not hardcoded device codes

## Conventions

- **File naming:** snake_case for all files (scenes, scripts, assets)
- **Script class naming:** PascalCase (e.g., `DroneController`)
- **Scene root nodes:** PascalCase (e.g., `Main`, `Drone`, `Terrain`)
- **Signals:** snake_case past tense (e.g., `crash_detected`, `mode_changed`)
- **Physics:** All drone physics in `_physics_process`, not `_process`
- **Input:** Always use `Input.get_vector` / `Input.get_action_raw_strength` for analog sticks
- **Commits:** Conventional Commits (`feat:`, `fix:`, `refactor:`, `docs:`, `chore:`)

## Development

- Godot editor must be open when using MCP tools (auto-import on file changes)
- GDScript files can be edited externally; Godot reloads on focus
- Scene files (.tscn) should be edited in the Godot editor unless making targeted text edits
- Test by running the scene (F6) in Godot after changes

## Controller Layout (Mode 2)

| Stick | Direction | Action |
|---|---|---|
| Left | Up/Down | Throttle (climb/descend) |
| Left | Left/Right | Yaw (rotate) |
| Right | Up/Down | Pitch (forward/back) |
| Right | Left/Right | Roll (tilt left/right) |
| L1/R1 | Toggle | Switch flight mode |
| R2 | Hold | Toggle FPV camera |

## License

Private project. No license file needed yet.
