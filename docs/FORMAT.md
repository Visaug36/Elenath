# Elenath's folder format

This is the contract for what Elenath keeps on disk. The library is a folder of plain files, and the folder is
the truth: any app that follows this document can read it, and Elenath shows whatever is in it, including
changes made in Finder or another editor.

Format version **1**. It covers what Elenath 0.1 reads and writes. Boards, charts and Nano bot's files are
reserved here and specified when they ship.

## Principles

- **Plain files.** Notes are UTF-8 Markdown. Settings that belong to the library are small JSON files.
- **Nothing hidden elsewhere.** Copying the library folder is a full backup. The search index and safety
  copies in Elenath's container are derived from the folder and are rebuilt when missing.
- **Never rewritten behind your back.** Elenath changes a file only when you change something. It never
  reformats a note body, and it keeps every byte it doesn't understand.
- **Never deleted.** Deleting moves to the Trash. The only files Elenath removes for good are its own old
  backups.
- **Never outside.** Nothing is written outside the library folder, except Elenath's index and safety copies
  in its own container.

## The library folder

```
Elenath/                              the library: one folder, chosen on first launch
├── .elenath/
│   ├── library.json                  id, schema version, order of spaces, settings that travel
│   └── backups/                      rolling backups of library.json
├── Inbox/                            everything dumped, until it is filed
│   └── Attachments/
├── Uni/                              a space: any other visible top-level folder
│   ├── .space/
│   │   ├── space.json                id, color, symbol, sealed, description, keywords
│   │   ├── backups/                  rolling backups of space.json
│   │   ├── memory.md                 reserved for Nano bot
│   │   └── decisions.jsonl           reserved for Nano bot
│   ├── Reading list.md               a note at the top of the space
│   └── Physics/                      a folder; folders nest to any depth
│       ├── Lecture 7 notes.md
│       ├── Attachments/              files dropped on notes in this folder
│       └── Free body diagrams.board/ reserved for boards
└── Red Cross/                        another space
```

- A folder is an Elenath library when it contains `.elenath`.
- **Spaces** are the visible folders directly inside the library, except `Inbox`. Their names are the folder
  names.
- The **Inbox** is the folder named `Inbox`. It belongs to no space. Its name on disk is always `Inbox`,
  whatever language Elenath runs in.
- Files directly inside the library folder belong to no space. Elenath leaves them alone and doesn't show them.
- Hidden items (names that start with a dot) are ignored everywhere, apart from `.elenath` and `.space`.

### Reserved names

| Name | Where | Meaning |
|---|---|---|
| `.elenath` | library folder | Elenath's own files for the library |
| `Inbox` | library folder | the Inbox; never a space |
| `.space` | a space's folder | Elenath's own files for the space |
| `Attachments` | any folder | files that belong to the notes beside it; not shown as a folder of notes |
| `*.board` | any folder | a board package (reserved) |

## Names

Elenath only creates and renames files and folders with names that pass these rules. Names made in Finder
are used as they are.

- `/` and `:` become `-`.
- Control characters and line breaks become spaces. Runs of whitespace collapse to one space.
- Leading dots are removed, so nothing Elenath names is hidden. Trailing dots and spaces are removed.
- A title keeps at most 120 characters and 200 UTF-8 bytes, cut on a character boundary. That leaves room
  for an extension and for the suffixes below inside the file system's 255-byte limit.
- A name that is empty after this becomes `Untitled`.
- Names are compared without regard to case or Unicode normalization, as macOS volumes do. Two items in
  one folder never differ only by case.
- **Clashes** get a number, as in Finder: `Notes.md`, `Notes 2.md`, `Notes 3.md`.

Characters that Windows forbids in file names (`\ * ? " < > |`) are allowed. A reader on another platform has
to map them.

## library.json

`.elenath/library.json`, pretty-printed with sorted keys:

