# Elenath design

This is the source of truth for how Elenath looks. Elenath lives in the same world as its sibling Ithil: the
tokens below were copied from Ithil's design into Elenath's own asset catalog (`Elenath/Assets.xcassets`) and
theme (`Elenath/Theme/`), so this repository never depends on Ithil's. No design export exists for Elenath, so
every screen is written here before it is built.

## Principles

- **Night** is the primary look. **Dawn** is the same world in daylight. In the asset catalog Night is the
  *Dark* appearance and Dawn is *Any* (light).
- **Stars** appear only in the sidebar, title areas, empty states and the Sky. Never behind text being read,
  and never on a board.
- **Amber is reserved** for selection, focus, primary buttons and "now".
- **Glows are static.** A glow marks a selection or a drop target. Nothing animates behind content.
- Icons are **SF Symbols**. File icons are the system's own.
- **New York** for titles and headings, **SF Pro** for everything else, **SF Mono** for code, tabular numerals
  for times and counts.
- On macOS 26 the system draws Liquid Glass (the sidebar, toolbars, panels). Content keeps its opaque token
  backgrounds: no glass on glass.
- The invented sample library for `-demo` has three spaces: Uni, Red Cross (sealed) and Ideas.

## Color tokens

Names are the asset-catalog names. Xcode generates Swift symbols from them (`Color.backgroundWindow`,
`Color.textPrimary`, …).

| Token | Night | Dawn | Used for |
|---|---|---|---|
| `BackgroundWindow` | `#141B2E` | `#FBF6EA` | Window, the editor, lists |
| `BackgroundSidebar` | `#0F1527` | `#F2EAD7` | Sidebar, banners |
| `BackgroundRaised` | `#1D2642` | `#FFFCF4` | Cards, popovers, sheets, the Quick Capture panel |
| `BackgroundMenu` | `#232D4D` | `#FFFCF4` | Menus |
| `ControlFill` | `rgba(237,230,211,0.08)` | `rgba(27,35,64,0.06)` | Text fields, pills, tag capsules, code backgrounds |
| `SeparatorLine` | `rgba(237,230,211,0.08)` | `rgba(27,35,64,0.09)` | Dividers, card borders |
| `TextPrimary` | `#EDE6D3` | `#1B2340` | Titles, note text |
| `TextSecondary` | `#A9ADBE` | `#5A6180` | Captions, secondary lines, icons (the moonlight tint) |
| `TextTertiary` | `#888EA5` | `#62687E` | Section labels, Markdown markers, hints |
| `AccentColor` | `#F2B45A` | `#E9A23B` | Selection ring, focus, primary buttons, "now" |
| `AccentText` | `#F5C27A` | `#8D5416` | Amber text and icon tint for the active or primary thing |
| `TextOnAccent` | `#1F1607` | `#1B2340` | Text on amber fills |
| `AccentSoft` | `rgba(242,180,90,0.15)` | `rgba(233,162,59,0.18)` | Selected rows, find and search matches |

Text contrast on each background (WCAG 2 ratios, translucent tokens composited first). Everything is at least
AA (4.5:1):

| Token | Theme | On window | On sidebar | On raised |
|---|---|---|---|---|
| `TextPrimary` | Night | 13.8 | 14.6 | 12.0 |
| `TextSecondary` | Night | 7.7 | 8.1 | 6.7 |
| `TextTertiary` | Night | 5.3 | 5.6 | 4.6 |
| `AccentText` | Night | 10.5 | 11.1 | 9.2 |
| `TextPrimary` | Dawn | 14.3 | 12.9 | 15.1 |
| `TextSecondary` | Dawn | 5.6 | 5.1 | 5.9 |
| `TextTertiary` | Dawn | 5.1 | 4.6 | 5.4 |
| `AccentText` | Dawn | 5.7 | 5.1 | 6.0 |

`TextOnAccent` on `AccentColor`: 9.7 (Night), 7.1 (Dawn).

### Increase Contrast

With **Increase Contrast** on (System Settings → Accessibility → Display), the tokens that carry text or lines
switch to stronger values: the asset catalog's High Contrast variants. Backgrounds, amber fills and space
colors stay as they are. Views that draw their own borders strengthen them when
`colorSchemeContrast == .increased`.

| Token | Night | Dawn |
|---|---|---|
| `TextSecondary` | `#C8CBD6` | `#383C52` |
| `TextTertiary` | `#B8BBC9` | `#454A5D` |
| `AccentText` | `#FFCF8A` | `#623A0D` |
| `SeparatorLine` | `rgba(237,230,211,0.40)` | `rgba(27,35,64,0.50)` |
| `ControlFill` | `rgba(237,230,211,0.16)` | `rgba(27,35,64,0.12)` |

With these, text tokens reach 7:1 on every background they are used on, and lines reach 3:1.

### Space palette

Each space has one of these colors, or a custom one.

