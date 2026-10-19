# Agent Re-review — design

Status: agreed with the Owner in chat on 2026-10-19. Vocabulary is defined in `CONTEXT.md`; this document adds one term, **Agent Re-review**. It extends Agent Review (`2026-10-14-mr-review-assistant-design.md`) and the Review Notice with findings (`2026-10-19-findings-notice-design.md`), which must land first: this design reuses its planner path, its `findings` outbox column and `countFindings`.

## Intent

The flow the Owner described: an Author adds the Owner as a Reviewer, Suica writes an Agent Review and it is posted, the Author pushes fixes, and then Suica reviews the MR again on its own and tells the Author in Teams. Today the agent reviews an MR once (or when GitLab asks the Owner again), so the fixes go unchecked until the Owner remembers to press Review again, and the Author hears nothing.

## New term

**Agent Re-review**: an Agent Review of an MR whose previous Agent Review was posted, written after the Author pushed new commits. It reviews the changes since the commit the previous review covered and says, for each finding of the previous review, whether it was fixed. _Avoid_: incremental review, follow-up review. (Add to `CONTEXT.md`, next to Agent Review.)

## Goals

- When the head commit of an MR where the Owner is a Reviewer moves past the commit of its latest posted Agent Review, queue an Agent Re-review once the head has been stable for a while.
- The re-review focuses on the changes since the previously reviewed commit and checks every finding of the previous review (fixed, not fixed, partly fixed).
- Once the re-review is posted, the Author gets one Teams chat that says it is a re-review and how many **new** findings it has per severity.

## Non-goals

- The Owner's own MRs: that is the Re-review Nudge, unchanged.
- Re-reviewing after a previous review the Owner discarded, or one that failed or was skipped. Those keep today's behaviour: the Owner presses Review again.
- Counting or listing the status of the previous findings in Teams. The chat reports new findings only; the status of the earlier ones is in the GitLab comment.
- Changing how a review is posted. `review.post` (`approval` by default) and `review.postAs` apply to re-reviews as they are. With `approval`, the Teams chat goes out only after the Owner posts the re-review.
- Resolving or replying to the previous review's GitLab threads.

## Anti-goals (a failure even if it works)

- Several re-reviews for one burst of pushes.
- Two Teams chats for one re-review, or a plain "comments" Review Notice in addition to the findings one (the guard of the findings notice already covers this; keep it).
- A finding of the previous review counted as a new finding in the Teams chat, or posted again as an inline thread.
- A re-review of commits that were already there when the previous review ran, or a re-review queued for MRs reviewed before this version was installed whose head has not moved since.
- A re-review of a draft.

## Behaviour (decided with the Owner)

1. **Trigger.** For each non-draft MR in `reviewRequested` (the Owner is still a Reviewer), whatever the Owner's own reviewer state. Look at the MR's newest Agent Review row that is `posted` or `discarded`, ignoring rows that are `skipped` or `failed` (my call: a skip such as "this commit was already reviewed" or a passing SSH failure must not switch re-reviews off for good). That row must be `posted` and have a `headSha`, and the MR's current `headSha` must differ from it. The Owner's state does not matter (my call), because GitLab may or may not reset the Owner's approval on a push, and the Owner asked for a re-review after every push.
2. **Debounce.** The new head must have stayed unchanged for `review.rereviewAfterMinutes` (new key, default `10`) before the re-review is queued. Several pushes in a row produce one re-review of the last head. Suica records the head of each review-requested MR and when it last changed; the first sighting of an MR records its current head and announces nothing until it changes.
3. **One per head.** A re-review is queued at most once per head commit, recorded with the head tracking of rule 2 (not derived from the newest row, which rule 1 lets be `skipped` or `failed`). A re-review that fails or is skipped is not retried on its own, as with every automatic review. The Owner can press Review again.
4. **Not while one is open.** Nothing is queued while the MR has a `queued` or `running` review (`queueAgentReview` already refuses). A re-review that is `ready` or `posting` is neither `posted` nor `discarded` yet, so rule 1 still sees the older posted review. Rule 3 keeps that from queueing another for the same head; a later push may queue a re-review against the older posted review (my call: rare, and the Owner then discards whichever is stale). After a discard, rule 1 finds a `discarded` row, so nothing is queued until the Owner presses Review again.
5. **Cap.** Re-reviews are automatic reviews: they need `review.auto: true` and count against `review.maxPerDay`. Initial reviews keep priority: the existing candidates are queued first, then re-reviews, oldest MR first.
6. **Manual Review on a reviewed MR.** When the Owner presses Review on an MR whose rule-1 row was posted at another commit, the run is a re-review too (my call: same prompt and same Teams wording, so the Author is told about it consistently).
7. **"Review requested again" on a reviewed MR.** `queueAutomaticReviews` today queues a review at once when GitLab asks for the Owner's review again (the Owner's state returns to `UNREVIEWED`). GitLab can do that on a push, which would queue a review of an in-between head with no debounce. My call: when rule 1 finds a posted review for the MR, that immediate path is skipped and rule 2 decides. If the head did not move, nothing runs; if it moved, the debounced re-review runs.

