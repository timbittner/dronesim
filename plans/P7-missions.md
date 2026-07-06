In P7 the "gameplay" aspects of the simulator are enhanced to make it more presentable/fun.

- **Quest/mission HUD** — P5 shipped mission
  targets + a `MissionTracker` (`scripts/mission/`) and a MISSION SUCCESS
  banner, but no proper objective list / progress panel. Build the HUD panel
  that lists active `MissionTarget`s and their state.
- **Payload physics** — Carrying a payload
  should affect mass/CoG/handling, not just be a flag. Toggling/dropping is a
  natural fit for the P6 DPad menu's entry list. Pairs with the payload-drop
  `MissionTarget` type in [quests-and-scenarios.md](quests-and-scenarios.md).
- **No-fly zones / geofencing** — "avoid X" quests, ties into the jammer
  danger-zone idea and target/goal marking. P5 shipped the `JammingNode`
  primitive (`scripts/mission/jamming_node.gd`) which doubles as a no-fly-zone
  building block.
- **Payload-drop target type** — P5's
  `MissionTarget` (`scripts/mission/mission_target.gd`) has an enum `type`
  (OBSERVE / CRASH) explicitly left extensible for a DELIVER/drop type — the
  drone releases a payload within `radius` to clear it. Pairs with the payload
  physics item in [immersion-and-features.md](immersion-and-features.md).
- **NPC/AI traffic** — other drones/vehicles as obstacles.
- **Visible air-defense interceptor** — **P7 candidate** (pushed from P6);
  the first NPC aircraft. P5 shipped the radar shoot-down as a stub: exceeding
  the `AirspaceControl` (`scripts/mission/airspace_control.gd`) ceiling for the
  countdown just calls `drone.lose_signal()`. The expiry was deliberately kept
  a single method call so a visible interceptor can slot in behind the same
  trigger and physically fly at / down the drone instead.
- **Adversary drones** — hostile swarm/aircraft beyond the
  interceptor, pairs with quest upgrades.
- **Scenario based backups**: respawn tied to quest/backup inventory, 
  adversary attrition.