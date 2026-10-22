# Merge requests, My MRs, Teams messages from an MR, pipeline progress

Status: built from the Owner's request on 2026-10-22: "Add more category in Review requests: Reviewed and Approved; re label review requests to Merge requests; move My MR to its own separate menu; can trigger teams message from either My MR or other's MR menu; show pipeline progress in the MR detail." Choices marked _my call_ are the builder's.

## Pages

- **Review requests** is now **Merge requests**. Its tabs are the MRs where the Owner is a Reviewer: **Waiting** (Owner's state UNREVIEWED, not a draft), **Reviewed** (any other state but APPROVED), **Approved** (the Owner approved) and **Drafts**. "Reviewed" existed before and held approved MRs too; Approved is split out of it. Without `me` (an older agent) there is one **All** tab.
- **My MRs** is its own sidebar row under Merge requests, with the Owner's open MRs (what the Yours tab held), no tabs and its own search prompt.
- Both pages share one `ReviewsModel` and one selection (_my call_: the MR detail cache, the refresh loop and Overview's links stay as they were). `ReviewsModel.show(scope)` keeps the selection when the page lists it and otherwise selects the page's first MR; a refresh with nothing selected selects the first MR of the page on screen. A page never shows the other page's MR on its right.
- The Go menu keeps ⌘1 to ⌘0 for the existing sections; My MRs takes **⇧⌘2**, beside Merge requests' ⌘2, and is listed after it (_my call_: renumbering would move every shortcut the Owner already knows).
- Overview's **Your MRs** tile and its MR rows open the page that lists the MR.
- The Overview tally keeps counting approved MRs as reviewed ("3 reviewed"): it is a summary, not the tabs.

## Teams message from an MR

- **Message on Teams…** on every MR page opens a sheet: **To** (on your MR its Reviewers; on another's its Author first, then the other Reviewers; never the Owner), **Start from** (your MR: nudge, reminder, rereview; another's: notice.comments, notice.changes, notice.approved), the text, a Teams preview, and **Send**.
- The default template follows the state (_my call_): on your MR a Reviewer still UNREVIEWED gets the review request, anyone else the re-review request; on another's MR the notice matching the Owner's own review (approved, changes requested, else comments).
- The agent drafts the text from the real template, so variants, escaping, `{{agent.name}}` and `{{time.greeting}}` are what a planned message would have. Picking another recipient or template drafts again and replaces the text.
- **Send** sends the text as shown, at once: outside working hours too and whatever the flow's mode (_my call_: the Owner pressing Send is the approval those rules wait for).
- The message is an outbox row like any other (kind from the template, `approved`, dedupe key `manual:<key>:<username>:<ms>`), so it shows in Messages and counts in Statistics. It is never skipped as obsolete: the obsolescence checks protect planned messages from being sent late, and a message sent by hand is wanted as it is. When Teams cannot be reached it stays `pending` and Messages offers **Send** again.
- No ledger change (_my call_): a message by hand does not count towards `teams.maxMessagesPerReviewer` and does not stop a planned nudge or reminder.
- The recipient is checked against the MR on GitLab, never taken on trust from the request.

### CLI

`suica message <key> --json` reads `{"to": "<username>", "template": "<Teams template name>", "text": "<string>" | null, "send": true | false}` on stdin (text at most 4,000 characters; blank means none).

- `send: false`: `{"status": "draft", "text": "…"}`, the template's text; nothing is stored or sent.
- `send: true`: sends `text`, else the template's text, and prints `{"status": …}`: `sent`, `unresolved`, `lookup-error`, `failed`, `retry-later` or `busy`, as `suica send` does.
- Refusals: `bad-request` (malformed request or key), `bad-recipient` (not the Author or a Reviewer, or the Owner), `teams-off`, `failed` with a `message` (GitLab could not be read, a broken template).

## Pipeline progress

- `suica mr <key> --json` gains `pipeline`: `{iid, status, url, startedAt, finishedAt, stages: [{name, status, jobs: [{name, status, allowFailure, url, startedAt, finishedAt}]}]}` or null, from GitLab's head pipeline stages and jobs. A retried job's earlier runs are left out. Stage statuses are upper-cased like job statuses. `pipelineStatus` stays. The contract stays version 1: the field is an addition and the app reads its absence as no pipeline detail (then it shows the old badge).
- The MR page shows a strip under the chips: state, "n of m jobs done", the current stage, the run time (ticking while it runs) or how long it took, a bar with one segment per stage sized by its jobs and filled as they finish, and **Show jobs** with each stage's jobs, their state, time and GitLab link. A failed job that may fail is orange and marked "allowed to fail".
- Done counts SUCCESS, FAILED and CANCELED; manual, skipped and created-but-never-run jobs are left out of both counts unless they are active, so a passed pipeline with a manual deploy reads as complete (_my call_).
- While the selected MR's pipeline is active, the page refreshes every 10 seconds instead of 30 (_my call_).

## Not done

- No badge on the My MRs sidebar row, no My MRs choice for "Open the window on" in Appearance, no tabs inside My MRs, no free-form message without a template. None was asked for.
- No live job log in the app; **Show jobs** links to GitLab.

## Tests

- Node: pipeline stages and jobs in the MR detail golden (retried run left out, links on the MR's host); `parseMessageRequest`, `kindOf`, `fetchMessageContext` (Author, Reviewer, outsider, Owner, missing MR); `draftManual`; `sendManual` sends outside hours in approval mode and records an approved sent row; a manual row left pending is not skipped as obsolete.
- Swift: tabs with Approved, grouping and search; `show(scope)` and the scope-aware first selection; pipeline decoding, progress and current stage; refresh every 10 s while a pipeline runs; Teams message request encoding (null text), draft, send and failure; recipients and default templates on your MR and another's.
