# Release checklist

Before every release: the review in section R, then this pass on a real Mac for a release that people will
rely on (0.1.0 and later). CI can't check the Mac part. Test both **Night** and **Dawn**.

This list grows with the app: each phase adds its own section.

## R. The review, before every release

Since 0.1.1, every release is reviewed for errors and security problems first, by an independent reviewer
(a separate agent or person that didn't write the code), across the whole app and repository, not only what
changed. Every finding is fixed with a test that fails without the fix, or written down in CLAUDE.md's log
with the reason it stays. Cover at least:

- [ ] **Files.** Nothing is read or written outside the library and Elenath's own container: symbolic links,
      named pipes and odd names in imported folders and in the library, path tricks in titles, links and
      chat exports, Recovery and Inbox copies, `.space` and `.elenath` folders that are links.
- [ ] **Untrusted input.** Malformed, huge and hostile Markdown, front matter, chat exports, Word, RTF,
      web pages, PDFs, pictures, library.json and space.json: nothing crashes, hangs or eats memory. Time
      that grows faster than the input counts as a hang (`HostileInputTests.expectLinear`).
- [ ] **Links and files in notes.** ⌘-click opens web and mail links at once and asks about anything else;
      files that could run as a program are asked about (`OpenPolicy`).
- [ ] **SQLite.** Every value is bound, search text can't break a full-text query, a damaged database is
      replaced.
- [ ] **Privacy.** Logs, the diagnostics report and crash output never contain note text, titles, file names
      or paths (`scripts/check-rules.sh` rule 5 catches the obvious ones; read the rest).
- [ ] **Sealing.** Try to break it: every `Retrieval` query from every workplace, the editor's rescue and
      Recovery paths, imports, and anything new in this release (`SealingLeakTests`).
- [ ] **The repository.** No personal data added to the history. Workflows have the least permissions they
      need, actions pinned to commits, and nothing a pull request from a fork could use to push, release or
      read secrets (`scripts/check-rules.sh` rule 6).
- [ ] **The crash check** (CI's "Crash check" job) passes: the `-demo` app walks through its screens and
      actions, hostile imports included, without crashing, hanging or reporting an error.

## 0. Before you start

- [ ] `main` is green in CI: the project's rules, lint, tests, the String Catalog check, an arm64 Release
      archive, zero warnings and the crash check.
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

## 3. Notes (from 0.1)

- [ ] First launch: onboarding, choosing a folder (an empty one, and one that already holds Markdown files),
      and the first spaces.
- [ ] Quit and open again: the library opens by itself, quickly.
- [ ] ⌥⇧Space in another app opens Quick Capture; ↩ saves to the Inbox, ⌘↩ saves and opens, "uni: …" files
      it in Uni, esc closes. Changing the shortcut in Settings works, and ⌥Space still belongs to Ithil.
- [ ] Typing in a long note doesn't stutter. Headings, lists, quotes, code, tables, task boxes, links and tags
      are styled as you type; ⌘-click follows a link; `[[` completes titles; ticking a box changes the file.
- [ ] Dropping a picture or a PDF on a note copies it into `Attachments` and shows it under its line.
- [ ] A note edited in TextEdit while Elenath shows it updates in Elenath. Editing the same note in both before
      Elenath saves keeps both versions, with a banner.
- [ ] Renaming or moving a note rewrites the links to it; ⌘Z puts everything back. A note renamed in Finder
      keeps its links.
- [ ] Moving a note to the Trash, and ⌘Z.
- [ ] Import: a folder of Markdown files, a Word document, a PDF, and a WhatsApp chat export (unzipped first).
- [ ] A sealed space: its notes, tags and tasks never show up in search, Today or link completion from outside
      it, and other spaces' don't show up inside it.
- [ ] Settings → Files: Rebuild Index, and moving the library to another folder.

## 4. Safety (from 0.1.1)

- [ ] ⌘-click on a web or mail link opens it at once. A link to another app (`zotero://…`, `file://…`) asks
      first and names the app. A PDF or picture in `Attachments` opens in its app; an app, a script or a
      `.webloc` there asks first, and "Show in Finder" is the default.
- [ ] A note with dozens of large photos scrolls smoothly, and Elenath stays under 400 MB in Activity Monitor.
- [ ] A note over 2 MB opens as plain text and typing in it is smooth. A note over 16 MB isn't opened: a
      banner offers another app and Finder.
- [ ] Importing a saved web page (`.html`, `.webarchive`) brings in its text and loads nothing from the web.
- [ ] Importing an Obsidian vault: its `Attachments` folder arrives, and the pictures its notes embed show.
- [ ] A note of a sealed space deleted in Finder while it has unsaved edits: on closing, the edits are a
      conflict copy in that space, never in the Inbox.

## 5. Only a real Mac can tell

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