| Token | Night | Dawn |
|---|---|---|
| `SpaceClay` | `#E08A62` | `#C0643C` |
| `SpaceTeal` | `#6FB5B0` | `#3F8A86` |
| `SpaceIris` | `#A598D6` | `#7466B0` |
| `SpaceFern` | `#8FB07A` | `#5E8650` |
| `SpaceRose` | `#D98FA6` | `#B8657F` |

- **Space dot:** an 8 pt circle in the space color, before a space's name wherever a note's place is shown.
- **Space fill** (capsules, selected swatches) = the space color at 20 % (Night) / 15 % (Dawn), with a 1 pt
  border of the space color at about 35 %.
- **Space text** uses the space color in Night (at least 6.5:1). The Dawn colors are only about 3.8:1 on cream,
  so in Dawn, and for any custom color, text uses the color mixed toward `TextPrimary` until it reaches 4.5:1.

## Type

- **New York** (`Font.Design.serif`), semibold: note title 28 pt, view titles ("Today", "Inbox") 26 pt, card
  and sheet titles 22 pt, empty-state headline 20 pt, the name in the sidebar 18 pt.
- **SF Pro**: interface text 13 pt, secondary 12.5 pt, captions and section labels 11 pt semibold, footnotes
  11 pt.
- **Note text** is SF Pro 15 pt with 1.45 line spacing, in a column at most 720 pt wide.
- **SF Mono** 13.5 pt for code in notes, 12.5 pt elsewhere.
- **Tabular numerals** for every time and count (`.monospacedDigit()`).

Defined in `Elenath/Theme/Typography.swift`.

## Spacing and shape

- 4 pt grid. Sidebar 244 pt (200 to 320). Toolbar 52 pt. Main window at least 720 × 480.
- The note column: at most 720 pt wide, centered, 40 pt side padding (24 pt in a narrow window), 28 pt above
  the title.
- Padding: popovers and sheets 18 pt, grouped form rows 10 × 14 pt, sidebar rows 7 × 8 pt.
- Radii: controls 6, list rows 7, cards, form groups and drop zones 10, popovers 12, panels 14.
- Glow: selection = 1.5 pt amber ring + 14 pt soft shadow; drop target = 1.5 pt ring + 32 pt shadow at 32 %.

Defined in `Elenath/Theme/Metrics.swift`.

## SF Symbols

| Symbol | Used for |
|---|---|
| `sun.horizon` | Today |
| `tray`, `tray.full` | Inbox, empty and with items |
| `tray.and.arrow.down` | Quick Capture |
| `folder` | a folder; the default symbol of a space |
| `doc.text`, `lightbulb`, `star` | a note, an idea, a goal |
| `doc.richtext`, `photo`, `doc.plaintext`, `doc` | a PDF, a picture, a text file, any other file (from 0.3) |
| `calendar` | a file in an event's folder, in search results (from 0.3) |
| `number` | a tag |
| `lock.fill` | a sealed space; read-only |
| `magnifyingglass` | search |
| `square.and.pencil` | new note |
| `chevron.left`, `chevron.right`, `sidebar.left` | back, forward, the sidebar |
| `link`, `paperclip`, `checklist`, `clock` | links, attachments, tasks, recent |
| `square.and.arrow.down` | import |
| `exclamationmark.triangle` | a problem that needs a decision |
| `gearshape`, `circle.grid.2x2` | Settings: General, Spaces |
| `sparkles` | Nano bot, and nothing else |

Tint: `TextSecondary` (moonlight) by default, `AccentText` for the active or primary thing, the space color
for a space's own symbol.

## Assets

| Asset | What it is |
|---|---|
| `AppIcon` | An open notebook glowing amber on a dark hill, under the Plough drawn as a constellation, on Ithil's deep navy night sky with small stars: Ithil's icon with a notebook where it has its window and a constellation where it has its moon. The body sits on Apple's 824/1024 grid with a soft drop shadow, at 16–512 pt @1x/@2x. The master is `docs/icon/icon.svg`; `scripts/icon/make-appicon.sh` renders it, and a 1024 px copy is in `docs/images/icon-1024.png`. |
| `StarField` | A static 512 × 512 pt tile (@1x, @2x) of about 95 small dots, drawn with `.resizable(resizingMode: .tile)`. Night: cream `#EDE6D3` stars; Dawn: faint amber `#C79A55` specks. Transparent, so it sits on any background. |
| `EmptySky` | SVG. A small constellation with a glowing star over a hill, and a house with a lit door. For the empty window and an empty space or folder. |
| `EmptyInbox` | SVG, drawn with the Inbox. An open tray on the hill with one star above it. |
| `EmptySearch` | SVG, drawn with search. A hanging lantern with a flame and a warm glow, as in Ithil. |

Every image has a Night (Dark) and Dawn (Any) variant. Illustrations are plain SVG: no masks, no filters.

## Screens

Screen 0 is built. Screens 1 to 11 are version 0.1.

### 0. The shell (version 0.0.1)

