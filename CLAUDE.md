# Elenath

Save this brief as CLAUDE.md in the repo root, follow it in every session, and keep it updated as we make decisions.

You're building Elenath, a native macOS app that replaces the seven places I keep notes with one. It's a private, offline home for my ideas, university work, Red Cross work and everything else I do, with a small on-device assistant called Nano bot that files what I dump on it and shows me how things connect. It's the sibling of Ithil, my calendar (https://github.com/Visaug36/Ithil): the same look, the same principles, plain files in real Finder folders. It's for me alone, on my Mac. Reliability beats features. My notes are never lost, never locked in, and never leave the Mac.

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
- The language model, the embedder, the file system, the clock and Ithil's folder all sit behind small protocols, so everything runs on CI with fakes. CI runners have no Apple Intelligence, so no test may need the real model.
- App Sandbox and Hardened Runtime on. Entitlements: user-selected read-write files and app-scope bookmarks only. No network entitlement and never the Private Cloud Compute entitlement, so macOS itself guarantees that nothing leaves the Mac.
- The main thread never waits on disk, the index or the model.
- Logs use os.Logger. Note titles, note text, file names and prompts are always .private.
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
└── Red Cross/                        another space
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
- Copying the library folder is a full backup. Opening it on another Mac restores everything; the index rebuilds itself.

