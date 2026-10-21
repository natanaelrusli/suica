# Office sun and moon — design

Status: written from the Owner's request on 2026-10-21 ("Improve the sun positioning and shine in the 3d office, also make the moon glow"). Choices marked _my call_ are the builder's. Revises the Sky section of `2026-10-21-office-street-design.md`.

## What was wrong

- The sun was a flat yellow sphere with a dull halo sphere around it: RealityKit's tone mapping turned the unlit yellow olive, and the halo was a hard-edged, half-transparent ball rather than a glow.
- It sat near the top centre of the view, where its halo ran off the top edge at the default camera.
- The moon was the same two spheres in grey: no glow at all.

## Now

- The sun and the moon are flat cards (10 m square, 60 m from the camera) carried by the camera, so they face the viewer and stay in the sky however the view is turned. The ground still hides them when the view is turned so ground fills the top.
- Each card is a texture painted with Core Graphics at launch (512 px, 16 bits per channel so the glow's fade shows no banding, _my call_). Unlit and kept out of tone mapping, so the sun is a bright yellow and the moon a clean white.
  - Sun: a disc, lighter in the middle, in a warm haze that fades into the sky; behind it a second card with twelve rays, long and short alternating, that fade as they reach out.
  - Moon: a pale disc in a cool blue glow.
- The cards sit in the top right of the view (0.6 of the half width, 0.7 of the half height): the glow stays clear of the edges, and the face stands above the row of trees (_my call_).
- With Appearance → Animation at Full, the rays turn slowly (one turn in about two minutes) and breathe a little (±4 % in size); the moon has no rays. Still otherwise, like the travellers.
- If the texture cannot be painted, the card stays invisible rather than drawing a plain square.

## Not done

- The key light still comes from the upper left of the world while the sun is pinned to the camera's top right; they cannot agree at every camera angle, so shadows were left as they were.

## Tests

No logic to unit-test: the change is paint and placement. Checked by eye in light and dark with the offscreen `RealityRenderer` harness; the ray animation runs in the app only and was not captured.