`WindowGroup` + `NavigationSplitView`. The sidebar (`BackgroundSidebar` + stars) shows "Elenath" in New York
semibold 18 pt over "All the stars together." in 12.5 pt `TextSecondary`. The detail is the empty state on
`BackgroundWindow` with stars: `EmptySky`, "Nothing here yet.", and one secondary line. The toolbar has no
items, so its background is hidden and the stars run up under the title bar.

### 1. Main window

**Sidebar** (244 pt, `BackgroundSidebar` + stars). Rows are 28 pt high with radius 7; the selected row has an
`AccentSoft` fill and semibold text.

- **Today** (`sun.horizon`), **Inbox** (`tray`, or `tray.full` with items) and **Calendar** (`calendar`). The
  Inbox count sits at the right, tabular, in a `ControlFill` capsule. While the calendar is open, Ithil's
  **mini month** and **subjects** sit right under the Calendar row (screen 12).
- **Spaces** (section label 11 pt semibold `TextTertiary`): one row per space with its symbol in the space
  color and its name, and `lock.fill` (10 pt, `TextTertiary`) after the name of a sealed space. A disclosure
  chevron shows the space's folders, indented 16 pt per level. Notes are not listed in the sidebar.
- A sealed space shows its folders only while you are working in it. From anywhere else it is a single row.
- **Tags** (section label): the tags readable from where you are, with counts. A nested tag (`#uni/physics`)
  sits under its parent.
- Context menus: New Note, New Folder, Rename, Show in Finder, Move to Trash; on a space also Edit Space….
- While files are dragged over it, the row under the pointer gets the drop glow.

**Toolbar** (52 pt): `sidebar.left`; a `ControlGroup` with back and forward; the place of what is open as a
breadcrumb (space dot, "Uni › Physics", 12.5 pt `TextSecondary`); on the right a search field ("Search",
`magnifyingglass`) and a square amber New Note button (`square.and.pencil`, `.borderedProminent`). The Nano bot
toggle (`sparkles`) joins them when Nano bot does.

**Detail** (`BackgroundWindow`, no stars): the view that was opened. Selecting a space or folder shows its
contents: subfolders, then notes as rows (title 13 pt semibold with the kind's symbol, first line 12.5 pt
`TextSecondary`, date at the right, tabular). Opening a note shows the editor. Back and forward walk through
what was opened, like a browser.

A space's own page starts with a header: the space's symbol in its color, its name (New York 26 pt), a
`lock.fill` "Sealed" capsule for a sealed space, its description in `TextSecondary`, and New Folder
(`folder.badge.plus`) at the right. Then an **Open tasks** card with the space's first six open tasks and "Show
All", and its folders and notes. A folder's page has the folder's name and the same list.

VoiceOver reads a space row as "Uni, space" or "Red Cross, sealed space", and the Inbox as "Inbox, 3 items".

**Alerts about kept edits.** When the library opens with edits kept in Recovery: "Elenath kept edits it
couldn't save" / "2 notes couldn't be saved before Elenath closed. The text is safe: put it in the Inbox to look
at it." with Put Them in the Inbox (default) and Later. When a note closes with edits that couldn't go where it
was, the "That didn't work" alert says where they went ("They are in the Inbox as “Plan (conflict …)”").

**Banners at the foot of the window** (`BackgroundSidebar`, a `SeparatorLine` on top, 12.5 pt `TextSecondary`):

- *Read-only* (`lock.fill` in `AccentText`): the library was saved by a newer Elenath.
- *Links to update* (`link`): notes were renamed or moved outside Elenath and other notes still link to where
  they were. "“Reading list” was renamed “To read” outside Elenath. Links in 2 notes still use the old name."
  (or "was moved…", or "3 notes were renamed or moved outside Elenath…"), with Not Now (plain) and Update Links
  (small, amber). Update Links is one step that ⌘Z takes back.

### 2. Today

The landing screen. A header band 96 pt high with stars: "Today" (New York 26 pt) and the date
("Tuesday, 10 November", `TextSecondary`). Below it, a column of cards at most 720 pt wide. Cards are
`BackgroundRaised`, radius 10, with a `SeparatorLine` border and an 11 pt semibold `TextTertiary` label.

- **Inbox**: the count and the three newest items (title, age), and "Open Inbox". Empty: "Nothing waiting."
- **Open tasks**: up to eight, each a checkbox, the task's text and, in `TextSecondary`, the space dot and the
  note's title. Ticking one changes the note. "Show All" opens the full list.
- **Recently edited**: up to six notes with the space dot, folder and a relative time (tabular).

- **Up next** (from 0.2, first card): Ithil's Up next rows, the next four events. The very next one in an
  `AccentSoft` row (radius 7) with its subject dot, title and an amber `AccentText` line "in 10 min · 14:00 ·
  Room B204"; the others with "Tomorrow · 09:00" in `TextSecondary`. Clicking a row shows it in the calendar.
  Empty: "Nothing coming up." "Open Calendar" at the right of the label. Events from every space are here,
  sealed ones too (the calendar exception): title, time and location only.