```json
{
  "id" : "5F0C1B7E-3A0D-4B0E-9C59-0F5B6E1D2A31",
  "savedAt" : "2026-11-10T14:30:00Z",
  "schemaVersion" : 1,
  "settings" : {

  },
  "spaces" : [
    "0E6C3E2F-6F0B-4C55-9A1E-1D6A2B7C8D90",
    "9B1D4C7A-2E5F-4A60-8B3C-7E9F0A1B2C3D"
  ]
}
```

| Key | Type | Meaning |
|---|---|---|
| `schemaVersion` | integer | 1 |
| `savedAt` | ISO 8601, UTC, whole seconds | when the file was written |
| `id` | UUID | the library's identity; never changes |
| `spaces` | array of UUID | the order of the spaces in the sidebar, by their `space.json` ids. Spaces missing from the list come last, by name. Ids with no folder are kept. |
| `settings` | object | settings that travel with the library. Empty in version 1. Unknown keys are kept. |

## space.json

`<space>/.space/space.json`:

```json
{
  "color" : "teal",
  "description" : "University courses and coursework.",
  "id" : "0E6C3E2F-6F0B-4C55-9A1E-1D6A2B7C8D90",
  "keywords" : [
    "uni",
    "lecture",
    "exam"
  ],
  "savedAt" : "2026-11-10T14:30:00Z",
  "schemaVersion" : 1,
  "sealed" : false,
  "symbol" : "graduationcap"
}
```

| Key | Type | Meaning |
|---|---|---|
| `schemaVersion` | integer | 1 |
| `savedAt` | ISO 8601, UTC | when the file was written |
| `id` | UUID | the space's identity. It survives renaming the folder. |
| `color` | string | a palette name (`clay`, `teal`, `iris`, `fern`, `rose`) or a custom color as `#RRGGBB` |
| `symbol` | string | an SF Symbol name. An unknown name falls back to `folder`. |
| `sealed` | boolean | whether the space is sealed (see below) |
| `description` | string | what the space is for, in a sentence. May be empty. |
| `keywords` | array of string | words that mean this space, for filing. Lowercase, no duplicates. |

- A top-level folder without `.space` is a space too. Elenath gives it a `space.json` (not sealed, color and
  symbol by default) the first time it opens the library.
- **Sealed fails closed.** If a `space.json` is missing or damaged, Elenath restores it from its newest backup
  or safety copy and says so. If nothing can be restored, the space counts as sealed until you decide, so its
  content is never shown elsewhere by mistake.

### What sealed means for readers

A sealed space's notes and files are used only while working inside that space. Any app that reads this
format and wants to respect it must not show a sealed space's content in another space's search, links or
suggestions, and must not show other spaces' content inside it. Its name, description and keywords may be
used elsewhere, to offer the space as a place to file something. Its folder names may not.

## Saving, backups and recovery

`library.json` and `space.json` are both saved the same way.

- **Atomic writes.** A file is written beside its target and renamed over it, so a reader sees the old file
  or the new one, never half of one.
- **Rolling backups.** Before a save replaces the file, the old file is copied to `backups/` beside it as
  `library-yyyyMMdd-HHmmss.json` or `space-yyyyMMdd-HHmmss.json` (UTC; `-2`, `-3`… within one second), at most
  once every 15 minutes. The newest 50 are kept.
- **Safety copy.** The same bytes are written into Elenath's container (see "Outside the library").
- **Recovery.** A missing or damaged file is replaced by the newest backup or safety copy that can be read.
  The damaged file is kept beside it as `library.corrupt-yyyyMMdd-HHmmss.json` or
  `space.corrupt-yyyyMMdd-HHmmss.json`. Elenath tells you what it did.
- **Newer versions.** A file whose `schemaVersion` is higher than the reader knows is never changed. A newer
  `library.json` makes the whole library read-only; a newer `space.json` makes that space read-only.
- **Older versions** are migrated in memory and written in the current schema at the next save, after a
  backup.

## Notes

