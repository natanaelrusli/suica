# Document Edit Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The Documents page gets a View | Edit switch: edit a document's text, save it safely, and never lose or overwrite work.

**Architecture:** Pure SuicaCore code does the text handling (line endings, conflict-checked atomic write) and `DocumentsModel` keeps a Draft per path in memory, so navigation never loses edits. The page adds a mode switch, a plain `TextEditor` and notices; a quit guard in the existing app delegate protects Drafts.

**Tech Stack:** Swift 6, SwiftUI (`TextEditor`), Observation, Swift Testing. No new dependency.

**Spec:** `docs/superpowers/specs/2026-11-05-document-edit-mode-design.md` (amends `2026-11-04-documents-page-design.md`; read both). The Documents code this builds on is on branch `feat/no-ticket-documents`.

## Global Constraints

- Work in the worktree `/Users/anb-0826009/project/suica-document-edit` on branch `feat/no-ticket-document-edit` (stacked on `feat/no-ticket-documents`); commit with `git -C /Users/anb-0826009/project/suica-document-edit …` as its own command. No planner key exists: never invent one.
- Tests: `cd macos/Suica && swift test`; new tests in `macos/Suica/Tests/SuicaCoreTests/DocumentEditTests.swift`, camelCase sentence names; shared helpers `tree(_:)` and `MemoryStore` live in `PlansTests.swift`.
- Every UI string goes through `Copy`; English only. No new Node command, config key, contract golden or dependency.
- Only `.md` files that the page can show are editable: at most `MarkdownFiles.maxBytes` (1,000,000), UTF-8.
- Nothing is written until the Owner saves; a save never overwrites text changed on disk since the Draft began; a failed save keeps the Draft; no stray temp files.
- File reads and writes run off the main thread.
- Do not run `make install-app` or touch the real preferences while verifying; use a scratch harness (memory `suica-ui-screenshot-harness`) and fixtures only under the scratchpad.
- End every commit message with `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`.

## Review Focus

- The file changed on disk (an agent rewrote the plan) while a Draft is open: Save refuses, nothing is written, the Draft stays; activation never replaces a Draft. [Tasks 2, 3]
- Round trip: CRLF, a BOM and a missing final newline come back byte-identical when nothing was edited; an edit keeps the file's line ending. [Tasks 1, 2]
- The write fails (read-only file, file deleted, over 1,000,000 bytes after the edit): a reason is shown, the Draft is kept, the file is untouched, no temp file remains; permissions survive a successful save. [Task 2]
- Navigating away (open, Back, Forward, link, Rescan) with a Draft keeps it, marks the file, and shows it again on return; quitting with Drafts asks. [Tasks 3, 5]
- Switching View↔Edit with a Draft shows the Draft as the preview, and a Draft equal to the saved text is not a Draft. [Task 3]

---

### Task 1: Text handling

**Files:**
- Modify: `macos/Suica/Sources/SuicaCore/Documents.swift` (`DocumentContent`, `loadContent`)
- Test: `macos/Suica/Tests/SuicaCoreTests/DocumentEditTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public enum LineEnding: Equatable, Sendable { case lf, crlf }
  public enum DocumentText {
      /// Text with every `\r\n` and lone `\r` turned into `\n`, and the ending the file used (`.crlf` when it held any `\r\n`).
      public static func normalise(_ raw: String) -> (text: String, ending: LineEnding)
      /// The inverse for saving: `\n` become `\r\n` for `.crlf`.
      public static func restore(_ text: String, ending: LineEnding) -> String
      /// What View mode draws for `text` (already LF): front matter split, wikilinks rewritten.
      public static func render(_ text: String) -> DocumentContent
  }
  ```
  `DocumentsModel.loadContent` must use `normalise` + `render` instead of its inline copy.