Today reads only spaces that aren't sealed, apart from Up next. A sealed space has the same three cards on its
own page. Nano bot's proposals come later.

### 3. The editor

One pane of Markdown, styled as it is typed. There is no preview.

- **Title**: the file name, New York semibold 28 pt, editable in place; Return moves to the text. Placeholder
  "Untitled" in `TextTertiary`.
- **Details row** under the title, 12.5 pt `TextSecondary`: the space dot and place ("Uni › Physics"), a kind
  menu (`doc.text` Note, `lightbulb` Idea, `star` Goal), the tags as `ControlFill` capsules (11 pt) with a
  `+` to add one, and "Edited 14:30" (tabular).
- **Text**: the styles below. Markdown markers stay in the text and are dimmed, never hidden. Styling never
  changes a character.

| Element | Style |
|---|---|
| Body | SF Pro 15 pt, `TextPrimary` |
| Heading 1, 2, 3 | New York semibold 22, 18, 15 pt |
| Heading 4 to 6 | SF Pro semibold 15 pt |
| Markers (`#`, `**`, `[[`, list bullets, table pipes) | `TextTertiary` |
| Emphasis, strong, strikethrough | italic, semibold, struck through |
| Quote | `TextSecondary`, with a 2 pt `TextTertiary` bar at the left |
| Inline code | SF Mono 13.5 pt on `ControlFill`, radius 4 |
| Code block | SF Mono 13.5 pt on `ControlFill`, radius 8, 10 pt padding |
| Link to a note | space text of the space it points to, with a thin underline |
| Link that resolves to nothing | `TextTertiary`, dashed underline |
| Web link | `TextSecondary`, underlined |
| Tag | `TextSecondary` on a `ControlFill` capsule |
| Open task | a 14 pt rounded box with a `TextSecondary` border |
| Done task | the box filled `TextTertiary` with a check; the text `TextTertiary`, struck through |
| Selection, the caret | amber, as the system draws them |
| Find matches | `AccentSoft` |

- Links are told apart by more than color: they are underlined. A link takes the color of the space it points
  to, so a link out of the current space is visible at a glance.
- **Following a link:** ⌘-click, or ⌘↩ with the caret in it. A link that resolves to nothing offers to create
  the note. A link with several candidates shows them in a menu.
- **Tasks:** clicking the box ticks it.
- **Embeds:** an image shows under its line, at most as wide as the column, radius 6. A PDF shows its first
  page with its name and page count; clicking opens Quick Look.
- **`[[` completion**: a list under the caret, 320 pt wide, up to eight rows, `BackgroundRaised`, radius 10.
  Each row is a title (13 pt) over the space dot and folder (`TextSecondary`); the selected row is
  `AccentSoft`. ↑ and ↓ move, ↩ or ⇥ accepts, esc closes. When nothing matches exactly, the last row is
  "Create “…”".
- **Find in note** (⌘F) is the system's find bar.
- **Linked from**, under the text: a section label, then one row per note that links here: its title (13 pt
  semibold), the line that holds the link (12.5 pt `TextSecondary`) and the space dot. The section is absent
  when nothing links here.
- **Related** (from 0.3), under Linked from: the same section label style, then up to five rows of notes and
  files about the same things, best first. A row is the kind's or the file type's symbol and the title (13 pt
  semibold), the passage that is closest (12.5 pt `TextSecondary`, at most two lines, no marks: nothing
  matched a word), and the space dot with the place. A file's row adds its page ("Page 12", tabular) when it
  is a PDF's. Clicking a note opens it; a file opens in its app. The section is filled in the background
  after the note opens, only from what the note's own space may read, and is absent when nothing is related
  or meaning search isn't available on the Mac. Never a spinner: it appears when it is ready.
- Text follows each paragraph's own direction, so right-to-left and mixed text read correctly.

**Banners** sit above the title as a slim strip (`BackgroundSidebar`, 12.5 pt, a symbol, one sentence, buttons
at the right):

| State | Symbol | Text and buttons |
|---|---|---|
| Read-only library or space | `lock.fill` | "Read-only: this was saved by a newer version of Elenath." |
| Changed on disk while editing | `exclamationmark.triangle` | "This note changed on disk while you were editing. Your version is saved as “Title (conflict …)”." Show Both |
| Could not be saved | `exclamationmark.triangle` | "Elenath couldn't save this note. Your text is safe." Try Again |
| Gone from disk | `exclamationmark.triangle` | "This note was moved or deleted outside Elenath." Save It Again, Close |
| Not UTF-8 | `lock.fill` | "Elenath can't edit this file's text encoding, so it is shown read-only." |

### 4. Inbox

"Inbox" (New York 26 pt) with the count. A list of items, each row 56 pt: the title (13 pt semibold), the
first line (12.5 pt `TextSecondary`), the age at the right (tabular, `TextTertiary`), and `paperclip` with a
count when it has files. Opening an item shows it in the editor with a filing bar above the title: an amber
"File to…" button with a menu of spaces and folders, and "Move to Trash". Items can also be dragged to a space
or folder in the sidebar.

