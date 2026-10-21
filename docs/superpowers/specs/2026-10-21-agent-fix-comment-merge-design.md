# Agent Fix, comments and merging from Suica — design

Status: written from the Owner's request on 2026-10-21 ("Watcher to all of my MR and trigger agent to solve findings from reviewer, watcher closed when the MR is approved; able to add comment to MR from suica; able to merge my MR from suica") and the conversation after it. Choices marked _my call_ are the builder's and can be changed. Vocabulary is in `CONTEXT.md`.

## Intent

Suica already reviews other people's MRs for the Owner. This turns it the other way: when a Reviewer leaves findings on one of the Owner's own MRs, the agent checks out the branch, changes the code (or drafts a reply when it thinks nothing should change), and shows the Owner the result. Nothing reaches GitLab until the Owner confirms. Then Suica commits, pushes and replies on each thread. The Owner can also comment on and merge their own MRs from the app, so the whole loop from "Reviewer commented" to "merged" can happen in Suica.

## Goals

1. **Watcher.** Every MR the Owner authored is watched for **Finding Threads** (new vocabulary, below), starting from the first poll that sees a new one. Watching an MR stops once it is approved.
2. **Agent Fix.** Each poll that finds new Finding Threads queues an Agent Fix for that MR. The model CLI works on a checkout of the source branch. For each thread it either changes the code or drafts a reply saying why nothing should change. The fix then waits for the Owner.
3. **Confirm.** The Owner sees the diff, each thread with its answer (changed or reply), the draft replies and a draft commit message. All of it is editable except the code. **Confirm** commits, pushes (never with force) and posts one reply per thread. Suica never resolves the threads: that is left to the Reviewer.
4. **Comment.** A **Comment** box on each of the Owner's MRs posts a general Markdown note as the Owner.
5. **Merge.** A **Merge** button on each of the Owner's MRs opens a sheet where the Owner picks squash, delete source branch and the commit message each time. A running pipeline means "merge when the pipeline succeeds". A failed pipeline, missing approval, conflicts or draft state disable the button and show the reason.

## Non-goals

- Fixing other people's MRs, or fixing failed pipelines.
- Resolving threads, approving, rebasing, force pushing, or editing the MR description.
- Running the project's tests or build during a fix (_my call_: see "Model run").
- Line comments from the Comment box. Thread replies come only from Agent Fix.
- Choosing which threads a fix covers before it runs. The Owner can choose which replies to post.

## Anti-goals

These make it a failure even if it works:

- Any commit, push or reply reaching GitLab without the Owner pressing Confirm.
- Overwriting someone else's commits. A push that is not a fast-forward fails and is never retried with force.
- Two fixes for the same MR working on the branch at once.

## Vocabulary (add to `CONTEXT.md`)

**Finding Thread**:
An unresolved, resolvable discussion on the Owner's own MR whose newest note was written by someone other than the Owner. A Reviewer's new thread is one. So is a Reviewer's answer to a reply the agent posted earlier.
_Avoid_: comment, finding (alone)

**Agent Fix**:
A change to the Owner's own MR that the agent writes with a language model to answer Finding Threads. It changes code, drafts replies, or both, and is committed, pushed and replied only once the Owner confirms it.
_Avoid_: auto fix, bot commit

**Watched MR**:
An MR the Owner authored that is open and not yet approved. Only Watched MRs get automatic Agent Fixes.

## Behaviour

### Watching