A note is a file whose name ends in `.md` or `.markdown` (in any case), anywhere inside a space or the Inbox,
except inside `.space`, `Attachments`, a `*.board` package or a hidden folder.

- **Title.** The file name without its extension. Renaming the note renames the file.
- **Encoding.** UTF-8. A byte order mark is kept if the file has one. A file that isn't valid UTF-8 is shown
  read-only and never rewritten.
- **Line endings** are kept as they are (`LF` or `CRLF`). Notes Elenath creates use `LF` and end with one.
- **Body.** Everything after the front matter. Elenath writes back exactly the text in the editor: no
  reformatting, no trimming, no renumbering.

Other files in a space (PDFs, images, anything else) are documents. Elenath lists them and can show them,
and never changes them.

### Front matter

Optional. It starts on the first line, which is exactly `---`, and ends at the next line that is exactly `---`.
If there is no closing line, the whole file is body.

```markdown
---
id: 8D2F6A1C-4B7E-4F03-A5D9-3C1E0B9F7A62
created: 2026-11-10T14:30:00+02:00
kind: idea
tags: [physics, exam]
goals: ["[[Pass Physics 1]]"]
event: 4954484C-DE30-4000-8000-000000000201/2026-10-06
---
```

Elenath understands six keys:

| Key | Value | Meaning |
|---|---|---|
| `id` | UUID | the note's identity. With it, links follow the note when its file is renamed or moved outside Elenath. |
| `created` | ISO 8601 date or date and time | when the note was created. Without it, the file's creation date is used. |
| `kind` | `note`, `idea` or `goal` | `note` when missing. Another value is kept and treated as `note`. |
| `tags` | list of strings | tags without `#`. A flow list (`[a, b]`), a block list (`- a` lines) or one comma-separated string. |
| `goals` | list of links | the goals this note points at, each a quoted link such as `"[[Pass Physics 1]]"` |
| `event` | string | an Ithil event occurrence: the event's id, `/`, and the occurrence's date (`yyyy-MM-dd`) |

- The block is read as simple YAML: `key: value` lines, values plain or quoted, lists in either form.
- **Everything else is kept byte for byte:** unknown keys, comments, blank lines, the order of keys and how
  values are quoted. Elenath never re-serializes the block. When it changes a key, it rewrites that key's
  lines and nothing else; a new key goes at the end of the block.
