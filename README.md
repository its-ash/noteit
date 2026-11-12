# NoteIt

Sticky notes for macOS with built-in AI. NoteIt works like Stickies: colored notes on your desktop, rich text, float on top, translucent, collapse. Click ✨ on a note and AI refines the text with the provider and model you choose.

SwiftUI and AppKit, Swift 6, macOS 15 or later.

## Features

**Stickies features**
- As many notes as you like: ⌘N, the + on any note, or the menu bar icon. All notes reopen where you left them.
- Lives in the menu bar, with no Dock icon. Settings → General → Startup can open it at login.
- Eight preset paper colors per note (⌘1–⌘8, the palette button, or right-click), all tuned for easy reading (text contrast of 7:1 or more)
- Rich text, images, links, lists, and rulers; drag the bottom-right corner to resize
- Float on top (⌥⌘F), translucent (⌥⌘T), collapse (⌘M, or double-click the strip at the top)
- Find and replace, spelling and grammar, substitutions, transformations, speech
- New note from the clipboard (⇧⌘N), and **Services → Make New NoteIt Note** from text selected in any app
- Import text or Markdown; export one note (plain, Markdown, RTF, RTFD), or export all notes as rich text or Markdown
- Arrange By color, date created, date modified, or title
- Use as Default copies a note's color and font to new notes
- Notes and their positions are saved automatically and restored at launch

**Titles, pinning, and All Notes**
- Give any note a title: File → Set Title… (⌥⌘R), right-click a note, or type it in All Notes. Without a title, the first line stands in.
- **All Notes** (⌘0, Window menu, or the menu bar icon): a OneNote-style window with three columns. On the left: All Notes, Favorites, On Desktop, Reminders, Archive, Trash, your notebooks, and #tags. In the middle: the notes, with search and sorting. On the right: the note.
- Pinned notes show on the desktop as stickies. ✕ on a sticky (or the pin button, ⌥⌘P) takes it off the desktop; it stays in All Notes. Pin it again to bring it back.
- A pinned note edited in All Notes updates on the desktop as you type, and the other way around

**Organize**
- Notebooks: make one with + in the sidebar; move notes with right-click → Move to Notebook. Deleting a notebook keeps its notes.
- Tags: type `#idea` anywhere in a note. Tags appear in the sidebar with counts.
- Favorites (★) sort to the top; Archive hides a note from All Notes and the desktop without deleting it.
- Trash: Move to Trash (File menu, right-click, or the Delete key in the All Notes list). Restore within 30 days; after that the note is deleted for good. Empty Trash from the sidebar.
- Sort by date edited, date created, title, or color. Keyboard: ⇧⌘F searches all notes, ↑/↓ moves through the list, Return starts editing.

**Stickies, improved**
- Clickable checklists: click ☐ to tick it. Format → Checklist (⇧⌘L) adds or removes boxes on the selected lines. The sticky header and the list show progress, like 2/5.
- Reminders: right-click → Remind Me…, or the bell in All Notes. A notification appears at that time and opens the note.
- Quick capture: ⌃⌥N in any app makes a new sticky (Settings → General).
- Stickies snap to screen edges and to each other as you drag them; hold ⌥ to move freely.

**AI across your notes**
- ✨ works in All Notes too, on the selection or the whole note.
- Ask Your Notes (the speech-bubble button in All Notes): ask a question and the AI answers from your notes, naming the notes it used.
- Suggest Title: the wand next to the title, or right-click a sticky.
- Search by meaning: All Notes search finds notes with matching words first, then notes that are close in meaning, using Apple's on-device language model (nothing leaves the Mac).

