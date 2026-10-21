# Office street outside — design

Status: written from the Owner's request on 2026-10-21 ("Make the building have environment outside of the office building, like having road, sun, people walking by, bicycle and cars"). Choices marked _my call_ are the builder's. Builds on `2026-10-21-office-variety-design.md`; vocabulary is in `CONTEXT.md`.

## Layout

- The street runs along the building's front (south, toward the default camera), laid out from the Office's size by `OfficeStreet` (in `SuicaCore`): a 1.4 m pavement 0.4 m from the front wall, a 4 m road (two car lanes, a 0.6 m bike lane each side, a dashed centre line), and a far pavement. It runs 12 m past each side of the building (_my call_).
- A lawn under it all, with a row of trees behind the building and trees and street lamps (alternating every 4 m) along the far edge of the far pavement. Nothing tall stands between the building and the road, so no Desk is hidden from the default camera (_my call_).
- A short path leads from the middle of the front wall to the pavement.

## Travellers

- Four cars (two per lane, the near lane westbound, the far one eastbound), a cyclist in each bike lane, and nine walkers on the pavements, keeping to their right half for their direction. Colours are seeded (`OfficeSeed("street")`), so the street looks the same each launch.
- Travellers on one line move at one speed and are spaced evenly, so they never run into each other; each wraps from one end of the street to the other (_my call_: a pop 12 m past the building is mostly off screen at the default zoom).
- Walkers swing arms and legs, cyclists pedal, wheels turn. Everything stands still when Appearance → Animation is not Full, like the bobbing figures.

## Sky

- The page paints a sky colour behind the scene (pale blue; night blue in dark mode). The lawn behind the building is short, so a strip of sky shows at the top of the default view.
- The sun (a pale moon in dark mode) is carried by the camera, at the top of the view, 60 m away: it always appears in the sky, and when the view is turned so ground fills the top, the ground hides it (_my call_: a world-fixed sun was off screen at the default angle, the camera looking down at 38°).
- Option-drag and two-finger scrolling can slide the view as far as the far pavement.

## Tests

`OfficeStreetTests`: the street lies in front of the building with walkers on pavements and vehicles on the road; it is the same each time; travellers stay on the street and come back after one lap; cars in one lane never meet. The scene was checked by eye in light, dark and a turned view with an offscreen `RealityRenderer` harness (the screen could not be captured at the time).
