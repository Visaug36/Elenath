# Release checklist

Do this pass on a real Mac before a release that people will rely on (0.1.0 and later). CI can't check any of
it. Test both **Night** and **Dawn**.

This list grows with the app: each phase adds its own section.

## 0. Before you start

- [ ] `main` is green in CI: the project's rules, lint, tests, the String Catalog check, an arm64 Release
      archive and zero warnings.
- [ ] `MARKETING_VERSION` in the Xcode project is the version to release.
- [ ] `CHANGELOG.md` has a `## [X.Y.Z] - YYYY-MM-DD` section for it.

## 1. First launch

- [ ] Download `Elenath-X.Y.Z.zip` (not "Source code") from the release page, unzip it and move Elenath to
      Applications.
- [ ] macOS says it can't verify the developer. System Settings → Privacy & Security → Open Anyway opens it.
- [ ] The window looks right in Night and Dawn, and Settings → General switches between them.
- [ ] Help → Check for Updates… and Report an Issue… open the GitHub pages in the browser.

## 2. Accessibility and looks

- [ ] VoiceOver reads every control.
- [ ] Full keyboard access (System Settings → Keyboard → Keyboard navigation): everything is reachable.
- [ ] Reduce Motion and Increase Contrast are respected.

## 3. Only a real Mac can tell

These are open questions from the brief. Version 0.1 has a diagnostics report (Settings → Files) that checks
them and can be copied.

- [ ] The on-device model answers from the sandboxed, ad-hoc-signed app.
- [ ] The embedding assets arrive without a network entitlement.
- [ ] The library folder is still remembered after updating to a new build.

## How a release is published

The **Release** workflow publishes by itself. On a push to `main` it reads the version from the Xcode
project; if `CHANGELOG.md` has a dated section for it and no release exists yet, it builds an arm64 Release,
zips it with `ditto`, adds the SHA-256, creates the tag `vX.Y.Z` on the commit it built, and publishes the
release with the changelog's notes.

- Versions below 1.0.0 are published as **prereleases**.
- **1.0.0 and later are never published automatically.** On GitHub: **Actions → Release → Run workflow**, type
  `publish` into the field, and run it on `main`.
- To publish nothing, leave the changelog section for the version undated ("Unreleased").

If the workflow can't create the tag, make the release by hand: **Releases → Draft a new release → Choose a
tag**, type `vX.Y.Z`, pick **Create new tag on publish** with `main` as the target, and publish (the title and
notes can stay empty). The workflow then builds that tag and adds the zip, the checksum and the notes.

## After publishing

- [ ] The release has `Elenath-X.Y.Z.zip` and `Elenath-X.Y.Z.zip.sha256`.
- [ ] `shasum -a 256 -c Elenath-X.Y.Z.zip.sha256` passes on the downloaded zip.
- [ ] The downloaded app shows version X.Y.Z in About Elenath.

## Signing

Releases are ad-hoc signed and not notarized, so each user allows the app once in Privacy & Security.
Notarization needs a paid Apple Developer Program membership; Ithil's release workflow shows how it would be
added.
