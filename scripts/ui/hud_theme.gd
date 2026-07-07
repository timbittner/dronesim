class_name HUDTheme
## Shared HUD color palette (P6.6) — was hardcoded per-label across
## debug_hud.gd and pad_menu.gd. One source of truth for the analog-FPV look.
const PANEL := Color(0.0, 0.0, 0.0, 0.65)          # telemetry/gizmo/wind panels
const PANEL_COMPASS := Color(0.0, 0.0, 0.0, 0.5)   # compass tape bg
const TEXT := Color(0.35, 1.0, 0.35)               # HUD green
const OUTLINE := Color(0, 0, 0)                     # text/line outline
const ACCENT := Color(1.0, 0.72, 0.1)              # amber — radar banner, reticle-on-target, active compass targets
const ALERT := Color(1.0, 0.15, 0.1)               # signal-lost red
const SUCCESS := Color(0.3, 1.0, 0.4)              # mission success / cleared targets
const MARKER := Color(0.3, 0.9, 1.0)               # dispatched-follower cyan
const WIND := Color(0.6, 0.85, 1.0)                # wind arrow / calm dot
const GIZMO_X := Color(1.0, 0.25, 0.25)            # world +X
const GIZMO_Y := Color(0.25, 1.0, 0.25)            # world +Y
const GIZMO_Z := Color(0.3, 0.5, 1.0)              # world +Z (back)
const GIZMO_CENTER := Color(1, 1, 1, 0.6)          # gizmo center dot
