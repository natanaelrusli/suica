# Task 2 scoped review fix

Implemented the requested review corrections in `/Users/anb-0826009/.t3/worktrees/suica/t3-2b3ecc28`.

- Replaced `DiffRequest` value equality in the SwiftUI `.task(id:)` path with a per-MR `UInt64` render revision. `ReviewsModel` compares the accepted response's head SHA and diff files once at response acceptance; equal replies retain the revision and local activity changes do not affect it. A same-head, same-length diff edit gets a new revision. Revisions are keyed per MR.
- Kept full content digest identity in `ReviewPresentationCache` and retained the `.task` cancellation check and clearing of prepared lines before fresh preparation.
- Preserved and committed the existing compact Back focus restoration change: defer focus until the list's view task yields, then guard cancellation.
- Added a model regression covering same-head diff changes, unchanged responses and per-key token isolation.

Commit: `6b15afe` (`perf: key diff preparation by accepted render revision`).

Checks: `git diff --check` passed. Tests, builds and linters were not run, as requested by fast-iteration guidance and because no push/MR gate was requested. Runtime profiling and manual keyboard/VoiceOver checks remain outstanding. `docs/review-ui-performance.md` was left untouched and untracked.