- [ ] **Step 1: Write the failing tests** (suite `DocumentTextTests`):
  - `normaliseReportsTheEndingTheFileUsed`: `"a\r\nb\r\n"` → `("a\nb\n", .crlf)`; `"a\nb"` → `("a\nb", .lf)`; `"a\rb"` → `("a\nb", .lf)`; `""` → `("", .lf)`; mixed `"a\r\nb\nc"` → `("a\nb\nc", .crlf)`.
  - `restoreIsTheInverseForUniformFiles`: for `"\u{FEFF}---\nk: v\n---\nbody\n\n"`, `"x"`, `"a\n\nb\n"` and the CRLF forms, `restore(normalise(s).text, ending: normalise(s).ending) == s`.
  - `renderSplitsFrontMatterAndRewritesWikilinks`: `render("---\ntitle: T\n---\nsee [[x]]\n")` equals `.text(entries: [FrontMatterEntry(key: "title", value: "T")], body: "see [x](suica-doc:x)\n")`.
  - The existing `DocumentsModelTests` for `loadContent` stay green unchanged.

- [ ] **Step 2: Run to verify they fail**

Run: `cd macos/Suica && swift test --filter DocumentTextTests`
Expected: build FAIL, "cannot find 'DocumentText' in scope".

- [ ] **Step 3: Implement `LineEnding` and `DocumentText`** in `Documents.swift`; switch `loadContent` to them.

- [ ] **Step 4: Run to verify they pass**

Run: `cd macos/Suica && swift test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git -C /Users/anb-0826009/project/suica-document-edit add docs macos
git -C /Users/anb-0826009/project/suica-document-edit commit -m "feat: line-ending aware text handling for documents"
```

### Task 2: Conflict-checked atomic write

**Files:**
- Modify: `macos/Suica/Sources/SuicaCore/Documents.swift`
- Test: `macos/Suica/Tests/SuicaCoreTests/DocumentEditTests.swift`

**Interfaces:**
- Consumes: `DocumentText`, `LineEnding` (Task 1), `MarkdownFiles.maxBytes`.
- Produces:
  ```swift
  public struct DiskDocument: Equatable, Sendable { public let text: String; public let ending: LineEnding }  // text is LF
  public enum SaveOutcome: Equatable, Sendable { case saved, conflict, failed(String) }
  public enum DocumentDisk {
      /// nil when the file is missing, unreadable, over `maxBytes` or not UTF-8.
      public static func read(_ path: String) -> DiskDocument?
      /// Writes `text` (LF) with `ending` only if the file on disk still reads as `base` (`overwrite: true` skips that check).
      public static func write(_ text: String, ending: LineEnding, to path: String, expecting base: String, overwrite: Bool = false) -> SaveOutcome
  }
  ```

- [ ] **Step 1: Write the failing tests** (suite `DocumentDiskTests`, temp files via `tree(_:)`, removed in `defer`):
  - `readGivesLFTextAndTheEnding`: a CRLF file → `DiskDocument(text: "a\nb\n", ending: .crlf)`; missing path, 1_000_001 bytes, `[0xFF, 0xFE]` → nil.
  - `writeSavesAndKeepsCRLFAndTheBOM`: file `"\u{FEFF}a\r\nb"`, write `"\u{FEFF}a\nB"` expecting `"\u{FEFF}a\nb"` with `.crlf` → `.saved`, file bytes equal `"\u{FEFF}a\r\nB"`.
  - `writeRefusesWhenTheFileChangedOnDisk`: file now `"changed"`, expecting `"orig"` → `.conflict` and the file is still `"changed"`; with `overwrite: true` → `.saved`.
  - `writeKeepsPermissionsAndLeavesNoTempFile`: file mode 0o640 → after `.saved` mode is still 0o640 and the folder holds only the one file.
  - `writeFailsCleanlyForAReadOnlyDeletedOrTooBigFile`: mode 0o444 → `.failed(reason)` with a non-empty reason and the file untouched; deleted file → `.failed`; text of 1_000_001 bytes → `.failed` and the file untouched; in every case no temp file remains.
  - `savingUnchangedTextRewritesTheSameBytes`: for `"x\r\n\r\ny"` (no final newline), `write(read.text, …, expecting: read.text)` leaves bytes identical.

