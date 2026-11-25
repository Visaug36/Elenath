# Elenath

Save this brief as CLAUDE.md in the repo root, follow it in every session, and keep it updated as we make decisions.

You're building Elenath, a native macOS app that replaces the seven places I keep notes, and my calendar, with one. It's a private, offline home for my ideas, university work, Red Cross work and everything else I do: notes, a calendar for everything I have to be at, and a small on-device assistant called Nano bot that files what I dump on it and shows me how things connect. Elenath takes over everything Ithil, my calendar (https://github.com/Visaug36/Ithil), does at 1.0.0: the same look, the same principles, plain files in real Finder folders. Once it has, Elenath is the only app I open. It's for me alone, on my Mac. Reliability beats features. My notes and my calendar are never lost, never locked in, and never leave the Mac.

"Elenath" is Sindarin for all the stars together. Every note is a star, and links are the lines between them.

## Start here
1. The repo https://github.com/Visaug36/Elenath already exists and holds only a README. Don't create another.
2. Read Ithil before writing anything: its CLAUDE.md (above all the decisions log, which records what worked and what failed in this same build environment), docs/DESIGN.md, docs/ARCHITECTURE.md, the Xcode project, Config/, scripts/ and .github/. Then reuse it. Copy and rename the project layout, entitlements, CI, release and screenshot workflows, scripts, swift-format config and community files, and the code that already works for storage, backups, folder access, the global hotkey, appearance and onboarding. Don't reinvent what Ithil solved.
3. Ask me these in one message and wait for the answers:
   - Which languages I write notes in.
   - Where my notes live today (about seven places), so imports can be planned.
   - Where my Ithil folder is (Ithil suggests ~/Documents/Ithil).
   - Which spaces to start with, and which of them are sealed (see Spaces).
   - Whether the repo is public or private, and the license (Ithil is MIT, copyright "Visaug36").
4. My Mac is an M1 MacBook Air with 8 GB, on macOS 26.6 with Apple Intelligence turned on. Every feature must work fully there. Anything that needs macOS 27 is an extra behind an availability check, never a requirement.
5. Check which macOS runner images and Xcode versions GitHub Actions offers today, then show me a plan for Phase 1 and wait for my OK.

## Architecture
- Swift 6 and SwiftUI, with AppKit where SwiftUI falls short (the text editor, the board canvas, floating panels). Deployment target macOS 26.0, Apple silicon only (arm64, so drop Ithil's universal-binary check). Build with the newest stable Xcode the runners have, and put anything newer than macOS 26 behind availability checks.
- No third-party packages. System frameworks only: Foundation Models, Natural Language, Vision, PDFKit, Swift Charts, Accelerate, and SQLite through the system's own library.
- Targets as in Ithil: `Elenath` (app), `ElenathCore` (static framework holding every piece of logic that can be tested without a window; no SwiftUI, no AppKit, no user-facing strings), `ElenathCoreTests` (Swift Testing, not hosted).
- The language model, the embedder, the file system, the clock and notifications all sit behind small protocols, so everything runs on CI with fakes. CI runners have no Apple Intelligence, so no test may need the real model.
- App Sandbox and Hardened Runtime on. Entitlements: user-selected read-write files and app-scope bookmarks only. No network entitlement and never the Private Cloud Compute entitlement, so macOS itself guarantees that nothing leaves the Mac.
- The main thread never waits on disk, the index or the model.
- Logs use os.Logger. Note titles, note text, event titles, file names, paths and prompts are always .private. Logs, the diagnostics report and crash output never contain them.
- Mac only for now. A Windows version may come later, so keep ElenathCore free of UI code and document every file format in docs/FORMAT.md. The folder is the contract another app could read.

## Data: plain files are the truth
```
Elenath/                              the library: one folder I choose on first launch
├── .elenath/
│   ├── library.json                  id, schema version, order of spaces, settings that travel
│   └── backups/
├── Inbox/                            everything I dump, until it's filed
├── Uni/                              a space
│   ├── .space/
│   │   ├── space.json                id, color, symbol, sealed, description, keywords
│   │   ├── memory.md                 what Nano bot has learned here; I can edit it
│   │   └── decisions.jsonl           proposals I accepted, changed or rejected
│   └── Physics/
│       ├── Lecture 7 notes.md
│       ├── Attachments/              files dropped on notes in this folder (copied, never moved)
│       └── Free body diagrams.board/ a board: board.json plus its images
├── Red Cross/                        another space
└── Calendar/                         the calendar, in Ithil's format (see Calendar)
    ├── .ithil/
    │   ├── events.json               subjects and events: schema version, migrations, backups
    │   └── backups/
    └── 2026-11-16/
        └── 14.00 Physics Lecture/    one folder per event occurrence, made when the first file arrives
            └── .ithil-event          marker with the event's id and date
```
- The library folder is chosen on first launch (suggest ~/Documents/Elenath) and kept as a security-scoped bookmark. Handle a non-empty folder, a missing folder ("Locate or choose folder", never crash, never quietly start empty) and moving the library exactly as Ithil does.
- Notes are UTF-8 Markdown files that any editor can open. Optional front matter holds only `id`, `created`, `kind` (note, idea, goal), `tags`, `goals` and `event`. Keys Elenath doesn't know are kept byte for byte, and Elenath never rewrites a body I didn't edit.
- Links are `[[Title]]`, `[[Title|shown text]]`, `[[Folder/Title]]` when titles clash, and `[[Space/Title]]` across spaces that mix. `![[file]]` embeds an image, PDF, board or chart. Tags are `#tag` and tasks are `- [ ]`. Stay compatible with Obsidian's conventions where they overlap, so an imported vault keeps working.
- Renaming or moving a note updates the links that point to it, as one undoable step. The `id` lets Elenath repair links when a file is renamed in Finder.
- Files dropped on a note are copied into an `Attachments` folder beside it. Name clashes get " 2", like in Finder.
- A board is a `Name.board` package (a schema-versioned board.json plus its images), registered as a document package so Finder shows it as one item.
- The folder is the source of truth. Watch it and show Finder edits live. If a note changes on disk while I have unsaved edits, keep both ("Title (conflict 2026-11-10 14.30).md") and tell me. Never silently pick one.
- Autosave with atomic writes; I never press Save. Deleting moves to the Trash, and nothing is ever deleted permanently. Nothing is written outside the library except Elenath's own index and safety copies in its container.
- library.json and space.json follow Ithil's LibraryStore: schema version with migrations, atomic writes, rolling backups, a safety copy in Application Support, recovery from the newest good backup with a message to me, and read-only opening of a newer schema.
- Sanitize file and folder names (no / or :, no leading dots, a length limit).
- Copying the library folder is a full backup, the calendar included. Opening it on another Mac restores everything; the index rebuilds itself.
- `Calendar` is a reserved name, like `Inbox`: it is never a space.

## Spaces
- A space is a top-level folder in the library: Uni, Red Cross, Ideas, whatever I create. Each has a color (Ithil's subject palette plus a custom color), an SF Symbol, and a description and keywords that help Nano bot route things.
- By default spaces mix: search, links, suggestions and the Sky can span them, so I can see how an idea connects to a course or a goal.
- A space can be **sealed**. A sealed space's notes, files, index, memory and decisions are used only while I'm working inside it. Nothing from it appears in another space's search, suggestions, answers, links or Sky, and nothing from other spaces appears inside it. One crossing is allowed: Nano bot may use a sealed space's name, description and keywords, never its contents, to propose filing an Inbox item there.
- The Inbox belongs to no space. Its items are used for nothing except filing them.
- **The calendar is the one deliberate exception to sealing.** Events from every space, sealed ones included, show fully on the calendar, on Today, in notifications and in the menu bar (Red Cross shifts next to lectures). The exception covers an event's title, time, location and file count there, and opening its folder in Finder ("Open Files"), and nothing else: the seal keeps my Red Cross material out of search, suggestions and Nano bot, it doesn't hide my own files from me. An event's notes, its files' names and contents, and its linked notes stay sealed, and outside its space the event stays out of the main search, suggestions, the Sky and anything Nano bot is shown. The calendar's own search finds every event by title and location, never by a sealed event's notes or files. The leak tests prove both halves.
- Enforce sealing at one choke point in ElenathCore's retrieval layer and prove it with tests: a marker word planted in a sealed space must never show up in any search result, suggestion or model prompt built for another space.

## Features
1. **Main window.** Sidebar: Today, Inbox with a count, the Calendar, spaces with their folders, tags. Detail: the note, board, calendar or view I opened. Toolbar: back and forward, search, new note, the Nano bot panel toggle.
2. **Today.** The landing screen: what's up next and today's events, what's waiting in the Inbox, proposals from Nano bot, open tasks and recently edited notes.
3. **Editor.** One pane of Markdown styled as I type, with no separate preview: headings, emphasis, lists, clickable checkboxes, quotes, code, simple tables, inline images, links (⌘-click to follow), `[[` autocomplete, find in note. Backlinks and related notes sit below the note. Any language, including right-to-left and mixed-direction text.
4. **Inbox and Capture.** One floating panel from anywhere, for notes and events, on one changeable hotkey. Type, paste text, an image or a link, or drop files. A note is the default: ↩ saves to the Inbox, ⌘↩ saves and opens, esc closes, and starting with a space's name or keyword ("uni: …") files it there directly. When the text reads like an event ("physics quiz thursday 10am", Ithil's Quick Add parsing), the panel shows what it understood ("Thu 10:00 · Physics") with the hint "⌥↩ Add to Calendar", and the line is clickable; ⌥↩ adds the event and ⌥⌘↩ adds and opens it. A note stays the default, so a note that mentions a date never becomes an event by accident. The hotkey is ⌥Space; if it can't be registered (for example while Ithil still runs), the app says so instead of failing silently. A pasted link is kept as a link: Elenath can't fetch pages.
5. **Search.** Across titles, text, tags, attachments, event files and boards, with filters for space, folder, tag, kind and date. Results open at the matching spot. The calendar has its own search over events, as in Ithil.
6. **Import.** Drop files or whole folders onto a space or the Inbox: Markdown, plain text, RTF, Word documents, PDFs, images. Originals are copied, never moved. Write docs/IMPORT.md with the steps for each place my notes live today. "Bring in my Ithil calendar" moves my calendar in (see Calendar).
7. **Calendar.** Everything Ithil 1.0.0 does (see Calendar): Week, Day and Month views, events with every field, repeats, subjects, notifications, a Finder folder per event, drag to move and resize, undo.
8. **Boards.** An infinite canvas for drawing and thinking: freehand strokes (trackpad or mouse), rectangles, ellipses, lines and arrows, connectors that stay attached, text, sticky notes, images, note cards that open the note, and charts. Select, move, resize, group, align, reorder, snap, undo, copy and paste. Export a selection or the whole board as PNG, PDF or SVG. Text on a board is searchable.
9. **Charts.** A chart is a small table plus a few settings, stored as text inside a note (a fenced `chart` block) or as an element on a board, and drawn with Swift Charts in the app's palette: bar, line, area, scatter, donut. Export as PNG or PDF.
10. **Goals.** A goal is a note of kind `goal`, with an optional due date and parent goal. Any note can point at goals. A goal's page shows everything that points at it over time, its open tasks and when it last moved, so I can see what brings me closer to what.
11. **The Sky.** A map of a space, or of all spaces that mix: notes are stars sized by their links, goals are bright stars, links are faint lines. Filter by tag, goal and time; click a star to preview the note. The layout is computed once in the background and cached. Nothing drifts or jitters. Provide a list alternative for VoiceOver.
12. **Frames, for design work.** Fixed-size frames on a board (presets such as A4, square post, phone screen, Mac window) with their own background, text styles and color swatches, alignment guides, and export per frame. This is not Figma: no components, auto layout or prototyping. Ask before adding more.
13. **Settings**, one window (General / Spaces / Calendar / Nano bot / Files): appearance Night / Dawn / Match System, the Capture hotkey, library folder, spaces and sealing, subjects with their colors, keywords and homes, default alert, first weekday, notifications, Bring in my Ithil calendar, Nano bot's permissions, self-test and index tools, launch at login, menu bar.
14. **Onboarding** in the app's style: welcome, choose folder, create first spaces, notifications (explained before macOS asks), bring in an Ithil calendar if I have one, meet Nano bot (with its availability explained).
15. **Menu bar extra**, one for everything: today and the next event with Open Files, Capture, the Inbox count, Open Elenath, Settings, Quit. Can be turned off.
16. **Keyboard:** ⌘N new note, ⌘O jump to a note by title, ⌘F find, ⇧⌘F search everywhere, ⌘K Nano bot's command field, ⌘, Settings, and Ithil's calendar keys: ⌘1 / ⌘2 / ⌘3 Day, Week and Month from anywhere, ⌘T today (elsewhere it opens Today), ← / → previous and next, ⌘N a new event while the calendar shows (elsewhere a new note), Delete. The Inbox is ⌥⌘I. Everything is reachable by keyboard, with ⌘Z / ⇧⌘Z everywhere, including after Nano bot's changes and for events. Help menu: "Check for Updates…" and "Report an Issue…" open GitHub in the browser; the app itself never touches the network.

## The index (the retrieval layer)
- The index is a derived cache that can be rebuilt at any time: one SQLite database per space, kept in Elenath's container and never inside the library, which may sit in a synced folder.
- Chunk notes by Markdown structure (heading path plus paragraphs, roughly 200 to 300 tokens), PDFs by page (PDFKit), and images through Vision text recognition. Store each chunk's text and source range.
- Keyword search uses FTS5. Meaning search uses one vector per chunk from the Natural Language framework (`NLContextualEmbedding`, mean-pooled and normalized) behind an `Embedder` protocol, compared by cosine similarity with Accelerate. Fuse the two rankings with reciprocal rank fusion.
- Keyword search must work fully when no embedding model covers a language or its assets aren't on the Mac yet. Check at run time which scripts have a model; don't assume.
- Indexing is incremental (content hashes), runs in the background, can be paused, and is stamped with the embedder's identifier and revision so it rebuilds itself when that changes. Settings has "Rebuild Index".
- Measure retrieval instead of assuming it: keep a small set of demo questions with the notes they should find, run it in the self-test on the real embedder, and use the score to choose between embedder options.
- Open tasks, backlinks, tags and related notes are all read from this index.
- An event's files are indexed into its subject's home space, so sealing applies to them.
- All retrieval for Nano bot goes through this index so sealing holds. Never hand the model a system-wide search tool.

## Nano bot
Nano bot is a small assistant, not a genius: Apple's on-device model has about 3 billion parameters and a context window of a few thousand tokens. Design for that. Swift code runs the show and the model fills in typed blanks.
- **Engine.** Apple's on-device system model through the Foundation Models framework, behind our own `BotModel` protocol. On-device only: never Private Cloud Compute, never a server model. The floor is my Mac, an M1 MacBook Air with 8 GB. The system owns the model's memory; Elenath loads no weights itself.
- **Availability and errors.** Check `SystemLanguageModel.default.availability` and give every unavailable case a plain explanation and a way forward: device not eligible, Apple Intelligence turned off (show where to turn it on), model still downloading. Handle every generation error the same way: unsupported language, guardrail refusal (my Red Cross notes may mention injuries and first aid), context exceeded. A note Nano bot can't process is never lost or blocked. Everything else in Elenath works fully without Nano bot.
- **Every job is a pipeline.** Retrieve candidates in Swift, ask the model one small question with guided generation (`@Generable` types and constrained choices, such as "one of these folder IDs"), validate the result, then propose. Structure always comes from guided generation; never parse it out of free-form text. No job may depend on the model knowing facts about the world.
- **Budget.** Read the context size at run time and never hard-code it (4,096 tokens was the figure on macOS 26; reports for macOS 27 differ). Count tokens with the framework where it can, reserve room for the answer, chunk and reduce long inputs, and use a fresh session per job.
- **Jobs:**
  1. *File*: for each Inbox item, propose a space, folder, title and tags with a one-line reason. When unsure, leave it in the Inbox with a question for me.
  2. *Link*: propose links to related notes, chosen from retrieval candidates.
  3. *Tidy*: turn a messy dump into a clean note. Show it as a diff and keep the original.
  4. *Summarize*: a note, a folder, or a week.
  5. *Ask*: answer a question from my notes, citing the notes used with links. Say "that isn't in your notes" when retrieval is weak, and never pass off the model's own knowledge as mine.
  6. *Spark*: for an idea, ask three sharpening questions, show notes it could combine with, and suggest next steps. It helps me think; it doesn't write the idea for me.
  7. *Review*: weekly. What's new, open tasks, ideas gone quiet, movement toward each goal.
- **Talking to it.** A side panel and a command field: a slash command per job, and plain language routed to one job by a guided-generation classifier. In Ask it may call a few read-only tools (search notes, read a note, list the Inbox, the calendar: what's coming, a given day, an event's files), with a small cap on calls per question and as few tools per session as possible, since every tool costs context.
- **Proposals.** Nano bot never changes anything directly. Every change is a proposal card (what, where, why) that I accept, edit or skip. Accepted changes go through the same code as my own edits and can be undone with ⌘Z or from an activity log. Each job has a setting: "Ask first" (the default) or "Do it and let me review". Nano bot can never delete, never write outside the library, and never add or change an event itself: it may propose events it finds in what I dump, as proposal cards like every other change.
- **Learning, without training anything:**
  - retrieval over everything indexed in the space;
  - every proposal I accept, change or reject is saved in the space's decisions.jsonl, and the most similar past decisions are shown to the model next time, so my corrections stick;
  - memory.md holds short facts and preferences per space. Nano bot proposes additions, and I can read and edit the file in the app or any editor.
- **Safety.** Text from notes and imported files is data, never instructions. Pass it in clearly delimited blocks, and give jobs that read content no tools that write.
- **Running.** One job at a time, in the background, cancellable. Pause in Low Power Mode. The queue survives quitting.
- **Self-test.** Settings > Nano bot > Run Self-Test runs a fixed set of cases through the real model and embedder on my Mac and produces a report I can copy: availability, context size, pass or fail per case, timings. This is how you learn what the real model does, since CI can't run it. Keep prompts in one place, versioned, with tests against a scripted fake model. Re-run after macOS updates, because the model can change underneath us.
- **Lineage.** Nano bot borrows the ideas of the open-source nanobot project (a small readable loop, a few tools, memory in plain files, background jobs) and is written natively in Swift. None of its code is used.

## Calendar
Elenath does everything Ithil 1.0.0 does. Ithil's CLAUDE.md (Features, Quality bar, decisions log) and its docs/RELEASE_CHECKLIST.md are the checklist. Nothing is dropped silently: if something doesn't fit, ask me.
- **What it covers:** Week (the default), Day and Month views, with the mini month, Up next and subjects with visibility toggles; events with every field (title, date, time or all-day, the event's own time zone, subject, location, alert, repeat with "this event or all future ones", notes); subjects with colors and Quick Add keywords; search; notifications that fire while the app is quit ("{Title} in 10 min", "time · location · N files", with "Open Files"); a Finder folder per event occurrence with drop, Quick Look, Show in Finder and live watching; drag to move and resize; undo; Ithil's keyboard shortcuts and menu bar items.
- **Port, don't rewrite.** IthilCore's code and its tests come across into ElenathCore (renamed where names clash), and Ithil's views into the app, adapted to Elenath's AppModel, undo and macOS 26. The product rules in Ithil's decisions log still hold. The screens are in Ithil's docs/DESIGN.md and are written into Elenath's before they are built.
- **Storage:** the `Calendar` folder in the library keeps Ithil's format on disk unchanged: `.ithil/events.json` with its schema version, migrations, backups, safety copy and recovery, and the dated event folders with their markers. So one folder is still my whole backup, and the Calendar folder stays a valid Ithil folder. Documented in docs/FORMAT.md. Elenath's own calendar settings (each subject's home) live in library.json, so events.json stays exactly Ithil's.
- **Each subject has a home:** a space and a folder. Notes for an event go there, a note can be linked to one occurrence (`event` in its front matter; "Notes for this lecture"), and an event's files are indexed into that space. An event's sealing follows its subject's home.
- **The sealing exception** is in Spaces: title, time, location, file count and Open Files cross to the calendar, Today, notifications and the menu bar; nothing else does.
- An event without a subject has no home: it is never sealed, and its notes go to the Inbox.
- **Moving in: "Bring in my Ithil calendar".** I pick my Ithil folder (read-only: Elenath never writes inside it). Elenath copies everything (events, subjects, each event's folder and files), checks the counts, and leaves the original untouched. Running it twice duplicates nothing. It tells me exactly how to stop the alerts Ithil has already scheduled.
- **One app:** one capture panel and hotkey for notes and events, one menu bar extra, one launch-at-login setting, one Settings window.
- **Nano bot** reads the calendar (what's coming, a given day, an event's files) and may propose events it finds in what I dump, as proposal cards. It never adds or changes events itself.
- The Ithil repo is left alone: it stays as it is at 1.0.0.

## Design
- The same world as Ithil. Copy its tokens from Ithil's docs/DESIGN.md and asset catalog into Elenath's own: Night and Dawn colors with their Increase Contrast variants, type, metrics and the star field. Elenath's repo must never depend on Ithil's.
- The calendar's screens are Ithil's (Week, Day, Month, the event editor and details, Quick Add, files, notifications, the menu bar), fitted into Elenath's window.
- Rules carried over: Night is the primary look and Dawn is the same world in daylight. Amber is reserved for selection, focus, primary buttons and "now". Stars appear only in the sidebar, title areas, empty states and the Sky, never behind text I'm reading or on a board. Glows are static assets. Icons are SF Symbols. New York for titles and headings, SF Pro for everything else, SF Mono for code, tabular numerals for times and counts.
- Space colors are Ithil's subject palette (Clay, Teal, Iris, Fern, Rose) plus a custom color.
- No design export exists for Elenath. Before building each new screen (editor, Inbox and capture panel, the calendar, Nano bot panel and proposal cards, search, boards, charts, the Sky, onboarding, settings), write it into docs/DESIGN.md the way Ithil's screens are written: tokens, sizes, symbols, states.
- Nano bot's mark is `sparkles` in the moonlight tint. Its proposals sit on `BackgroundRaised` cards, and only the Accept button is amber.
- App icon: draw three options as SVG in the style of Ithil's icon (the same night sky, hill and small stars, with a constellation where Ithil has its moon), render them, show me, and wait for my pick.
- On macOS 26 and later the system draws Liquid Glass. Content keeps its opaque token backgrounds, as in Ithil (no glass on glass).

## Quality bar
- No lag on an M1 MacBook Air with 8 GB: launches in under a second with 10,000 notes; typing never stutters in a 1 MB note; search-as-you-type answers within 100 ms across 20,000 chunks; switching weeks and months stays instant with 5,000 events; copying a 2 GB file into an event never freezes the UI; panning a board with 5,000 elements stays smooth; Elenath's own memory stays under 400 MB in normal use.
- Notifications fire while Elenath is quit.
- Never lose a keystroke: tests interrupt writes midway and the note must survive.
- Accessibility: VoiceOver labels everywhere, full keyboard access, Reduce Motion and Increase Contrast respected, text at WCAG AA contrast in both themes.
- Localization-ready: every string in a String Catalog, English first.
- Tests (Swift Testing) for: storage, migrations and corruption recovery; name sanitizing; front matter round-trips that preserve unknown keys and bodies byte for byte; link resolution and rename repair; conflict handling; hostile and huge input (Markdown, front matter, chat exports, documents, settings files); the calendar's date math, DST, recurrence, time zones, Quick Add parsing, folder naming and event file operations (Ithil's tests, ported); bringing in an Ithil folder (counts, run twice, a newer schema); the chunker; hybrid ranking with a fake embedder; sealing leak tests, the calendar exception included; every Nano bot pipeline against a scripted fake model; proposal apply and undo; board geometry; chart parsing.
- A crash check on CI: the `-demo` app runs a scripted pass through its screens and actions, and CI fails if it crashes.
- Before every release, an independent review for errors and security problems (docs/RELEASE_CHECKLIST.md).
- Zero warnings. Format with swift-format.
- A `-demo` launch argument loads an invented sample library (Uni, a sealed Red Cross space, Ideas, a week of events), a scripted fake model and a fixture Ithil folder into a temporary folder, for screenshots and testing. It never touches real data and never schedules real notifications.

## Repo
- Bundle ID `io.github.visaug36.Elenath`.
- README.md: icon, one-line pitch, screenshots, features, download and first-launch steps (the app isn't notarized, so explain System Settings > Privacy & Security > Open Anyway, and say up front "download Elenath-x.y.z.zip, not Source code"), how files are stored (the folder tree), what Nano bot needs and can't do, privacy, backup and moving to a new Mac, uninstall, FAQ, license, and a note that "Elenath" is Sindarin from J.R.R. Tolkien's writings and the project isn't affiliated with the Tolkien Estate.
- docs/: DESIGN.md, ARCHITECTURE.md, FORMAT.md, IMPORT.md, RELEASE_CHECKLIST.md. CHANGELOG.md (Keep a Changelog and SemVer). If the repo is public, add the community files Ithil has.
- CI (GitHub Actions) as in Ithil: swift-format lint, tests, a Release archive, the String Catalog check, and failure on any warning, on every push and pull request.
- Workflows have the least permissions they need and pinned actions, and nothing a pull request from a fork can use to push, release or read secrets. No new personal data in the history (the past is left as it is; see the log).
- A Screenshots workflow from Phase 1 on, so every phase's pull request shows me real screenshots from `-demo`. I often review from my phone.
- Releases: an arm64 Release build, zipped with ditto, with its SHA-256, attached to a GitHub Release with notes from CHANGELOG. Ad-hoc signed. Tag pushes are refused in this environment (see Ithil's log), so first try having the workflow create the tag and the release itself when the version changes on `main`. If that can't work, do it Ithil's way: I create the tag from the Releases page, and you tell me exactly what to tap. You may publish 0.x prereleases yourself after a phase is merged; 1.0.0 only when I say so.
- scripts/install.sh builds Release locally and copies it to /Applications.
- Never commit: my notes, anything from my real library or Ithil folder, design references, secrets, personal info, absolute paths, xcuserdata, DerivedData. Demo content is invented.

## How to work
- **Environment** (the same as for Ithil): you work in a Linux cloud container without Xcode, so GitHub Actions is the compiler and test runner. Write each module's API contract in docs/ARCHITECTURE.md first, implement against it, have it reviewed independently, integrate, and let CI on the pushed branch judge. Read failures from the xcresult summary and swift-format's printed patch.
- **Look things up.** Foundation Models, Liquid Glass and the other 2025 and 2026 APIs are newer than what you remember, and they changed again in macOS 27. Read Apple's current documentation before coding against them.
- **Phases.** Each ends with CI green, screenshots, updated docs and CHANGELOG, this log updated, and a short list of what I should try. Order changed on 2026-11-15: the review, then the calendar, then search by meaning, then Nano bot, so Nano bot is built into the finished app.
  1. Foundation (done, 0.0.1).
  2. Notes (done, 0.1.0). **Stop point: I install it and move my notes in.**
  3. Review: test the whole app and repo for errors and security problems with an independent reviewer; fix each finding with a test; add the crash check to CI. Release 0.1.1, then tell me plainly what only I can test on my Mac.
  4. Calendar: Ithil moves in (see Calendar), with the leak tests extended to the calendar exception. Release 0.2.0.
  5. Meaning: chunking, the embedder, hybrid search, related notes, PDF and image text (event files included), and the leak tests extended to suggestions. Release 0.3.0.
  6. Nano bot: the engine and availability, the File, Link, Tidy, Summarize and Ask jobs, the calendar tools and event proposals, proposals, undo and the activity log, learning, the self-test, and the leak tests extended to prompts. Release 0.4.0. **Stop point: I run the self-test and send you the report, and you tune from it.**
  7. Boards and charts.
  8. Goals and the Sky, with the Spark and Review jobs.
  9. Frames, an accessibility pass and polish. Get 1.0.0 ready, but don't publish it until I say so.
- **Before every release,** repeat the review of phase 3 (docs/RELEASE_CHECKLIST.md).
- **My reports come first:** when my diagnostics report or bug reports arrive, they come before the phase in progress.
- **Working mode.** Carry each phase through to merged and green yourself, and push after each one. Wait for me only at the stop points, and when a product decision is unclear. In that case ask me instead of guessing.
- Don't start a phase while the one before it has known bugs.

## Not now
A Windows or phone version, sync between devices, a different local model (if Apple's proves too weak, the route is an MLX-backed model behind `BotModel`, but it adds a package and a model download, so ask first), changes to the Ithil repo (it stays at 1.0.0), sharing or collaboration.

## Decisions & status log
Keep this section current. Newest first.

### Decisions
- **Check everything after phase 5 (user, 2026-11-25):** "once you finish this phase check for everythinggg,
  security, functionability and everything". Before 0.3.0 is released, the review is wider than section R:
  security and sealing, every feature against this brief (does it work as described), data safety,
  performance against the quality bar, accessibility, the docs. Independent reviewers, each finding fixed
  with a test.
- **The review for 0.2.0 (2026-11-21).** Two independent reviewers (files and untrusted input; sealing,
  privacy and the repository) found 15 problems; the usage limit stopped them once, and they were resumed.
  Each is fixed, with a test that fails without the fix (checked by undoing each fix in a scratch copy), or
  a crash-check step. The rules that came out of it:
  - **Bring In** copies hidden files under their own names and counts them (`FileCopier.Naming.exact`);
    only markers, `.DS_Store`, AppleDouble and icon files and unfinished copies stay behind. A folder Ithil
    never marked gets the marker of the one occurrence whose folder it is. `run` returns Ithil's calendar
    (`source`), and the app merges only that into the calendar as it is when the copy ends. `.ithil` and
    `backups` must be real folders (read-only opening too); copies are rooted at the Calendar folder.
  - **The expander** looks back at most 366 days and keeps the latest 32 occurrences of a series that last
    into a range: one event lasting centuries had expanded its whole series (739,942 occurrences a week).
  - **Fail closed:** a `calendar` or `homes` that isn't an object makes every subject's home unreadable;
    the calendar settles it when it opens (an unreadable `{}` entry per subject, the value kept under
    `foundUnreadable`). Two entries for one subject are unreadable. Calendar settings are backed up at once
    when they change.
  - **Deleting a subject** whose events would come out of a seal (sealed, gone or unreadable home) is
    refused with an explanation, instead of keeping per-event homes in library.json (a new format key that
    could itself be damaged). The editor doesn't change the subject of an event whose notes it hides.
  - **The sidebar** remembers the workplace its tags and folders were read for and clears sealed ones at
    once when the calendar's workplace changes (the calendar tells the window).
  - **Quick Capture's event** reads the first line after a space prefix, at most 300 characters
    (`CaptureEvent`), takes a subject homed in that space, and is refused for a sealed space without one.
  - **A newer events.json** arriving while open makes the calendar read-only; recovery is shown on reload.
  - **Moving the library** refuses while files copy into events and waits for the calendar's saves and its
    folders' disk work. Not covered by an automated test: the demo can't move its library. It is on the
    user's checklist with the rest of the move.
  - **check-rules:** rule 4 and 4b match a query by name and first argument label (each overload needs its
    own leak test); rule 5 also covers location, notes, keywords and `describing`.
- **Phase 4 as built: the calendar (2026-11-19).** Ithil 1.0.0 moved in, ported, not rewritten: IthilCore and
  its tests into `ElenathCore/Calendar` (Ithil's `LibraryCodecTests` too, with a byte-for-byte golden file of
  events.json), Ithil's app layer into `Elenath/Calendar` (its `AppModel` is `CalendarModel`). The rules that
  came out of it:
  - **The calendar is `<library>/Calendar`, in Ithil's format**, with Ithil's backups and Elenath's safety copy
    beside the spaces'. `Calendar` is reserved like `Inbox`; a space called "Calendar" from 0.1 stays a space
    and the calendar asks for a rename. A link or file called Calendar is never used. events.json may be
    128 MB (settings files keep 8 MB); markers are read up to 64 KB. The library move takes the calendar along.
  - **Subject homes** are in library.json (`settings.calendar`), with the calendar's id. A home that can't be
    read or whose space is gone **fails closed**: the events' content is read from nowhere until the subject
    gets a home again (the brief's "counts as no home" would have opened a deleted sealed space's events).
  - **`CalendarReach` is the calendar's one decision point** beside `Reach`: title, time, location and file
    count everywhere; notes, file names and linked notes only where the home's content may be read. The
    calendar works "everywhere" or inside one space ("Open in Red Cross", a capsule in the toolbar to leave).
    The leak tests cover both halves, and check-rules rule 4b requires every `CalendarReach` query in them.
  - **Notes for an occurrence** use front matter `event`; the index keeps it (schema 3) and
    `Retrieval.notes(linkedTo:from:)` finds them through `Reach`. Notes for events without a home go to the
    Inbox, and like every Inbox item they aren't shown elsewhere.
  - **Bring in my Ithil calendar** reads the Ithil folder only, merges by id (a subject of the same name is
    reused), copies event folders file by file without overwriting (markers written anew, hidden files left),
    checks every file, and takes the merge in as one undo step. Running it again brings in nothing twice.
  - **Event files join the main search in 0.3** with their text (phase 5); in 0.2 they are found from the
    calendar, and the leak tests check they never reach the index.
  - **Shortcuts** as agreed: ⌘1/2/3 Day/Week/Month, ⌘T, ⌘←/→, ⌘N (event in the calendar), ⌥⌘I Inbox; Quick
    Capture ⌥Space by default (a recorded shortcut stays). Settings has Calendar and Subjects tabs; the menu
    bar extra is `star.fill` with Capture and the Inbox; onboarding adds notifications and Ithil pages; an
    empty calendar offers to bring Ithil's in.
  - **Undo, corrected:** phase 3's "a group of its own when no group is open" didn't hold. With `groupsByEvent`
    on, an explicit `beginUndoGrouping()` at level 0 also opens AppKit's event group, which closes only after
    the next event, so changes made without one (Bring In after its copy, the crash check) all joined one
    group; the crash check's log showed one Undo taking back three note steps, unnoticed since phase 3.
    `UndoManager.registerAsOwnGroup` opens the group with `groupsByEvent` off; notes and the calendar use it
    on the same window undo manager. The crash check now names every Undo and Redo it expects and checks
    what each puts back.
  - **Small choices, shown to the user:** Ithil's Up next is on Today and in the menu bar, not in the
    calendar's sidebar (DESIGN.md); the app's back and forward stay beside the calendar's ‹ Today › in the
    toolbar; the demo's "Halloween at the observatory" is a "Night at the observatory" away from 31 October,
    since Elenath's demo week is in November.
- **Phase 3 as built: the review (2026-11-16).** Two independent reviewers (one on files and untrusted input, one on links, SQLite, privacy, sealing and the repository) and the new crash check found the problems below; each is fixed with a test that fails without the fix. The rules that came out of it:
  - **Linear time for hostile text.** The Markdown scanner matches brackets and parentheses once per stretch, looks code spans up by run length and keeps CommonMark's openers bottom; `HostileInputTests.expectLinear` compares a sixteenth of the input with all of it (at most 40× the time). 300,000 random notes scanned the same before and after.
  - **Files that aren't what they seem.** `readData` refuses anything but a regular file (a named pipe blocks forever); listings, the index, attachments and imports skip pipes and links; a copied folder never holds a link; a chat's attachment names must be regular files right in the export; `.space`, `.elenath` and `backups` that are links are refused.
  - **Every `Retrieval` query takes a workplace**, the ones about one note too, and answers nothing about a container the workplace may not read. The leak tests ask each from every outside workplace.
  - **The index** binds and reads text by length (NUL), keeps 32 search words, matches a one-letter word whole and looks for one or two letters of a spaced script only at word starts; a damaged database is replaced and rebuilt, an unopenable one is skipped, a replaced file is reopened.
  - **Opening** (`OpenPolicy`): web and mail links open at once, other schemes ask (naming the app); documents, pictures, sound and video open at once, anything else asks with "Show in Finder" as the default.
  - **Sealing in rescue and Recovery:** edits to a vanished note go back into its own space; only a space that mixes may use the Inbox; Recovery keeps copies by space (`RecoveryFolder`), never replaces one, and puts each back in its space; a copy whose space is gone stays and is shown in Finder.
  - **Limits** (`NoteLimits`): notes over 16 MB aren't opened (banner), over 2 MB are plain text, the index reads 4 MB, huge text and documents import as files; settings files over 8 MB or 64 levels deep are refused before parsing (CI on macOS crashed on deep nesting: secondary threads have 512 KB stacks, Linux's tests didn't show it). Pictures in the editor are decoded once at column size into a 160 MB cache, and not at all over 100 megapixels.
  - **Web pages** are read by `HTMLText`, never WebKit; other documents by AppKit with an explicit type.
  - **Logs:** check-rules.sh rule 5 fails on a log line that makes a path, title, name, text, body, prompt or error description public. **Workflows:** rule 6 requires actions pinned to commits and `contents: read` at the top; the release and screenshot workflows build with read-only tokens, and a separate small job with no project code publishes or pushes.
  - **The Trash in the sandbox.** Undoing a move to the Trash restores the item when Elenath can reach it; when it can't (the sandbox, an emptied Trash) the message names Finder's Put Back, and a failed undo or redo drops the older undo steps instead of failing at each. On the runner the sandboxed app did put a note, a folder and a space back (the demo library lives in the app's container); whether it can for a library in Documents is on the user's checklist. This answers Ithil's open question for the container case.
  - **Undo.** Steps run one after another (`AppModel.lastStep`), never overlapping, and each registers an undo group of its own when no group is open: without user events AppKit put several programmatic steps into one group, and undoing it ran their inverses at the same time ("That file isn't there any more"). A title field that had focus while its note was renamed or moved committed the old title when it lost focus; a rename from elsewhere now updates a title the user hasn't changed.
  - **The crash check** (`-demo -demoSelfCheck`, CI job "Crash check") names every action, fails at the first reported error, skips the `[[` completion list (it runs a loop that waits for a real keyboard; the titles are checked directly), and imports hostile files including a named pipe, a note of embeds and notes too large to open or style.
- **Ithil moves into Elenath (user, 2026-11-15):** "I don't want to open two apps." Elenath gets everything Ithil 1.0.0 does, and then it is the only app the user opens. The brief was rewritten for it: the pitch, a Calendar section in place of the Ithil bridge, Features, Spaces (the calendar exception to sealing), Design, Quality bar, the phases, Not now. The user's terms:
  - First a review of the whole app and repo for errors and security problems, with an independent reviewer, fixed with a test each, released as 0.1.1, plus an automatic crash check on CI. The review is repeated before every release from now on.
  - Then the calendar, before search by meaning and Nano bot, so Nano bot is built into the finished app. New order: review (phase 3, 0.1.1), calendar (4, 0.2.0), meaning (5, 0.3.0), Nano bot (6, 0.4.0, stop point), then boards and charts, goals and the Sky, frames and polish.
  - Port Ithil's code, tests and views; don't rewrite. Keep its product rules. Keep its format on disk unchanged in a `Calendar` folder unless there is a strong reason against it. "Bring in my Ithil calendar" copies everything, checks the counts, leaves the original untouched and never duplicates.
  - The calendar is for everything: events from every space show fully on the calendar, Today, notifications and the menu bar, sealed spaces included. That is the one deliberate exception to sealing, and it covers title, time and location only.
  - Each subject has a home (a space and a folder). One capture panel for notes and events, with a note as the default. Nano bot reads the calendar and only ever proposes events.
  - No need to wait for the 0.1.0 feedback to start; reports from the user come first when they arrive. The Ithil repo stays as it is at 1.0.0.
- **Answers to the calendar plan (user, 2026-11-15):** the plan stands, and building starts with phase 3.
  - Git history: no rewrite. The user turned on GitHub's "Keep my email addresses private". The same address is in Ithil's history more often, so rewriting Elenath alone wouldn't hide it: the past is left alone in both repos.
  - Capture hotkey ⌥Space. If it can't be registered because Ithil still runs, the app says so.
  - Capture shows the event it understood ("Thu 10:00 · Physics") with the ⌥↩ hint beside it, and the line is clickable.
  - Shortcuts: ⌘1/2/3 Day/Week/Month from anywhere, ⌘T today (Today elsewhere), ←/→, ⌘N a new event in the calendar (a note elsewhere), the Inbox on ⌥⌘I.
  - Calendar search finds every event by title and location, never by a sealed event's notes or files; the main search outside a space shows nothing from a sealed space.
  - A sealed space's events are like any other in notifications: the file count, and Open Files opens the folder in Finder. The seal keeps that material out of search, suggestions and Nano bot; it doesn't hide the user's files from them. So the exception also covers an event's file count and opening its folder.
  - An event without a subject has no home, is never sealed, and its notes go to the Inbox.
- **Ithil (user, 2026-11-10)**, superseded on 2026-11-15: Elenath was to look like Ithil and read its data through a read-only bridge.
- **Phase 2 as built (2026-11-13):**
  - **App layer:** `AppModel` (with `+Notes`, `+Import`, `+Files`, `+LinkRepair`) owns the library, navigation and every change; `EditorSession` owns the open note's autosave (0.5 s), conflicts and recovery copies. The editor is an `NSTextView` on TextKit 1, restyled per edited paragraph from the core's scanner.
  - **Undo:** every change to notes, folders and spaces is an `UndoableStep` on the window's undo manager; a step returns its own inverse. Typing has its own undo per note.
  - **Renames in Finder:** the index recognizes them; a banner offers to update the links that still point to the old place ("Update Links", one undoable step; Undo restores a note only if it still says what Elenath wrote). Nothing is rewritten without that click. The watcher's changes wait while one of Elenath's own steps runs, so its own renames are never offered.
  - **Imports:** a `.zip` is copied as it is (unzipping would need code outside the system frameworks); the import card says to unpack a WhatsApp export first and stays until closed.
  - **Search filters:** the space (spaces that mix), the folder (once a space is chosen, or inside a sealed space), the kind, the tag and the time.
  - **Counts** use automatic grammar agreement (`^[\(n) item](inflect: true)`), so the catalog has no plural variants to keep.
  - **Platform facts from CI:** `NSMenuItem` isn't main-actor isolated in the macOS 26 SDK, so a menu item that runs a closure goes through a main-actor `NSObject` target (`MenuAction`). `showSettingsWindow:` does nothing since macOS 14; the demo opens Settings with the `openSettings` environment action. Xcode 27 warns about `[weak self]` inside a closure that captured `self` strongly (`#ImplicitStrongCapture`).
  - **String Catalog check:** it also lists the keys the code no longer uses (from the `.stringsdata` JSON), as warnings with `UNUSED` lines.
  - **Independent review of the app layer (2026-11-15):** it found 11 problems: 7 could lose text, 1 leaked titles across a seal, 3 were bugs. All are fixed. The rules that came out of it: the session reads the text view synchronously whenever it may go away; Elenath's own steps hold the open note's saves (`beginStep`/`endStep`); edits to a note whose file, space or library vanished go into the Inbox as a conflict copy when it closes or the app quits; `NoteStore` never recreates a vanished space or library folder; edits that can't be written go to Recovery with unique names and are offered at the next launch; a save never waits for the index; moving the library pauses the watcher; link-update offers follow `Reach`.
  - **Defaults chosen during the core's review, shown to the user:** titles Elenath makes turn `# | ^ [ ]` into "-"; a space restored from a backup is sealed until the user decides; a space folder copied in Finder gets an id of its own and keeps every setting.
- **Icon (user, 2026-11-11):** option A, the open notebook under the Plough. The master is `docs/icon/icon.svg`; `scripts/icon/make-appicon.sh` renders the AppIcon set and the README images from it. The other two options are gone from the tree (they are in the history).
- **Import (user, 2026-11-11):**
  - WhatsApp: the notes are in a chat with oneself, so every message is a note. A chat export becomes notes where it is dropped (usually the Inbox): messages sent within a few minutes of each other are one note, dated when they were sent.
  - The other laptop: files in folders. Dropping a folder covers it.
  - The phone: no steps per app are wanted. The user's words: "dont care about where other notes are, I will import them using the built in ai". So docs/IMPORT.md gives the general route (paste, or export and drop on the Inbox), and Nano bot's File job does the sorting. Nano bot arrives in Phase 4 (0.2.0); until then the Inbox holds what was dumped and filing is by hand. The user was told this.
- **Phase 1 as built (2026-11-11):**
  - **Project layout:** as Ithil's. `Elenath.xcodeproj` (objectVersion 77, file-system-synchronized folders, so new files need no project edit), targets `Elenath`, `ElenathCore` (static framework) and `ElenathCoreTests` (Swift Testing, not hosted). Swift 6 language mode, macOS 26.0, `ARCHS = arm64`, ad-hoc signing, sandbox and hardened runtime, entitlements in `Config/Elenath.entitlements`.
  - **Color tokens:** Ithil's names and values. `Subject{Clay,Teal,Iris,Fern,Rose}` became `Space…`.
  - **CI:** two jobs, both green from the first run, about two minutes each. The gate runs on `macos-26` with Xcode 26.6 (macOS 26.7.2): the project's rules, lint, tests, a test count from the xcresult (a run with no tests fails), the String Catalog check, an arm64 Release archive and zero warnings. The second job runs on `xcode-27` with Xcode 27.2 (macOS 27.0.1) and may fail without failing the run.
  - **Rules as checks:** `scripts/check-rules.sh` fails on a Swift package, on a UI import in `ElenathCore`, and on any entitlement beyond the sandbox, app-scope bookmarks and user-selected files, in the project and in the archived app.
  - **Platform facts from CI:** the system SQLite on macOS 26.7.2 is 3.51.0, and on macOS 26 and 27 it has FTS5 and the trigram tokenizer (`SQLiteProbeTests`).
  - **Screenshots:** the Screenshots workflow commits `docs/images/window-*.png` to the branch it ran on, so pull before pushing after a run. With no toolbar items, a window needs `.toolbarBackground(.hidden, for: .windowToolbar)` or macOS 26 draws a bare toolbar band.
  - **Release workflow:** on a push to `main` it publishes `MARKETING_VERSION` when CHANGELOG has a dated section for it and no release holds the zip yet, creating the tag itself with `gh release create --target`. Versions below 1.0.0 are prereleases. From 1.0.0 it only publishes when run by hand with "publish" typed in, or to complete a release the user made on the Releases page. **It works:** 0.0.1 was published this way on 2026-11-11. To release a version: set `MARKETING_VERSION`, give its CHANGELOG section a date, merge to `main`.
- **Local checks (2026-11-11):** `ElenathCore` and its tests build and run on Linux with the open-source toolchain, so most logic is checked in seconds without CI. `scripts/dev/bootstrap-swift.sh` installs Swift 6.3.3 (the compiler in Xcode 26.6), and `scripts/dev/core-test.sh` lints everything and runs the core tests. Only the app layer needs CI to compile. To keep this working, Apple-only calls in `ElenathCore` sit behind `#if canImport` or a protocol (docs/ARCHITECTURE.md).
- **Defaults Claude chose while writing the docs (2026-11-11), shown to the user to confirm or change:**
  - Notes Elenath creates start with front matter (`id`, `created`). Notes from elsewhere stay untouched until first edited in Elenath.
  - A note's title is its file name. A new top-level folder made in Finder becomes an unsealed space. A `space.json` that can't be read or restored makes the space sealed until the user decides.
  - Today and other "everywhere" views read no sealed space; a sealed space has its own page. Inbox items are found only in the Inbox.
  - Links take the color of the space they point to and are underlined, since amber is reserved. Markdown markers stay visible and dimmed. Note text is 15 pt. The editor is an `NSTextView` on TextKit 1.
- **Cloud environment (2026-11-11):** the user's Default environment has unrestricted network access and no setup script. It is left as it is; the Swift toolchain is installed per session with the bootstrap script.
- **Phase 1 plan (2026-11-10):** shown with the start-up questions. The user answered the questions and raised no objection, which is taken as the OK. Nothing reaches `main` before the icon pick, so the user can still object. The plan's choices:
  - CI gates on `macos-26` with the newest Xcode 26.x there (26.6), because tests and screenshots then run on the macOS generation the user's Mac has. A second job builds and tests on `xcode-27` and may fail without blocking a merge. Switch the two when the user moves to macOS 27.
  - After Phase 1 is merged, a 0.0.1 prerelease of the empty window proves that the release workflow can create the tag itself.
  - 0.1.0 gets a small diagnostics report (model, embedding assets, folder bookmark), so the "needs a real Mac" items are answered at the first stop point.
- **Start-up answers (user, 2026-11-10):**
  - Languages: mainly English. Which others isn't known yet.
  - Notes today: WhatsApp chats, old Markdown files, and notes on a phone and on another laptop (the apps aren't named yet).
  - Ithil folder: Ithil's default, `~/Documents/Ithil`.
  - Spaces: left to Claude. Recommended: Uni, Red Cross (sealed), Ideas and Personal. Only Red Cross is sealed, because it can hold other people's details; any space can be sealed later in Settings. Onboarding suggests these four and the user can change them there.
  - Repo: public. MIT license, copyright "Visaug36", with Ithil's community files. Because the repo is public, this log and the docs name apps and languages but no personal paths or details.
- **Foundation Models facts (Apple's documentation, read 2026-11-10; not a decision, here so it isn't looked up twice):**
  - `SystemLanguageModel.contextSize` works from macOS 26.0 (back-deployed; in the SDK since 26.4) and `tokenCount(for:)` from macOS 26.4, so both work on the user's Mac and compile with Xcode 26.6. Apple's documentation gives the context window as 4,096 tokens.
  - The unavailable reasons are `deviceNotEligible`, `appleIntelligenceNotEnabled` and `modelNotReady`. Generation errors on macOS 26 are `LanguageModelSession.GenerationError` (context window exceeded, guardrail violation, refusal, unsupported language or locale, rate limited, and others).
  - The on-device model changed in macOS 26.4 and changes again in macOS 27, so prompts need re-testing after both.
  - Only in the macOS 27 SDK: `SystemLanguageModel.Variant`, dynamic profiles, the `LanguageModel` protocol for other models (Apple lists open-source MLX and Core AI adapters for it), `PrivateCloudComputeLanguageModel`, and the new error types (`LanguageModelError` and others). On macOS 26 the fallback is `GenerationError` behind an availability check.
- **Environment (2026-11-10):** the same Linux cloud container as for Ithil. Apple's documentation can be read from it: `https://developer.apple.com/tutorials/data/documentation/<path>.json` returns a page as JSON. `docs.github.com` and `github.blog` are blocked by the environment's network policy, so facts about runners come from the `actions/runner-images` repository.
- **Name (user, 2026-11-10):** Elenath. Repo https://github.com/Visaug36/Elenath.
- **Platform (user, 2026-11-10):** Mac only for now. Built natively in Swift like Ithil (proposed in planning, and the user went ahead with it). Windows maybe later, as a separate app reading the same folder.
- **Fully local (user, 2026-11-10):** no network, no accounts, no cloud model.
- **Nano bot (2026-11-10):** the user asked for a modest on-device model with an M1 MacBook Air (8 GB) as the floor and left the choice of bot open. Chosen in planning: Apple's built-in on-device model, and a lean native bot modelled on the open-source nanobot instead of an embedded copy, because bundling that Python project and a downloaded model would break the no-network, no-dependency sandbox. Both choices were pointed out to the user, who went ahead with the brief.
- **My Mac (user, 2026-11-10):** M1 MacBook Air, 8 GB, macOS 26.6, Apple Intelligence on.
- **Retrieval (user, 2026-11-10):** Nano bot learns from my own material through a local index.
- **Spaces (user, 2026-11-10):** things connect by default, and any space (Red Cross, for one) can be kept apart.
- **Goals (user, 2026-11-10):** room for them in the data from day one; the screens come in Phase 7.
- **Ithil (user, 2026-11-10):** Elenath looks like Ithil, and Nano bot can read Ithil's data.

### Open items
- Not answered yet: which other languages besides English. Keyword search is built for space-separated words first, with the trigram table for anything else.
- The defaults listed under Decisions were shown to the user on 2026-11-11. They stand unless the user changes them.
- The Liquid Glass app icon for macOS 26 (an Icon Composer `.icon` file) is not planned; the AppIcon set is used, as in Ithil.
- Not verified (the page is blocked here): whether GitHub has declared the `xcode-27` image generally available.
- Whether the embedder and the model cover the other languages, once they are known.
- Needs a check on a real Mac (CI can't do it): Does the on-device model answer from the sandboxed, ad-hoc-signed app? Do the embedding assets arrive without a network entitlement? Do the folder bookmarks survive an update to a new ad-hoc-signed build? Version 0.1.0's diagnostics report (Settings › Files › Run Diagnostics) answers the first two; ask the user for it at the stop point.
- Not covered yet: a space folder renamed in Finder breaks links written as `[[Space/Title]]` in other spaces (renaming the space in Elenath rewrites them). The banner only offers notes that moved inside one space.

### Status
- 2026-11-25: **Phase 5 (meaning) in progress; stopped at the user's request** ("finish this little task
  and stop"). Done on `claude/new-session-fplgmb` (598 core tests pass locally): the contract in
  docs/ARCHITECTURE.md ("Meaning"), the chunker, the embedder layer (`Embedder`, models by script,
  `ContextualEmbedder` behind `#if canImport(NaturalLanguage)`, `HashingEmbedder` in the tests), index
  schema 4 with chunks, vectors and stamps and the background embedding pass, `Retrieval.searchByMeaning`
  (reciprocal rank fusion) and `Retrieval.related(to:from:limit:)`, with the leak tests asking both (shown
  to fail when `related` ignores seals). Not built yet: PDF, picture and event-file text (task 35), the
  app layer with DESIGN.md first (36: fused search, Related under notes, indexing status and pause, the
  diagnostics benchmark), then the full check the user asked for and 0.3.0 (37). The app layer hasn't been
  compiled with these changes on CI beyond the push of the index schema.
- 2026-11-21: **0.2.0 published; phase 4 (the calendar) done.** Merged (https://github.com/Visaug36/Elenath/pull/4)
  and published by the Release workflow as a prerelease (https://github.com/Visaug36/Elenath/releases/tag/v0.2.0,
  `Elenath-0.2.0.zip` with its SHA-256). The user was given what to try (docs/RELEASE_CHECKLIST.md, section 5).
  Next: phase 5, meaning, with its contracts in docs/ARCHITECTURE.md first.
- 2026-11-21: **Phase 4 (the calendar) built, reviewed and green; 0.2.0 dated.** Ithil 1.0.0 is in: its
  core and tests ported, its views fitted into Elenath's window, the calendar in `<library>/Calendar`,
  Bring In, subject homes and the sealing exception. The release review (two independent reviewers) found
  15 problems, all fixed (see "The review for 0.2.0"); the undo grouping from phase 3 was also corrected.
  CI is green on macOS 26 and 27: 593 tests, the String Catalog, the arm64 Release archive, zero warnings,
  and the crash check through every calendar step. Next: the PR, merge, the Release workflow publishing
  0.2.0, then tell the user what to try (docs/RELEASE_CHECKLIST.md, section 5) and start phase 5 (meaning).
- 2026-11-16: **0.1.1 published; phase 3 (the review) done.** The review was merged (https://github.com/Visaug36/Elenath/pull/3) and the Release workflow published https://github.com/Visaug36/Elenath/releases/tag/v0.1.1 as a prerelease, with `Elenath-0.1.1.zip` and its SHA-256: the reworked workflow (a read-only build job, then a small publish job that runs no project code) works, creating the tag itself as before. The user was given what only their Mac can test (docs/RELEASE_CHECKLIST.md, sections 4 and 5, and the diagnostics report). Next: phase 4, the calendar, with contracts in docs/ARCHITECTURE.md and screens in docs/DESIGN.md before code.
- 2026-11-16: **Phase 3 (the review) built; CI green, the crash check included.** 277 core tests pass locally and on macOS 26 and 27, with the String Catalog, the Release archive and zero warnings, and the self-check walks through every step on the runner. The crash check found three more bugs on the way (the `[[` list blocking a run without a keyboard, overlapping undo steps, the title field renaming a note back), all fixed. A timing test that flaked once on macOS 27 now takes its best of three runs. Next: a PR, merge, and the Release workflow publishing 0.1.1; then tell the user what only they can test (docs/RELEASE_CHECKLIST.md, sections 4 and 5), and start phase 4 (the calendar).
- 2026-11-15: **The user answered the plan's questions; phase 3 (review) started.**
- 2026-11-15: **Change of plan: Ithil moves into Elenath.** CLAUDE.md rewritten for it. Ithil 1.0.0 was read again for the plan: about 5,000 lines of IthilCore, 326 tests and 16,000 lines of app code to port. The plan and questions were sent to the user; nothing is built until they say OK. A first finding for the review is already known: personal data in 3 merge commits on `main`.
- 2026-11-15: **0.1.0 published; stopped for the user (first stop point).** Phase 2 was merged (https://github.com/Visaug36/Elenath/pull/2) and the Release workflow published https://github.com/Visaug36/Elenath/releases/tag/v0.1.0 as a prerelease, with `Elenath-0.1.0.zip` and its SHA-256, creating the tag itself. Waiting for the user to install it and move their notes in. Ask them for: the diagnostics report (Settings › Files › Run Diagnostics), what broke or felt wrong while moving notes in, the other languages they write in, and any default to change. Phase 3 (meaning) starts after that, and not while 0.1.0 has known bugs.
- 2026-11-15: **Phase 2 built and reviewed; PR open** (https://github.com/Visaug36/Elenath/pull/2). The app compiles with zero warnings on Xcode 26.6 and 27.2, 240 core tests pass, and the Screenshots workflow shows every screen. The independent review of the app layer ran once the usage limit reset; its 11 findings are fixed. Next: CI green on the fixes, date the 0.1.0 changelog section, merge, check that the Release workflow publishes 0.1.0, then stop for the user to install it and move their notes in.
- 2026-11-11: **0.0.1 published; Phase 2 started.** The Release workflow built the merge commit and published https://github.com/Visaug36/Elenath/releases/tag/v0.0.1 as a prerelease, creating the tag itself, so no tag ever has to be pushed from here or made by hand. Phase 2 has begun on `claude/new-session-fplgmb`, restarted from `main`: the name rules, the model types, the folder policy and the document store for library.json and space.json are in `ElenathCore` with their tests (74 tests locally). Next in Phase 2, in this order: `LibraryCatalog`, `NoteText` and front matter, `NoteStore`, the Markdown scanner, links, the index with `Reach` and the leak tests, capture, import; then the app layer.
- 2026-11-11: **Phase 1 merged** (https://github.com/Visaug36/Elenath/pull/1). The user picked icon A. The independent review the brief asks for was started twice and cut off both times by the account's usage limit, so it did not report; Claude checked the riskiest points itself instead (the release workflow's cases, run locally with a fake `gh`; the sealing choke point; the format against the architecture) and added `Retrieval.text(of:from:)` to the contract. Run an independent review on the first Phase 2 modules, where it matters more. Next: check that the Release workflow published 0.0.1, then Phase 2.
- 2026-11-11: **Phase 1 built, waiting for the icon pick.** The project, tokens, the empty themed window, CI, the Screenshots and Release workflows, scripts and community files are on `claude/new-session-fplgmb`, with docs/DESIGN.md, docs/FORMAT.md and docs/ARCHITECTURE.md for version 0.1. CI is green on both jobs (12 tests, zero warnings). An independent review was run. What is left: wire the picked icon in, date the 0.0.1 changelog section, merge, and check that the Release workflow publishes 0.0.1.
- 2026-11-10: **start-up done, waiting for the user.** The brief is saved as CLAUDE.md on `claude/new-session-fplgmb`. Ithil was read: its CLAUDE.md, docs, the Xcode project, Config, scripts, workflows, and the storage, folder access, hotkey, appearance and onboarding code. The repo is public and has no license yet. Nothing is built.
  - Runners on 2026-11-10 (from `actions/runner-images`): `macos-26` (also `macos-latest`) is macOS 26.7.2 on arm64 with Xcode 26.0.1 to 26.6; 26.6 is the default and its SDK is macOS 26.5. `xcode-27` is macOS 27.0.1 with Xcode 27.0, 27.1 (the default) and 27.2, and the README still marks that image as a preview. `macos-15` has Xcode 16.x and 26.0.1 to 26.3. The macOS 14 images were retired on 2026-11-02.
- 2026-11-10: brief written. Nothing built yet.
