# Screenshots

The images in `docs/images/` are taken from the `-demo` build by `capture.sh`: one fresh launch per scene, with
throwaway settings, in British English. Your own notes, folder and settings are never touched.

- **On GitHub:** run the **Screenshots** workflow from the Actions tab. It sets the runner's display to
  1920×1080, takes the shots and commits the ones that really changed (`keep-unchanged.sh` ignores a few
  pixels of rendering noise) to the branch it ran on. It also runs on its own when the app or this folder
  changes on a `claude/**` branch, so every phase's pull request shows current screenshots.
- **On your Mac:** build Release, then run
  `scripts/screenshots/capture.sh path/to/Elenath.app docs/images`. macOS asks Terminal for Screen Recording
  permission the first time. It quits any running Elenath before each shot.

The scenes come from the demo launch arguments (see `Elenath/App/DemoScene.swift`): `-demoAppearance night|dawn`,
`-demoWindowSize 1280x800`, `-demoNow 2026-11-10T14:30` (a pinned clock, so dates don't change between runs) and
`-demoScene today|note|inbox|space|search|sealed|capture|onboarding`.
