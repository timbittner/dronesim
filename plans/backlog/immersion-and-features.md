# Immersion & Features

- **UI Menu** — DPad-controlled 2D menu to toggle various simulation flags,
  similar to Forza Horizon / F1 Series menus. **Deferred out of P5 to P6** —
  natural host for the P5 "cheats" toggles (e.g. disable radar/signal loss)
  and feed-switching.
- **Quest/mission HUD** — deferred out of P5 to P6. P5 shipped mission
  targets + a `MissionTracker` (`scripts/mission/`) and a MISSION SUCCESS
  banner, but no proper objective list / progress panel. Build the HUD panel
  that lists active `MissionTarget`s and their state.
- **Payload physics** — if quests include "drop payload," carrying it should
  affect mass/CoG/handling, not just be a flag. Toggling/dropping is a
  natural fit for the DPad menu above. See the payload-drop `MissionTarget`
  type deferred to P6 in [quests-and-scenarios.md](quests-and-scenarios.md).
- **Multi-camera / gimbal** — a gimbal-stabilized camera feed separate from
  the airframe-locked FPV. Switching feeds is another DPad-menu candidate.
- **Sound simulation** — floated, but Tim is skeptical it's more than a
  gimmick. Low priority.