- [ ] **Step 2: Run to verify they fail**

Run: `cd macos/Suica && swift test --filter DocumentDiskTests`
Expected: build FAIL, "cannot find 'DocumentDisk' in scope".

- [ ] **Step 3: Implement `DocumentDisk`.** `read` reuses the size/UTF-8 rules `loadContent` has; `write` re-reads, compares to `base` unless `overwrite`, refuses text over `maxBytes`, writes with `Data.write(to:options: .atomic)`, then restores the original POSIX permissions with `FileManager.setAttributes`; map every thrown error to `.failed(error.localizedDescription)`; a missing file is `.failed`, not a recreate.

- [ ] **Step 4: Run to verify they pass**

Run: `cd macos/Suica && swift test --filter DocumentDiskTests && swift test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git -C /Users/anb-0826009/project/suica-document-edit add macos
git -C /Users/anb-0826009/project/suica-document-edit commit -m "feat: save a document atomically unless it changed on disk"
```

### Task 3: Drafts in DocumentsModel

**Files:**
- Modify: `macos/Suica/Sources/SuicaCore/Documents.swift` (`DocumentsModel`)
- Test: `macos/Suica/Tests/SuicaCoreTests/DocumentEditTests.swift`

**Interfaces:**
- Consumes: `DocumentDisk`, `DocumentText`, `SaveOutcome` (Tasks 1-2).
- Produces (members of `DocumentsModel`):
  ```swift
  public enum Mode: Equatable, Sendable { case view, edit }
  public var mode: Mode                                   // one switch for the page; starts as .view and persists while the app runs
  public func draft(for path: String) -> String?          // nil when there is no Draft
  public var unsavedPaths: Set<String> { get }            // paths with a Draft
  public var draftText: String { get set }                // the open document's text while editing (saved text when no Draft)
  public private(set) var diskChanged: Bool               // the open file changed on disk while a Draft exists
  public private(set) var saveError: String?              // last failure reason for the open file
  public func startEditing() async                        // loads the file's text as the base; mode = .edit; unavailable files stay in .view
  public func save(overwrite: Bool = false) async -> SaveOutcome
  public func revert()                                    // drops the open file's Draft
  public func reload() async                              // Reload after a conflict: drops the Draft, rereads
  public func checkDisk() async                           // on app activation: clean → reload silently; Draft → set diskChanged
  public func discardAll()                                // quit path: drops every Draft
  public func saveAll() async -> [String: SaveOutcome]    // quit path
  ```
  `content` in View mode renders the Draft when one exists (`DocumentText.render(draft)`); `loadContent()` never replaces a Draft; `open`, `back`, `forward` keep every Draft. Setting `draftText` equal to the base text removes the Draft.

- [ ] **Step 1: Write the failing tests** (suite `DocumentDraftTests`, `@MainActor`, real temp files, a model with `PlansModel(store: MemoryStore())`):
  - `typingMakesADraftAndRestoringTheTextRemovesIt`: after `startEditing()` on a file, `draftText = "new"` → `draft(for:) == "new"`, `unsavedPaths == [path]`; `draftText = original` → no Draft.
  - `saveWritesTheFileAndClearsTheDraft`: `.saved`, file holds the text, `unsavedPaths` empty, `saveError == nil`; the base is now the saved text (a second edit + save works).
  - `saveRefusesAfterAnExternalChangeAndKeepsTheDraft`: change the file on disk, `save()` → `.conflict`, file untouched, Draft kept; `save(overwrite: true)` → `.saved`; `reload()` instead → Draft gone and `draftText` is the disk text.
  - `aFailedSaveKeepsTheDraftAndSaysWhy`: read-only file → `.failed`, `saveError` non-empty, Draft kept; the next successful save clears `saveError`.
  - `draftsSurviveNavigationAndRescan`: edit a, `open(path: b)`, `back()`: a's Draft is still there, `unsavedPaths == [a]`; `refresh()` and `loadContent()` do not replace it.
  - `viewModeShowsTheDraftAsAPreview`: Draft `"see [[x]]"` → after `loadContent()` in `.view`, `content == .text(entries: [], body: "see [x](suica-doc:x)")`; `revert()` and `loadContent()` show the saved text.
  - `checkDiskReloadsACleanDocumentAndFlagsADirtyOne`: clean + file changed → `content` shows the new text and `diskChanged == false`; with a Draft → `diskChanged == true`, Draft kept; `save(overwrite: true)` clears `diskChanged`.
  - `startEditingAnUnavailableFileStaysInViewMode`: a file over 1 MB or non-UTF-8 → `mode == .view`, no Draft.
  - `saveAllAndDiscardAll`: two Drafts → `saveAll()` returns `.saved` for both; with `discardAll()` instead `unsavedPaths` is empty and the files are untouched.

