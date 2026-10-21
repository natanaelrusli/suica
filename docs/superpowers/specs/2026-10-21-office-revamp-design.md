# Office look after Software Inc. — design

Status: written from the Owner's request on 2026-10-21 ("Revamp the looks of the Office 3D world", referring to the game Software Inc.). Choices marked _my call_ are the builder's. Builds on `2026-10-21-office-building-design.md`, `2026-10-21-office-variety-design.md` and `2026-10-21-office-street-design.md`; vocabulary is in `CONTEXT.md`.

## Look

- **Shadows**: the key light casts soft shadows, so desks, figures, furniture and trees sit on the ground instead of floating.
- **Floors**: project Rooms get warm wooden planks running across the room, every other plank a shade darker; the Center Room gets two-tone carpet tiles in a chequerboard (0.8 m tiles).
- **Walls**: white plaster, a little taller (0.55 m), with the dark cap along the top that Software Inc. uses to show a wall cut away; Room names stand just above the cap.
- **Desks**: a light top on a grey metal frame with a modesty panel, a black-bezelled monitor on a stand, and a keyboard. The chair is an office chair: five spokes on wheels, a column, a padded seat and a low back.
- **Outside**: the building stands on a concrete plinth a step above the lawn, with the path starting at its edge; low clipped hedges run along the back and the sides, never along the street side, so they hide no Desk (_my call_). The lawn is a brighter green by day.
- Dark mode keeps every element, in night tones (_my call_: same structure, darker palette).

Not changed: the layout, Desk placement, figures, furniture kinds, the street and its travellers, the camera and interaction. Wall thickness stays 0.06 m so the furniture clearances in `SuicaCore` still hold (_my call_).

## Tests

Scene-only change (no `SuicaCore` model or layout change), so no new unit tests; `swift test` still passes. The scene was checked by eye with the offscreen render harness in light and dark.