Empty: `EmptyInbox`, "Inbox is empty.", "Press ⌥⇧Space anywhere to capture something." (with the current
shortcut).

### 5. Quick Capture (⌥Space anywhere, from 0.2)

A nonactivating floating `NSPanel`, 560 pt wide, radius 14, `BackgroundRaised`. On macOS 26 the opaque fill is
inset 2 pt over a `.glassEffect(.regular)`, so only a thin glass rim shows and every word stays on the opaque
token color.

- Top: `tray.and.arrow.down` in `AccentText`, then a text area at 15 pt that grows from one line to eight.
  Placeholder: "Capture a thought…".
- At the right, a capsule says where it will go: `tray` "Inbox" on `ControlFill`, or, once the text starts with
  a space's name or keyword and a colon, the space dot and name on the space fill.
- Pasted images and dropped files appear as chips under the text, each with a remove button.
- Footer (11 pt `TextTertiary`, above a separator line): at the left "Space matched from “uni”" when it applies;
  at the right the key hints "↩ Save", "⌘↩ Save and open", "esc Close".
- ↩ saves, ⇧↩ starts a new line. Closing with esc keeps unsaved text for the next time.
- Dragging files over the panel gives it the drop glow.
- **An event line** (from 0.2): when the text reads like an event (Ithil's Quick Add parsing: "physics quiz
  thursday 10am"), a row appears above the footer: `calendar.badge.plus` in `AccentText`, what was understood
  as "Thu 10:00 · Physics" (13 pt, the subject dot before the subject), and at the right the hint
  "⌥↩ Add to Calendar" (11 pt `TextTertiary`). The whole row is a button with the same action. ⌥↩ adds the
  event, ⌥⌘↩ adds it and opens it in the calendar. ↩ still saves a note, so a note that mentions a date never
  becomes an event by accident. VoiceOver: "Add to Calendar: Thursday 10:00, Physics Quiz, Physics".
- **The shortcut is ⌥Space** (it was ⌥⇧Space while Ithil had ⌥Space). When it can't be registered, the
  panel's settings and the menu bar say so: "⌥Space is in use, perhaps by Ithil. Quit Ithil and turn off its
  Launch at Login, or choose another shortcut."

### 6. Search and Jump

**Search** (⇧⌘F focuses the toolbar field). While the field has text, the detail shows results:

- A row of filter capsules (`ControlFill`; the active ones `AccentSoft` with `AccentText`), each a menu: the
  space ("Every Space" or one of the spaces that mix), the folder (once one space is chosen: "Any Folder" or a
  folder, nested ones as "Physics › Week 1"), the kind, the tag and the time ("Any Time", "Past Week", "Past
  Month", "Past Year"). The count of results sits at the right ("1 result", "12 results").
- In a sealed space the space is fixed and reads `lock.fill` "Red Cross only"; the folder filter offers its
  folders. Started from the Inbox, it reads `tray` "Inbox only".
- The results sit in the reading column (720 pt), like every other page.
- Each result: the title (13 pt semibold) with the kind's symbol, a snippet (12.5 pt `TextSecondary`, the
  matched words in `TextPrimary` on `AccentSoft`), then the space dot, folder and date (tabular).
- **Two passes** (from 0.3): the results by words show at once, as before; a moment later the results by
  meaning are merged in (reciprocal rank fusion), without a spinner. The selected row stays selected when it
  moves. A result found only by meaning has its passage as the snippet, without marks.
- **Files** (from 0.3) are results like notes: a PDF, a picture or a text file found by the text in it shows
  the file type's symbol, its name as the title and the matching passage. A PDF's result adds "Page 12"
  (tabular) after the date. ↩ opens it in its app (Preview cannot be told the page; the row says it).
- **A file in an event's folder** shows `calendar`, its name, the passage, and in the place line the event's
  title and day ("Physics Lecture · Mon 16 Nov") instead of a folder. ↩ shows the file in its event's folder
  in Finder. It is found only where its event's home space may be read, like the event's notes.
- ↑ and ↓ move, ↩ opens. A result opens at its first match, selected.
- Empty: `EmptySearch`, "Nothing by that name.", "No notes match “chemistry”."

**Jump to a note** (⌘O): a panel in the middle of the window, 520 pt wide, radius 14, `BackgroundRaised`, with
a 17 pt field ("Jump to a note…") over a list of titles. It lists recent notes until something is typed.

### 7. Import

- Dragging files or folders over a space, a folder or the Inbox in the sidebar gives that row the drop glow.
  Over a folder's contents in the detail, a dashed amber drop zone (radius 10) covers the view:
  `square.and.arrow.down`, "Drop to import into Physics".
- File › Import… does the same with an open panel.
- While it runs, a card at the foot of the sidebar shows "Importing 12 of 40…", an amber progress bar and
  Cancel. When it ends, the card says what happened ("Imported 40 items into Physics.", then "Skipped 2 items:
  hidden files and links to elsewhere." or "Couldn't read 1 item." when that happened) with Show and Done. It
  goes away on its own after 8 seconds, unless something couldn't be read or a `.zip` was copied: then it says
  so ("A .zip file was copied as it is. To import a chat exported from WhatsApp, double-click the .zip in
  Finder, then drop the folder it makes.") and stays until Done.
- Originals are copied, never moved. The card says so the first time.

### 8. Spaces

A sheet, 420 pt wide, for a new space and for editing one:

- **Name**.
- **Color**: the five palette swatches and a custom color well; the selected one has the amber ring.
- **Symbol**: a grid of SF Symbols to pick from.
- **Sealed** switch with one line under it: "Keep this space apart. Its notes stay out of search, links and
  suggestions everywhere else, and nothing from other spaces shows up inside it."
- **Description** and **Keywords** (as tokens), with the footnote "These help file things here."
- Buttons bottom right: Cancel, and Create Space or Done (amber).

Sealing or unsealing takes effect at once and can be undone.

### 9. Settings (General / Spaces / Calendar / Subjects / Files)

`Settings` scene with toolbar tabs. `Form.formStyle(.grouped)`, groups on `BackgroundRaised`.

- **General** (`gearshape`): Appearance as three thumbnail cards (Night, Dawn, Match System, the last split
  diagonally; the selected card has the amber ring and a bold label; built). The Quick Capture shortcut as a
  recorder field with Reset, as in Ithil. Launch at login.
- **Spaces** (`circle.grid.2x2`): the spaces in order, each with its symbol, name and `lock.fill` if sealed.
  Drag to reorder. Edit…, Move to Trash…, and New Space….
- **Files** (`folder`): the library folder with Show in Finder and Change… (which offers to move everything).
  The index: its state ("Up to date · 1,204 notes") and Rebuild Index. Diagnostics: Run Diagnostics, then the
  report in a monospaced box with Copy Report.
  - From 0.3 the index's state names what it is doing, one line, 12.5 pt `TextSecondary`: "Up to date",
    "Updating…", "Reading files · 12 waiting", "Finding meaning · 340 passages waiting", "Paused" or "Paused in
    Low Power Mode". Beside Rebuild Index, **Pause Indexing** / **Resume Indexing**. Keyword search always
    works from what is indexed; pausing only holds back reading files and finding meaning.
  - **Search by meaning**: "Ready" with the scripts it reads ("Latin"), or "Not on this Mac yet: search finds
    words only" when no model is there. A footnote: "Elenath reads PDFs and pictures on this Mac to find the
    text in them. Nothing leaves your Mac."
  - The diagnostics report adds the embedding models by script with their revisions, how many files were
    read, are waiting or couldn't be read, and the retrieval benchmark: the demo library's questions asked
    on this Mac's model, "9 of 10 found in the top 5".

- **Calendar** (`calendar`, from 0.2): **Default alert**, **First day of the week**, **Notifications**
  (status and the button that fits), **Show in menu bar**, and **Bring In Ithil Calendar…** (screen 13).
- **Subjects** (`circle.hexagongrid`, from 0.2): Ithil's subject cards (color swatch, name, palette and custom
  color, Quick Add keywords; add and delete), each with a **Home** menu: "No Home", or a space, and in a space
  that mixes one of its folders ("Uni › Physics"). A sealed space's folders are named only inside it, so its
  home shows as the space alone. A subject whose home is gone shows `exclamationmark.triangle` in `AccentText`
  and "Its home is gone. Its events' notes and files are hidden until you choose one."

The Nano bot tab comes with Nano bot.

### 10. Onboarding (first launch)

Three short pages on `BackgroundWindow` with stars, each centered and at most 440 pt wide: the app icon
(96 pt), a New York headline 26 pt, one line in 13 pt `TextSecondary`, the page's content, then its buttons
(amber prominent, or quiet `ControlFill`). Three 7 pt step dots along the bottom: the current one amber. Pages
slide in by 40 pt and fade (0.25 s); with Reduce Motion they only cross-fade.

1. **Welcome**: "Welcome to Elenath" / "One private place for your notes, on your Mac." A `BackgroundRaised`
   card with three points: `lock` "Offline and private", `folder` "Plain files in a real folder", `keyboard`
   "Capture from anywhere" (with the current shortcut). Continue.
2. **Choose folder**: "Choose where Elenath keeps your notes" / "Notes are Markdown files in real folders, so
   you can also open them in Finder." Create Elenath Folder… (suggesting ~/Documents/Elenath) and Use Existing
   Folder…. Footnote: "Copy the folder to back up everything, or open it on another Mac to pick up where you
   left off."
3. **First spaces**: "Make your first spaces" / "A space is a folder for one part of your life. You can change
   these any time." Rows to switch on or off, each with a symbol, an editable name and a Sealed switch: Uni,
   Red Cross (sealed), Ideas, Personal. Add Another…. Continue creates them.

4. **Notifications** (from 0.2): "Stay on time" / "Elenath reminds you before events, even when it is
   closed.", Ithil's permission card (explained before macOS asks), Skip or Continue.
5. **Your calendar** (from 0.2): "Bring in your calendar" / "Have you used Ithil? Elenath can copy your events,
   subjects and files. Your Ithil folder stays as it is." Bring In Ithil Calendar… (screen 13) and "Start With
   an Empty Calendar" (quiet). Five step dots.

A page that introduces Nano bot is added when Nano bot is.

### 11. Folder screens

As in Ithil, on the starry window background with the app icon, a New York headline and the buttons:

- **Choose** (after onboarding, when no folder is remembered): the same actions as onboarding's second page.
- **Missing**: "Elenath can't find its folder", the last path in a `ControlFill` capsule, Locate Folder… and
  Choose Another Folder…. Elenath never starts over with an empty library without being asked.
- **No library** and **Unreadable**: what was found, and what can be done.

### 12. The calendar (from 0.2)

Ithil's screens (Ithil 1.0.0's docs/DESIGN.md, screens 1 to 8 and 10), fitted into Elenath's window: the
same tokens, sizes and symbols, with these differences.

**Sidebar.** Under the selected Calendar row: Ithil's **mini month** ("November" in New York semibold with ‹ ›,
weekday initials in `TextTertiary`, the visible week or month as a `ControlFill` pill, today as an amber circle)
and **Subjects** (section label; a rounded checkbox filled with the subject color and the name; unchecking
hides that subject's events). The spaces and tags follow as usual. Ithil's "Up next" lives on Today and in the
menu bar.

**Toolbar** (replacing the breadcrumb and New Note while the calendar is open): Ithil's title "November 2026"
(month New York semibold 26 pt, year regular `TextSecondary`), then the workplace capsule when the calendar works
inside a space; `ControlGroup` "‹ Today ›", the Day | Week | Month segmented picker, the search field (it
searches events while the calendar is open), and the square amber `+` (New Event). Back and forward stay.

**An empty calendar** (no events and no subjects) shows a card at the bottom: `calendar.badge.plus`, "Coming
from Ithil?" / "Bring in your events, subjects and files. Your Ithil folder stays as it is." and Bring In Ithil
Calendar…, so someone who had Ithil finds the way in without onboarding.

**Week, Day and Month views**: as Ithil's, on `BackgroundWindow` with no stars: the 56 pt header row, the 56 pt
time gutter with tabular hour labels, 48 pt hour rows, the amber "now" pill and line, event blocks (radius 6,
subject fill and border, title 12 pt semibold, time 11 pt, `paperclip` + file count), the 1.5 pt amber ring on
the selected event, the all-day strip, drag to move and resize, Month's 3 rows per day and "N more". A sealed
event's block shows `lock.fill` (9 pt) after its time. Month no longer collapses the sidebar (Elenath's sidebar
holds the spaces); ⌃⌘S does.