- [ ] **Step 2: Run to verify they fail**

Run: `cd macos/Suica && swift test --filter DocumentDraftTests`
Expected: build FAIL, "value of type 'DocumentsModel' has no member 'startEditing'".

- [ ] **Step 3: Implement the Draft state** as private dictionaries on `DocumentsModel` (`bases: [String: DiskDocument]`, `drafts: [String: String]`) so Observation tracks them; all disk calls go through `Task.detached`; results for a path other than the current selection still update that path's entry but never `content`.

- [ ] **Step 4: Run to verify they pass**

Run: `cd macos/Suica && swift test --filter DocumentDraftTests && swift test`
Expected: PASS, no new warnings.

- [ ] **Step 5: Commit**

```bash
git -C /Users/anb-0826009/project/suica-document-edit add macos
git -C /Users/anb-0826009/project/suica-document-edit commit -m "feat: drafts, save and conflict handling in the documents model"
```

### Task 4: Edit mode in the page

**Files:**
- Modify: `macos/Suica/Sources/Suica/Window/DocumentsView.swift`, `macos/Suica/Sources/SuicaCore/Copy.swift`
- Create (only if `DocumentsView.swift` passes about 280 lines): `macos/Suica/Sources/Suica/Window/DocumentEditor.swift` holding the editor pane and its notices

**Interfaces:**
- Consumes: the Task 3 members of `DocumentsModel`.
- Produces: no new public API; `Copy` strings: `editMode = "Edit"`, `viewMode = "View"`, `saveDocument = "Save"`, `revertDraft = "Revert"`, `unsavedDot` accessibility label `"Unsaved changes"`, `fileChangedOnDisk = "The file changed on disk"`, `overwriteFile = "Overwrite"`, `reloadFile = "Reload"`, `keepEditing = "Keep editing"`, `saveFailed(reason)` = `"Couldn't save: \(reason)"`, `cantEditFile = "This file can't be edited"`.

- [ ] **Step 1: Add the strings** above to `Copy` (Documents section).

- [ ] **Step 2: Mode switch and toolbar.** A segmented `Picker` (View | Edit) in the toolbar bound to `model.mode` (changing to Edit calls `await model.startEditing()`), ⌘E toggles it; **Save** (⌘S, disabled when the open file has no Draft) and **Revert** buttons shown in Edit mode. The shortcuts exist only on this page.

- [ ] **Step 3: Editor pane.** In Edit mode the detail is a `TextEditor(text: $model.draftText)` (use a `Binding` to `draftText`) in `.system(.body, design: .monospaced)` filling the pane, with an accessibility label; no rendered Markdown. A header dot (`Copy.unsavedDot`) beside the file name and in the tree/flat list rows for `model.unsavedPaths`. A document the page cannot show stays in View with `Copy.cantEditFile` on the Edit segment's help.

