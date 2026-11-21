# Moving your notes into Elenath

How to bring the notes you keep elsewhere into Elenath, from version 0.1 on.

## How import works

- Drop files or whole folders onto a space, a folder or the Inbox in Elenath's sidebar, or onto a folder's
  list. Or choose **File › Import…** (<kbd>⇧</kbd><kbd>⌘</kbd><kbd>I</kbd>): it imports into the space or
  folder you have open, or into the Inbox.
- Everything is **copied**. Your originals stay where they are, untouched.
- Folders keep their structure. If a name is already taken, the new item gets a number, as in Finder.
- A card at the foot of the sidebar shows the progress, and can cancel. What was copied before you cancel
  stays.
- Not sure where something belongs? Drop it on the Inbox and file it later.

| What you drop | What Elenath makes of it |
|---|---|
| Markdown (`.md`, `.markdown`) and plain text (`.txt`) | A note, with its text exactly as it was. Over 16 MB it is copied as a file instead: a note that large can't be edited |
| Rich text and Word documents (`.rtf`, `.rtfd`, `.doc`, `.docx`, `.odt`) | A note with the document's text; the original is kept beside it in `Attachments` and linked from the top of the note. Over 64 MB it is copied as a file only |
| Saved web pages (`.html`, `.htm`, `.webarchive`) | A note with the page's text: headings, paragraphs, lists and quotes. Elenath reads the text itself, so the page runs no script and nothing is loaded from the web; pictures on the web stay out. The original is kept beside it |
| A WhatsApp chat export (its `.txt` file, or the folder it unpacks to) | Its messages as notes where you drop it. Messages sent within a few minutes of each other become one note, dated when they were sent, with their photos and files |
| PDFs and images | Copied as they are. Version 0.1 finds them by name; a later version also reads their text |
| A `.zip` file | Copied as it is: Elenath doesn't unpack it. Double-click it in Finder first and drop what comes out |
| Hidden files and folders (names starting with a dot, such as `.obsidian`) | Skipped |
| Aliases, symbolic links and other special files | Skipped: Elenath copies only real files and folders, so nothing in your library points outside it |
| Anything else | Copied as it is |

## From each place

### Markdown files and files in folders, also from another computer

1. If they are on another computer, copy the folder to the Mac first (a USB drive, AirDrop or a shared folder).
2. Find the folder in Finder.
3. Drag the folder onto the space where it belongs (or drag the files onto a folder in that space).

Links such as `[[Other note]]`, tags such as `#exam` and tasks such as `- [ ] Revise` keep working: Elenath
follows the same conventions as Obsidian where they overlap. A folder of another app's own settings (such as
`.obsidian`) is skipped. A vault's own `Attachments` folder becomes Elenath's `Attachments` folder beside the
notes, so the pictures your notes embed still show.

### A WhatsApp chat with yourself

WhatsApp can export one chat at a time. Its menus change between versions, so the names below may differ a
little.

1. On the phone, open the chat.
2. Open the chat's menu (tap the name at the top on iPhone; the three dots, then More, on Android) and choose
   **Export Chat**.
3. Choose whether to include photos and files, then send the export to the Mac, for example with AirDrop or by
   saving it to a folder the Mac can see. From an iPhone it arrives as a `.zip` file; from Android, as a `.txt`
   file with the photos beside it.
4. If it's a `.zip`, double-click it in Finder. It becomes a folder.
5. Drag the folder (or the `.txt` file) onto the Inbox in Elenath, or onto a space if the whole chat belongs
   there.

Each thought you sent yourself becomes its own note in the Inbox, so it can be filed where it belongs.

### Notes in an app on a phone

There are no steps per app. Two routes work for any of them:

- **A few notes:** copy the text and paste it into Quick Capture, or into a new note.
- **Many notes:** export them from the app as Markdown, plain text, Word or PDF, bring the files to the Mac, and
  drop them on the Inbox.

### Your Ithil calendar

Elenath does everything Ithil does, so your calendar moves in once and Ithil can go.

1. In Elenath, open **Settings › Calendar** and click **Bring In Ithil Calendar…** (an empty calendar and the
   first launch offer it too).
2. Choose your Ithil folder. Ithil suggests `Documents/Ithil`. Elenath only reads it: nothing in it is
   changed, moved or deleted.
3. Elenath copies your subjects, your events and every event's files into the `Calendar` folder of your
   library, checks that every file arrived, and shows the counts. Bringing it in again later brings in only
   what's new, never anything twice.
4. Elenath asks where each new subject belongs: the space its notes go to (change it later in **Settings ›
   Subjects**). A subject homed in a sealed space keeps its events' notes and files sealed there; its
   events still show on the calendar with everything else.
5. Stop Ithil's own alerts, or every alert arrives twice: **System Settings › Notifications › Ithil**, turn
   off **Allow Notifications**. Then quit Ithil and turn off its **Open at Login**.

Your Ithil folder stays as it was. Keep it as an extra backup, or move it to the Trash once you're happy.

## Filing what you imported

Everything dropped on the Inbox waits there until it is filed. Until version 0.4 you file by hand: drag an
item onto a space or folder in the sidebar, use the menu on an item in the Inbox (**File to…**), or the bar
above an Inbox note. From version 0.4, Nano bot proposes a space, a folder, a title and tags for each item,
and you accept, change or skip each proposal.