- **Approved** means the MR has at least one Reviewer and every Reviewer's state is `APPROVED` (_my call_: GitLab's own `approved` field is true from the start on projects with no approval rules, which would stop the watcher at once). Once approved, the MR stops being watched: a queued fix is cancelled with "The MR was approved." A running or ready fix is left alone, and the Owner can still confirm or discard it. When a new Reviewer is added or one revokes their approval, the MR is watched again.
- When the MR is merged or closed (it leaves the snapshot), queued and running fixes are cancelled. Ready ones are discarded with "The MR is no longer open."
- Drafts are watched too (_my call_: a Reviewer who comments on a draft still expects an answer).
- **Detecting cheaply.** The snapshot already has the last 50 note ids of each authored MR. The detail fetch (`fetchMrDetail`, which has the discussions) runs only when a non-system note by someone other than the Owner appears that the agent has not seen. In the detail, a thread counts only when it is unresolved, resolvable and its newest note is by someone else. It also must not already be handled at that newest note: the `fix_threads` table records the newest note id each fix covered, so a discarded fix's threads stay quiet until someone writes on them again.
- **Everyone counts.** Bots and the authors in `notifications.ignoreAuthors` count as "someone other than the Owner" too. The Owner chose this: every thread gets an answer.
- **Which endings mark threads as handled** (_my call_). Pushed, discarded, failed and skipped mark them, so a broken fix does not loop and use up the daily limit. The Owner has the failure notification and Retry. Cancelled does not mark them (the MR was approved, closed or the agent shut down), so they come back if the MR is watched again.
- **Daily limit.** A fix beyond `fix.maxPerDay` stays `queued` until the next local day. It is not skipped.
- **Fix findings now** covers every unresolved, resolvable thread whose newest note is by someone else. It ignores `fix_threads`, so threads handled before (for example after a Discard) can be redone (_my call_). When none match it prints `nothing-to-fix` and queues nothing.
- **First run.** When the feature first runs, unresolved Finding Threads that already exist count as new (_my call_; `fix.maxPerDay` caps the cost).
- One open fix per MR. While an MR has a fix that is queued, running or ready, new Finding Threads wait. They are picked up by the next poll after that fix ends (pushed, discarded, failed, cancelled). When a queued fix exists and more threads appear, the threads are added to it, since it has not checked out yet.

### Model run

- **Worker.** A separate worker runs one fix at a time (_my call_: fixes are rarer than reviews, and one slot keeps checkouts and tokens small). Fixes count toward `fix.maxPerDay`, not `review.maxPerDay`.
- **Checkout.** The checkout reuses the Agent Review clone (shallow, SSH, LFS off, `--branch=<source>`). It goes to `<state dir>/fixes/<id>/repo` instead of a temp folder, because it must survive until the Owner confirms, including across an agent restart. It is deleted when the fix ends. On start, the agent deletes any `fixes/<id>` folder whose fix is not running or ready. The cloned commit is stored as `baseSha`.
- **Inputs** written next to `repo/`, like a review:
  - `mr.md`: title, description and branches.
  - `threads.md`: each Finding Thread with its id, file and line (for a diff note) and every note in order with author names.
  - `notes.md`: the Owner's retry note, if any.
- **Tools** (_my call_):
  - claude: `Read Glob Grep Edit Write` with `--permission-mode dontAsk` and `--strict-mcp-config`. There is no shell, so the model cannot run project code or reach the network.
  - codex: `--sandbox workspace-write`, with network off (the sandbox default).
  - Gemini: unsupported, as for reviews.

  The Owner reviews the diff, which stands in for tests here.
- **Prompt.** Answer each thread. Change code only where the finding is right and the change is small and on topic. Otherwise draft a short, polite reply that says why. Never touch files the threads are not about unless the fix needs it. The model ends with a fenced JSON block, which is validated with zod:
  ```json
  { "commitMessage": "…", "threads": [ { "id": "gid://gitlab/Discussion/…", "action": "changed" | "reply", "reply": "…" } ] }
  ```
  A thread the model left out gets `action: "reply"` with an empty reply, and the Owner sees it flagged. A `changed` reply may contain `{{sha}}`, which is filled with the short commit sha at push time. The prompt asks for a reply like "Fixed in {{sha}}: …".
- **Result.** After the CLI exits, Suica runs `git add -A` and `git diff --cached --binary` in the checkout. The diff is stored on the row, up to 500 KB (_my call_; larger fails with "the change is too large to show"). An empty diff with only replies is a valid ready fix. Every `changed` thread with an empty diff becomes `reply`.
- Model, effort and timeout come from `fix.*` (below). Tokens are recorded with purpose `fix` in the usage table, so they show on the Usage page.

### States

`queued → running → ready → confirming → pushed`

