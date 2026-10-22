# Office mouse control — design

Status: written from the Owner's request on 2026-10-22 ("Improve the mouse control in the 3d office scene, right now it seems optimized for trackpad"). Choices marked _my call_ are the builder's. Revises the camera controls of `2026-10-21-virtual-office-design.md`; vocabulary is in `CONTEXT.md`.

## What was wrong

- Sliding the view needed a trackpad (two-finger scroll) or a held ⌥ key: a mouse has neither a second finger nor a reason to reach for the keyboard, and its secondary button did nothing.
- The mouse wheel zoomed by a linear step (5% per unit of delta) that followed the wheel's acceleration unclamped: a slow notch barely moved, a quick spin jumped, and a step in was not undone by the same step out.

## Now

- **Right-drag or middle-drag slides the view** (pans), no modifier needed (_my call_: the secondary button is the one every 3D app on a mouse reaches for; the middle button is for mice whose wheel clicks). A plain drag still turns the view and ⌥-drag still slides it, so the trackpad loses nothing. The drag is read from the window's secondary-button events by the same local event monitor that catches the wheel; it starts only when the pointer is over the scene, keeps going if the pointer leaves it, and never reaches anything behind (the scene has no context menu to lose).
- **The wheel zooms by a symmetric step**: the factor is `exp(gain × delta)` with the delta clamped, so a notch in and a notch out return to the same view and a fast spin stays smooth. A mouse wheel uses gain 0.12 and a clamp of ±3 lines (about 13% per slow notch, at most 43% per event, _my call_); a trackpad's ⌘-scroll uses gain 0.01 and a clamp of ±40 points. Scroll up still brings the view closer. The step lives in `SuicaCore` (`OfficeCamera.zoomFactor`) so it can be tested.
- The hint under the scene and the README name the new controls.

## Not done

- Zooming toward the pointer rather than the centre of the view (_my call_: would need a floor-plane projection of the pointer; the right-drag pan covers the need for now).
- Horizontal wheel (⇧-wheel) turning or sliding the view.

## Tests

`OfficeTests` covers the zoom step: symmetry, direction, the clamp and the two gains. The secondary-button drag is AppKit event handling and is checked in the installed app, not in the harness.
