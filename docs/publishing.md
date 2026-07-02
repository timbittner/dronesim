# Publishing

Both targets are updated **once per Px milestone**, not continuously.

## GitHub (one-time setup)

1. Create a public repo named `dronesim` on github.com (no README/license —
   the repo already has them).
2. ```sh
   git remote add origin git@github.com:<your-username>/dronesim.git
   git push -u origin main
   ```
3. CI (`.github/workflows/ci.yml`) runs the headless test suites on every
   push. For the docs site, enable **Settings → Pages → Source: GitHub
   Actions** (one-time toggle).

Per milestone afterwards: `git push`.

## itch.io web build (Draft)

Build the zip:

```sh
./export_web.sh          # → build/dronesim-web.zip
```

Requires the Godot 4.7 web export templates (Editor → Manage Export
Templates) — already installed if you've exported before.

Sanity-check locally before uploading (the build has `thread_support=false`,
so no cross-origin-isolation headers are needed — a plain static server works):

```sh
python3 -m http.server -d build/web 8000   # open http://localhost:8000
```

Upload (first time):

1. itch.io → Upload new project. Title: DroneSim. Kind of project: **HTML**.
2. Upload `build/dronesim-web.zip`, tick **"This file will be played in the
   browser"**.
3. Viewport: 1280×720, fullscreen button enabled.
4. Visibility: keep **Draft** (default) — only you (and people with the
   secret URL) can see it until you publish.

Per milestone afterwards: re-run `./export_web.sh`, replace the zip on the
project's Edit page.

Notes:
- A gamepad is only detected by browsers after a button press inside the
  page; click the canvas first, then press any button on the controller.
- DualSense over Bluetooth on macOS is not reliably detected in **Safari**
  (confirmed independent of this project — a plain JS Gamepad-API test page
  fails identically); **Chrome** detects it fine. Recommend Chrome for the
  itch.io page.