- From `ready`: `discarded`.
- From `running`: `failed`, `skipped` or `cancelled`.
- From `confirming`: `push-failed`.

These guarded transitions work like `agent_reviews`, with cancel by row change every two seconds. A ready fix the Owner does nothing with stays ready (_my call_: no expiry; a new push to the branch by the Owner makes Confirm fail safely, see below).

**Retry with a note.** On a ready, failed or push-failed fix, this discards it and queues a new fix for the same threads with the Owner's note. The new fix gets a fresh checkout at the current head.

### Confirm

The Owner's edits travel with the command: commit message, and per thread the reply text or "don't post". Then, in order:

1. Compare the branch head on GitLab (MR detail `headSha`) with `baseSha`. If they differ, the fix becomes `push-failed` with "The branch moved since the fix was made; retry to redo it on the new commits." Nothing is pushed.
2. `git commit -m <message>` with the Owner's own git identity, from their global git config. Hooks are not installed in a fresh clone. `--no-verify` is never passed.
3. `git push origin HEAD:refs/heads/<source>`, with no force and the same SSH as the clone. A rejected push becomes `push-failed` with the reason.
4. For each thread not marked "don't post", post `discussions/:id/notes` with `{{sha}}` filled in. A reply that fails does not undo the push. The fix is `pushed` with "2 of 3 replies posted", and **Post missing replies** retries only those (_my call_).
5. Delete the checkout. Record each thread's newest note id, now the Owner's reply. The thread is not a Finding Thread again until the Reviewer writes on it.

The existing Re-review Nudge flow then sees the push like any other push by the Owner. Nothing new is needed there.

### Comment

- `suica mr comment <key> --json` reads the body from stdin (_my call_: no size or quoting limits from argv) and POSTs `projects/:id/merge_requests/:iid/notes`. It prints `{"status": "posted" | "failed" | "bad-key"}`.
- In the app: a Markdown box with a preview at the bottom of the Comments tab of the Owner's MRs. **Send** posts the comment, then reloads the detail.

### Merge

