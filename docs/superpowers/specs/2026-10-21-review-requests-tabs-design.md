# Review requests in tabs

## Problem

The review requests list stacked **Your MRs**, **Waiting for you**, **You reviewed** and **Drafts** in one scrolling list. A long category (your own MRs, say) pushed the others out of view.

## Design

A segmented tab bar sits above the list: **Yours**, **Waiting**, **Reviewed**, **Drafts**, each with its count. The list below shows only the selected tab's rows.

- **Counts follow the search.** While searching, each tab counts its matches, so the tab holding a hit is visible without opening them. Search never moves an MR to another tab.
- **Selection and tab stay together.** Switching tabs selects the tab's first MR (nothing when it is empty). An MR selected from outside the list (Overview, a refresh that drops the selected MR) switches to the tab that holds it.
- **Empty tabs stay.** The tabs are always the same four, so they do not move; an empty tab says what it means ("Nothing is waiting for your review.").
- **Without `me`** (an older agent) the MRs you review cannot be told apart: tabs are **Yours** and **All**.
- **Opens on Waiting** (my call): it is where the first selected MR is, and what the menu bar badge counts.
- **"Yours" instead of "Your MRs"** (my call): four labels with counts only fit the 300 pt list in the small control size with short titles. The longer names are the tabs' help text.

## Code

`ReviewTab`, `ReviewListDocument.tabs`, `keys(in:matching:)` and `tab(containing:)` in `SuicaCore` hold the logic (tested in `ReviewsTests`); `ReviewsView` only draws it. The contract and the agent are unchanged.
