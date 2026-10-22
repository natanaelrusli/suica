# MR detail fits a narrow window on both pages

## Problem

On **My MRs**, the selected MR's actions (Merge…, Fix findings now, Unwatch, Fix pipeline, Close MR…, Message on Teams…, Open in GitLab, reload) ran past the right edge in a 1100 pt window with the sidebar open, and dragged the chips and the pipeline strip (with Show jobs) with them. **Merge requests** fit at that width, but broke the same way at 800 pt.

## Cause

Both pages already use one view, `MergeRequestDetailView`. Only its actions and tabs depend on the page (`yours`). The action row was a `.fixedSize()` `HStack`, so it never got narrower than all its buttons in one line. Once it no longer fit beside the facts, the stacked fallback was just as wide. My MRs has twice as many buttons, so it hit that at a much wider window. The long branch chip in `FlowRow` and the four tabs did the same at about 800 pt.

## Change

- The actions are a `FlowRow` and wrap onto more lines. They stay on one line beside the facts while they fit, and beside the collapsed title while it keeps 160 pt (my call). Otherwise they go under the title.
- `FlowRow` cuts a child wider than the row to the row's width. It caps only the width, with `lineLimit(1)` on the chips and actions, so the branch chip truncates in the middle. Asking the child for its size at the narrower width made text wrap letter by letter under the parent's zero-width probe, and the page header grew taller than the window.
- The tab bar scrolls sideways when the tabs do not fit. The horizontal `ScrollView` is pinned to its content's height, because otherwise it takes height from the page.

## Not changed

`PipelineProgressView` is unchanged; a sibling branch (pipeline jobs scroll) is editing it. At a page of about 280 pt, its one-line summary truncates every part to a few letters.
