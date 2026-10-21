# Office figures and furniture — design

Status: written from the Owner's request on 2026-10-21 ("Add more variations of the employees: shirt, hair, color, etc."; "Add random furniture on each rooms"). Choices marked _my call_ are the builder's. Builds on `2026-10-21-office-building-design.md`; vocabulary is in `CONTEXT.md`.

## Figures

- Each Session's figure gets a **look** (`OfficeLook`, in `SuicaCore`): skin tone (6), hair style (bald, short, long, bun, ponytail, spiky, backwards cap), hair colour (8, two of them dyed), shirt style (tee, stripe, hoodie, collar), trousers (5) and an extra (none half the time, else glasses or headphones). The figure is seated: legs, arms reaching to the desk, hands, eyes.
- The look is picked from the Session's id with a seeded generator (FNV-1a seed, SplitMix64), not Swift's `Hasher`, which changes per launch: a figure keeps its look across polls and app launches (_my call_).
- The shirt stays a shade of the agent's colour (darker, as is, lighter, lightest), so the agent type still reads at a glance; only the shade varies (_my call_: the agent colour is the Office's legend).
- Idle and exited figures are greyed part by part, keeping each part's lightness, instead of one flat grey, so a greyed figure still looks like itself (_my call_).

## Furniture

- Every room, the Center Room included, gets furniture from ten kinds: plant, small tree, bookshelf, cabinet, water cooler, floor lamp, whiteboard, armchair, bean bag, bin. Low-poly geometry built in code, as the rest of the scene; some kinds come in a few colours.
- Pieces stand against the west and east walls, where Desks never stand, with their backs to the wall: in the corners (one corner may stay empty) and, in a room deep enough, half the time between them. Every piece fits in a 0.8 m square, clear of Desks, chairs and the doorway.
- Tall kinds (tree, bookshelf, water cooler, lamp, whiteboard) only go in the back half of a room, so they never hide a Desk from the default camera (_my call_).
- The near west corner stays empty in every room: the room's name stands on that wall (on the Center Room's floor), and a piece behind it made the name hard to read (_my call_, seen in the harness).
- The choice is seeded by the room's path, so a room keeps its furniture while its size stays the same; when a Room grows or shrinks, its pieces are placed again from the same seed (_my call_).

## Tests

`OfficeTests`: a look is stable per Session id and looks vary across Sessions; a shirt keeps its agent's hue; greying keeps lightness; every room is furnished, the same way each time and differently between rooms; furniture stays inside its room against a side wall, clear of Desks and the doorway, tall pieces only at the back; the corner under a room's name stays free. The scene itself was checked by eye with the screenshot harness in light and dark.
