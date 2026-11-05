# Document edit mode — design

Status: written from the Owner's request on 2026-11-05 ("make suica able to have 2 modes in markdown document: view and edit"). It amends `2026-11-04-documents-page-design.md`, whose non-goal "Editing, creating or deleting files. The page never writes to a document" no longer holds for editing. Choices marked _my call_ are the builder's. Vocabulary is in `CONTEXT.md`.

## Why

The Documents page reads plans and docs. Fixing a typo, ticking a step or adding a note means leaving Suica for an editor. These files are also rewritten by agents while the Owner reads them, so a write path must never overwrite a change it has not seen.

## Goals

- A **View | Edit** switch on the open document (⌘E). View is today's rendered page; Edit is the file's own text in a plain monospaced editor.
- **Save** (⌘S) writes the text back to the file. Nothing is written until the Owner saves (_my call_: no autosave, because an agent may be rewriting the same file).
- A **Draft** (unsaved text) is never lost by moving around: opening another file, Back, Forward, following a link, leaving the page or closing the window keeps it; the list marks files that have one. Quitting the app with Drafts asks first (Save All, Discard, Cancel).
- View mode shows the Draft when there is one (a live preview), the saved file otherwise.

## Non-goals

- Creating, renaming, moving or deleting files; a rich or live-preview editor, syntax highlighting, wikilink completion, split view (_my call_: the first cut is a text editor).
- Merging a conflict. Suica offers Overwrite, Reload or Keep editing, never a three-way merge.
- Editing files the page cannot show (over 1,000,000 bytes, not UTF-8, unreadable).

## Behaviour

- **What is edited:** the whole file text, front matter included. Lines are edited with `\n`; a file that used `\r\n` is saved with `\r\n` again, and one that used `\n` stays `\n` (_my call_: a file with both becomes all `\r\n`). A leading BOM and a missing final newline are kept. A file opened for editing and saved without a change is byte-identical, and Save is disabled while there is no Draft change.
- **Conflict:** Save first reads the file again. If its text differs from the text the Draft started from, nothing is written and the page says "The file changed on disk" with **Overwrite**, **Reload** (drops the Draft) and **Keep editing**. The same check runs when the app becomes active: a clean document reloads silently; one with a Draft shows the notice and keeps the Draft.
- **Write:** atomic (a failed or interrupted write never leaves a half file) and the file keeps its permissions. A file that is read-only, deleted, grew past 1,000,000 bytes or cannot be written shows the reason; the Draft stays.
- **Revert** drops the Draft and shows the saved text again.
- **Marks:** a dot beside the file name in the header and the list for each file with a Draft.
- **Reload on Rescan or app activation** never replaces a Draft.
- Sidebar and shortcuts: ⌘E toggles View/Edit and ⌘S saves, on the Documents page only.

## Anti-goals

- A save that silently overwrites a change made on disk since the Draft began.
- A save, a reload or a scan that blocks the window.
- Losing a Draft to navigation, a rescan, a link click or closing the window.
- Writing anything outside the one file being saved (no temp files left behind, no change to other files).
