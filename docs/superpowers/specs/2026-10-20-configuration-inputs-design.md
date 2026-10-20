# Configuration page: categories only, fitting inputs and review effort — design

Status: written on 2026-10-20 from the Owner's request to stop repeating every setting on the Configuration page and its category pages, improve the Model CLI choice, the URL, number and time inputs and the dropdowns, and show a slider for the review effort. Choices marked _my call_ are the builder's and can be changed.

## Configuration page

**Configuration** in the sidebar is now an overview: one card per category, in the agent's order, plus **Message templates**. A card names what the category holds and counts its settings, its unsaved edits and its problems; it opens the category's page. A setting is shown only on its category's page. A search typed on any page still looks through every setting and names each group with its category.

Long categories are split into sections (_my call_): Teams into Connection, Send modes, Working hours, Timing and limits, People and wording; Agent Review into Automation, Posting, Skill and model, Limits. The mapping lives in the app (`Copy.configSection`); a field it does not know lands in the category's last section, or in no section for the other categories.

## Field hints from the agent

`config show` gains optional properties on a field, so the app can pick an input without guessing from labels:

- `unit` (int only): what the number counts. `seconds`, `minutes` and `hours` make it a duration; the key's suffix and the unit must agree (a test checks it). Labels lose their "(seconds)" suffix.
- `max` (int only): the schema's cap; only `review.concurrency` (4) has one. Every int is at least 1.
- `format` (string only): `hostname` for `gitlab.hostname`, `path` for the glab executable, the Teams command, the templates folder and the state file.
- type `level`: an `enum` whose options run from least to most, shown as a slider. Only `review.effort` is one.

An older app decodes `level` as an unknown type and shows it read-only; the other properties are ignored by it. The contract stays version 1.

## Review effort

`review.effort` (`low`, `medium`, `high`, `xhigh`, `max`; default `medium`, as it was hard-coded) is passed to Claude Code as `--effort` and to Codex as `model_reasoning_effort`, where `max` becomes `xhigh`, the highest level Codex has. `suica status --json` reports it under `agentReview.effort`, and Overview's Agent Review settings show the same slider, saving that one key.

## Inputs

- **Host**: a fixed `https://` before the box; a pasted URL keeps only its host and port. A button opens `https://<host>` in the browser.
- **Path**: monospaced, left-aligned text, **Choose…** (files and folders, hidden ones shown) writing a `~`-abbreviated path, and **Show in Finder** while the path exists.
- **Duration**: a whole number, a stepper and a unit menu from the key's own unit up to days. It opens in the largest unit that shows the value exactly (120 seconds as 2 minutes); changing the unit keeps the number and changes its meaning (_my call_: "2 seconds" to "2 minutes" is what a unit menu usually does). The file still gets the key's own unit.
- **Other numbers**: a stepper, the unit after the box, and thousands separators while the box is not being edited (in the Mac's number format). A number over `max` is lowered to it; 0 and an empty box are not values and block Save, as before.
- **Small ranges**: `max` of 6 or less is a row of buttons (Reviews at once 1 to 4).
- **Choices**: up to four options the app can name are side-by-side buttons with plain names (Send automatically, Ask me first, Dry run; Wait for me to post, Post automatically; One comment, Inline threads), and a line under them says what the picked one does; the agent's help, which lists the raw values, is then left out. Other choices stay a pop-up menu.
- **Model CLI**: a card each for Auto, Claude Code, Codex and Gemini CLI, saying which is installed and which is in use (from the status document), on Configuration and on Overview.
- **Review model**: a menu beside the box suggests `opus`, `sonnet` and `haiku` while Claude Code reviews.
- **Working hours**: start and end on one row as 24-hour time pickers over a bar of the day, with the length of the day under it and a warning when the start is not before the end. Typed `HH:MM` boxes are gone, so a half-typed time can no longer block Save.

## Sidebar and navigation (follow-up the same day)

- The sidebar's Settings group has Configuration only: no rows under it, and Appearance moved onto the overview as a card next to Message templates. On a category page, Message templates or Appearance the sidebar marks Configuration, a back button in the toolbar returns to the overview, and clicking Configuration does too (its row is already marked, so the click is handled by a tap on the row, as picking it changes no selection).
- Statistics keeps its three pages under it, behind a chevron on its row. The sidebar list's own expanding (an `OutlineGroup` or `DisclosureGroup`) drew the new rows over the ones below while sliding those down, on macOS 26; the pages are now plain indented rows added without the list's animation, each fading in, and the chevron turns. A Statistics page opened from elsewhere opens them.
- The overview's cards are a `Grid` whose rows are as tall as their tallest card (a `LazyVGrid` sized each card to its own text), up to four per row by the page's width.
- The Model CLI cards show the name and the radio mark only, without an icon per CLI.
