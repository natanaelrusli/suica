# Suica plans: tracker

- **As of:** 2026-10-28, read from `git` in this checkout (`main` at 51d1980; P11 from `feat/no-ticket-ota-updates`) and from the plan files in this folder.
- **Scope:** the 12 plans in this folder. Suica is a personal project, so there are no planner keys and no MRs: every branch is `feat/no-ticket-*` and work lands by a local `git merge --no-ff` into `main`.
- **"Merged"** means the branch head is an ancestor of `main` (`git merge-base --is-ancestor`). Merged does not say the app was installed or tried on the real machine.
- **The plan files' own checkboxes are all unticked** and are not the status; this file is.
- Update this file in the same change that adds a plan or merges its branch.

## 1. Status per plan

| ID | Plan | Spec | Branch | Status | Merged into `main` | Steps in plan (unticked) |
|---|---|---|---|---|---|---|
| P1 | [Foundation, review requests and activity alerts](2026-10-14-mr-review-assistant-plan-1-foundation-and-alerts.md) | [design](../specs/2026-10-14-mr-review-assistant-design.md) | `feat/no-ticket-polling-foundation` | **Merged** | 2026-10-20 (4331629 is the first merge on its path) | 58 |
| P2 | [Teams](2026-10-16-mr-review-assistant-plan-2-teams.md) | same design, section "Teams (Plan 2)" | `feat/no-ticket-polling-foundation` (same branch as P1) | **Merged** | 2026-10-20 (4331629) | 70 |
| P3 | [macOS menu bar app](2026-10-16-mr-review-assistant-plan-macos-menubar.md) | none (decisions in the plan) | `feat/no-ticket-macos-menubar` | **Merged** | 2026-10-20 (4331629) | 32 |
| P4 | [Suica rename](2026-10-16-suica-plan-1-rename.md) | none (name table in the plan) | `feat/no-ticket-suica-rename` | **Merged** | 2026-10-20 (4331629) | 24 |
| P5 | [Suica app window](2026-10-16-suica-plan-2-app-window.md) | none (decisions in the plan) | window work in c3ce52d, d2f8970 and neighbours | **Merged** | 2026-10-20 (4331629) | 50 |
| P6 | [Agent Re-review](2026-10-19-agent-rereview.md) | [design](../specs/2026-10-19-agent-rereview-design.md), [findings notice](../specs/2026-10-19-findings-notice-design.md) | `feat/no-ticket-agent-review-and-approve` | **Merged** | 2026-10-20 (4331629) | 35 |
| P7 | [Overview widgets and panel](2026-10-20-overview-widgets-and-panel.md) | [design](../specs/2026-10-20-overview-widgets-and-panel-design.md) | `feat/no-ticket-overview-widgets-and-panel` | **Merged** | 2026-10-20 (63b6e88) | 13 |
| P8 | [Agent Fix, comments and merging](2026-10-21-agent-fix-comment-merge.md) | [design](../specs/2026-10-21-agent-fix-comment-merge-design.md) | Agent Fix commits 5f9af2e to ba89acd | **Merged** | 2026-10-21 (c869b8d) | 42 |
| P9 | [Virtual office](2026-10-21-virtual-office.md) | [design](../specs/2026-10-21-virtual-office-design.md) | `feat/no-ticket-virtual-office` | **Merged** | 2026-10-21 (3525407) | 31 |
| P10 | [Review lessons](2026-10-26-review-lessons.md) | [design](../specs/2026-10-26-review-lessons-design.md) | `feat/no-ticket-review-lessons` | **Merged** | 2026-10-26 (a4f3020), folder picker 51d1980 | 69 |
| P11 | [OTA updates](2026-10-28-ota-updates.md) | none (decisions in the plan) | `feat/no-ticket-ota-updates` | **Implemented on branch, not merged** | not merged | 37 |
| P12 | [Lessons usage log](2026-10-29-lessons-usage-log.md) | [design](../specs/2026-10-29-lessons-usage-log-design.md) | `feat/no-ticket-lessons-usage` | **Implemented on branch, not merged** | not merged | 30 |

## 2. Branches and merge commits per plan

| Plan | Branch | Head | Merge commit into `main` | Date | Notes |
|---|---|---|---|---|---|
| P1, P2 | `feat/no-ticket-polling-foundation` | 149b1fb | 4331629 (first merge on the path) | 2026-10-20 | One branch carries both plans. |
| P3 | `feat/no-ticket-macos-menubar` | a025564 | 4331629 | 2026-10-20 | |
| P4 | `feat/no-ticket-suica-rename` | 62f2ead | 4331629 | 2026-10-20 | |
| P5 | none checked | – | 4331629 | 2026-10-20 | Window commits c3ce52d, f1f906f, d2f8970. |
| P6 | `feat/no-ticket-agent-review-and-approve` | 655a730 | 4331629 | 2026-10-20 | Follow-ups merged separately (re-review approval, 12a316d and others). |
| P7 | `feat/no-ticket-overview-widgets-and-panel` | 13a13dc | 63b6e88 | 2026-10-20 | |
| P8 | `feat/no-ticket-mr-fixes` (Agent Fix commits 5f9af2e to ba89acd) | 8c591bb | c869b8d | 2026-10-21 | Later: Watch/Unwatch e8338c4, My MRs split 190cd39. |
| P9 | `feat/no-ticket-virtual-office` | 70a8229 | 3525407 | 2026-10-21 | Many office follow-ups, each with its own merge. |
| P10 | `feat/no-ticket-review-lessons` | 06edbf3 | a4f3020 | 2026-10-26 | Folder picker merged in 51d1980. |
| P11 | `feat/no-ticket-ota-updates` | see `git log` | not merged | – | Updater is inert until the real public key is committed; not exercised on a real release. |
| P12 | `feat/no-ticket-lessons-usage` | see `git log` | not merged | – | Hook and `suica lessons usage --json` tried on the real state folder (one session entry, removed afterwards); the app Usage view rendered in a scratch harness only, not installed. |

## 3. Work in the checkout that no plan covers

Uncommitted on `main` at the time of writing (from `git status`): a lessons graph (`LessonGraph.swift`, `LessonsGraphView.swift`) and a zip export (`src/lessons/zip.ts`), touching `Lessons.swift`, `LessonsView.swift`, `AgentClient.swift`, `Copy.swift`, `SuicaApp.swift`, `src/cli.ts` and their tests. No plan or spec file exists for it yet. Not committed, not merged.

## 4. Designs with no plan

48 of the 55 specs in `docs/superpowers/specs/` have no file in this folder; those features were built straight from the design (each has its own merge commit in `git log --merges`). Specs that do have a plan are listed in section 1. Reconstructing a plan after the fact is not needed; add a row to section 1 only when a new plan file is written.

## 5. Open items

- **Review lessons (P10):** installing the hook on the real `~/.claude` and learning from real data are not done (memory note of 2026-10-26).
- **Local worktrees:** about 50 sibling worktrees (`../suica-*`) from merged features still exist; they were not checked for leftovers.

## 6. Not verified

- Nothing here says a feature runs on the real machine; only that its branch is in `main`.
- P1 to P5 and P6 share one first merge commit (4331629) because they were merged together; that is the first merge on their path, not necessarily the only one.
- P5 and P8 have no branch of their own that was checked; their status comes from their commits being ancestors of `main`.
- Step counts are the number of `- [ ]` lines, not a measure of work done.
