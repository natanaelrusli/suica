# Office street lamps that light the street — design

Status: written from the Owner's request on 2026-10-21 ("Make the street light in 3d office to have actual glow and lighting, the other 3d object should also respond to the light"). Choices marked _my call_ are the builder's. Revises the street lamps of `2026-10-21-office-street-design.md`.

## What was wrong

- A street lamp's head was a plain unlit box in the glow colour: it lit nothing, threw no shadow and had no glow round it.

## Now

- The lamps are lit at night only (dark mode), like real street lamps; by day they look as before, with a pale lens (_my call_).
- Each lamp head is a dark metal housing with a glowing lens under it, unlit and kept out of tone mapping at night so it stays a bright warm yellow.
- At night each lamp carries a RealityKit spot light under its head, aimed down and a little out over the road (warm, 45° inner and 110° outer cone, 12 m reach), with shadows. Everything with a lit material answers it: the pavement, the road and its markings, the trees beside it, and the walkers, cyclists and cars passing under it, which cast shadows across the pool of light.
- Round each lit head is a soft warm haze: a 1.6 m card painted with a radial fade (16 bits per channel, like the sun and the moon), turned to face the camera whenever the view moves. It writes no depth, so its clear rim hides nothing behind it.
- At night the key and fill lights become a cool moonlight at about 60 % of the daylight intensity (2,200 and 900 rather than 3,800 and 1,500), so the pools of lamplight show while the Rooms and Desks stay readable (_my call_).
- Every lamp gets its light, however wide the street: a 45 m-wide office (eight lamps) rendered with every pool lit, so no cap on the number of lights is needed.

## Not done

- The floor lamps inside the Rooms and the cars' headlights stay unlit glow: lighting them too would add a light per Room and per car.
- At the default camera the lamps stand just below the bottom edge of the view; their pools show at the bottom edge, and turning or panning the view brings them into sight. The lamps were not moved.

## Tests

No logic to unit-test: the change is lights, paint and placement. Checked by eye in light and dark with the offscreen `RealityRenderer` harness, from the default view, looking down the street from the building's side, and on a 45 m-wide office. The harness's lighting is a little flatter than the app's, and its frames are still, so the shadows of passing travellers were seen in a still frame only.
