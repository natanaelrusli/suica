# Re-review Nudge — design

Status: agreed with the Owner in chat on 2026-10-19. Vocabulary is defined in `CONTEXT.md`; this document adds one term, **Re-review Nudge**, and otherwise uses the existing ones. It extends the main design (`2026-10-14-mr-review-assistant-design.md`).

## Intent

The Owner opens an MR, a Reviewer reviews it (approves, requests changes or comments), the Owner pushes fixes. Today nothing tells the Reviewer the MR changed unless the Owner remembers to chat them or presses GitLab's re-request button. The Owner wants Suica to notice the push and offer, with a macOS notification on the Owner's Mac, to send that Reviewer a Teams chat asking them to look again. The Reviewer sees Teams' own notification; nothing runs on the Reviewer's machine.

## New term

**Re-review Nudge**: a Teams chat from the Owner to a Reviewer of the Owner's own MR who had already reviewed it, sent after the Owner pushed new commits, asking them to review again. _Avoid_: re-request, follow-up. (Add to `CONTEXT.md`.)

## Goals

- Detect new commits on the Owner's non-draft MRs that arrived after a Reviewer's review.
- Hold a Re-review Nudge per such Reviewer as a Pending Message and tell the Owner with a macOS notification.
- Clicking the notification opens Suica on that message, where the Owner sends or skips it as with any Pending Message.

## Non-goals

- Pressing GitLab's re-request button or changing anything in GitLab. The nudge is only the Teams chat.
- Notifying the Reviewer through Suica. They get Teams' own notification.
- macOS notifications for the other held messages (nudge, reminder, notice). They keep the menu bar badge only.
- A reminder after a Re-review Nudge.

## Anti-goals (a failure even if it works)

- Two Re-review Nudges to the same Reviewer for the same round of fixes.
- One notification per push when the Owner pushes several times in a row.
- A nudge for commits that were already there when Suica first saw the MR, or when Teams was switched on (history is never announced).
- A Re-review Nudge sent without the Owner's approval while the mode is the default.

## Behaviour (decided with the Owner)

