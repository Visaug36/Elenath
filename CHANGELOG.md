# Changelog

All notable changes to Elenath are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.1] - 2026-11-16

A review for errors and security problems before the calendar arrives, by a reviewer independent of the
code. Every finding is fixed, each with a test. Nothing about how Elenath looks or works changes, except
where it was unsafe.

### Security

- **⌘-click asks before it opens anything but a web page or an e-mail.** A link to another app
  (`file://`, `zotero://` and the like) says which app it opens first. A file in a note that could run as a
  program (an app, a script, an installer, a `.webloc`) asks too, and offers to show it in Finder instead.
  Documents, pictures, sound and video open as before.
- **Sealed spaces hold in more places.** Every question asked of the index now says where it is asked from,
  so even a question about one note can't reach across a seal; the tests ask each one from everywhere.
  Unsaved edits to a sealed note whose file vanished stay in that space instead of going to the Inbox, and
  so do edits kept in Recovery.
- **Nothing outside the library is read or copied by accident.** Aliases and symbolic links in imported
  folders are skipped, a copied folder never holds one, a WhatsApp export can't name a file outside itself,
  and a `.space` or `.elenath` folder that is a link is refused.
- **Saved web pages are read as text**, without WebKit: they run no script and load nothing from the web.
- **Logs** never show the description of a login-item error, which can contain a path. A check in CI now
  fails on any log line that would show a title, a text, a file name or a path.
- **The project's workflows** use actions pinned to exact versions, read-only tokens by default, and no job
  that runs the project's code holds a token that can push or publish.

### Fixed

- A note full of brackets, backticks or `*` could take minutes to open: the Markdown reader now takes time
  in step with a note's length, whatever is in it.
- A named pipe in a folder (an unusual kind of file) could make Elenath wait forever when indexing or
  importing it. It is now skipped.
- A settings file nested thousands of levels deep could crash Elenath; such a file is now treated as damaged.
- A damaged search index made every search fail; it is now rebuilt from your notes, and the other spaces keep
  working meanwhile.
- A search with a thousand words failed, a note with a NUL character in it was only partly searchable, and
  typing a single letter in search read every note.
- A note with hundreds of pictures could use gigabytes of memory; pictures are now decoded once, at the size
  they are shown, and only the recent ones are kept. A picture that claims to be enormous isn't decoded.
- Very large notes: over 2 MB a note is shown as plain text so typing stays smooth; over 16 MB it isn't opened
  and a banner offers another app. Search reads the first 4 MB of any note.
- Recovery copies of a note with a long title could replace each other. Each now keeps a name of its own.
- Importing an Obsidian vault failed on its own `Attachments` folder; it is now merged into Elenath's.
- Undo could fail with "That file isn't there any more" when several changes were undone together or ⌘Z was
  pressed again quickly: changes now run one after another, each is undone on its own, and an undo that
  fails no longer leads to more errors.
- Renaming or moving a note while its title was being edited could rename it back when the title lost focus.
- Undoing a move to the Trash now explains how to use Finder's Put Back if Elenath can't take the item back
  itself.

### Added

- **A crash check on CI**: the demo app walks through its screens and actions, imports a folder of hostile
  files, and fails the build if it crashes, hangs or reports an error.
- docs/RELEASE_CHECKLIST.md starts with this review, repeated before every release.

## [0.1.0] - 2026-11-15

The notes. Elenath now keeps your notes as Markdown files in a folder you choose. Nano bot, the assistant,
arrives in 0.2; until then you file the Inbox by hand.

### Added

- **The library.** On first launch Elenath asks for a folder (it suggests Documents/Elenath; a folder that
  already holds Markdown files works too) and suggests a few spaces to start with. It finds a folder that was
  moved, says so when it is missing instead of starting empty, and can move the library to another folder or
  open another one (Settings › Files).
- **Spaces**, each with a color, a symbol, a description and keywords. A **sealed** space keeps its notes out
  of search, links, tags, tasks and Today everywhere else, and nothing from other spaces shows inside it.
  Tests plant a word in a sealed space and check that it never reaches anything outside.
- **The editor**: one pane of Markdown, styled as you type, with headings, emphasis, lists, quotes, code,
  tables, task boxes you can tick, `[[links]]` with completion (⌘-click or ⌘↩ follows one), `#tags`, and the
  pictures and PDFs you drop on a note shown in it. Above the text: the title, the place, the kind and the
  tags. Below it: the notes that link here. It saves as you type. Any language, right to left included.
- **Plain files, live.** Renaming or moving a note rewrites the links to it. When a note is renamed or moved
  in Finder, a banner offers to update the links that still point to where it was. Edits made in Finder or
  another app show up at once. If a note changes on disk while you have unsaved edits, both versions are kept, as
  "Title (conflict date time)". A save that fails keeps your text and a recovery copy. Deleting moves to the
  Trash.
- **Inbox and Quick Capture** (⌥⇧Space from any app; change it in Settings): type, paste text, a picture or a
  link, or drop files. ↩ saves to the Inbox, ⌘↩ saves and opens, and "uni: …" files it in that space. File
  Inbox items from the Inbox, from the note, or by dragging them onto a space or folder.
- **Today**: what waits in the Inbox, open tasks and recently edited notes.
- **Search** as you type across titles, text, tags and file names, with filters for the space, the folder,
  the kind, the tag and the time. ⌘O jumps to a note by its title.
- **Import** by dropping files or folders, or File › Import…: Markdown, text, Word and rich-text documents,
  PDFs, pictures, whole folders and WhatsApp chat exports. Everything is copied; the originals stay put.
- **Undo and redo** for every change to notes, folders and spaces, as well as for typing.
- **Settings**: General (appearance, the Quick Capture shortcut, opening at login), Spaces (sealing, colors,
  symbols, order) and Files (the library folder, Rebuild Index, a diagnostics report to copy).
- docs/IMPORT.md: how to bring notes in from other places.

## [0.0.1] - 2026-11-11

The foundation. This version is only the window: there are no notes yet.

### Added

- The app icon: an open notebook under a constellation.
- The themed main window with a starry sidebar and an empty state, in Night and Dawn or matching the system,
  with stronger colors when Increase Contrast is on.
- Settings with the appearance choice.
- A Help menu that opens the project's GitHub pages in your browser. Elenath itself has no network access.
- The folder format (docs/FORMAT.md), the design of the first screens (docs/DESIGN.md) and the architecture for
  version 0.1 (docs/ARCHITECTURE.md).
- A `-demo` launch argument with throwaway settings, for screenshots.

[Unreleased]: https://github.com/Visaug36/Elenath/compare/v0.1.1...HEAD
[0.1.1]: https://github.com/Visaug36/Elenath/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/Visaug36/Elenath/releases/tag/v0.1.0
[0.0.1]: https://github.com/Visaug36/Elenath/releases/tag/v0.0.1
