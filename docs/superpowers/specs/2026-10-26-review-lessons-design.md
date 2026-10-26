# Review lessons — design

Status: written from the Owner's request on 2026-10-23 ("build a knowledge graph based on the findings result of each review, either my MR or other's MR … so later on the same mistake will not happen again") and their answers: the graph is for their Coding Agent first and a reminder for them second; every finding teaches, whatever became of it; a lesson applies across the repos of a folder the Owner configures, which may be one repo or a parent of many (theirs is `repo.madhani.one`); it exports one way as a markdown vault the team can share. Choices marked _my call_ are the builder's. Vocabulary is in `CONTEXT.md`.

## Why

Reviews keep flagging the same kinds of mistakes: a missing timeout here, an unscoped query there. Each finding is read once, fixed or argued about, and forgotten. The Coding Agent that writes the next change has never seen it, so it can make the same mistake in the next repo. Suica already holds most of these findings; it only has to keep them as lessons and hand them to the agent at the moment it writes code.

## Goals

- Every finding becomes an occurrence of a **Lesson**: a short, general rule ("HTTP clients need an explicit timeout") with every place it was flagged.
- Lessons are a graph: a Lesson links to the repos and kinds of code it touches and to related Lessons, and a new finding that repeats an existing Lesson is added to it, not stored as a new one.
- The Owner's Coding Agent gets the Lessons that match a file when it reads that file, and its folder's heaviest Lessons when a session starts there, in any repo under a configured **Lesson Scope**, without having to remember to ask.
- Any Coding Agent can ask Suica for Lessons by itself (before planning, or without hooks).
- The Owner is reminded: a finding that repeats a Lesson says so, and the app lists Lessons by how often they repeat.
- The Lessons export as a markdown vault (one note per Lesson, `[[links]]` between them) to a folder the Owner picks, for the team to read.

## Non-goals