**Event details popover**: Ithil's (subject label, title in New York 22 pt, date and time, `mappin`, `bell`,
`repeat`, then Files with Show in Finder and the file list with Quick Look), plus:
- **Home**: `house` and the home as "Uni › Physics" with the space dot, or "No home · notes go to the Inbox".
- **Notes for this event** (section label): the notes linked to this occurrence (title, first line, open on
  click), then "New Note for This Event" (`square.and.pencil`), which makes a note in the home's folder (the
  Inbox without a home) linked to the occurrence and opens it.
- **When the event is sealed and the calendar isn't working in its space**: title, subject, date and time,
  location, alert and repeat as usual; "Files · 3" with **Open Files** (`folder`, opens the folder in Finder);
  then a `BackgroundRaised` card instead of the notes and the file list: `lock.fill` in the space color, "Kept
  in Red Cross" (13 pt semibold) / "This event's notes, files and linked notes are sealed in its space."
  (`TextSecondary`), and **Open in Red Cross**, which switches the calendar into that space.
- **When the subject's home is missing**: the same card with `exclamationmark.triangle`, "Its home is gone" /
  "Choose a home for Physics in Settings to see this event's notes and files." and **Open Settings**.

**Working in a space.** The calendar normally reads from everywhere. "Open in Red Cross" switches it into that
space: a capsule after the title, the space's symbol in its color, its
name and `xmark` ("Leave Red Cross"), on the space fill. Inside a sealed space, its own events show their notes
and files and every other event shows only its title, time, location and file count; leaving goes back to
everywhere. The calendar's search follows the same rules (notes only where they may be read, never files).

