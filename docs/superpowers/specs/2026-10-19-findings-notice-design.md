# Review Notice with Agent Review findings — design

Status: agreed with the Owner in chat on 2026-10-19. Vocabulary is defined in `CONTEXT.md`; this adds no new term. It extends the Review Notice of the main design (`2026-10-14-mr-review-assistant-design.md`).

## Intent

When an Agent Review is posted on someone else's MR, the Owner wants the Author to hear about it in Teams straight away, with how many findings the review has per severity, instead of finding the comments in GitLab by chance. The plain Review Notice already chats the Author after a review, but only after a 10-minute wait, without numbers, and the Owner keeps it in `dry-run`.

## Goals

- One Teams chat to the Author per posted Agent Review, saying how many findings it has per severity, for example "Halo Budi, saya sudah review MR kamu: ada 8 findings (7 Minor, 1 Nit)." with the MR link, or "tidak ada findings".
- Sent without the Owner's approval by default, with its own send mode, so the other Review Notices can stay as they are.
- Sent at the first poll that sees the review's comments, without the Review Notice's debounce.

## Non-goals

- MRs where the Owner is not a Reviewer: the Review Notice never covers them, and neither does this.
- Messages outside working hours: they wait in the queue like every message.
- Listing the findings themselves in Teams. The chat says where to read them.

## Anti-goals (a failure even if it works)

- Two chats to the Author for the same comments (the findings chat and a plain "comments" Review Notice).
- A chat for an Agent Review posted before Suica saw the MR, or before the upgrade to this version.
- A count that includes a finding's own Case and Fix bullets, or notes the review keeps outside its findings ("Outside this diff").

## Decisions

- **A Review Notice variant, not a new kind.** Kind `notice`, variant `notice.findings`, template `notice.findings.txt`. It is still a chat to the Author after the Owner reviewed, so the obsolete check (the MR is still a non-draft Review Request), the Statistics count and the app's grouping under other people's MRs carry over. The send mode is chosen by variant: `teams.modes.findings` (default `auto`, the Owner asked for it to go out directly) for this variant, `teams.modes.notice` for the others.
- **The planner decides, not the post.** `loadTeams` returns the latest posted Agent Review of each MR (`id`, its `updated_at` as the post time, its body). The round of each MR remembers `announcedReview`, the latest review already announced. Only the planner writes rounds, so the post path writes nothing new and no row has two writers.
- **When.** A posted review with an id above `announcedReview` is announced once the Owner's note count has risen above what was last announced (its comments are visible), or once `teams.noticeDebounceMinutes` has passed since the post, should the count never rise (the snapshot reads the last 50 notes only). The same round update sets `noticedNotes` to the current count, so the plain "comments" notice does not follow. `noticedState` is left alone, so a later approval or request for changes still gets its own Review Notice.
- **History is never announced.** A new round starts with `announcedReview` set to the latest posted review. Schema 9 adds `review_round.announced_review` and seeds it the same way for the rounds that already exist, and adds `outbox.findings`.
- **Counting.** `countFindings` in `src/inline-review.ts` counts the items under a heading named Findings, per subheading whose title is one word (`### Minor`, `### Major (2)`). Items under any other subheading are skipped. Only items at the indent of the section's first item count; items reading "None" are skipped; code fences are ignored. Severities are ordered Blocker, Major, Minor, Nit, then others as they appear, then items under no subheading ("tanpa severity"). Checked on the five latest real Agent Reviews: each total matches the review's last finding number.
- **Wording.** `describeFindings` in `src/teams/templates.ts` builds the `{{review.findings}}` value once, when the message is queued, and the outbox keeps it in `findings`. The value is Markdown-safe (severity names are escaped). The placeholder renders empty in the other templates.

## Left to the builder

- The app shows the new template under Configuration → Message templates with its own title and description, and previews `{{review.findings}}` with a sample value.
