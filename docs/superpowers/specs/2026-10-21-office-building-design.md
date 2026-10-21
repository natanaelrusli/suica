# Office as a building, and refresh — design

Status: written from the Owner's request on 2026-10-21 ("make a feature to refresh the agent shown"; "make the rooms like in an actual office building, connected, with a Center room that connects these rooms"). Choices marked _my call_ are the builder's. Builds on `2026-10-21-virtual-office-design.md`; vocabulary is in `CONTEXT.md`.

## Refresh

- A **Refresh** button in the Office page's toolbar, with ⌘R, like Messages and Review requests. It runs the same read as the two-second poll (`OfficeModel.refresh()`) at once, so a new or finished Session shows without waiting; a failure keeps the last good office and shows its message (existing behaviour).
- It does not clear Sessions that left: the CLI reports them as exited for five minutes, so clearing them locally would bring them back on the next poll (_my call_).

## Building layout

- The Office is one rectangle: the **Center Room** runs across its middle, a row of project Rooms on its far side and a row on its near side. Rooms touch each other and the Center Room; no gaps between them.
- Each Room opens onto the Center Room through a doorway (a 1.4 m gap in the wall facing it, with a mat on the floor). The Center Room has its own floor tint and its name on the floor.
- Rooms alternate sides in order (first far, second near, …), so a new Room never leaves a side empty while the other fills (_my call_). A row is stretched so it fills the building's width, and every Room in a row gets the row's depth; Desks stay centred in their Room. The Center Room is 2.6 m deep and at least as wide as the building.
- With no Session the Office is the Center Room alone. With one Room, the near side of the Center Room is left open.
- Room names stand on top of each Room's near wall: on the floor they hid behind the walls and Desks (_my call_).
- Not covered: more than about eight Rooms makes each row long; the camera still fits it and can zoom, but there is no second floor or wing (_my call_).

## Tests

`OfficeTests`: Rooms and the Center Room do not overlap, the building is centred and its extent matches the rooms; rows fill the width and touch the Center Room with doors facing it; one Room leaves the near side open; an empty Office is the Center Room alone. The scene itself is checked by eye with the screenshot harness.
