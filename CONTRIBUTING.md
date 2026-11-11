# Contributing to Elenath

Thanks for looking. Elenath is a personal project: a private, offline notes app built for one person's notes,
and shared in case it is useful to others. **Reliability beats features**, so the bar for changes that touch
people's notes is high, and new features follow the plan in [CLAUDE.md](CLAUDE.md).

By taking part you agree to follow the [Code of Conduct](CODE_OF_CONDUCT.md).

## Before you start

- **Bugs:** open an issue with the bug template. Steps to reproduce help more than anything.
- **Features:** open an issue with the feature template first, so the idea can be discussed before you spend time
  on code.
- **Security problems:** don't open an issue; see [SECURITY.md](SECURITY.md).

## Building

You need Xcode 26 on macOS 26, on a Mac with Apple silicon.

```sh
git clone https://github.com/Visaug36/Elenath.git
cd Elenath
open Elenath.xcodeproj
```

Press ⌘R to run and ⌘U to test. To try Elenath without touching your own settings, edit the scheme (Product →
Scheme → Edit Scheme… → Run → Arguments) and enable `-demo`.

From the command line:

```sh
xcodebuild test -project Elenath.xcodeproj -scheme Elenath -destination 'platform=macOS'
scripts/install.sh          # builds Release and copies it to /Applications
scripts/dev/core-test.sh    # lints and tests ElenathCore with the open-source toolchain, also on Linux
```

## How the code is organized

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the full picture, [docs/DESIGN.md](docs/DESIGN.md) for the
look and [docs/FORMAT.md](docs/FORMAT.md) for what is kept on disk. In short:

- `ElenathCore/`: all logic, in plain Swift. No SwiftUI, no AppKit, no user-facing strings. Everything here is
  tested, and it builds without a Mac.
- `Elenath/`: the SwiftUI app, AppKit glue and every user-facing string (in `Localizable.xcstrings`).
- `ElenathCoreTests/`: Swift Testing tests for `ElenathCore`.

## Rules for changes

- **No third-party dependencies**, no network access, no analytics. The sandbox has no network entitlement on
  purpose, and `scripts/check-rules.sh` keeps it that way.
- **Never risk a note.** Copy files, never move them; never delete permanently (use the Trash); never write
  outside the library folder; keep writes atomic and backups working; never rewrite a note the user didn't edit.
- **Sealed means sealed.** Anything that reads notes for search, links, suggestions or the assistant goes
  through `Retrieval`, and comes with a leak test.
- **The main thread never waits** on disk, the index or the model.
- **Zero warnings.** CI builds with warnings as errors.
- **Format with swift-format** (it ships with Xcode):
  `xcrun swift-format format --in-place --recursive Elenath ElenathCore ElenathCoreTests`. CI runs
  `swift-format lint --strict`.
- **Every user-facing string is localizable** and lives in `Elenath/Localizable.xcstrings`. CI fails if code
  uses a string the catalog doesn't have (`scripts/check-strings.sh`).
- **Accessibility:** VoiceOver labels on every control, full keyboard access, respect Reduce Motion and Increase
  Contrast, and keep text at WCAG AA contrast in both Night and Dawn.
- **Tests:** logic changes in `ElenathCore` come with Swift Testing tests. Tests must not depend on the
  machine's time zone, locale or the current date.
- **Design:** use the tokens from the asset catalog and `Elenath/Theme/`, not new colors or sizes.

## Pull requests

1. Fork, then branch from `main`.
2. Keep each pull request to one change, with a clear description and screenshots for anything visible (Night
   and Dawn).
3. Make sure `xcodebuild test` passes and swift-format is clean. CI checks both, plus a Release build.
4. Add a line to the `[Unreleased]` section of [CHANGELOG.md](CHANGELOG.md).

## License

By contributing you agree that your contributions are licensed under the [MIT License](LICENSE).
