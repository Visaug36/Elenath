# Moving your notes into Elenath

Import arrives with **version 0.1**. This page is the plan for it, written ahead so the importer is built for
the places notes really come from. It will be completed and checked against the real thing before 0.1 ships.

## How import works

- Drop files or whole folders onto a space, a folder or the Inbox in Elenath's sidebar, or use File › Import….
- Everything is **copied**. Your originals stay where they are, untouched.
- Folders keep their structure. If a name is already taken, the new item gets a number, as in Finder.
- Not sure where something belongs? Drop it on the Inbox and file it later.

| What you drop | What Elenath makes of it |
|---|---|
| Markdown (`.md`, `.markdown`) and plain text (`.txt`) | A note, with its text exactly as it was |
| Rich text and Word documents (`.rtf`, `.rtfd`, `.doc`, `.docx`) | A note with the document's text; the original is kept beside it in `Attachments` and linked from the top of the note |
| A WhatsApp chat export | One note per chat, a heading per day, with photos and files in `Attachments` |
| PDFs and images | Copied as they are. Version 0.1 finds them by name; a later version also reads their text |
| Anything else | Copied as it is |

## From each place

### Old Markdown files

1. Find the folder that holds them in Finder.
2. Drag the folder onto the space where it belongs (or drag the files onto a folder in that space).

Links such as `[[Other note]]`, tags such as `#exam` and tasks such as `- [ ] Revise` keep working: Elenath
follows the same conventions as Obsidian where they overlap. A folder of another app's own settings (such as
`.obsidian`) is skipped.

### WhatsApp chats

WhatsApp can export one chat at a time. Its menus change between versions, so the names below may differ a
little.

1. On the phone, open the chat.
2. Open the chat's menu (tap the name at the top on iPhone; the three dots, then More, on Android) and choose
   **Export Chat**.
3. Choose whether to include photos and files, then send the export to the Mac, for example with AirDrop or by
   saving it to a folder the Mac can see. It arrives as a `.zip` or a `.txt` file.
4. Drag that file onto the Inbox or a space in Elenath.

### Notes on a phone or on another laptop

The steps depend on the app the notes are in. They will be written here once that is known. The general
route is the same for most apps: export the notes as Markdown, plain text, Word or PDF, bring the files to the
Mac, and drop them on Elenath.