- [ ] **Step 4: Notices** above the editor: when `model.diskChanged` or a save returns `.conflict`, a banner `fileChangedOnDisk` with **Overwrite** (`save(overwrite: true)`), **Reload** (`reload()`) and **Keep editing** (dismiss); `saveError` shows `saveFailed(reason)` with a close ×. The app-active handler calls `model.checkDisk()` instead of only `loadContent()`.

- [ ] **Step 5: Build and test**

Run: `cd macos/Suica && swift build && swift test`
Expected: build clean with no new warnings; all tests PASS.

- [ ] **Step 6: Look at it** with the screenshot harness (scratch files only under the scratchpad): a fixture with a CRLF file, a plain file and a file with front matter. Check: View↔Edit switch; typing makes the dot appear in the header and the list; ⌘S clears it and the file on disk changes; change the file from the shell while a Draft is open → banner, Overwrite and Reload both work; a read-only file shows the failure; Back and return keeps the Draft; View mode shows the Draft preview; light and dark; narrow width. If the screen is locked and screenshots are blank, say so and verify by printing state.
Expected: all as described; fix what does not before committing.

- [ ] **Step 7: Commit**

```bash
git -C /Users/anb-0826009/project/suica-document-edit add macos
git -C /Users/anb-0826009/project/suica-document-edit commit -m "feat: edit mode on the Documents page"
```

### Task 5: Quit guard and docs

**Files:**
- Modify: `macos/Suica/Sources/Suica/SuicaApp.swift` (`LinkDelegate`, `SuicaApp.init`), `README.md` (the `## Documents` section), `CONTEXT.md` (new **Draft** term after **Document**), `docs/superpowers/specs/2026-11-04-documents-page-design.md` (amend the non-goal)

**Interfaces:**
- Consumes: `DocumentsModel.unsavedPaths`, `saveAll()`, `discardAll()`.
- Produces: `LinkDelegate.documents: DocumentsModel?` (static, set in `SuicaApp.init` beside `LinkDelegate.window`) and `applicationShouldTerminate(_:) -> NSApplication.TerminateReply` on `LinkDelegate`.

- [ ] **Step 1: Quit guard.** In `applicationShouldTerminate`: no Drafts → `.terminateNow`; otherwise an `NSAlert` (message `"You have unsaved changes in N documents"`, buttons **Save All**, **Discard**, **Cancel**; strings in `Copy`). Save All saves, and quits only when every outcome is `.saved` (else the alert's failure text is shown and the app keeps running); Discard calls `discardAll()` and quits; Cancel returns `.terminateCancel`. The in-app updater's `NSApp.terminate(nil)` goes through the same guard.

- [ ] **Step 2: Docs.** README `## Documents`: the View/Edit switch (⌘E, ⌘S), no autosave, Drafts kept while navigating and marked in the list, the conflict choices, line endings kept, what edit mode does not do (non-goals); remove the sentence that says the page is read-only. CONTEXT.md: **Draft** — text edited on the Documents page and not yet saved; kept in the app only; `_Avoid_: unsaved file`. Amend the 2026-11-04 spec's non-goal to "Creating, renaming or deleting files; editing is in `2026-11-05-document-edit-mode-design.md`" and its anti-goal "never writes" accordingly.

- [ ] **Step 3: Build and test**

Run: `cd macos/Suica && swift build && swift test`; then run prettier over the worktree files you changed (`make format` needs `node_modules`; use the main checkout's prettier if the worktree has none).
Expected: PASS; formatting clean.

- [ ] **Step 4: Look at it.** In the scratch harness, create a Draft and call the delegate's `applicationShouldTerminate` path with a stubbed alert response if the alert cannot be driven; verify the three answers' effects on the model and on disk. State plainly what could not be checked.

- [ ] **Step 5: Commit**

```bash
git -C /Users/anb-0826009/project/suica-document-edit add README.md CONTEXT.md docs macos
git -C /Users/anb-0826009/project/suica-document-edit commit -m "feat: ask before quitting with unsaved documents"
```
