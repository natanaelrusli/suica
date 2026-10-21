# Office sun and moon — design

Status: written from the Owner's request on 2026-10-21 ("Improve the sun positioning and shine in the 3d office, also make the moon glow"). Choices marked _my call_ are the builder's. Revises the Sky section of `2026-10-21-office-street-design.md`.

## What was wrong

- The sun was a flat yellow sphere with a dull halo sphere around it: RealityKit's tone mapping turned the unlit yellow olive, and the halo was a hard-edged, half-transparent ball rather than a glow.
- It sat near the top centre of the view, where its halo ran off the top edge at the default camera.
- The moon was the same two spheres in grey: no glow at all.

## Now

- The sun and the moon are flat cards (10 m square), fixed in the world 60 m from the default camera, as `2026-10-21-office-street-design.md` asks, and turned to face the camera whenever the view moves. The ground still hides them when the view is turned so ground fills the top. (This branch first carried them on the camera; merged with the world-fixed sun on 2026-10-21.)
- Each card is a texture painted with Core Graphics at launch (512 px, 16 bits per channel so the glow's fade shows no banding, _my call_). Unlit and kept out of tone mapping, so the sun is a bright yellow and the moon a clean white.
  - Sun: a disc, lighter in the middle, in a warm haze that fades into the sky; behind it a second card with twelve rays, long and short alternating, that fade as they reach out.
  - Moon: a pale disc in a cool blue glow.
- The cards sit to the right of centre at the top of the default view (0.4 of the half width, 0.85 of the half height), between the two right-hand trees, with the face clear of them; the page now runs up under the title bar, so the glow's top fades under its vignette (_my call_; the first values, 0.6 and 0.7, hid the face behind a tree once the page grew taller).
- With Appearance → Animation at Full, the rays turn slowly (one turn in about two minutes) and breathe a little (±4 % in size); the moon has no rays. Still otherwise, like the travellers.
- If the texture cannot be painted, the card stays invisible rather than drawing a plain square.

## Not done

- The key light still comes from the upper left of the world while the sun sits at the default view's top right; shadows were left as they were.

## Tests

No logic to unit-test: the change is paint and placement. Checked by eye in light and dark with the offscreen `RealityRenderer` harness; the ray animation runs in the app only and was not captured.
