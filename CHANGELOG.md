# Changelog

All notable changes to Elenath are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2026-11-13

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
- **Plain files, live.** Renaming or moving a note rewrites the links to it. Edits made in Finder or another
  app show up at once. If a note changes on disk while you have unsaved edits, both versions are kept, as
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

[Unreleased]: https://github.com/Visaug36/Elenath/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/Visaug36/Elenath/releases/tag/v0.1.0
[0.0.1]: https://github.com/Visaug36/Elenath/releases/tag/v0.0.1
