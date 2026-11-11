## What this changes

<!-- One or two sentences. Link the issue it closes, e.g. "Closes #12". -->

## Why

## Screenshots

<!-- For anything visible: Night and Dawn. -->

## Checklist

- [ ] `xcodebuild test` passes and there are no new warnings
- [ ] swift-format is clean (`xcrun swift-format lint --strict --recursive Elenath ElenathCore ElenathCoreTests`)
- [ ] New logic in `ElenathCore` has tests that don't depend on the machine's time zone, locale or date
- [ ] New user-facing strings are in `Localizable.xcstrings`
- [ ] VoiceOver labels and keyboard access for anything new
- [ ] Notes and files are only ever copied or moved to the Trash, never deleted or written outside the library
- [ ] Nothing reads a sealed space's content from outside it
- [ ] A line in the `[Unreleased]` section of `CHANGELOG.md`