- Lessons flowing back from the vault: the export is one way (the Owner's answer, "for now").
- Findings Suica does not collect today: comments the Owner writes by hand, and other reviewers' comments on other people's MRs.
- Filtering findings by outcome. A finding that was disputed, ignored or never answered still teaches (the Owner's answer); its outcome is recorded, not used to drop it.
- Writing Lessons into a repo's `CLAUDE.md`, `AGENTS.md` or any other tracked file (_my call_: teammates would see them in diffs, and those files grow without limit).
- Editing or deleting Lessons by hand in this first version, beyond what the app section allows.

## Anti-goals

- An agent buried in Lessons. If every edit pastes twenty Lessons into the agent's context, it stops reading them and pays tokens for nothing; what reaches the agent must be few and matching.
- An edit that waits on a model. The hook must answer from what is stored, fast; no model call on the path of a read or an edit. And no Lesson ever blocks or refuses an edit (the Owner's answer).
- A Lesson that leaks outside its scope: a Lesson learned under one Lesson Scope never reaches a repo outside it.

## Terms (to add to `CONTEXT.md`)

**Lesson**: A general rule learned from one or more review findings, with every occurrence. _Avoid_: rule, knowledge, memory.

**Occurrence**: One finding a Lesson was learned from or matched: its MR, repo, file and line, severity, text, source (Agent Review or Finding Thread) and outcome. _Avoid_: instance, hit.

**Lesson Scope**: A folder on the Owner's Mac whose repos share Lessons: one repo, or a parent folder of many (searched for repos below it). _Avoid_: root, workspace.

**Topic**: A kind of code or concern a Lesson is about (`http-client`, `db-pool`, `auth`, `sql`, `logging`, a language). The graph's link between Lessons. _Avoid_: tag, category.

## Where findings come from

- **Agent Reviews of other people's MRs**: the findings `extractFindings` already reads from a review's body (`path:line`, text), when the review reaches `ready` (_my call_: the Owner may not post every review, and a skipped review's findings still teach). `Finding` has no severity today; the builder adds it from the same severity subheadings `countFindings` reads (_my call_). A re-review's own new findings count; its `## Previous review` section does not add occurrences, but its fixed / not fixed / partly fixed verdict becomes the outcome of the occurrence it names. That section names items by location and title, never by number, so a verdict is matched to its occurrence by `path` and title (_my call_).
- **Finding Threads on the Owner's own MRs**: each thread's first note is the finding; the thread's later notes and what an Agent Fix did (`changed` or `reply`) give the outcome. Today threads are read only when the fix watch reads a Watched MR or the Owner runs a fix; the builder makes sure every Finding Thread on the Owner's open MRs is read at least once for Lessons, watched or not, without changing what the fix watch does.
- An Agent Review of the Owner's own MR, if one is ever run, counts like any other.
- **History**: on the first run after the upgrade, existing ready or posted Agent Reviews and stored `fix_run` threads are learned too, oldest first, in the background (_my call_). Suica logs how many are waiting.

Each finding is learned once: an occurrence is keyed by its source (review id and finding number, or discussion id) so a restart or a re-read never doubles it.

## Learning a Lesson

- A finding's MR is mapped to a Lesson Scope (below). A finding whose MR maps to no scope is still stored as an occurrence, unassigned, so a scope added later picks it up (_my call_).
- A model run turns new findings into Lessons, in batches per MR, with the Model CLI and model the reviews use (`review.model`, no skill; _my call_: one setting fewer). It gets the findings and, for each, the existing Lessons of the same scope that look close (same Topic, or matching words), and answers per finding: an existing Lesson's id, or a new Lesson (title of at most ~80 characters, one-paragraph rule with the reason, Topics, and the file kinds it applies to as globs such as `**/*.go` or `**/handlers/**`). The answer is JSON, checked against a schema; an invalid answer fails that batch, which is retried later with backoff, and never drops findings.
- The model never sees more than one scope's Lessons (anti-goal: no leak between scopes).
- Token use is recorded like other runs (`token_usage`, purpose `lessons`).
- A Lesson's **weight** for ranking: occurrences, with Blocker and Major counting more than Minor and Nit, and recent ones more than old ones (_my call_; the exact formula is the builder's).

## Lesson Scopes and repos

- Config: `lessons.scopes`, a list of folder paths (`~` allowed). Each is either a git repo itself or a folder whose git repos below it (not inside `node_modules` or other repos' worktrees) all share that scope.
- A repo is matched to GitLab by its `origin` remote: host equal to `gitlab.hostname` and the project path (`group/sub/project`) equal to the MR key's project. Suica re-scans the scopes when the config changes and at most hourly (_my call_), so a newly cloned repo joins.
- A repo under two scopes belongs to the deeper one (_my call_).
- A Lesson's scope is worked out from its occurrences' repos, not fixed when it is learned (_my call_). When `lessons.scopes` changes (a scope added inside another, removed or renamed, a repo cloned elsewhere), Suica re-maps every occurrence's repo; a Lesson whose occurrences now fall in two scopes is split into one Lesson per scope with the same title and rule, and a Lesson with no occurrence in any scope is kept but reaches no agent and is not exported. This keeps the no-leak anti-goal true after any change.
- Config also gains `lessons.enabled` (default off, so an upgrade does not start spending tokens unasked), `lessons.vaultPath` (unset: no export) and `lessons.perFile` (how many Lessons the hook hands over for one file, default 5) and `lessons.perSession` (how many when a session starts, default 5).

## The Coding Agent

### Before it writes (Claude Code)

The Lessons must reach the agent before it writes the change: a hook on the edit itself runs after the agent has written the edit, so it can only correct the next step. Lessons are therefore handed over when a session starts and when the agent reads a file, and never by blocking an edit (the Owner's answer).


- `suica lessons hook` is one Claude Code hook command for three events:
  - `SessionStart`: when the session's folder is in a Lesson Scope, the top `lessons.perSession` Lessons of that scope by weight, as titles and one-line rules, with a line saying more come per file as it reads and that it can ask the `lessons` MCP server.
  - `PostToolUse` on `Read`: the file's Lessons, as below (_my call_: after the read, so the Lessons sit next to the file's content in the agent's context).
  - `PreToolUse` on `Write`, `Edit` and `MultiEdit`, as a backstop for files the agent writes without reading them first (a new file): the same file Lessons. It only adds context; it never answers deny or ask.
- For a file, it reads the hook's JSON from stdin, takes the file path, finds the Lesson Scope the file is in, and prints the hook's JSON answer with `additionalContext`: the top `lessons.perFile` Lessons of that scope whose file globs or Topics match the file, by weight, each as its title, rule and "flagged N times, last in `repo` !iid". Nothing matching, a file outside every scope, or any error: it prints nothing and exits 0. It never blocks a read or an edit.
- Matching is by path only: the Lesson's file globs (the model writes them, language globs included) against the file's path relative to its repo. Topics are the graph's links and the view's filter, not a match key; the hook never reads the file's content (_my call_: content matching would break the speed limit). The weight ranks matches, and `lessons.perFile` caps them, so a `.go` file gets the few heaviest Go Lessons, not all of them.
- It opens the database read-only, and must answer in well under a second; no model call, no network.
- A Lesson already handed to the same Claude Code session is not handed again, whichever event or file it came with (_my call_: the session id is in the hook input; this keeps repeated reads and edits quiet). That memory is a small JSON file per session in Suica's state folder, not the database, and files older than a day are removed on the next run (_my call_).
- `suica lessons install` adds the hook to `~/.claude/settings.json` (keeping everything already there) and `suica lessons uninstall` removes only Suica's entry. The app's settings offer the same as a toggle. Installing asks the Owner first; nothing changes `~/.claude/settings.json` without that (_my call_).

### Asking (any Coding Agent)

- `suica lessons mcp` is a local MCP server over stdio, which Claude Code, Codex and Gemini CLI launch themselves. No network port.
- Tools: `lessons_for_path` (a file or folder path; the matching Lessons, as the hook gives them), `search_lessons` (words and an optional Topic, within the scope of a given path), `get_lesson` (one Lesson with its occurrences). All are read-only and scoped: a path outside every Lesson Scope gets nothing.
- `suica lessons install` also registers the server for Claude Code (user scope) and, when installed, Codex; the README shows the line for others.

## The Owner

- **Repeat marker**: an Agent Review whose finding matched an existing Lesson shows, under that finding in MR detail, "Flagged N times before, in `repo-a`, `repo-b`" with a link to the Lesson. N counts only earlier occurrences from other MRs (time, then insertion order); sibling findings of the same MR and later ones never count. On the Owner's own MR, the same shows on the Finding Thread in the fix view. Nothing is added to what Suica posts to GitLab or Teams (_my call_: the Lessons are the Owner's, not the Author's).
- **Lessons view** in the app window: Lessons of each scope ranked by weight, filterable by Topic and repo, searchable; a Lesson opens to its rule and every occurrence with links to the MRs. The Owner can merge two Lessons that are the same, or archive one that is wrong (archived Lessons are not handed to agents and not exported) (_my call_: the only hand edits, so a bad model grouping is fixable).
- No new macOS notification (_my call_: the marker sits where the Owner already reads findings).

## The vault

- On each change, and with `suica lessons export`, Suica writes `lessons.vaultPath`: `Lessons/<slug>.md` per Lesson, `Topics/<topic>.md` and `Repos/<repo>.md` per Topic and repo, and an `index.md` ranking Lessons by weight. Notes link by `[[…]]` so Obsidian's graph shows Lesson–Topic–Repo links.
- A Lesson note: front matter (id, scope, Topics, weight, first and last seen), the rule, then occurrences (repo, MR link, file, severity, outcome, the finding's text, capped).
- Suica owns the folder's `Lessons/`, `Topics/` and `Repos/` and rewrites them; it never deletes a file it did not write (it keeps a manifest) (_my call_).
- Archived Lessons are left out. Author names are left out; occurrences name the repo and MR, not the person (_my call_: a shared vault should not read as a list of who made which mistake).

## Data

- New tables (next schema version): `lesson` (id, scope, title, rule, topics, globs, archived, timestamps), `lesson_occurrence` (source key unique, lesson id nullable until learned, mr key, repo, path, line, severity, text, source, outcome, timestamps), `lesson_link` (lesson to lesson, from shared Topics or the model's answer). Exact columns are the builder's.
- `contracts/reviews.v1.json` gains, per finding with a repeat, the Lesson id and count; a new `contracts/lessons.v1.json` serves the Lessons view (golden plus Swift decoder).

## Constraints

- Finding text is untrusted: it is written by a model or another person. It reaches the learning prompt fenced as data, and reaches the Coding Agent only as Lesson text the model wrote, capped in length; the hook output is plain text with no instructions beyond the Lessons.
- Nothing leaves the Mac except the model runs Suica already makes, and the vault folder the Owner chooses.
- The hook command starts fast: it must not load the daemon's whole runtime.
- `README.md`, `CONTEXT.md`, the contracts and their Swift decoders change in the same branch.

## Left to the builder

- How close-Lesson candidates are picked for the model (Topic and word match is enough to start; embeddings are not needed).
- The weight formula, the vault's slug rule and file layout details, the Lessons view's layout.
- Batch sizes, retry timing, and how the background learner shares the model runner with reviews and fixes (reviews and fixes go first).

## Tests

- Agent (vitest): finding extraction to occurrences for reviews, re-reviews and Finding Threads, keyed once; scope scan and remote matching (nested repos, two scopes, non-GitLab remotes); the model answer schema and a failed batch kept for retry; the hook: each of the three events, matching by glob, the per-session repeat filter, never a deny or ask answer, empty output outside scopes and on error, read-only; MCP tools scoped by path; vault export (links, manifest, archived left out); settings.json install and uninstall keep other entries; schema migration; contract goldens.
- App (swift test): decoders; the repeat marker; merge and archive.
- UI: harness screenshots of the Lessons view and of a finding with its repeat marker.
