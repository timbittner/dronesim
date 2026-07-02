# P3 — Project Health

Promoted from `backlog/project-health.md`, plus one new item: an itch.io web
export in Draft mode. Pushing to GitHub is intended to be **rare — once per Px
milestone** — so each push must be validating (CI) and publishable (itch.io
zip, Pages docs) with minimal ceremony. No new CLI tools: no `gh`, no butler —
SSH push and manual zip upload only.

## Phases

- [x] **A — GitHub upstream**: `README.md` (user-facing intro), MIT `LICENSE`,
  `.github/workflows/ci.yml` (download Godot 4.7-stable linux, `--import`,
  run both headless test scenes). One-time manual step: create public repo
  `dronesim` on github.com, `git remote add origin
  git@github.com:<user>/dronesim.git && git push -u origin main`.
- [x] **B — itch.io web export (Draft)**: `export_web.sh` (headless
  `--export-release` + zip, excluding `*.import`); `export_path` →
  `build/index.html` (itch.io needs index.html at zip root);
  `docs/publishing.md` documents the manual draft-upload flow. Verify with a
  local `python3 -m http.server` (thread_support=false → no COOP/COEP needed).
- [x] **C — doc-comments pass**: GDScript `##` doc comments across
  `scripts/**/*.gd` — one block per class, `##` on exported tuning vars and
  public methods/signals; `class_name` where missing. Written for
  `godot --doctool --gdscript-docs` (feeds Phase E); validate the pipeline
  locally once.
- [x] **D — telemetry logging (no playback)**: new
  `scripts/environment/flight_recorder.gd` (`FlightRecorder`, sibling node in
  `main.tscn`, CrashEffects/WindField observer pattern). Streams one JSONL
  line per physics tick to `user://telemetry/flight_<timestamp>.jsonl`
  (`t`, pos, quat, vel, angvel, rotor mix, sticks+assist flags, mode, wind,
  crashed; meta header line; flush 1/s; rotate on reset; absolute path
  printed at startup for agent runs). Controller grows only `last_mix` and a
  `drone_reset` signal. Test pair `flight_recorder_test.gd` /
  `flight_recorder_test_scene.tscn` added to `run_tests.sh` + CI. In-sim
  replay/scrubbing deferred → `backlog/drone-controls-and-physics.md`.
- [x] **E — GitHub Pages generated docs**: CI docs job — doctool XML from the
  Phase C comments → `make_rst.py` (curl'd from godotengine/godot `4.7`
  branch) → Sphinx HTML → `actions/deploy-pages`. Landing page links itch.io
  build + publishing guide. One-time toggle: Pages source = "GitHub Actions".

## Verification

- `./run_tests.sh` green (including new recorder suite); CI green on first push.
- `./export_web.sh` zip loads in a local browser serve.
- Doc pipeline output sane locally; Pages live after the milestone push.
- Telemetry JSONL greppable after a headless run.

Docs updated at the end: AGENTS.md current phase + architecture,
PROJECT_SUMMARY.md, backlog files. Each phase = one conventional commit.
