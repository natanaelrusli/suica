# Menu bar panel motion and re-reviews on open — design

Status: asked by the Owner on 2026-10-22 ("Make the menubar menu opens and closes with smooth animation transition" and "When the app is opened, MR re review not triggered"). The Owner chose, when asked, that opening the app should run due re-reviews right away instead of waiting for the next poll and the `review.rereviewAfterMinutes` wait. Choices marked _my call_ are the builder's.

## Menu bar panel motion

- **What was there.** The `MenuBarExtra` panel (`.window` style) appears and disappears in one frame: its `NSPanel` has `animationBehavior` `.default`, which animates nothing for this panel. Measured in a scratch app that clicks its own status item: with `.utilityWindow` AppKit fades the panel out on close (about 160 ms) but still does nothing on open; `.alertPanel` animates the opening only, with a bounce (about 400 ms); `.documentWindow` animates the closing only.
- **Close.** The panel gets `.utilityWindow`, so AppKit fades it out.
- **Open.** `MenuPanelMotion` sets the panel's `alphaValue` to 0 and animates it to 1 (200 ms ease-out; 120 ms with **Fades only**). It runs when the view first moves into the panel (the first opening) and when the panel becomes key while its occlusion state is not yet visible (each later opening; `isVisible` is already true at that point, so it cannot tell). A panel that becomes key while on screen is left alone.
- **Content.** With full motion the content also drops 8 pt into place (`.smooth`, 300 ms). _My call_: an offset only, no scale, since a scale re-lays out the lists' AppKit views every frame. A `keyframeAnimator` was tried first and left the panel blank; a state-driven offset works.
- **Animation levels.** Full: fade and drop. Fades only: shorter fade, no drop. Off: `animationBehavior` `.none` and no fade.

## Re-reviews on open

- **What was there.** An automatic Agent Re-review is queued by the poll loop once the Author's latest push has stood for `review.rereviewAfterMinutes` (10 by default). Opening the app did not change that: the review requests list said "Auto re-review due at …" and nothing ran until then.
- **Now.** When the app starts, when the window opens and when the menu bar panel opens (after the setup check), the app reads `suica reviews --json` and queues each MR whose `rereviewWaiting.reason` is `waiting` with `suica review queue <key> --auto --json`. MRs held by the daily cap, an approval or a draft stay held, and nothing is queued while setup is needed. Two openings at the same time make one run.
- **`--auto`.** New flag of `suica review queue`: the row is queued with trigger `auto`, so it counts toward `review.maxPerDay`, and the command answers `daily-cap` (exit 1) when the cap is used up. _My call_: the app cannot see the cap while a re-review is still waiting (the reason only becomes `daily-cap` once it is due), so the check sits in the command.
- **Head tracking.** Unchanged: a review queued between polls is seen by the next poll as queued, then ready or posted at the head, and `planRereviews` marks the head as queued, as it does for **Re-review** pressed by hand.
- **Trade-off.** _Accepted by the Owner_: a push followed by more pushes within the wait can be re-reviewed early, at the head the app saw, if the app is opened in between; the later push is then re-reviewed after its own wait.

## Tests

- Swift: `ReviewsModel.runWaitingRereviews` queues only `waiting` MRs, with `--auto`, shows the `daily-cap` outcome, and does nothing when the list cannot be read.
- CLI: `suica review queue --auto` queues an `auto` row and refuses with `daily-cap` once `review.maxPerDay` is reached.
- The panel motion was measured in a scratch `MenuBarExtra` app (alpha over time on first and later openings, captured frames); there is no automated test for it.
