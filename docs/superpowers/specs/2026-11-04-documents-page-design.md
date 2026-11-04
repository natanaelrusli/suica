# Documents page — design

Status: written from the Owner's request on 2026-11-04 ("making markdown viewer like obsidian into suica, this is to read plans, documents, etc.") after reading the Plans page, `parseMarkdownBlocks` and the review page's `MarkdownText`. Choices marked _my call_ are the builder's. Vocabulary is in `CONTEXT.md`.

## Why

The Plans page tracks where a plan stands but, by its own spec, never shows the plan's text. Reading a plan, the spec it names or any other Markdown file means leaving Suica for an editor. Obsidian's reading side (a folder tree, rendered Markdown, links that jump between files) is what is missing.

## Goals

- A **Documents** page lists every Markdown file under the Plan folders as a folder tree, and renders the selected file.
- Search the list by file name and path.
- Links work like in Obsidian: `[[Note]]`, `[[Note|alias]]`, `[[Note#Heading]]` and relative links such as `[spec](../specs/x.md)` open the target on the page; Back and Forward walk the files visited.
- A leading YAML front matter block is shown as a small Properties grid, not as text.
- The Plans page gets a **Read** button that opens the plan on the Documents page.

## Non-goals

- Editing, creating or deleting files. The page never writes to a document; "Open in editor" and "Show in Finder" cover changes.
- Backlinks, graph, outline, tags, callouts (`> [!note]`), embeds (`![[x]]` is shown as written), images, math, Mermaid, tabs, themes (_my call_: each needs its own parser work; the first cut is reading).
- Scrolling to the `#Heading` of a link: the file opens at the top.
- A folder list of its own (_my call_: the Documents page uses the **Plan folders**, so there is one list to keep and the Read button lands on a file the page already lists). Adding or removing a folder on either page changes both.
- A change to the heading sizes of the shared `MarkdownText`, which the review page also draws.

## Behaviour

- **What is listed:** every `.md` file of at most 1,000,000 bytes under the Plan folders; hidden folders, `node_modules` and `.build` are skipped, symlinks are not followed, a file is listed once however many folders reach it. At most 5,000 files are listed; the page then says so (_my call_: a parent folder such as `~` must not hang the window). A file that is not UTF-8 or cannot be read is listed and shows as unavailable when opened.
- **Scan:** off the main thread; the previous list stays until it finishes; only the newest scan sets the list (as Plans does).
- **List:** a tree, folders first, then files, each sorted as Finder does (`localizedStandardCompare`); the top level is one node per Plan folder. With text in the search box the list is flat: files whose name or relative path hold every word.
- **Link targets:** a wikilink target is a file name without `.md` (case-insensitive), or a path suffix when it holds `/`. With several matches the one in the file's own folder wins, then the shortest relative path, then the first by path (_my call_). A relative link is tried from the file's folder, then each parent up to its Plan folder, and must end in `.md` and stay inside that Plan folder (_my call_: plans cite specs by repo-relative path, not file-relative). A link that resolves to nothing does nothing; `http(s)` links open in the browser. A wikilink inside a code span or a code fence is left as written.
- **History:** opening a file other than the current one drops the Forward list and adds the current one to Back; at most 50 entries are kept (_my call_). Back to a file deleted since shows it as unavailable.
- **Front matter:** a file whose first line is `---` and that has a closing `---` or `...` line starts with front matter. Only `key: value` lines, `key: [a, b]` and `key:` followed by `- item` lines are read; list values are joined with `, `; quotes around a value are dropped. Without a closing line, or when a line between the markers is prose (not blank, a `#` comment, indented, a `- ` item or `key:`), the whole file is the body, so a `---` at the top used as a rule is not swallowed (_my call_).
- **Reloading:** the open file is read again when the app becomes active and on Rescan, so a plan an agent just rewrote is current.
- Sidebar: Insights, after Plans; ⇧⌘D.

## Anti-goals

- A scan or a file read that blocks the window.
- A file that fails to open taking the page down: it shows "can't be shown" with Open and Show in Finder, and the list stays usable.
- A new Node command, config key or contract golden: the page reads files and keeps nothing but what Plans already keeps (the folders), plus the last page state in memory only.