**Sync and safety**
- Sync with Firebase: Settings → Sync. Sign in with the same email on each Mac. See [Firebase setup](#firebase-setup).
- Daily backups of all notes (the newest 14 are kept). Back Up Now and Restore from Backup… are in the File menu and Settings → General.

**AI**
- ✨ (or ⌘R) runs your default action on the selection, or on the whole note when nothing is selected
- The chevron, the AI menu (⌃⌘1–9), and the note's context menu list every action
- 10 built-in actions: Refine, Fix Spelling and Grammar, Make Shorter or Longer, Summarize, Make a List or Checklist, Professional or Friendly tone, Translate. Add, edit, reorder, or turn off any of them.
- Choose what happens with the answer: replace the text, insert it below, or preview it first
- The answer streams into the note as it's written; one ⌘Z undoes the whole edit. ⌘. stops it.
- Providers: Router (local), Anthropic, OpenAI, OpenRouter, Google Gemini, Groq, Ollama, LM Studio, or any custom OpenAI-compatible or Anthropic-format server
- Per-provider API keys in the macOS Keychain, a model picker filled from the provider, effort or temperature, timeout, custom instructions, and a connection test

## Build

```bash
make run         # build and open build/NoteIt.app
make build       # release build and app bundle
make install     # build, copy to /Applications, and open it
make zip         # build/NoteIt-<version>-macos.zip for a release
make deploy      # release: bump version, GitHub release, update the Homebrew tap (V=1.2.0 to choose)
make swift-test  # run tests
```

`make build` needs `rsvg-convert` (`brew install librsvg`) to make the app icon.

## Data

- Notes: `~/Library/Application Support/NoteIt/notes.json`
- Backups: `~/Library/Application Support/NoteIt/Backups/`
- Sync state: `~/Library/Application Support/NoteIt/sync.json`
- Settings: `in.itsash.noteit` defaults
- API keys and the Firebase sign-in token: login Keychain, service `in.itsash.noteit`

## Firebase setup

NoteIt syncs through the Firebase project `its-ash`, using Firebase Auth (email and password) and Cloud Firestore over their REST APIs. There is no Firebase SDK in the app. Set up the project once in the [Firebase console](https://console.firebase.google.com/project/its-ash):

1. **Authentication → Sign-in method:** turn on **Email/Password**.
2. **Firestore Database:** create a database (production mode).
3. **Firestore → Rules:** let each user read and write only their own notes:

```
rules_version = '2';
service cloud.firestore {
  match /databases/{database}/documents {
    match /users/{uid}/notes/{noteId} {
      allow read, write: if request.auth != null && request.auth.uid == uid;
    }
  }
}
```

The web API key in `Sync.swift` only identifies the project; these rules are what keep notes private. Notes are stored as plain data in Firestore, not end-to-end encrypted.

### Firestore schema

One document per note at `users/{uid}/notes/{noteId}`, where `noteId` is the note's UUID. Any other app (iOS, web) can use the same data:

| Field | Type | Meaning |
| --- | --- | --- |
| `name` | string | Title; empty means "use the first line" |
| `text` | string | Plain text |
| `markdown` | string | The same note as Markdown (when it fits) |
| `rtfd` / `rtf` | bytes | Rich text from the Mac, when it fits under the 1 MiB document limit |
| `color` | string | `yellow`, `orange`, `pink`, `purple`, `blue`, `teal`, `green`, `gray` |
| `notebook` | string | Notebook name; empty for none |
| `favorite`, `archived` | bool | |
| `trashed`, `remind`, `created`, `modified` | double or null | Seconds since 1970 |
| `deleted` | bool | `true` for a deleted note (a tombstone with no content) |
| `syncedAt` | timestamp | Set by the server on every write (`REQUEST_TIME` transform); clients pull changes ordered by it |

Each note's `modified` time decides conflicts: the newest edit wins. Which notes sit on a Mac's desktop, and where, is not synced.

### Writing from other apps (Android, web)

- **IDs:** use uppercase UUIDs for `noteId` (`UUID.randomUUID().toString().uppercase()` on Android). A lowercase ID makes the Mac create a second copy.
- **Every write:** set `syncedAt` to the server time (`FieldValue.serverTimestamp()`), and `modified` to now in seconds since 1970 as a double.
- **Changing the text:** write `text`, and `markdown` if you have formatting, and delete `rtfd` and `rtf`. A Mac shows `markdown` with its formatting (bold, italic, links, headings, `- [ ]` checklists) when it describes the same text as `text`; otherwise it shows `text` as plain text.
- **Deleting:** don't delete the document. Write `deleted: true` with a new `modified` and `syncedAt`, so other devices learn about it.
- **Your own fields:** add any fields you like. Macs change only the fields in the table above, so yours are kept.