1. **Who**: every Reviewer of the Owner's non-draft MR who has reviewed it, excluding the Owner. "Has reviewed" means their GitLab state is anything other than `UNREVIEWED` (approved, requested changes, reviewed, unapproved, …) **or** they left at least one non-system note on the MR. Approvers are included: the Owner asked for that. Comment-only Reviewers (notes without submitting a review, so still `UNREVIEWED`) are included (my call).
2. **When**: the MR's head commit changed after that Reviewer's review, and has then been stable for `teams.rereviewAfterMinutes` (default `10`). Several pushes in a row produce one nudge.
3. **One per round**: after a Re-review Nudge is queued for a Reviewer, the next one for that Reviewer on that MR needs the Reviewer to review again first, then another push. "Reviewed again" means a new non-system note by them, or a state change *to* a review state (`APPROVED`, `REQUESTED_CHANGES`, `REVIEWED` or any other state except `UNREVIEWED` and `UNAPPROVED`). A state change *to* `UNAPPROVED` or `UNREVIEWED` is not review activity: GitLab can reset approvals or reviewer states when the Owner pushes, and that must not swallow the nudge (my call).
3a. **Drafts**: the ledger keeps its rows while the MR is a draft. No nudge is queued while it is a draft; when it is marked ready, a Reviewer whose review predates the current head is nudged after the debounce, as if the pushes had just happened (my call).
4. **Approval by default**: the flow has its own send mode `teams.modes.rereview`, default `approval`, also `auto` and `dry-run`, like the other flows. Working hours, identity resolution, at-most-once delivery, `suica send/skip/retry` all apply unchanged.
5. **Notification to the Owner**: when Re-review Nudges move to `pending` (that is, in working hours and in `approval` mode), one macOS notification per MR, in Indonesian like the other notifications, naming the MR and the Reviewers. Title along the lines of "Minta review ulang?", body along the lines of "Kamu push ke <MR title> setelah <names> review. Kirim pesan Teams?". No notification in `auto` or `dry-run` mode.
6. **Click-through**: with `terminal-notifier`, clicking opens Suica's window on **Messages → Your MRs** with that message selected. Without it (osascript), the notification is not clickable, as today; the badge still shows the message.
7. **Template**: a new template `rereview.txt`, built in in Indonesian, editable in **Configuration → Message templates** like the others, with the same placeholders. Built-in text (my call, Owner can edit): `Halo {{person.name}}, MR ini sudah saya update sesuai review-mu. Boleh minta tolong dicek lagi?\n{{mr.link}}\nTerima kasih!`
8. **Obsolete**: a Re-review Nudge waiting to be sent is skipped as `obsolete` when the MR is gone, merged, closed or a draft, the Reviewer was removed, or the Reviewer reviewed again (rule 3) since it was queued.
8a. **No double message**: a Reviewer never gets both a Reviewer Nudge and a Re-review Nudge for the same head. When a Reviewer who had reviewed drops to `UNREVIEWED` in the same poll the head changed (a reset caused by the push), it is a Re-review Nudge and the existing Reviewer Nudge is not queued. When the drop to `UNREVIEWED` happens without a head change (the Owner pressed GitLab's re-request), the existing Reviewer Nudge is queued as today and any waiting Re-review Nudge for that Reviewer becomes obsolete (my call).
9. **App**: Messages lists Re-review Nudges under **Your MRs** with their own label (e.g. "Re-review"). Statistics counts them with nudges and reminders sent unless that is awkward; then as their own figure (builder's call).

## Constraints

- Follows every rule in the main design: GitLab read-only for this flow, templates never written by a language model, state written before sending, a missed nudge is acceptable and a duplicate is not, logs carry no names, IDs or MR titles.
- The poll stays one GraphQL query: the head commit comes from adding `diffHeadSha` to `MrFields`, not from extra calls.
- Re-review Nudges do not count against `teams.maxMessagesPerReviewer`, and the existing nudge/reminder logic is unchanged except for rule 8a.
- A baseline rule like the existing ledger: the first time Suica (with Teams on) sees an MR or Reviewer, it records the current head as "already seen" and announces nothing.
- Outbox kinds, template names and config keys are part of the CLI–app contract: update `contracts/*.v1.json`, the Swift decoders and their tests together.
- README (Teams section, config table, app sections) and `CONTEXT.md` ship in the same change.

## How detection works (my call; builder may refine)

Per Owner MR (drafts included): the current head SHA and when it last changed. Per Reviewer on that MR: the head SHA at their latest review activity (`reviewedAt`, null while they have not reviewed), the last seen state and count of their non-system notes (to detect new activity per rule 3), and whether a Re-review Nudge was queued since their latest activity (`nudged`). A Reviewer gets an intent when: live (both baselines done), MR not a draft, they have reviewed (rule 1), head ≠ `reviewedAt`, not `nudged`, and head unchanged for the debounce. Dedupe key `rereview:<reviewerKey>:<head sha>`. New review activity moves `reviewedAt` to the current head and clears `nudged`. Rows for MRs or Reviewers that disappear from the open authored MRs are deleted.

Known imprecision, accepted: a rebase or a merge of the target branch also changes the head and counts as a push; the 50-note window can miss a Reviewer's comment on a very busy MR.

## App click-through (my call)

Register a `suica://` URL scheme in `macos/Info.plist.template`. The notifier passes `-open suica://message/<outbox id>` for a single message, or a URL to Messages → Your MRs for several. The app handles the URL by opening the window (as **Open Suica…** does), switching to Messages → Your MRs and selecting the row if it still exists.

## Left to the builder

- Store schema for the new ledger (a migration bumping the schema version, following the existing pattern).
- Exact notification wording within the lines above, and where in the poll cycle the notification is sent (after dispatch; a notification failure is logged and never undoes or repeats the message).
- Label text in the app, and the Statistics treatment (point 9).
- Test levels per `madhani-testing-strategy`: the planner is pure and gets unit tests for every rule above, including the anti-goals.