- A key at its default is not written (`kind: note`, an empty `tags`).
- **When Elenath writes it.** Notes created in Elenath start with `id` and `created`. Notes that came from
  elsewhere are left exactly as they are until you first edit them in Elenath; that save adds `id` and
  `created` (from the file's creation date).
- Two notes with the same `id` are a duplicated file. The one created later gets a new `id` the next time
  Elenath saves it.

### Links

Links between notes are wiki links, compatible with Obsidian's.

| Form | Meaning |
|---|---|
| `[[Title]]` | the note with that title |
| `[[Title\|shown text]]` | the same, shown as "shown text" |
| `[[Folder/Title]]` | when titles clash: the end of the note's path inside its space, as many folders as needed |
| `[[Space/Title]]`, `[[Space/Folder/Title]]` | a note in another space, by its path from the library folder |
| `[[Title#Heading]]` | a heading in that note |
| `[[Title#^block]]` | kept as written; opens the note |

- A target may end in `.md`. Titles, folders and spaces are compared without regard to case or Unicode
  normalization.
- **Resolving a target from a note in space S:**
  1. A target without `/` is a title. If one note in S has it, that is the target. If several do, the one in
     the linking note's folder wins, then the one with the shortest path; a tie is ambiguous. If none in S
     has it and S isn't sealed, a note with that title in another unsealed space is the target when there is
     exactly one.
  2. A target with `/` is first matched against the ends of paths in S, then, if S isn't sealed, read as a
     path from the library folder.
  3. A target that matches nothing is unresolved. It stays as written, and following it offers to create the
     note.
- **Sealed spaces.** A link in a sealed space resolves only inside that space. A link elsewhere never
  resolves into a sealed space; it stays as written and reads as unresolved.
- **Writing links.** Elenath writes the shortest form that resolves to the note: `[[Title]]`, then
  `[[Folder/Title]]`, then `[[Space/Title]]`.
- **Renaming or moving a note** rewrites the links that point to it, keeping any shown text and heading. Links
  to it that were ambiguous or unresolved are left alone.
- Markdown links work too: `[text](Other%20note.md)` is a link to a note by its path from the linking
  note's folder, and `[text](https://example.com)` opens in the browser.

### Embeds

`![[file]]` shows a file in place: an image, a PDF, and later a board or a chart.

- The name includes its extension: `![[diagram.png]]`. `![[diagram.png|300]]` sets a width in points.
- It is looked up in the `Attachments` folder beside the note, then in the note's folder, then anywhere in the
  same space when exactly one file has that name.
- `![[Title]]` with a note's title is shown as a link.
- Markdown images work too: `![alt](Attachments/diagram.png)`.

### Tags

- In the body: `#tag`, after the start of a line or whitespace. A tag is letters, digits, `_`, `-` and `/`,
  with at least one character that isn't a digit. `/` nests: `#uni/physics`.
- In front matter: the `tags` list.
- Not a tag: anything inside code, a link or a URL, and a `#` followed by a space (a heading).
- Tags are compared without regard to case and shown as first written.

### Tasks

A task is a list item whose text starts with `[ ]` (open) or `[x]` / `[X]` (done): `- [ ] Revise chapter 4`.
The list marker may be `-`, `*`, `+` or a number, at any indent. Ticking a task changes that one character.

### Attachments

- A file dropped on a note is **copied** into the `Attachments` folder beside the note (created when the first
  file arrives). The original stays where it was. Clashes get a number, as in Finder.
- The note refers to it with `![[name.ext]]` for images and PDFs, and with a Markdown link
  (`[name.ext](Attachments/name.ext)`) for other files.
- When Elenath moves a note to another folder, the attachments that only this note uses move with it.

## The Inbox

- An Inbox item is anything directly inside `Inbox`: a note, a file or a folder.
- A capture is a note. Its title is its first line (made safe as a name, at most 60 characters), or
  `Capture 2026-11-10 14.30` when it has none. Pasted images and dropped files go to `Inbox/Attachments`.
- Filing an item moves it into a space, with its attachments.
- Inbox items are used for nothing except filing them: they don't appear in a space's search, links or
  suggestions.

## Conflicts

When a note changes on disk while Elenath holds unsaved edits to it, both are kept. The file on disk stays as
it is, and the unsaved edits are saved beside it as `Title (conflict 2026-11-10 14.30).md` (local time; a
number is added if that name is taken). Elenath never picks one silently.

## Reserved for later versions

These names and syntaxes are reserved. Elenath 0.1 leaves them untouched.

- `<space>/.space/memory.md` and `<space>/.space/decisions.jsonl`: what Nano bot has learned in a space, and
  the proposals that were accepted, changed or rejected.
- `Name.board`: a board, as a folder holding `board.json` and its images.
- A fenced code block marked `chart` inside a note: a chart, as a small table plus settings.

## Outside the library

Elenath keeps three things in its own container, `~/Library/Containers/io.github.visaug36.Elenath/`. None of
them is needed to open a library: all are rebuilt from the folder or are only a second line of defense.

| What | Where (under `Data/Library/Application Support/Elenath/`) |
|---|---|
| Safety copies of `library.json` and every `space.json` | `SafetyCopies/<library id>/` |
| The search index, one SQLite database per space and one for the Inbox | `Index/<library id>/` |
| Edits that could not be saved, kept until the next launch | `Recovery/<library id>/` |

Which folder is the library (a security-scoped bookmark), the appearance and the shortcuts are settings of
the Mac, kept in the app's preferences.

## Versions of this format

| Version | Elenath | Changes |
|---|---|---|
| 1 | 0.1 | The first version. |