## Spaces
- A space is a top-level folder in the library: Uni, Red Cross, Ideas, whatever I create. Each has a color (Ithil's subject palette plus a custom color), an SF Symbol, and a description and keywords that help Nano bot route things.
- By default spaces mix: search, links, suggestions and the Sky can span them, so I can see how an idea connects to a course or a goal.
- A space can be **sealed**. A sealed space's notes, files, index, memory and decisions are used only while I'm working inside it. Nothing from it appears in another space's search, suggestions, answers, links or Sky, and nothing from other spaces appears inside it. One crossing is allowed: Nano bot may use a sealed space's name, description and keywords, never its contents, to propose filing an Inbox item there.
- The Inbox belongs to no space. Its items are used for nothing except filing them.
- Enforce sealing at one choke point in ElenathCore's retrieval layer and prove it with tests: a marker word planted in a sealed space must never show up in any search result, suggestion or model prompt built for another space.

## Features
1. **Main window.** Sidebar: Today, Inbox with a count, spaces with their folders, tags. Detail: the note, board or view I opened. Toolbar: back and forward, search, new note, the Nano bot panel toggle.
2. **Today.** The landing screen: what's waiting in the Inbox, proposals from Nano bot, open tasks, recently edited notes and, once the Ithil bridge exists, what's up next.
3. **Editor.** One pane of Markdown styled as I type, with no separate preview: headings, emphasis, lists, clickable checkboxes, quotes, code, simple tables, inline images, links (⌘-click to follow), `[[` autocomplete, find in note. Backlinks and related notes sit below the note. Any language, including right-to-left and mixed-direction text.
4. **Inbox and Quick Capture.** A floating panel from anywhere (default ⌥⇧Space, changeable, because Ithil owns ⌥Space). Type, paste text, an image or a link, or drop files. ↩ saves to the Inbox, ⌘↩ saves and opens, esc closes. Starting with a space's name or keyword ("uni: …") files it there directly. A pasted link is kept as a link: Elenath can't fetch pages.
5. **Search.** Across titles, text, tags, attachments and boards, with filters for space, folder, tag, kind and date. Results open at the matching spot.
6. **Import.** Drop files or whole folders onto a space or the Inbox: Markdown, plain text, RTF, Word documents, PDFs, images. Originals are copied, never moved. Write docs/IMPORT.md with the steps for each place my notes live today.
7. **Boards.** An infinite canvas for drawing and thinking: freehand strokes (trackpad or mouse), rectangles, ellipses, lines and arrows, connectors that stay attached, text, sticky notes, images, note cards that open the note, and charts. Select, move, resize, group, align, reorder, snap, undo, copy and paste. Export a selection or the whole board as PNG, PDF or SVG. Text on a board is searchable.
8. **Charts.** A chart is a small table plus a few settings, stored as text inside a note (a fenced `chart` block) or as an element on a board, and drawn with Swift Charts in the app's palette: bar, line, area, scatter, donut. Export as PNG or PDF.
9. **Goals.** A goal is a note of kind `goal`, with an optional due date and parent goal. Any note can point at goals. A goal's page shows everything that points at it over time, its open tasks and when it last moved, so I can see what brings me closer to what.
10. **The Sky.** A map of a space, or of all spaces that mix: notes are stars sized by their links, goals are bright stars, links are faint lines. Filter by tag, goal and time; click a star to preview the note. The layout is computed once in the background and cached. Nothing drifts or jitters. Provide a list alternative for VoiceOver.
11. **Frames, for design work.** Fixed-size frames on a board (presets such as A4, square post, phone screen, Mac window) with their own background, text styles and color swatches, alignment guides, and export per frame. This is not Figma: no components, auto layout or prototyping. Ask before adding more.
12. **Settings** (General / Spaces / Nano bot / Ithil / Files): appearance Night / Dawn / Match System, Quick Capture hotkey, library folder, spaces and sealing, Nano bot's permissions, self-test and index tools, the Ithil folder and subject mapping, launch at login, menu bar.
13. **Onboarding** in the app's style: welcome, choose folder, create first spaces, meet Nano bot (with its availability explained).
14. **Menu bar extra** (`sparkles` template icon): Quick Capture, Inbox count, Open Elenath, Settings, Quit. Can be turned off.
15. **Keyboard:** ⌘N new note, ⌘O jump to a note by title, ⌘F find in note, ⇧⌘F search everywhere, ⌘K Nano bot's command field, ⌘, Settings. Everything is reachable by keyboard, with ⌘Z / ⇧⌘Z everywhere, including after Nano bot's changes. Help menu: "Check for Updates…" and "Report an Issue…" open GitHub in the browser; the app itself never touches the network.

## The index (the retrieval layer)
- The index is a derived cache that can be rebuilt at any time: one SQLite database per space, kept in Elenath's container and never inside the library, which may sit in a synced folder.
- Chunk notes by Markdown structure (heading path plus paragraphs, roughly 200 to 300 tokens), PDFs by page (PDFKit), and images through Vision text recognition. Store each chunk's text and source range.
- Keyword search uses FTS5. Meaning search uses one vector per chunk from the Natural Language framework (`NLContextualEmbedding`, mean-pooled and normalized) behind an `Embedder` protocol, compared by cosine similarity with Accelerate. Fuse the two rankings with reciprocal rank fusion.
- Keyword search must work fully when no embedding model covers a language or its assets aren't on the Mac yet. Check at run time which scripts have a model; don't assume.
- Indexing is incremental (content hashes), runs in the background, can be paused, and is stamped with the embedder's identifier and revision so it rebuilds itself when that changes. Settings has "Rebuild Index".
- Measure retrieval instead of assuming it: keep a small set of demo questions with the notes they should find, run it in the self-test on the real embedder, and use the score to choose between embedder options.
- Open tasks, backlinks, tags and related notes are all read from this index.
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
- **Talking to it.** A side panel and a command field: a slash command per job, and plain language routed to one job by a guided-generation classifier. In Ask it may call a few read-only tools (search notes, read a note, list the Inbox, upcoming Ithil events), with a small cap on calls per question and as few tools per session as possible, since every tool costs context.
- **Proposals.** Nano bot never changes anything directly. Every change is a proposal card (what, where, why) that I accept, edit or skip. Accepted changes go through the same code as my own edits and can be undone with ⌘Z or from an activity log. Each job has a setting: "Ask first" (the default) or "Do it and let me review". Nano bot can never delete, never write outside the library, and never touch Ithil's folder.
- **Learning, without training anything:**
  - retrieval over everything indexed in the space;
  - every proposal I accept, change or reject is saved in the space's decisions.jsonl, and the most similar past decisions are shown to the model next time, so my corrections stick;
  - memory.md holds short facts and preferences per space. Nano bot proposes additions, and I can read and edit the file in the app or any editor.
- **Safety.** Text from notes and imported files is data, never instructions. Pass it in clearly delimited blocks, and give jobs that read content no tools that write.
- **Running.** One job at a time, in the background, cancellable. Pause in Low Power Mode. The queue survives quitting.
- **Self-test.** Settings > Nano bot > Run Self-Test runs a fixed set of cases through the real model and embedder on my Mac and produces a report I can copy: availability, context size, pass or fail per case, timings. This is how you learn what the real model does, since CI can't run it. Keep prompts in one place, versioned, with tests against a scripted fake model. Re-run after macOS updates, because the model can change underneath us.
- **Lineage.** Nano bot borrows the ideas of the open-source nanobot project (a small readable loop, a few tools, memory in plain files, background jobs) and is written natively in Swift. None of its code is used.

## Ithil bridge
- I choose my Ithil folder once (security-scoped bookmark). It is read-only: Elenath never writes inside it.
- Read `.ithil/events.json` as documented in Ithil's docs/ARCHITECTURE.md (schema version 1). Copy the model, codec and occurrence expansion source from IthilCore; don't link the two repos. If the file has a newer schema than Elenath knows, say so and show nothing rather than guess. Watch the file for changes.
- Uses:
  - "Up next" on Today, with a button that reveals the event's folder in Finder or opens Ithil.
  - Linking a note to an event occurrence (`event` in front matter), and "Notes for this lecture".
  - When I capture during an event, offer that event's subject and folder.
  - In Settings, map each Ithil subject to a space and folder. Files in mapped events' folders (PDFs, text, images) are indexed into that space, and sealing applies to them too.
  - Nano bot's read-only tools: upcoming events, events on a day, files in an event's folder.
- Later, and only if I ask, because it needs a change in Ithil: an `ithil://` link to open an event, or to create one from Elenath.

## Design
- The same world as Ithil. Copy its tokens from Ithil's docs/DESIGN.md and asset catalog into Elenath's own: Night and Dawn colors with their Increase Contrast variants, type, metrics and the star field. Elenath's repo must never depend on Ithil's.
- Rules carried over: Night is the primary look and Dawn is the same world in daylight. Amber is reserved for selection, focus, primary buttons and "now". Stars appear only in the sidebar, title areas, empty states and the Sky, never behind text I'm reading or on a board. Glows are static assets. Icons are SF Symbols. New York for titles and headings, SF Pro for everything else, SF Mono for code, tabular numerals for times and counts.
- Space colors are Ithil's subject palette (Clay, Teal, Iris, Fern, Rose) plus a custom color.
- No design export exists for Elenath. Before building each new screen (editor, Inbox and capture panel, Nano bot panel and proposal cards, search, boards, charts, the Sky, onboarding, settings), write it into docs/DESIGN.md the way Ithil's screens are written: tokens, sizes, symbols, states.
- Nano bot's mark is `sparkles` in the moonlight tint. Its proposals sit on `BackgroundRaised` cards, and only the Accept button is amber.
- App icon: draw three options as SVG in the style of Ithil's icon (the same night sky, hill and small stars, with a constellation where Ithil has its moon), render them, show me, and wait for my pick.
- On macOS 26 and later the system draws Liquid Glass. Content keeps its opaque token backgrounds, as in Ithil (no glass on glass).

## Quality bar
- No lag on an M1 MacBook Air with 8 GB: launches in under a second with 10,000 notes; typing never stutters in a 1 MB note; search-as-you-type answers within 100 ms across 20,000 chunks; panning a board with 5,000 elements stays smooth; Elenath's own memory stays under 400 MB in normal use.
- Never lose a keystroke: tests interrupt writes midway and the note must survive.
- Accessibility: VoiceOver labels everywhere, full keyboard access, Reduce Motion and Increase Contrast respected, text at WCAG AA contrast in both themes.
- Localization-ready: every string in a String Catalog, English first.
- Tests (Swift Testing) for: storage, migrations and corruption recovery; name sanitizing; front matter round-trips that preserve unknown keys and bodies byte for byte; link resolution and rename repair; conflict handling; the chunker; hybrid ranking with a fake embedder; sealing leak tests; every Nano bot pipeline against a scripted fake model; proposal apply and undo; the Ithil reader against fixture files, including a newer schema; board geometry; chart parsing.
- Zero warnings. Format with swift-format.
- A `-demo` launch argument loads an invented sample library (Uni, a sealed Red Cross space, Ideas), a scripted fake model and a fixture Ithil folder into a temporary folder, for screenshots and testing. It never touches real data.

## Repo
- Bundle ID `io.github.visaug36.Elenath`.
- README.md: icon, one-line pitch, screenshots, features, download and first-launch steps (the app isn't notarized, so explain System Settings > Privacy & Security > Open Anyway, and say up front "download Elenath-x.y.z.zip, not Source code"), how files are stored (the folder tree), what Nano bot needs and can't do, privacy, backup and moving to a new Mac, uninstall, FAQ, license, and a note that "Elenath" is Sindarin from J.R.R. Tolkien's writings and the project isn't affiliated with the Tolkien Estate.
- docs/: DESIGN.md, ARCHITECTURE.md, FORMAT.md, IMPORT.md, RELEASE_CHECKLIST.md. CHANGELOG.md (Keep a Changelog and SemVer). If the repo is public, add the community files Ithil has.
- CI (GitHub Actions) as in Ithil: swift-format lint, tests, a Release archive, the String Catalog check, and failure on any warning, on every push and pull request.
- A Screenshots workflow from Phase 1 on, so every phase's pull request shows me real screenshots from `-demo`. I often review from my phone.
- Releases: an arm64 Release build, zipped with ditto, with its SHA-256, attached to a GitHub Release with notes from CHANGELOG. Ad-hoc signed. Tag pushes are refused in this environment (see Ithil's log), so first try having the workflow create the tag and the release itself when the version changes on `main`. If that can't work, do it Ithil's way: I create the tag from the Releases page, and you tell me exactly what to tap. You may publish 0.x prereleases yourself after a phase is merged; 1.0.0 only when I say so.
- scripts/install.sh builds Release locally and copies it to /Applications.
- Never commit: my notes, anything from my real library or Ithil folder, design references, secrets, personal info, absolute paths, xcuserdata, DerivedData. Demo content is invented.

## How to work
- **Environment** (the same as for Ithil): you work in a Linux cloud container without Xcode, so GitHub Actions is the compiler and test runner. Write each module's API contract in docs/ARCHITECTURE.md first, implement against it, have it reviewed independently, integrate, and let CI on the pushed branch judge. Read failures from the xcresult summary and swift-format's printed patch.
- **Look things up.** Foundation Models, Liquid Glass and the other 2025 and 2026 APIs are newer than what you remember, and they changed again in macOS 27. Read Apple's current documentation before coding against them.
- **Phases.** Each ends with CI green, screenshots, updated docs and CHANGELOG, this log updated, and a short list of what I should try.
  1. Foundation: the project from Ithil's template, design tokens, docs/DESIGN.md for the Phase 2 screens, the icon options, docs/FORMAT.md and the Phase 2 contracts, CI green on an empty themed window, the Screenshots workflow.
  2. Notes: library, spaces and sealing (with leak tests from the first search onward), storage and watching, the editor, Inbox and Quick Capture, the first half of the index (links, backlinks, tags, open tasks, FTS5 keyword search), import, Today, appearance, onboarding, settings. Release 0.1.0. **Stop here: I install it and move my notes in.**
  3. Meaning: chunking, the embedder, hybrid search, related notes, PDF and image text, and the leak tests extended to suggestions.
  4. Nano bot: the engine and availability, the File, Link, Tidy, Summarize and Ask jobs, proposals, undo and the activity log, learning, the self-test, and the leak tests extended to prompts. Release 0.2.0. **Stop here: I run the self-test and send you the report, and you tune from it.**
  5. Ithil bridge.
  6. Boards and charts.
  7. Goals and the Sky, with the Spark and Review jobs.
  8. Frames, the menu bar extra, an accessibility pass and polish. Get 1.0.0 ready, but don't publish it until I say so.
- **Working mode.** Carry each phase through to merged and green yourself, and push after each one. Wait for me only at the two stop points, at the icon pick, and when a product decision is unclear. In that case ask me instead of guessing.
- Don't start a phase while the one before it has known bugs.

## Not now
A Windows or phone version, sync between devices, a different local model (if Apple's proves too weak, the route is an MLX-backed model behind `BotModel`, but it adds a package and a model download, so ask first), writing into Ithil, sharing or collaboration.

## Decisions & status log
Keep this section current. Newest first.

### Decisions
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
- The languages I write in, and whether the embedder and the model cover them.
- The seven places my notes live today.
- Needs a check on a real Mac (CI can't do it): Does the on-device model answer from the sandboxed, ad-hoc-signed app? Do the embedding assets arrive without a network entitlement? Do the folder bookmarks survive an update to a new ad-hoc-signed build?

### Status
- 2026-11-11: **0.0.1 published; Phase 2 started.** The Release workflow built the merge commit and published https://github.com/Visaug36/Elenath/releases/tag/v0.0.1 as a prerelease, creating the tag itself, so no tag ever has to be pushed from here or made by hand. Phase 2 has begun on `claude/new-session-fplgmb`, restarted from `main`: the name rules, the model types, the folder policy and the document store for library.json and space.json are in `ElenathCore` with their tests (74 tests locally). Next in Phase 2, in this order: `LibraryCatalog`, `NoteText` and front matter, `NoteStore`, the Markdown scanner, links, the index with `Reach` and the leak tests, capture, import; then the app layer.
- 2026-11-11: **Phase 1 merged** (https://github.com/Visaug36/Elenath/pull/1). The user picked icon A. The independent review the brief asks for was started twice and cut off both times by the account's usage limit, so it did not report; Claude checked the riskiest points itself instead (the release workflow's cases, run locally with a fake `gh`; the sealing choke point; the format against the architecture) and added `Retrieval.text(of:from:)` to the contract. Run an independent review on the first Phase 2 modules, where it matters more. Next: check that the Release workflow published 0.0.1, then Phase 2.
- 2026-11-11: **Phase 1 built, waiting for the icon pick.** The project, tokens, the empty themed window, CI, the Screenshots and Release workflows, scripts and community files are on `claude/new-session-fplgmb`, with docs/DESIGN.md, docs/FORMAT.md and docs/ARCHITECTURE.md for version 0.1. CI is green on both jobs (12 tests, zero warnings). An independent review was run. What is left: wire the picked icon in, date the 0.0.1 changelog section, merge, and check that the Release workflow publishes 0.0.1.
- 2026-11-10: **start-up done, waiting for the user.** The brief is saved as CLAUDE.md on `claude/new-session-fplgmb`. Ithil was read: its CLAUDE.md, docs, the Xcode project, Config, scripts, workflows, and the storage, folder access, hotkey, appearance and onboarding code. The repo is public and has no license yet. Nothing is built.
  - Runners on 2026-11-10 (from `actions/runner-images`): `macos-26` (also `macos-latest`) is macOS 26.7.2 on arm64 with Xcode 26.0.1 to 26.6; 26.6 is the default and its SDK is macOS 26.5. `xcode-27` is macOS 27.0.1 with Xcode 27.0, 27.1 (the default) and 27.2, and the README still marks that image as a preview. `macos-15` has Xcode 16.x and 26.0.1 to 26.3. The macOS 14 images were retired on 2026-11-02.
- 2026-11-10: brief written. Nothing built yet.