**Event editor popover**: Ithil's (title, date, time, the event's time zone, subject, location, alert, repeat
with "this event or all future ones", notes, the file drop zone "Copied to Calendar › 2026-11-12 › 10.00
Physics Quiz", Cancel and the amber Add Event or Done). For a sealed event outside its space, the Notes field is
replaced by "Notes are kept in Red Cross." (`TextTertiary`); dropping files still works and shows the count.

**Empty states**: Ithil's ("A quiet day.", "No files yet. Drop some here.", "Nothing by that name." / "No events
match “chemistry”."), with "Press ⌘N to add something."

**A space called "Calendar"** (from Elenath 0.1): instead of the calendar, the empty state "The name Calendar
is taken" / "A space is called Calendar, the name the calendar uses now. Rename the space to open the calendar."
with Rename Space… (amber).

**Notifications** (drawn by macOS): Ithil's. Title "Physics Lecture in 10 min", body "14:00 – 15:30 · Room B204 ·
4 files", the "Open Files" action. The same for sealed events. Identifiers start with `elenath.alert.`.

**Menu bar extra** (one for everything, from 0.2): Ithil's, with `star.fill` as its template label and these rows
under the day lists: "Capture… ⌥Space", "Inbox" with its count at the right (tabular), "Open Elenath", "Settings…
⌘,", "Quit Elenath ⌘Q". Show in menu bar is in Settings › Calendar; it is on by default.

