# Re-review approval, stale reviews in the list, and the agent's name — design

Status: written from the Owner's request on 2026-10-20 ("focus on functionality"); the Owner was not available for questions, so every choice below marked _my call_ is the builder's and can be changed. Vocabulary is in `CONTEXT.md`. It extends Agent Re-review (`2026-10-19-agent-rereview-design.md`) and the Review Notice with findings (`2026-10-19-findings-notice-design.md`).

## Intent

The Owner asked for three things:

1. When an MR the agent reviewed is updated, the agent reviews it again on its own; when the re-review finds nothing, it approves the MR and tells the Author in Teams; when it finds something, it tells the Author too.
2. The review requests list marks an MR whose Agent Review was posted and which has changed since (code or description) without a newer review, and offers a **Re-review** button on the row.
3. The agent has a name, so its Teams chats say who is writing ("Hello, I am Bahlil").

Most of item 1 exists: a push to an MR with a posted Agent Review queues an Agent Re-review once the head has settled, and the posted re-review is announced to the Author with its new findings (`notice.refindings`). What is new is the approval and its Teams wording, the description as a kind of update, the list marking, and the name.

## Goals

- A posted Agent Re-review that is **clean** approves the MR as the Owner at the reviewed commit, and the Author's Teams chat says so.
- A posted Agent Re-review with findings keeps today's chat (new findings per severity).
- The list says which MRs changed since the agent's posted review, how (code, description or both), and queues a re-review from the row.
- A description-only change can be re-reviewed: the run is not skipped as "already reviewed".
- Every built-in Teams template introduces the agent by name.

## Non-goals

- Approving after a first Agent Review, however clean (_my call_: the Owner asked for it after an update; a first review with no findings on code nobody checked is a different decision).
- Requesting changes, merging, or resolving threads on GitLab.
- Automatic re-review on a description-only change (_my call_: the badge and the button cover it; a push keeps the existing automatic re-review). Can be added later by folding the description into the head tracking.
- Naming the agent in the GitLab note label (it already says a language model wrote it).
- A toggle for the approval on the Overview card; the key is edited under Configuration.

## Anti-goals (a failure even if it works)

- Approving an MR whose source branch moved after the review (the approval is tied to the reviewed commit; GitLab's 409 is honoured).
- Approving when a previous finding is still open, even with no new findings.
- Two Teams chats for one re-review (the approval chat and a plain "approved" Review Notice).
- Marking every reviewed MR as changed after the upgrade, because old rows lack a description hash.
- A re-review queued by hand for a description change being skipped as "this commit was already reviewed".

## Behaviour

### Approval (item 1)

1. **Switch.** `review.approve` (new key, boolean, default `false`, _my call_: approving on GitLab as the Owner is outward-facing, so it is opt-in; the README says so in the Agent Review section). The approval needs nothing else: with `review.post: approval` it follows the Owner's **Post to GitLab…**; with `review.post: auto` the whole chain is automatic.
2. **When.** Right after a review is posted (`postAgentReview` returns `posted`), when the review is a re-review (`previousSha` set) and clean. Not for a first review.
3. **Clean** means: `countFindings` totals zero, and the `## Previous review` section has no open item. An item is open unless its text says it is fixed and does not say not fixed, partly fixed, partially fixed or unfixed (_my call_: conservative, since the wording comes from a model; an item without the word "fixed" counts as open).
4. **How.** `approveMergeRequest(key, headSha)` as the Owner. `approved` is recorded on the review row; `head-changed`, `failed` and `bad-request` leave it unapproved and write one sentence in the row's `detail` ("Not approved: the source branch moved" and so on). No retry; the Owner can approve from the MR page.
5. **Notification.** The macOS notification after an automatic post says "sudah diposting ke GitLab dan di-approve" when approved.
6. **Teams.** The findings notice planner picks `notice.reapproved` (new template, `teams.modes.findings` mode, same timing, same `announcedReview` bookkeeping) when the posted review is approved, else `notice.refindings`/`notice.findings` as today. The round's `noticedState` is set to `APPROVED` at the same time, so the plain `notice.approved` does not follow. Built-in text (_my call_): `Halo {{person.name}}, saya {{agent.name}}, agen review-nya {{owner.name}}. Saya sudah review ulang update MR kamu: {{review.findings}}, jadi MR-nya sudah saya approve.\n{{mr.link}}`.

### Changed since the review (item 2)

1. **Description hash.** The snapshot fetches `description` for each MR and keeps `descriptionSha` (SHA-256 hex of the text, empty text included) on `MergeRequest`; the text itself is not kept. A review row records `descriptionSha` when it reaches ready, next to `headSha`.
2. **The list.** `suica reviews --json` adds `changedSinceReview` to each MR: `null`, or `{ "code": boolean, "description": boolean }` with at least one true. It is set when the MR's newest posted-or-discarded Agent Review is posted (the same base rule as the automatic re-review), the MR's head or description hash differs from that review's, and the MR has no open review (queued, running, ready or posting). A row whose newest review failed or was skipped after the posted one still shows it, so the button is the way to retry. A base row without a description hash (reviewed before this version) compares the head only.
3. **The app.** The row shows a badge "Changed since the agent's review: code / description / code and description" and a **Re-review** button that queues a review by hand (the existing `suica review queue`); the button is hidden while a review is open, as **Review again** is.
4. **Not skipped.** The run's "this commit was already reviewed" skip compares the description hash too: a ready, posting or posted review at the same head with the same hash (or no hash, for old rows) skips the run; a different hash runs. The run is a re-review when the previous posted review's head or hash differs; with the same head no incremental diff is fetched and the prompt says the code did not change and only the description did.

### The agent's name (item 3)

1. **Key.** `teams.agentName` (new key, string, default `Suica`).
2. **Placeholder.** `{{agent.name}}`, escaped like `owner.name`, in every template; the app's preview shows it with a sample value.
3. **Built-in templates.** Every built-in template starts with `Halo {{person.name}}, saya {{agent.name}}, agen review-nya {{owner.name}}.` followed by today's text (first letter capitalised). A template file in the templates folder is untouched, so an Owner who edited one keeps it.

## Constraints

- Everything in the main design still holds: GitLab is written only by posting a review (now also by approving after a clean re-review, when `review.approve` is on), templates are never written by a language model, logs carry no names, IDs, titles or review text.
- Schema 11 adds `agent_review.description_sha` (TEXT, null on old rows) and `agent_review.approved` (INTEGER, 0 on old rows).
- Contracts (`reviews.v1.json`, `templates.v1.json`, `config.v1.json`), the Swift decoders and their tests change together.
- README (line 5, config table, Agent Review, Teams) and `CONTEXT.md` (Review Notice) ship in the same change.

## Left to the builder

- Where the clean check lives (next to `countFindings` in `src/inline-review.ts` is the natural place).
- The exact wording of the badge and the `detail` sentences.
- Test levels per `madhani-testing-strategy`: the clean check, the list marking and the planner variant are pure and get unit tests; the approval after a post and the description-aware skip get integration tests on the in-memory store with a fake GitLab.
