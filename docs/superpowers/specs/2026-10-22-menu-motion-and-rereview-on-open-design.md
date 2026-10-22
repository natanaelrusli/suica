# Menu bar panel motion and re-reviews on open — design

Status: asked by the Owner on 2026-10-22 ("Make the menubar menu opens and closes with smooth animation transition" and "When the app is opened, MR re review not triggered"). The Owner chose, when asked, that opening the app should run due re-reviews right away instead of waiting for the next poll and the `review.rereviewAfterMinutes` wait. Choices marked _my call_ are the builder's.

## Menu bar panel motion

- **What was there.** The `MenuBarExtra` panel (`.window` style) appears and disappears in one frame: its `NSPanel` has `animationBehavior` `.default`, which animates nothing for this panel. Measured in a scratch app that clicks its own status item: with `.utilityWindow` AppKit fades the panel out on close (about 160 ms) but still does nothing on open; `.alertPanel` animates the opening only, with a bounce (about 400 ms); `.documentWindow` animates the closing only.
- **Revised the same day.** The Owner asked for it smoother, with the panel's background growing out of the menu bar icon and shrinking back into it, not only the content. The first version (a fade plus an 8 pt drop of the content) is replaced by the following.
- **What is scaled.** The panel is drawn by its frame view's layer (the material background and the SwiftUI content together), so that layer is scaled. It is made layer-backed when it has no layer yet (the first opening). _My call_: a layer transform, not an animated window frame, which would lay the lists out again on every frame.
- **Open.** The layer grows from 10% to full size around the middle of the menu bar icon on the panel's top edge, with a spring (stiffness 260, damping 28: settles in about half a second with a barely visible overshoot), and fades in over 180 ms.
- **Close.** SwiftUI hides the panel with `order(.out, relativeTo:)` at once, so the panel's class gets a hook that holds the hide back while the layer shrinks into the icon and fades (220 ms, ease in), then hides it. A reopening during the shrink (`makeKeyAndOrderFront`, hooked too) cancels the hide and grows from where the shrink was.
- **Hooks.** The panel is already wrapped by AppKit's key-value observing subclass, and a further runtime subclass crashed in a scratch app, so the two methods are added to the panel's own SwiftUI class (`MenuBarExtraWindow`), once, calling NSWindow's implementations. Only menu bar panels of this app are affected.
- **Shadow.** The window shadow is drawn for the full-size panel, so it is off while the panel grows or shrinks and comes back once it has settled.
- **Animation levels.** Full: grow and shrink. Fades only: a 150 ms fade in, AppKit's utility-window fade out. Off: shown and hidden at once.

## Re-reviews on open

- **What was there.** An automatic Agent Re-review is queued by the poll loop once the Author's latest push has stood for `review.rereviewAfterMinutes` (10 by default). Opening the app did not change that: the review requests list said "Auto re-review due at …" and nothing ran until then.
- **Now.** When the app starts, when the window opens and when the menu bar panel opens (after the setup check), the app reads `suica reviews --json` and queues each MR whose `rereviewWaiting.reason` is `waiting` with `suica review queue <key> --auto --json`. MRs held by the daily cap, an approval or a draft stay held, and nothing is queued while setup is needed. Two openings at the same time make one run.
- **`--auto`.** New flag of `suica review queue`: the row is queued with trigger `auto`, so it counts toward `review.maxPerDay`, and the command answers `daily-cap` (exit 1) when the cap is used up. _My call_: the app cannot see the cap while a re-review is still waiting (the reason only becomes `daily-cap` once it is due), so the check sits in the command.
- **Head tracking.** Unchanged: a review queued between polls is seen by the next poll as queued, then ready or posted at the head, and `planRereviews` marks the head as queued, as it does for **Re-review** pressed by hand.
- **Trade-off.** _Accepted by the Owner_: a push followed by more pushes within the wait can be re-reviewed early, at the head the app saw, if the app is opened in between; the later push is then re-reviewed after its own wait.

## Tests

- Swift: `ReviewsModel.runWaitingRereviews` queues only `waiting` MRs, with `--auto`, shows the `daily-cap` outcome, and does nothing when the list cannot be read.
- CLI: `suica review queue --auto` queues an `auto` row and refuses with `daily-cap` once `review.maxPerDay` is reached.
- The panel motion was measured in a scratch `MenuBarExtra` app that clicks its own status item: the layer's scale, offset and opacity over time on the first opening, a later opening, a close and a reopening during the shrink, with captured frames. There is no automated test for it.
