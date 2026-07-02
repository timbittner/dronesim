# Project Health

- **GitHub upstream** — push this to a public/shared remote:
  - README (distinct from AGENTS.md/PROJECT_SUMMARY.md — a user-facing
    intro, not agent instructions)
  - CI? (headless test suite already exists — `godot --headless --path .
    scenes/test/*.tscn` — could run in a workflow)
  - License — MIT proposed
  - Documentation — GitHub Pages?
- **Replay/telemetry logging** — record and scrub back through a flight;
  useful for debugging control feel, scenario results, and agentic
  workflows (e.g. an agent inspecting a run without watching it live).
- **Doxygen-style docs** — wanted so the codebase is self-explanatory at a
  glance. Agreed candidate for a "documentation after P2" pass.
