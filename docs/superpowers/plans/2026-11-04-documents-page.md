# Documents Page Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Documents page in the Suica window that browses every Markdown file under the Plan folders as a tree and renders the selected one, with Obsidian-style links, Back/Forward and a front matter grid.

**Architecture:** All logic is pure SuicaCore code (file walk, front matter, link rewriting and resolving, tree, `DocumentsModel`) tested with Swift Testing; the SwiftUI page is a thin layer over it and reuses the review page's `MarkdownText` unchanged. The Plan scanner's file walk is extracted so Plans and Documents share it, and `DocumentsModel` shares `PlansModel`'s folder list.

**Tech Stack:** Swift 6 (language mode v6), SwiftUI, Observation, Swift Testing, Foundation's `AttributedString(markdown:)`. No new dependency.

**Spec:** `docs/superpowers/specs/2026-11-04-documents-page-design.md` (read it first: it holds the "my call" decisions).

## Global Constraints

- Work in the worktree `/Users/anb-0826009/project/suica-documents` on branch `feat/no-ticket-documents`; commit with `git -C /Users/anb-0826009/project/suica-documents …` (the rule-20 hook checks the session folder's branch). No planner key exists: never invent one.
- Swift tests: `cd macos/Suica && swift test` (about 200 tests, a few seconds). New tests live in `macos/Suica/Tests/SuicaCoreTests/DocumentsTests.swift`; test names are camelCase sentences as in `PlansTests.swift`.
- Every UI string goes through `Copy` in `macos/Suica/Sources/SuicaCore/Copy.swift`; the app is English only.
- Listed files: `.md`, at most `1_000_000` bytes, at most `5_000` files; skip hidden folders, `node_modules`, `.build`; symlinks are not followed; a file is listed once.
- The page never writes to a document. No new Node command, config key, contract golden or dependency.
- Scans and file reads run off the main thread; only the newest scan sets the list.
- Wikilinks inside code spans and fenced code stay as written; `![[x]]` stays as written.
- End every commit message with `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`.

## Review Focus

Failure modes the spec implies that a person using the page will meet; each has a test in the task that owns the code (named in brackets).

- A wikilink to a note that does not exist, differs only in case, exists twice, or sits inside a code span or fence: unresolved does nothing, case is ignored, the same-folder match wins, code is not linked. [Task 3]
- A file starting with `---` that is not front matter (a rule, unterminated, prose between the markers): the body is shown whole. [Task 2]
- A listed file that is deleted, over 1 MB or not UTF-8 by the time it is opened: "can't be shown", never a crash; Back to a deleted file does the same. [Task 6]
- A folder with more than 5,000 Markdown files, or one Plan folder inside another: the list is capped and says so; each file appears once. [Task 1]
- A relative link that climbs out of its Plan folder, points at a non-`.md` file or at a missing file: nothing happens. A self-link or a link cycle does not grow Back, and Back stops at 50 entries. [Tasks 3, 6]

---

### Task 1: Shared Markdown file walk

**Files:**
- Create: `macos/Suica/Sources/SuicaCore/Documents.swift`
- Modify: `macos/Suica/Sources/SuicaCore/Plans.swift:111-152` (`PlanScanner`), `macos/Suica/Tests/SuicaCoreTests/PlansTests.swift:97,152` (drop `private` from `tree(_:)` and `MemoryStore` so `DocumentsTests.swift` can use them)
- Test: `macos/Suica/Tests/SuicaCoreTests/DocumentsTests.swift`

**Interfaces:**
- Consumes: `Folders.expand(_:home:)`.
- Produces:
  ```swift
  public struct DocumentFile: Equatable, Identifiable, Sendable {
      public let path: String          // absolute, symlinks resolved
      public let folder: String        // the Plan folder it was found under, absolute, resolved
      public let relativePath: String  // path below `folder`, no leading slash
      public let modified: Date
      public var id: String { path }
      public var name: String { get }  // file name without ".md"
      public init(path: String, folder: String, relativePath: String, modified: Date = .distantPast)
  }
  public enum MarkdownFiles {
      public static let maxBytes = 1_000_000
      public static let maxFiles = 5_000
      public static func find(in folders: [String], home: String = NSHomeDirectory(),
                              limit: Int = maxFiles) -> (files: [DocumentFile], truncated: Bool)
  }
  ```

- [ ] **Step 1: Write the failing tests** in `DocumentsTests.swift` (`import Testing`, `@testable import SuicaCore`), suite `MarkdownFilesTests`, each test removes its `tree` root in a `defer`. Temp paths contain `/var` → `/private/var`, so compare `relativePath` and `lastPathComponent`, never absolute paths built from the temp URL.
  - `findReturnsFolderAndRelativePath`: `tree(["a/b/x.md": "x", "a/y.txt": "y"])`; `find(in: [root.path]).files` has one file; `relativePath == "a/b/x.md"`, `name == "x"`, `path == folder + "/a/b/x.md"`, `truncated == false`.
  - `findSkipsHiddenNodeModulesBuildHugeAndSymlinkedFiles`: files `.h/a.md`, `node_modules/b.md`, `.build/c.md`, `huge.md` (1_000_001 bytes), `ok.md`, plus a symlink `link.md` → `ok.md`; result is only `ok.md`.
  - `findListsAFileOnceWhenAPlanFolderIsInsideAnother`: `tree(["a/p.md": "p"])`, `find(in: [root.path, root.path + "/a"])` has 1 file and its `relativePath == "a/p.md"`.
  - `findStopsAtTheLimitAndSaysSo`: 3 files, `limit: 2` → 2 files, `truncated == true`; 2 files, `limit: 2` → `truncated == false`.
  - `findExpandsATildeAndIgnoresAMissingFolder`: `find(in: ["~/a", "/nonexistent-suica"], home: root.path).files.count == 1`.

- [ ] **Step 2: Run to verify they fail**

Run: `cd macos/Suica && swift test --filter MarkdownFilesTests`
Expected: build FAIL, "cannot find 'MarkdownFiles' in scope".

- [ ] **Step 3: Implement `MarkdownFiles.find` and `DocumentFile`** in `Documents.swift` by moving `PlanScanner.scan`'s walk (enumerator with `.skipsHiddenFiles`, `node_modules`/`.build` skip, size cap, `resolvingSymlinksInPath`, `seen` set) into `find`. Resolve each root first (`URL(fileURLWithPath: Folders.expand(folder, home:)).resolvingSymlinksInPath()`) and enumerate the resolved root, so `relativePath` is a plain suffix of `path`; a symlinked file is not `isRegularFile` and is skipped as today. Stop when `limit` files are held and one more is found (`truncated = true`).

- [ ] **Step 4: Make `PlanScanner.scan(folders:home:)` call `MarkdownFiles.find(in: folders, home: home, limit: .max).files`**, then read and parse each file as now (keep the UTF-8 read, `PlanDocument.parse` and the sort). In `PlansTests.swift` drop `private` from `tree` and `MemoryStore`.

- [ ] **Step 5: Run to verify everything passes**

Run: `cd macos/Suica && swift test --filter MarkdownFilesTests && swift test --filter PlanScannerTests && swift test`
Expected: PASS (all `PlanScannerTests` unchanged and green).

- [ ] **Step 6: Commit**

```bash
git -C /Users/anb-0826009/project/suica-documents add docs macos
git -C /Users/anb-0826009/project/suica-documents commit -m "feat: share the Markdown file walk between Plans and Documents"
```

### Task 2: Front matter

**Files:**
- Modify: `macos/Suica/Sources/SuicaCore/Documents.swift`
- Test: `macos/Suica/Tests/SuicaCoreTests/DocumentsTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public struct FrontMatterEntry: Equatable, Sendable { public let key: String; public let value: String }
  public enum FrontMatter {
      /// Entries of a leading `---` block and the text after it; the whole text when there is none.
      public static func split(_ text: String) -> (entries: [FrontMatterEntry], body: String)
  }
  ```

- [ ] **Step 1: Write the failing tests**, suite `FrontMatterTests`:
  - `splitReadsKeysListsAndQuotes`: `"---\nname: Plan\ntags: [a, b]\nowner: \"Nata\"\nurl: http://x\nlist:\n  - x\n  - y\n---\n# Title\n"` → entries `[("name","Plan"), ("tags","a, b"), ("owner","Nata"), ("url","http://x"), ("list","x, y")]`, `body == "# Title\n"`.
  - `splitHandlesCRLFBOMAndAnEmptyBody`: `"\u{FEFF}---\r\na: b\r\n---\r\ntext"` → `[("a","b")]`, `"text"`; `"---\na: b\n---"` → `[("a","b")]`, `""`.
  - `anUnterminatedBlockIsNotFrontMatter`: `"---\na: b\n\ntext"` → `[]`, body is the input unchanged.
  - `aRuleAtTheTopWithProseBetweenIsNotFrontMatter`: `"---\n\nSome prose here.\n\n---\nmore"` → `[]`, body unchanged.
  - `noBlockMeansNoEntries`: `"# Title\n---\nx"` and `""` → `[]`, body unchanged.

- [ ] **Step 2: Run to verify they fail**

Run: `cd macos/Suica && swift test --filter FrontMatterTests`
Expected: build FAIL, "cannot find 'FrontMatter' in scope".

- [ ] **Step 3: Implement `FrontMatter.split`.** The first line (after an optional BOM, `\r\n` normalised) must be `---`; the closing line is the first later line that is `---` or `...`. The block counts as front matter only if every line between is blank, a comment (`#`), indented, a `- ` item, or `key:`-shaped (`^[A-Za-z0-9_-]+:`). `key: value` splits on the first colon; `[a, b]` loses its brackets; matching surrounding quotes are dropped; `key:` with no value takes the following `- item` lines joined with `, `.

- [ ] **Step 4: Run to verify they pass**

Run: `cd macos/Suica && swift test --filter FrontMatterTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git -C /Users/anb-0826009/project/suica-documents add macos
git -C /Users/anb-0826009/project/suica-documents commit -m "feat: read the front matter of a document"
```

### Task 3: Links

**Files:**
- Modify: `macos/Suica/Sources/SuicaCore/Documents.swift`
- Test: `macos/Suica/Tests/SuicaCoreTests/DocumentsTests.swift`

**Interfaces:**
- Consumes: `DocumentFile` (Task 1).
- Produces:
  ```swift
  public enum DocumentLinks {
      public static let scheme = "suica-doc"
      /// `[[T]]`, `[[T|alias]]`, `[[T#H]]` → `[alias or T as written](suica-doc:<T#H percent-encoded>)`.
      public static func rewriteWikilinks(_ markdown: String) -> String
      /// The decoded target of a `suica-doc:` URL (read from `absoluteString`: the URL is opaque and its `path` is empty); nil for other URLs.
      public static func wikilinkTarget(_ url: URL) -> String?
      public static func resolveWikilink(_ target: String, from path: String, among files: [DocumentFile]) -> DocumentFile?
      /// `target` is the decoded path of a scheme-less link (`url.path`, fragment already dropped).
      public static func resolveRelative(_ target: String, from path: String, among files: [DocumentFile]) -> DocumentFile?
  }
  ```

- [ ] **Step 1: Write the failing tests**, suite `DocumentLinksTests`, with a helper `doc(_ path: String, folder: String = "/r") -> DocumentFile` (relativePath = path minus `folder + "/"`):
  - `rewriteTurnsWikilinksIntoLinks`: `"see [[Plan A]] and [[Plan A|the plan]] and [[Plan A#Goal]]"` → `"see [Plan A](suica-doc:Plan%20A) and [the plan](suica-doc:Plan%20A) and [Plan A#Goal](suica-doc:Plan%20A%23Goal)"` (percent-encode with `.alphanumerics` so `(`, `)`, `/`, `#` can never end the link).
  - `rewriteLeavesCodeEmbedsAndEmptyLinksAlone`: ``"`[[x]]` and [[y]]"`` → ``"`[[x]]` and [y](suica-doc:y)"``; a fenced block (```` ``` ````, and `~~~`) holding `[[x]]` is unchanged; `"![[x]]"` and `"[[]]"` are unchanged.
  - `aTargetSurvivesFoundationsParser`: `AttributedString(markdown: rewriteWikilinks("[[Some Note (v2)]]"), options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))` has a link run whose `wikilinkTarget` is `"Some Note (v2)"`; `wikilinkTarget(URL(string: "https://x")!) == nil`. Same parser on `"[t](docs/x.md)"`: the link has `scheme == nil` and `path == "docs/x.md"` (pins the assumption the page's link handler rests on).
  - `wikilinkResolvesByNameCaseHeadingExtensionAndPathSuffix`: files `/r/a/Plan.md`, `/r/b/Plan.md`, `/r/b/deep/Idea.md`; from `/r/b/x.md`: `"plan"`, `"Plan#Goal"`, `"Plan.md"` → `/r/b/Plan.md` (same folder wins); from `/r/c/x.md` → `/r/a/Plan.md` (shortest relative path, then path order); `"deep/Idea"` and `"b/deep/idea"` → `/r/b/deep/Idea.md`; `"Missing"`, `""`, `"#H"` → nil.
  - `relativeLinksTryTheFileFolderThenItsParentsInsideThePlanFolder`: from `/r/docs/plans/p.md`, files `/r/docs/specs/s.md`, `/r/README.md`, `/outside/o.md` (folder `/outside`): `"../specs/s.md"`, `"docs/specs/s.md"` (repo-relative, found from an ancestor) and `"README.md"` resolve; `"../../../outside/o.md"`, `"missing.md"`, `"notes.txt"`, `""` → nil. A `from` path that is not in `files` still resolves when its prefix is a known folder.

- [ ] **Step 2: Run to verify they fail**

Run: `cd macos/Suica && swift test --filter DocumentLinksTests`
Expected: build FAIL, "cannot find 'DocumentLinks' in scope".

- [ ] **Step 3: Implement `rewriteWikilinks`** line by line: toggle a fence flag on lines whose trimmed text starts with ```` ``` ```` or `~~~`; outside fences split each line on backticks and rewrite only even-indexed parts (the technique `inlineMarkdownSource` already uses in `Markdown.swift`) with `/(?<!!)\[\[([^\[\]|]+?)(?:\|([^\[\]]+?))?\]\]/` (a leading `!` is an embed).

- [ ] **Step 4: Implement `wikilinkTarget`, `resolveWikilink` and `resolveRelative`.** `resolveWikilink`: strip `#…` and a trailing `.md`; a target with `/` matches files whose `relativePath` without `.md` has it as a case-insensitive suffix at a path-component boundary, otherwise match `name`; tie-break in this order: the file's own folder, shortest `relativePath`, `path`. `resolveRelative`: the root is the longest `folder` among `files` that prefixes `from`; try `dirname(from)` then each parent up to the root, standardising `candidate + "/" + target`; accept only a result that ends in `.md`, stays under the root and is in `files`.

- [ ] **Step 5: Run to verify they pass**

Run: `cd macos/Suica && swift test --filter DocumentLinksTests`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git -C /Users/anb-0826009/project/suica-documents add macos
git -C /Users/anb-0826009/project/suica-documents commit -m "feat: Obsidian-style and relative links between documents"
```

### Task 4: Document tree

**Files:**
- Modify: `macos/Suica/Sources/SuicaCore/Documents.swift`
- Test: `macos/Suica/Tests/SuicaCoreTests/DocumentsTests.swift`

**Interfaces:**
- Consumes: `DocumentFile`.
- Produces:
  ```swift
  public struct DocumentNode: Identifiable, Equatable, Sendable {
      public let id: String                 // file path; folders: folder path + "/" + relative dir
      public let name: String               // file: DocumentFile.name; folder: its last component
      public let file: DocumentFile?        // nil for a folder
      public let children: [DocumentNode]?  // nil for a file (what `List(_:children:)` needs)
  }
  public enum DocumentTree { public static func build(_ files: [DocumentFile]) -> [DocumentNode] }
  ```

- [ ] **Step 1: Write the failing tests**, suite `DocumentTreeTests`:
  - `buildNestsByFolderWithFoldersFirstAndNaturalOrder`: files `/r/b.md`, `/r/a/10.md`, `/r/a/2.md`, `/r/a/z/q.md` → one root node `r` whose children are `[a (folder), b]`; `a`'s children are `[z (folder), 2, 10]`.
  - `buildMakesOneRootPerPlanFolderEvenWhenNamesCollide`: folders `/x/docs` and `/y/docs` → two root nodes named `docs` with different ids.
  - `buildOfNothingIsEmpty`.

- [ ] **Step 2: Run to verify they fail**

Run: `cd macos/Suica && swift test --filter DocumentTreeTests`
Expected: build FAIL, "cannot find 'DocumentTree' in scope".

- [ ] **Step 3: Implement `DocumentTree.build`** grouping by `folder` (roots in first-seen order) then by `relativePath` components; sort siblings folders first, then `localizedStandardCompare` on `name`.

- [ ] **Step 4: Run to verify they pass**

Run: `cd macos/Suica && swift test --filter DocumentTreeTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git -C /Users/anb-0826009/project/suica-documents add macos
git -C /Users/anb-0826009/project/suica-documents commit -m "feat: folder tree of documents"
```

### Task 5: DocumentsModel — scan, list, search

**Files:**
- Modify: `macos/Suica/Sources/SuicaCore/Documents.swift`
- Test: `macos/Suica/Tests/SuicaCoreTests/DocumentsTests.swift`

**Interfaces:**
- Consumes: `PlansModel` (`folders`, `addFolders(_:)`, `removeFolder(_:)`), `MarkdownFiles.find`, `DocumentTree.build`, `Search.matches(_:_:)`.
- Produces:
  ```swift
  @MainActor @Observable public final class DocumentsModel {
      public init(plans: PlansModel,
                  find: @escaping @Sendable ([String]) -> (files: [DocumentFile], truncated: Bool) = { MarkdownFiles.find(in: $0) })
      public var folders: [String] { get }               // plans.folders
      public private(set) var files: [DocumentFile]
      public private(set) var truncated: Bool
      public private(set) var isScanning: Bool
      public var query: String
      public var visible: [DocumentFile] { get }         // files matching `query` on relativePath (and folder name); all when empty
      public var tree: [DocumentNode] { get }           // DocumentTree.build(files)
      public func refresh() async
      public func addFolders(_ chosen: [String])         // forwards to plans
      public func removeFolder(_ path: String)           // forwards to plans
  }
  ```

- [ ] **Step 1: Write the failing tests**, suite `DocumentsModelTests` (`@MainActor`), helper building `PlansModel(store: MemoryStore())` with folders added and a `DocumentsModel` whose `find` is a stub:
  - `refreshListsTheFilesOfThePlanFolders` (stub returns two files, `truncated: true` → `files.count == 2`, `truncated`, `isScanning == false`, `tree` has one root).
  - `refreshWithNoFoldersEmptiesTheList` (stub never called, `files == []`).
  - `anOlderSlowScanNeverOverwritesANewerOne` (mirror `PlansModelTests.anOlderSlowScanNeverOverwritesANewerOne` in `PlansTests.swift:242`).
  - `searchMatchesEveryWordOfTheRelativePathIgnoringCaseAndAccents`: files `docs/Résumé.md`, `docs/plans/a.md` → query `"resume docs"` → the first only; query `""` → both; query `"zzz"` → `[]`.
  - `addAndRemoveFoldersChangeThePlansFoldersToo`: after `documents.addFolders([dir])`, `plans.folders` holds `dir`; `removeFolder` removes it from both.

- [ ] **Step 2: Run to verify they fail**

Run: `cd macos/Suica && swift test --filter DocumentsModelTests`
Expected: build FAIL, "cannot find 'DocumentsModel' in scope".

- [ ] **Step 3: Implement `DocumentsModel`** following `PlansModel.refresh()` (`Plans.swift:197`): a `generation` counter, `Task.detached` around `find(folders)`, the previous list kept while scanning, stale results dropped.

- [ ] **Step 4: Run to verify they pass**

Run: `cd macos/Suica && swift test --filter DocumentsModelTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git -C /Users/anb-0826009/project/suica-documents add macos
git -C /Users/anb-0826009/project/suica-documents commit -m "feat: documents model scans the plan folders"
```

### Task 6: DocumentsModel — selection, history, links, content

**Files:**
- Modify: `macos/Suica/Sources/SuicaCore/Documents.swift`
- Test: `macos/Suica/Tests/SuicaCoreTests/DocumentsTests.swift`

**Interfaces:**
- Consumes: `FrontMatter.split`, `DocumentLinks.*`, `MarkdownFiles.maxBytes`, `DocumentsModel.files`.
- Produces: two top-level types in `Documents.swift`, and these members added to `DocumentsModel`:
  ```swift
  public enum DocumentContent: Equatable, Sendable {
      case none, unavailable
      case text(entries: [FrontMatterEntry], body: String)   // body already passed through rewriteWikilinks
  }
  public enum LinkOutcome: Equatable, Sendable { case opened, ignored, external }
  // members of DocumentsModel:
  public private(set) var selectedPath: String?
  public private(set) var content: DocumentContent
  public var canGoBack: Bool { get };  public var canGoForward: Bool { get }
  public func open(path: String)        // no-op for the current path; else Back += current, Forward = [], content = .none
  public func back();  public func forward()
  public func openLink(_ url: URL) -> LinkOutcome
  public func loadContent() async       // reads selectedPath off the main thread
  ```

- [ ] **Step 1: Write the failing tests** (same suite; temp files via `tree(_:)`):
  - `openWalksBackAndForwardAndANewOpenDropsForward`: open a, b, c → `back()` twice gives a, `forward()` gives b, then `open(path: d)` → `canGoForward == false`, `back()` gives b.
  - `openingTheCurrentFileAgainDoesNotGrowBack`: open a, open a → `canGoBack == false`.
  - `backKeepsTheLast50Entries`: open 60 distinct paths, call `back()` until `canGoBack` is false → 50 calls, `selectedPath == "f9"` (paths `f0`…`f59`).
  - `openLinkOpensAResolvedWikilinkAndIgnoresAMissingOne`: files `/r/a.md`, `/r/b.md` loaded through the stub `find` and `refresh()`; select `/r/a.md`; `openLink(URL(string: "suica-doc:b")!) == .opened`, `selectedPath == "/r/b.md"`; `suica-doc:nope` → `.ignored`, selection unchanged.
  - `openLinkResolvesRelativeLinksAndLeavesWebLinksToTheSystem`: `URL(string: "a.md")!` from `/r/b.md` → `.opened`; `URL(string: "../x.md")!` → `.ignored`; `https://example.com` and `mailto:a@b.c` → `.external`; with nothing selected a scheme-less link → `.ignored`.
  - `loadContentReadsTextFrontMatterAndRewritesWikilinks`: file `"---\ntitle: T\n---\nsee [[x]]\n"` → `content == .text(entries: [FrontMatterEntry(key: "title", value: "T")], body: "see [x](suica-doc:x)\n")`.
  - `loadContentIsUnavailableForAMissingNonUTF8OrHugeFileAndBackToItRecovers`: for a deleted path, a file of bytes `[0xFF, 0xFE]` and a file of 1_000_001 bytes → `.unavailable`; open ok.md, open gone.md, `back()`, `loadContent()` → text again; `forward()`, `loadContent()` → `.unavailable`.
  - `loadContentWithNothingSelectedIsNone`.

- [ ] **Step 2: Run to verify they fail**

Run: `cd macos/Suica && swift test --filter DocumentsModelTests`
Expected: build FAIL, "value of type 'DocumentsModel' has no member 'open'".

- [ ] **Step 3: Implement selection and history** (two `[String]` stacks, Back capped at 50 by dropping the oldest; `open` clears `content`; `back()`/`forward()` also set `content = .none`).

- [ ] **Step 4: Implement `openLink`**: `wikilinkTarget(url)` non-nil → `resolveWikilink(_, from: selectedPath ?? "", among: files)`; `url.scheme == nil` → `resolveRelative(url.path, from:selectedPath, among: files)` (nil selection → `.ignored`); either resolved file → `open(path:)` and `.opened`, else `.ignored`; any other scheme → `.external`.

- [ ] **Step 5: Implement `loadContent`**: capture `selectedPath`; in `Task.detached` return `.unavailable` unless the file is at most `MarkdownFiles.maxBytes` and reads as UTF-8, else `.text` of `FrontMatter.split` with `rewriteWikilinks` on the body; drop the result if `selectedPath` changed meanwhile.

- [ ] **Step 6: Run to verify they pass**

Run: `cd macos/Suica && swift test --filter DocumentsModelTests && swift test`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git -C /Users/anb-0826009/project/suica-documents add macos
git -C /Users/anb-0826009/project/suica-documents commit -m "feat: open documents, follow links, walk back and forward"
```

### Task 7: The Documents page

**Files:**
- Create: `macos/Suica/Sources/Suica/Window/DocumentsView.swift`, `macos/Suica/Sources/Suica/Window/FolderPicker.swift`
- Modify: `macos/Suica/Sources/SuicaCore/Copy.swift` (new `// MARK: - Documents` after the Plans section, ~line 1782), `macos/Suica/Sources/Suica/Navigation.swift` (`WindowSection`, `SidebarNode.groups`), `macos/Suica/Sources/Suica/Window/MainWindow.swift:199,441`, `macos/Suica/Sources/Suica/SuicaApp.swift:173,262`, `macos/Suica/Sources/Suica/Window/PlansView.swift:58-68`

**Interfaces:**
- Consumes: `DocumentsModel`, `DocumentNode`, `DocumentContent`, `LinkOutcome` (Tasks 4–6); the review page's `MarkdownText(source:)` (`ReviewsView.swift:1327`, unchanged); `UnderTitleBar`, `ListTopBar`, `PlansView`'s layout as the model for the split and toolbar.
- Produces: `struct DocumentsView: View { @Bindable var model: DocumentsModel }`; `func pickFolders() -> [String]` (the `NSOpenPanel` now inside `PlansView.addFolders`, moved so both pages share it); `WindowSection.documents`.

- [ ] **Step 1: Add the `Copy` strings** (all `public static let` in `Copy`): `documents = "Documents"`, `searchDocuments = "Search documents"`, `noDocumentsTitle = "No documents found"`, `noDocumentsHint = "Markdown files under the Plan folders show here."`, `documentsTruncated = "Showing the first 5,000 documents."`, `documentUnavailableTitle = "This file can't be shown"`, `documentUnavailableHint = "It may have been moved or deleted, be larger than 1 MB, or not be UTF-8 text."`, `documentProperties = "Properties"`, `goBack = "Back"`, `goForward = "Forward"`, `readPlan = "Read"`. Reuse `Copy.noPlanFoldersTitle/Hint`, `addPlanFolder`, `plansFolders`, `rescanPlans`, `openPlan`, `showInFinder`, `loading` for folders, rescan and the file buttons.

- [ ] **Step 2: Add `WindowSection.documents`** after `.updates`, with title `Copy.documents`, symbol `"doc.richtext"`, tint `.yellow`, shortcut ⇧⌘D (`KeyboardShortcut("d", modifiers: [.command, .shift])`, as `.plans` does), and `SidebarNode(.documents)` after `SidebarNode(.plans)` in the Insights group. Fix every exhaustive switch the compiler then reports.

- [ ] **Step 3: Wire the model.** `SuicaApp.swift:173` declares models as `@State` property defaults, but `DocumentsModel` needs the same `PlansModel` instance: create both in an `init()` (`_plans = State(initialValue:)`, `_documents = State(initialValue: DocumentsModel(plans: plans))`), pass `documents` through `MainWindow` (`let documents: DocumentsModel`) and add `case .documents: DocumentsView(model: documents)` beside `.plans` in the page switch.

- [ ] **Step 4: Move the folder panel.** `FolderPicker.swift` holds `@MainActor func pickFolders() -> [String]` (the `NSOpenPanel` setup of `PlansView.addFolders`, returning `[]` unless OK); `PlansView.addFolders` becomes `model.addFolders(pickFolders())` plus the existing refresh.

- [ ] **Step 5: Build `DocumentsView`** as `PlansView` is built:
  - No folders → `ContentUnavailableView` with the add button; no files and not scanning → `noDocumentsTitle`/`Hint`; scanning with no files → `ProgressView`.
  - Split: left 280 pt, `List(selection:)` of `model.tree` with `children: \.children` when `query` is empty, else the flat `model.visible` showing each file's `relativePath` as a caption; selecting a node calls `model.open(path:)` only when the id is a listed file. `.searchable(text: $model.query, prompt: Copy.searchDocuments)`. A footer line `Copy.documentsTruncated` when `model.truncated`.
  - Toolbar: Back and Forward (`goBack`/`goForward`, `chevron.left`/`chevron.right`, disabled by `canGoBack`/`canGoForward`, ⌘[ and ⌘]), the folders menu, add folder, Rescan (⌘R: `refresh()` then `loadContent()`).
  - Detail: file name as title, `relativePath` caption, Open and Show in Finder buttons; a Properties grid (`LabeledContent` per `FrontMatterEntry`, selectable text) when `.text` has entries; then `MarkdownText(source: body)` in a `ScrollView` with `.padding(20)`. `.unavailable` → `ContentUnavailableView(Copy.documentUnavailableTitle, …, description: Text(Copy.documentUnavailableHint))` with the same two buttons; `.none` with a selection → `ProgressView`; nothing selected → `ContentUnavailableView(Copy.documents, systemImage: "doc.richtext")`.
  - `.environment(\.openURL, OpenURLAction { … })` on the detail: `.opened` and `.ignored` → `.handled`, `.external` → `.systemAction`.
  - `.task { await model.refresh() }` on the stable outer view (not on the switching group, see the comment in `PlansView.swift:23`); `.task(id: model.selectedPath) { await model.loadContent() }`; `.onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in Task { await model.loadContent() } }`.

- [ ] **Step 6: Build and test**

Run: `cd macos/Suica && swift build && swift test`
Expected: build succeeds with no warnings from the new files; all tests PASS.

- [ ] **Step 7: Look at it.** There is no accessibility access, so render the page as in the project's UI screenshot harness (a scratch `NSHostingView` harness, see memory `suica-ui-screenshot-harness`): a temp folder with `a.md` (front matter `title`, `tags: [x, y]`; a table; a code block; `[[b]]`, `[[Missing]]` and `[spec](sub/c.md)` links), `sub/c.md`, `b.md` and a non-UTF-8 `bad.md`. Check, with synthetic clicks where needed: tree and flat search list; Properties grid; `[[b]]` opens `b.md` and Back returns; `[[Missing]]` does nothing; `bad.md` shows "can't be shown"; light and dark appearance; the window at its narrowest width.
Expected: all of the above as described; fix what does not before committing.

- [ ] **Step 8: Commit**

```bash
git -C /Users/anb-0826009/project/suica-documents add macos
git -C /Users/anb-0826009/project/suica-documents commit -m "feat: Documents page to read Markdown files"
```

### Task 8: Read a plan from Plans, and the docs

**Files:**
- Modify: `macos/Suica/Sources/Suica/Window/PlansView.swift` (`PlansView`, `PlanDetail`), `macos/Suica/Sources/Suica/Window/MainWindow.swift:441`, `README.md` (new `## Documents` section after the Plans section at ~line 277; the Go-menu sentence at ~line 376), `CONTEXT.md` (term after **Plan Mark**, ~line 111), `docs/superpowers/specs/2026-10-27-plans-page-design.md` (one Behaviour bullet)

**Interfaces:**
- Consumes: `DocumentsModel.open(path:)`, `Navigator.selection`, `SidebarItem.section(_:)` (as `IdeasView` uses to reach Plans), `Copy.readPlan`.
- Produces: `PlansView(model: PlansModel, documents: DocumentsModel, navigator: Navigator)`.

- [ ] **Step 1: Add the Read button.** `PlansView` and the private `PlanDetail` take `documents` and `navigator`; a **Read** button (`Copy.readPlan`, `book` symbol) before Open runs `documents.open(path: plan.path)` then `navigator.selection = .section(.documents)`. `MainWindow` passes both.

- [ ] **Step 2: Build and test**

Run: `cd macos/Suica && swift build && swift test`
Expected: PASS.

- [ ] **Step 3: Look at it** with the screenshot harness: select a plan on the Plans page, click Read; the Documents page opens on that file, rendered, with Back disabled.
Expected: as described.

- [ ] **Step 4: Update the docs.** README: a `## Documents` section (what is listed and the caps, the tree and search, the link kinds and what is not supported, Back/Forward ⌘[ ⌘], the Properties grid, read-only, shares the Plan folders, the Read button, ⇧⌘D, design doc path) and "Documents with ⇧⌘D" in the Go-menu sentence. CONTEXT.md: **Document** — a Markdown file under the Plan folders, read on the Documents page; never edited by Suica; _Avoid_: note. Plans spec: "A **Read** button opens the plan on the Documents page."

- [ ] **Step 5: Run the repo checks**

Run: `make format` then `cd macos/Suica && swift test`
Expected: format check passes (if prettier flags the new spec, plan or README, run `make format-fix` and re-run); tests PASS.

- [ ] **Step 6: Commit**

```bash
git -C /Users/anb-0826009/project/suica-documents add -A
git -C /Users/anb-0826009/project/suica-documents commit -m "feat: read a plan on the Documents page"
```