**Shortcuts**: ⌘1 / ⌘2 / ⌘3 open Day, Week and Month from anywhere; ⌘T shows today in the calendar and opens
Today elsewhere; ← / → go to the previous and next day, week or month; ⌘N makes a new event while the calendar
is open (a note elsewhere); Delete deletes the selected event; ⌥⌘I opens the Inbox.

### 13. Bring in my Ithil calendar (from 0.2)

A sheet, 520 pt wide, `BackgroundRaised`, padding 24.
1. "Bring in your Ithil calendar" (New York 22 pt) / "Elenath copies your events, subjects and each event's
   files. Your Ithil folder stays exactly as it is." Choose Ithil Folder… (amber; the panel suggests
   ~/Documents/Ithil) and Cancel.
2. While copying: a progress bar and "Copying 12 of 40 files" (tabular), with Stop.
3. The result: `checkmark.circle.fill` in the fern color and "Everything is in Elenath" / "Brought in 42 events,
   5 subjects and 37 files." When something already was there: "12 events were already here; they were left
   alone." When the counts don't match: `exclamationmark.triangle` in `AccentText`, "2 files couldn't be
   copied" and their paths in a monospaced box with Copy List; running it again copies what's missing.
4. **Homes**: "Where do these subjects belong?" One row per subject brought in: the subject dot and name, and
   the Home pop-up ("No home" by default). Set Later leaves them without a home.
5. **Ithil's alerts**: a `BackgroundRaised` card with `bell.slash`: "Ithil's own alerts are still scheduled" /
   "To stop them: open System Settings › Notifications › Ithil and turn off Allow Notifications. Then quit
   Ithil and turn off its Open at Login." with Open Notification Settings. Done (amber) closes the sheet.

Errors: "This isn't an Ithil folder" (no `.ithil/events.json`), "This calendar was made by a newer Ithil",
"Ithil's events.json can't be read", "That folder is part of your Elenath library".

## Screen → SwiftUI map

| Screen | Implementation |
|---|---|
| Main window | `WindowGroup` + `NavigationSplitView`. Sidebar: a `ScrollView` of custom rows. Toolbar: `ControlGroup` back and forward, `.searchable`, `Button` `.borderedProminent` tinted amber. |
| Editor | An `NSTextView` (TextKit 1) in an `NSViewRepresentable`; attributes from `ElenathCore`'s Markdown scanner. Title and details row in SwiftUI above it. |
| Quick Capture | `NSPanel` (nonactivating, floating) hosting SwiftUI; Carbon `RegisterEventHotKey` for the global shortcut. |
| Jump to a note | An overlay in the main window with a `TextField` and a list. |
| Space sheet | `.sheet` with a grouped `Form`. |
| Settings | `Settings` scene, `TabView`, `Form.formStyle(.grouped)`. Appearance sets `NSApp.appearance`. |
| Empty states | `EmptyStateView`: an illustration asset, a New York headline, an SF Pro secondary line. |
| Onboarding | One view per page, `.transition` gated by `accessibilityReduceMotion`. |
| Calendar | Ithil's views, ported: `DayWeekView` (time grid, all-day strip, drag), `MonthView`, `CalendarSidebar` parts in `SidebarView`, `CalendarToolbar`, `EventDetailsView` and `EventEditorView` popovers, `SearchResultsView` for events. State in `CalendarModel` (`.environment`). |
| Menu bar | `MenuBarExtra(isInserted:)` with `.menuBarExtraStyle(.window)`, Ithil's `MenuBarContent` plus Capture and Inbox rows. |
| Bring in Ithil | `.sheet` over the window; `NSOpenPanel` for the folder; `CalendarImport` off the main thread with a progress callback. |

## Still to be designed

Written here before each is built: Nano bot's panel and proposal cards, boards and frames, charts, the Sky,
and goal pages.
