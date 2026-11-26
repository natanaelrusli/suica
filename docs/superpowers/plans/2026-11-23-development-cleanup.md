# Development Cleanup

Add a macOS sidebar page with **Ports** and **Worktrees** tabs. The Owner can identify a forgotten development server, stop it, and reclaim space from a finished checkout. Discovery runs when the page opens or the Owner refreshes it. Every cleanup action starts with an explicit selection. Keep the existing Suica cache and log cleanup command independent.

## 1. Find and stop a development server

- Add `suica ports list --json` in the TypeScript CLI. Enumerate visible TCP listeners with machine-readable lsof output. Build on the ps and working-directory probes in `src/office/probe.ts`. Group addresses and ports by process, including IPv4 and IPv6. Distinguish a failed or partial scan from an empty result.
- Show port, program, working folder and process age. Support searching by port or project. Age and folder help the Owner recognize a forgotten server. Neither establishes that a listener is unused.
- Add **Stop** for processes owned by the current account. Show the process and every port affected in the confirmation. Immediately before sending SIGTERM, recheck owner, PID, start time and the selected listener. Reject a changed identity and protect Suica's own processes. Refresh after a bounded wait and distinguish stopped, still running, permission denied and port reopened by another process.

## 2. Find and remove merged worktrees

- Let the Owner add a repository using the folder picker. Remember it so finished projects remain discoverable after all sessions close. Enumerate registered checkouts with `git worktree list --porcelain -z`, including linked paths outside the chosen folder. Deduplicate repositories by their common Git directory.
- Show path, branch, merge target and eligibility. Suggest the remote default branch when available and let the Owner select the actual target per repository. Record the target commit used for the check and show when its remote ref was refreshed. Fetch on request and require a successful refresh before removal against a remote target.
- Mark a linked branch **Merged** when its current HEAD is an ancestor of the selected target tip. Reject a target that is the candidate branch itself. Squash or rebase merges without ancestry evidence stay unverified in the first release. A merged MR alone cannot establish that later local commits are disposable.
- Protect the main checkout, locked or detached worktrees, unfinished Git operations, modified or untracked files, and checkouts with known active sessions or listeners. Inspect ignored files too. Block removal for unclassified ignored content such as local environment files. For explicitly recognized disposable output such as node_modules, show what will be discarded and its estimated size. Treat incomplete checks as ineligible.
- Load size estimates asynchronously on demand. Offer multi-select with a preview of exact paths, branches and estimated total. Before each removal, repeat identity, merge, contents and activity checks. Run ordinary `git worktree remove` for that path, keep the branch ref, and report each result independently. If Git refuses, surface its reason. Never retry with force. Label disk estimates as approximate because files can share storage.

## 3. Connect the UI and verify both flows

- Deliver Ports first, then Worktrees. For each slice, add a versioned JSON contract under `contracts/`, register the CLI commands in `src/cli.ts`, and wire the SwiftUI page through SuicaCore. Keep scan and action errors visible beside the affected item. Discard selection when refreshed data changes its identity.
- Verify Ports with a temporary listener on multiple ports, an old listener still in use, a replaced process and a listener that survives SIGTERM. Acceptance requires that the intended process stops, an unrelated listener survives, and the UI accurately reports the resulting port state.
- Verify Worktrees with temporary repositories covering merged and unmerged heads, post-merge commits, dirty and ignored files, locked and active trees, a moved target and a batch whose second item changes after preview. Acceptance requires that only eligible selected checkouts disappear, their branches remain, and the Owner sees which items were skipped and why.
- Run the repository's full relevant test and build gate before push or MR. No real development processes or worktrees are needed as test fixtures.

## 4. Follow-up audit (2026-11-24)

- Ports defaults to **Project servers** (working folder inside the home folder, outside `~/Library` and dot folders), shows the full command line, sorts oldest first and offers **Force Quit** (SIGKILL, `ports stop … --force`) only after SIGTERM leaves the process running.
- Worktrees whose folder was deleted outside Git are reported as `prunable`; **Prune…** runs `git worktree prune` after listing every entry it drops (`worktrees prune <repo> --json`).
- Scans use `git status --ignored=matching` and skip protected checkouts, so a 52-worktree repository scans in about 2 s instead of 40 s. Conventional build output (`dist`, `.next`, `test-results`, `*.tsbuildinfo`, …) no longer blocks removal; anything else ignored still does.
- The scan returns the resolved `targetRef`; the UI asks for a fetch only for `refs/remotes/…` targets and folds it into **Fetch & Remove**. Removal still succeeds when the target advanced after preview, as long as the preview commit is an ancestor of the new tip.
- Still out of scope: squash and rebase merges stay **Unverified**.
