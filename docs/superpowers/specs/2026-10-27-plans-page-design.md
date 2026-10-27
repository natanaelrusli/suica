# Plans page — design

Status: written from the Owner's request on 2026-10-27 ("i want suica to have a new page for this functionality, to track plans"), after a hand-written `docs/superpowers/plans/TRACKER.md` showed the shape: one row per plan with where it stands. Choices marked _my call_ are the builder's. Vocabulary is in `CONTEXT.md`.

## Why

Plans written with the writing-plans skill pile up in `docs/superpowers/plans/` of each repo. Their own checkboxes are never ticked, so a folder listing says nothing about which plan is merged, in review or abandoned. The tracker had to be kept by hand, in a file nobody opens.

## Goals

- A **Plans** page in the window lists every plan found in the folders the Owner picks, newest first, each with its title, date, goal, step progress and a status.
- The Owner sets a status and a one-line note per plan ("MR !42 open, waiting on Rayhan"); both survive restarts and a rescan.
- Search, and filter by status; the count of each status is always visible.
- A plan opens in the default editor or Finder from the page.

## Non-goals

- Reading GitLab, git or a planner for status (_my call_: Suica cannot know which branch a plan became; the Owner says). No new Node command, config key or contract golden.
- Editing a plan's text, or ticking its steps from the app.
- Plans of other kinds than Markdown files.

## Behaviour

- **What is a plan:** a `.md` file whose first 12 lines contain `For agentic workers` (the skill's header), or that sits in a folder named `plans` and starts with `YYYY-MM-DD-`. `TRACKER.md` and READMEs are not plans.
- **Where:** the plan folders, picked in a Finder panel on the page, kept in the app's user defaults (_my call_: not the agent's config; the agent never reads plans). Scanned recursively; hidden folders, `node_modules` and `.build` are skipped; symlinks are not followed; a file is listed once however many folders reach it.
- **Status:** Planned, In progress, In review, Done, Dropped. Until the Owner sets one, it is derived from the steps: no step ticked is Planned, some is In progress, all is Done. A set status wins over the derived one. "Reset" removes it.
- **Steps** are `- [ ]` and `- [x]` lines outside code fences (plans quote the checkbox template in a fence). Tasks are `### Task N: title` headings, each with its own step count.
- **Marks** (status and note) are keyed by the plan's absolute path. A mark whose file is gone stays stored and is not listed (_my call_: a plan that comes back, or a folder on an unmounted volume, keeps its status).
- The page lists a plan's tasks with their progress in the detail pane; it does not render the whole plan.
- Sidebar: Insights, after Lessons; ⇧⌘P.

## Anti-goals

- A scan that blocks the window: it runs off the main thread and the page shows the previous list until it finishes.
- A plan that vanishes because one file is unreadable: that file is skipped, the rest are listed.
