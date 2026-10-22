# Office chat input, the boss and more Office options — design

Status: written from the Owner's request on 2026-10-22 ("Make user able to chat with the agent from suica, when chatting or inputting message, show a "boss" 3d model approaching the worker and speaking as if giving instructions" and "Show more customizability in the 3d office world"). Choices marked _my call_ are the builder's. Revises the "it only shows" rule of `2026-10-22-office-chat-sidebar-design.md`; vocabulary is in `CONTEXT.md`.

## Writing to an agent

- The Chat Panel gets a message field at its bottom with a send button. Return sends, ⌥Return starts a new line (the system's own shortcut for a multi-line field).
- `suica office send <agent> <sessionId> --json` takes the message on stdin (at most 8,000 characters, not blank) and prints `{"status": …}`. It looks the Session up with the same detection as `suica office --json`, so the folder the agent runs in comes from detection, never from the caller.
- It runs one headless turn of the agent's own CLI in that folder, resuming the Session, and waits for it (at most 30 minutes):
  - Claude Code: `claude -p --resume <id> -- <message>`
  - Codex: `codex exec resume <id> -- <message>`
  - Gemini CLI: `gemini --resume <uuid> --prompt=<message>` (the full session id is read from the chat file's first line)
  - The message is always after `--` or bound to `--prompt=`, so a message that starts with `-` cannot become a flag.
- No permission flags are added: each agent runs with the Owner's own settings, so in a headless turn anything those settings do not allow is refused rather than asked (_my call_: Suica never widens what an agent may do).
- Outcomes: `sent`, `busy` (the Session is working: Suica does not start a second turn on top of a running one, _my call_), `not_found`, `unsupported` (an `office.custom` agent), `agent_missing` (its CLI is not installed), `empty`, `too_long`, `failed`. The app shows each as a line under the field.
- The answer is written to the Session's own transcript, so the panel shows it on the next poll. **Limit:** a terminal or the Claude app that still has the Session open does not see the new turn until it is resumed there; the agents offer no documented way to type into a running session. The field's hint says so.

## The boss

- While the field has focus or text for the selected Session, a boss figure walks from that Room's doorway to a spot behind the worker's chair, and stands facing the worker (_my call_: navy suit with a white collar, grey hair, glasses, so it never looks like an agent's figure).
- On send, a bubble over the boss shows the message (its first 60 characters, in quotes) and the boss points at the worker and nods while the turn runs, and for 6 seconds after it ends (_my call_).
- When the field is empty and unfocused, nothing is being sent, or the figure is deselected, the boss walks back out of the Room and waits under the lawn like a gone figure.
- Without animation the boss appears at the spot and disappears at once. **Boss walks over** in the Office options turns the boss off.

## More Office options

The toolbar's Style menu becomes **Customize** and Appearance → Office gets the same choices (kept in the app's user defaults with the others; **Restore defaults** resets them):

- **Time of day**: Follow appearance (default), Day, Night. Night lights the lamps, shows the moon and darkens the sky whatever the system's mode is.
- **Bubbles**: All (default), Selected only, Off.
- **Street life**: walkers, cyclists and cars on or off (default on).
- **Slow turn**: the camera turns slowly round the office while nothing is dragged (default off; only with full animation).
- **Boss walks over**: default on.

## Not done

- Typing into a Session open in a terminal or the Claude app (no documented interface; the Claude Code peer socket is internal).
- Stopping or approving an agent from the Office.

## Tests

- Node: the invocation per agent (the `--` and `--prompt=` guards), every outcome of `office send`, the Gemini id lookup and the stdin limits.
- Swift: the model's send state and outcome messages, the options' defaults, storage and reset, the time-of-day resolution. The boss is checked in the offscreen harness by rendering it at the desk with a message.
