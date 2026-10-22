# Idle figures pass the time — design

Status: built from the Owner's request on 2026-10-22 ("When an agent is idle in the 3d office, let them animated walking around, interacting with others, playing game, phone, etc."). Choices marked _my call_ are the builder's. Builds on `2026-10-22-office-life-design.md`, which had idle figures nod off at their desks and left "no coffee breaks, no visits to the Center Room" out.

## What an idle figure does

An idle Session's figure (no activity for 60 seconds) takes up an activity and keeps it for a **turn** of 30 seconds (_my call_: long enough to walk out and spend a while there, short enough that the office keeps moving):

- **Phone**: seated, a phone held up in the right hand with its screen lit toward the face, head bowed, the thumb scrolling.
- **Game**: seated, leaning in, hands hammering the keys, swaying; the monitor shows a game (a night sky, coloured blocks, a hero and a coin).
- **Doze**: seated, leaning back and nodding off (the old idle pose).
- **Stretch**: standing in the gap beside its desk, both arms up, leaning one way then the other.
- **Stroll**: walks out through its Room's doorway into the Center Room, stands at a spot there with its hands behind its back and looks around, facing the viewer.
- **Chat**: pairs up with another idle figure (from any Room) at a spot in the Center Room; the two stand 0.9 m apart facing each other and take turns to talk every 4 seconds: the speaker talks with a hand and the head, the listener nods with its hands together in front. While one has not arrived yet, or has gone back to work, the other waits on its phone.

## Who does what

- `OfficeIdle.plan(idle:hall:turn:)` in `SuicaCore` picks the activities from a seed of the turn number, so the same figures do the same thing on every redraw. Each figure in a shuffled order: about a third of the time it pairs with the next for a chat, another sixth it strolls, otherwise it stays: phone 35 %, game 30 %, doze 20 %, stretch 15 % (_my call_).
- Meeting spots run along the middle of the Center Room, 2 m apart and clear of its furniture, so the nearest figures of two chats side by side stand over a metre apart. Each turn a spot takes one stroller or one pair; with no spot left (a narrow office), everyone stays at their desk.
- The walk out: back along its Room's way (chair, gap beside its desk, aisle, doorway), straight out to the middle of the Center Room, then along it to the spot. Coming back is the same way in reverse. Between two spots in the Center Room a figure walks straight across.
- A figure still walking when a turn starts keeps what it was doing until the next turn (_my call_: a figure is never set down mid-walk).

## When the idle ends

- A Session that gets work, waits for the Owner or exits sends its figure straight back to its desk (or out of the office), from wherever it is.
- When the Owner starts writing to an idle Session, its figure goes back to its desk and waits on its phone, so the boss finds it there, and it is not sent anywhere else while the boss is with it.
- With Appearance → Animation at Fades only or Off, idle figures sit at their desks as before; nothing walks.

## Not done

- Figures do not avoid each other while walking: two crossing the Center Room may pass through each other (_my call_, rare and brief).
- No sound, no speech bubbles for chats, no coffee or water-cooler props: none was asked for.

## Tests

- `OfficeIdleTests`: the plan is the same for the same turn whatever the order of the ids, and changes between turns; over many turns every kind of activity occurs; chats come in pairs that face each other; no two figures share a spot; meeting spots stay in the middle of the Center Room, clear of its furniture; with no room to meet everyone stays at their desk; the way to the Center Room leaves by the doorway and crosses only the Center Room.
- The poses, props, game screen and walks were checked by eye in the offscreen `RealityRenderer` harness, stepping the scene clock: figures walking out through the doorways, pairs chatting and a stroller in the Center Room, a figure on its phone, a gamer with the game on its monitor.
