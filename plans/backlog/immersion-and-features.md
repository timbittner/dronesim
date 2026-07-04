# Immersion & Features

- **UI Menu** — **promoted to P6** (`../2026-07-04_P6-swarm.md`):
  DPad-controlled Forza-style strip driving swarm commands. Simulation-flag
  toggles ("cheats", feed-switching) stay backlog — the P6 menu's data-driven
  entry list is built to host them later.
- **Quest/mission HUD** — deferred out of P5 to P6. P5 shipped mission
  targets + a `MissionTracker` (`scripts/mission/`) and a MISSION SUCCESS
  banner, but no proper objective list / progress panel. Build the HUD panel
  that lists active `MissionTarget`s and their state.
- **Payload physics** — **P7 candidate** (pushed from P6). Carrying a payload
  should affect mass/CoG/handling, not just be a flag. Toggling/dropping is a
  natural fit for the P6 DPad menu's entry list. Pairs with the payload-drop
  `MissionTarget` type in [quests-and-scenarios.md](quests-and-scenarios.md).
- **Multi-camera / gimbal** — a gimbal-stabilized camera feed separate from
  the airframe-locked FPV. Switching feeds is another DPad-menu candidate.
- **Sound simulation** — floated, but Tim is skeptical it's more than a
  gimmick. Low priority.