- **New MR detail fields** (`mr-detail.v1.json`, plus the Swift decoder):
  - `detailedMergeStatus` (GraphQL `detailedMergeStatus`)
  - `squashOption` (`always | never | default_on | default_off`, from the project's `squash_option`)
  - `removeSourceBranchDefault` (`forceRemoveSourceBranch`)
  - `defaultMergeCommitMessage`
  - `defaultSquashCommitMessage`

  `pipelineStatus` and `squashOnMerge` already exist.
- **The sheet:**
  - A squash toggle, locked when the project says `always` or `never`.
  - A delete source branch toggle, starting from the MR's setting.
  - A commit message field, filled from GitLab's default for the chosen mode.
- **Button state:**
  - Enabled when `detailedMergeStatus` is `MERGEABLE`. It is also enabled when the status says only that the pipeline is still running (`CI_STILL_RUNNING` or `CI_MUST_PASS` while `pipelineStatus` is `RUNNING` or `PENDING`). Then it reads **Merge when pipeline succeeds**.
  - Disabled otherwise, with the reason in words: not approved, failed pipeline, conflicts, draft, unresolved threads, needs rebase, and so on (one Copy string per status, with a generic fallback).
- `suica mr merge <key> <sha> --json [--squash|--no-squash] [--remove-source-branch|--keep-source-branch] [--when-pipeline-succeeds]` reads the commit message from stdin. It sends `PUT projects/:id/merge_requests/:iid/merge` with:
  - `sha`, so a newer push is never merged by surprise
  - `squash` and `should_remove_source_branch`
  - `squash_commit_message` or `merge_commit_message`
  - `merge_when_pipeline_succeeds=true` when asked (the builder checks this name against the instance; newer GitLab also takes `auto_merge`)

  It prints `merged | scheduled | not-mergeable | sha-mismatch | failed` (405 → not-mergeable, 409 → sha-mismatch).
- `glab api -X PUT` needs a `glabPut` runner next to `glabPost`.
- Comment and Merge appear only on the Owner's MRs (_my call_). The CLI does not restrict them: GitLab's permissions decide.

### App

- **Fix tab** on the detail of the Owner's MRs, next to Agent review:
  - Status and activity feed while running.
  - When ready: the diff, using the Changes tab's diff rows, and one card per thread. Each card shows the Reviewer's notes, the model's action, an editable reply and a "Don't post" toggle.
  - An editable commit message.
  - Buttons: **Confirm and push**, which asks for confirmation first and says how many replies it will post; **Retry with a note…**; **Discard**.
  - A failed fix shows its reason with Retry.
  - **Fix findings now** queues a fix by hand, even with `fix.auto` off or on an approved MR.
- **Overview, menu bar panel and Reviews list:** a ready fix shows like a ready Agent Review, as "Fix ready: 3 threads, 2 changed". The Reviews list row of an own MR gets a Fix badge.
- **Notifications**, as new Alert Templates (editable, in `templates.v1.json`):
  - `alert.fix-ready` (`mr.title`, `fix.threads`)
  - `alert.fix-failed` (`mr.title`, `fix.reason`)
  - `alert.fix-pushed` (`mr.title`), shown only when replies failed
- **Configuration:** a new **Fixes** category with the `fix.*` fields.

### Config

```yaml
fix:
  auto: true            # watch the Owner's MRs and queue fixes by themselves (the Owner asked for the watcher)
  model: …              # optional, same rule as review.model
  effort: medium
  timeoutMinutes: 20
  maxPerDay: 10
```

`config.v1.json`, `config-fields.ts` and the Configuration page are updated with it.

### CLI and contracts

- `suica fix list --json`: open and recent fixes. The new contract `contracts/fixes.v1.json` includes, per fix: id, mrKey, mrTitle, status, detail, threads (id, author, action, reply), commitMessage, diff (ready only), activity, timestamps and pushedSha.
- `suica fix queue <key>`, `confirm <id>` (edits as JSON on stdin), `retry <id>` (note on stdin), `discard <id>`, `cancel <id>` and `replies <id>`. Each prints `{"status": …}`.
- `reviews.v1.json` gets an optional `fix` summary on the Owner's MRs (status and counts).
- Swift: `AgentClient` methods, decoders and `ReviewsTests`-style model tests.

### Logging

Structured events with `id`, `mr_key` and counts, following `agent review *`:

- `agent fix queued`, `started`, `ready`, `failed`, `cancelled`
- `fix pushed` (sha and reply counts)
- `fix push failed` (reason class)
- `mr comment posted`
- `mr merge` (outcome)

Bodies, replies and diffs are never logged.

## Security notes

- Branch names and SSH URLs go through the existing checks (`--branch=`, `SSH_URL`). `HEAD:refs/heads/<source>` is passed as one argument after `--`-safe options.
- Thread ids from the model are only accepted when they are in the fix's own thread list. Reply text is only ever a POST body.
- The model has no shell (claude) or a network-less sandbox (codex). It can only change files in its checkout, and nothing leaves the machine before Confirm.

## Tests

- **`test/agent-fix.test.ts`:**
  - Finding Thread detection: new thread, a reply after the agent's reply, the Owner's own note, resolved, non-resolvable, already handled at that note.
  - One open fix per MR, with threads added to a queued fix.
  - The approved rule, and watching again after a revoked approval.
  - Cancel and discard when the MR closes.
  - Prompt files and JSON parsing, including a missing thread and `changed` with an empty diff.
  - The diff size cap.
- **Confirm:** a moved branch fails without pushing; a rejected push; a partial reply failure, then Post missing replies; `{{sha}}` filled in; "don't post" respected; the checkout deleted.
- **`test/gitlab.test.ts` / new:** `glabPut`, comment and merge outcomes by HTTP status, and `merge_when_pipeline_succeeds` sent only when asked.
- **Config and contract golden tests** for `fix.*`, `fixes.v1.json` and the new `mr-detail` fields.
- **Swift:** decoders, the merge button state for each `detailedMergeStatus`, and the Fix tab model actions.

## Left to the builder

The prompt wording, the exact Copy strings, the layout of the Fix tab and Merge sheet, the store schema and migration, and how the fix worker shares the scheduler with the review worker.
