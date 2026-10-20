# A more customizable, more fun Appearance — design

Status: written from the Owner's request on 2026-10-20 ("make the appearance of the app more customizeable and more fun"). The Owner was not available for questions, so every choice marked _my call_ is the builder's and can be changed. It extends the Appearance page (accent colour, light or dark, density, motion, menu bar badge, popover counters, start page).

## Goals

- **Your own accent colour**: a colour well next to the swatches (theme `custom`).
- **Menu bar icon**: the penguin (default), a watermelon slice (the app's name is a watermelon), or any emoji you type.
- **Backdrop**: a soft wash behind the window's pages and the popover header: Plain, Accent wash (today's popover look, the default), Sunrise, Lagoon, Watermelon, Aurora (slowly drifts with full motion; still otherwise).
- **Celebrations**: confetti when you send a message, approve an MR, or clear everything that needs you (inbox zero). Off with motion off; the system's Reduce Motion stops it too.
- **Sound effects**: one of the system sounds (Pop, Glass, Purr, Hero, Tink, Submarine) for the same moments, or Off (the default; _my call_: sound surprises people).
- **Presets**: one click sets several choices at once: Classic, Watermelon party, Midnight, Sunrise, Zen. A preset only sets choices; you can change any of them afterwards.

## Non-goals

- Fonts and text size (_my call_: SwiftUI on macOS does not scale text styles with `dynamicTypeSize`, so it would be a setting that does nothing).
- Importing or sharing themes.
- Sounds or confetti for the agent's own background work (only for what you do in the app, plus inbox zero).

## Behaviour

1. Every choice is stored in the app's user defaults like the existing ones, applies at once, and **Restore defaults** resets it. An unknown stored value falls back to its default.
2. The custom colour is stored as `0xRRGGBB`; the default is the Watermelon red, so picking **Custom** first shows a colour.
3. The emoji icon keeps only the first character typed (one grapheme, so 👩‍💻 or 🇮🇩 stay whole); empty falls back to 🍉.
4. Celebrations come from the models: the popover model counts messages sent (`sent` result), the reviews model counts approvals (`approved` result), and inbox zero is the badge count going from above zero to zero. The views watch these counters, so a refresh or the agent never celebrates by itself, except for inbox zero, which the Owner causes by acting on the last item, or, rarely, by an item becoming obsolete (_my call_: still worth a smile).
5. Confetti is drawn in a `Canvas` for about 1.6 seconds above the content and never takes clicks.

## Testing

- `AppearanceSettings`: defaults, persistence and reset of the new choices; the emoji is cut to one character; presets set what they name.
- Celebration triggers: inbox zero only on the transition from above zero to zero; the sent and approved counters move only on success.
- Views: screenshots through the scratch harness.