## What the agent is given and asked (decided with the Owner)

- **Given:** everything a normal Agent Review gets (checkout at the new head, the full MR diff in `./mr.diff`, `./mr.md`), plus:
  - `./previous-review.md`: the body of the previous posted review, as untrusted data (it is model output and may quote MR content);
  - `./since-last-review.diff`: the diff from the previous review's commit to the new head.
- **Incremental diff source** (my call): GitLab's compare API (`repository/compare?from=<previous head>&to=<new head>`), because the clone is shallow. It is used only when the previous head is an ancestor of the new head. After a rebase or force-push (not an ancestor, or GitLab no longer has the commit), the file is not written, the agent reviews the whole MR, and the prompt tells it to say in its Scope that the incremental diff was unavailable. The previous findings are checked either way.
- **Asked:**
  1. A section headed exactly `## Previous review`, placed before the findings, with one line per open item of the previous review: its severity, location and a short title (not its number: every review numbers from 1), and status `fixed`, `not fixed` or `partly fixed`, with one sentence of evidence. The open items are the previous review's Findings **and** the items its own `## Previous review` section marked `not fixed` or `partly fixed`, so a finding that stays unfixed is carried through a chain of re-reviews until it is fixed (my call). `./previous-review.md` holds only the last posted body. A previous finding that is not fixed stays in this section and is **not** repeated under Findings.
  2. Findings only for problems introduced or still visible in the changes since the previous review, in the skill's normal output template, normal mode.
- **Label.** The GitLab note says it is a re-review and names both commits, along the lines of "> **Agent re-review**: … on commit `abcd1234`, since the review of `ef567890` …". Inline threads use the same "Agent re-review" label.
- **Counting guard.** `extractFindings` and `countFindings` treat any heading containing "findings" as the findings section. The prompt avoids that word in the previous-review heading, and as a defence both functions must also ignore a heading that starts with "Previous" (so a model that writes "Previous findings" anyway does not get its old findings counted or posted as threads).

## Teams chat (decided with the Owner)

- A new Review Notice variant `notice.refindings` with template `notice.refindings.txt`, built in, in Indonesian, editable in **Configuration → Message templates**. Built-in text (my call, Owner can edit): `Halo {{person.name}}, saya sudah review ulang update MR kamu: {{review.findings}}.\n{{mr.link}}\nDetailnya ada di komentar MR.`
- `{{review.findings}}` for this variant reads "ada 2 findings baru (1 Major, 1 Minor)", or "tidak ada findings baru" when there are none. `describeFindings` gains the "baru" form; the value is still built once when the message is queued and kept in `outbox.findings`.
- Everything else is the findings notice as designed: same planner rule (announced when the Owner's comments show, or after `teams.noticeDebounceMinutes`), same `announcedReview` bookkeeping, dedupe key `findings:<review id>`, send mode `teams.modes.findings` (default `auto`), working hours, obsolete check and Statistics count. The planner picks `notice.refindings` instead of `notice.findings` when the posted review is a re-review, so `loadTeams`'s posted-review record needs to say so.

## Constraints

- Everything in the main design still holds: GitLab is written only by posting an approved (or `review.post: auto`) review, templates are never written by a language model, logs carry no names, IDs, titles or review text, a missed message is acceptable and a duplicate is not.
- The poll stays one GraphQL query: `headSha` is already in the snapshot for review-requested MRs.
- New store columns or tables go through a schema migration after schema 9 (findings notice). An existing database must not queue re-reviews for heads that have not moved since the upgrade (rule 2's first sighting covers this).
- Template names, config keys and anything the app decodes are part of the CLI–app contract: update `contracts/*.v1.json`, the Swift decoders and their tests together.
- README (Agent Review section, Teams section, config table), `CONTEXT.md` and the new config key ship in the same change.

## Left to the builder

- Where the head-tracking for review-requested MRs lives (a new table, or columns next to the agent review rows) and how the re-review's link to the previous review is stored (for example a `previous_review` column on `agent_review`).
- How ancestry is checked through the compare API, and what happens when the incremental diff is larger than `review.maxChangedLines` (my suggestion: the existing full-MR size check stays the only gate).
- How the app's review requests page shows a re-review (a label such as "Re-review" is enough).
- Test levels per `madhani-testing-strategy`: the queueing rule and the planner are pure and get unit tests for every rule and anti-goal above; the prompt builder and the heading guard get unit tests.
