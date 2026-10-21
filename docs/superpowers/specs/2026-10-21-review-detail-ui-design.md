# MR detail page layout — design

Status: asked by the Owner in chat on 2026-10-21, with a screenshot of the page; the Owner picked every option offered plus "better text and code formatting".

## Intent

Make the MR page under **Review requests** easier to read and less tall above the content.

## Problems seen

- Description, comments and the Agent Review ran the whole width of the window, about 200 characters a line.
- Inline code was the size of the text around it, so a line full of paths read as code.
- The header took four rows (actions, facts, branches, Reviewers) before the tabs, and the reload button looked like an empty pill while the MR loaded, with the spinner at the far edge.
- The tabs were a large segmented control, with counts in brackets.

## Decisions

1. **Readable width.** Description, Comments and Agent review text stop at 780 pt, from the leading edge. Changes and Agent fix keep the full width for diffs.
2. **Text.** Line spacing 3 pt, 10 pt between blocks, headings one step smaller than before (`#` title 3, `##` headline, deeper subheadline) with room above them. Inline code is monospaced at callout size on a light tint. Code blocks are a bordered card with a **Copy** button.
3. **Header.** Title; then key, author and update on the leading side with the actions on the trailing side (`ViewThatFits` puts the actions beneath when the row is too narrow); then one wrapping row of chips: branches, pipeline with an icon, squash, size, labels and Reviewers. Reload shows its spinner in place.
4. **Tab bar.** Text tabs with an accent underline that slides to the one shown, counts as small capsules and a dot when a review or fix waits.
5. **Shrinks on scroll.** Once a tab's scroll view is more than 48 pt down, the header becomes the title on one line plus the actions; it grows back within 4 pt of the top (the gap stops it flickering). Switching tabs grows it back. _My call_: a shared environment binding that each tab's scroll view sets, so the tabs stay independent views.

## Not done

- No syntax highlighting in code blocks, and no image loading (images stay links).
- The MR list on the left is unchanged.
