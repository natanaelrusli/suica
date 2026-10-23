# My MRs filters

## Goal

Narrow My MRs to the MRs you care about right now: unapproved or approved, by head pipeline
(passed, running, failed), and by repository, with a search over the repositories.

## Behaviour

- A **Filter** button over the list opens a popover with three groups: Approval (Unapproved,
  Approved), Pipeline (Passed, Running, Failed) and Repository (a search field over checkboxes).
- Choices in one group widen the list (Passed or Failed); groups narrow each other (Unapproved and
  Passed). A group with nothing chosen lets every MR through (my call: the usual faceted filter).
- Approved means every Reviewer approved (`approvedByAll`), the same as the row's green approval
  count; an MR without Reviewers counts as unapproved.
- Pipeline states follow the row's pipeline mark: SUCCESS is passed, FAILED is failed, and the
  states the app already treats as running are running. An MR without a pipeline matches none.
- A repository is the MR key's project path (`group/project` in `group/project!12`).
- Each choice shows how many of your MRs it matches on its own. The toolbar search applies on top.
- While filters are on, the bar shows "N of M" and **Clear filters**; the button says how many
  choices are on.
- The filters live on `ReviewsModel` for as long as the app runs, so they survive switching pages
  (my call: not saved across launches, so a forgotten filter never hides an MR the next day).

## How

Client side only: the list the app already reads has the approvals, pipeline and key, so the CLI
and `contracts/reviews.v1.json` do not change. `MyMRFilter` in SuicaCore holds the choices and the
matching; `MyMRFilterViews.swift` draws the bar and the popover.
