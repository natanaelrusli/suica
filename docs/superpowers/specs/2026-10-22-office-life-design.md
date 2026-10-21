# Office life: styles, environments, titles, chat window and moving figures — design

Status: written from the Owner's request on 2026-10-21 ("add a feature to change styling of the building, change environment"; "Improve the 3d model overall"; "Make the app able to show the title of the agent session"; "When clicking a worker, show the LLM chat window"; "Make the worker have animation, walking, typing, etc."). The Owner was away, so every choice below marked _my call_ is the builder's and can be changed. Builds on `2026-10-21-virtual-office-design.md` and the Office specs after it; vocabulary is in `CONTEXT.md`.

## Building style and environment

- Two new Appearance choices, kept in the app's user defaults like the rest of Appearance (`appearance.officeStyle`, `appearance.officeEnvironment`) and applied at once: the **building style** and the **environment**. They are picked from a **Style** menu in the Office page's toolbar (a paintbrush) and from an **Office** section of the Appearance page (_my call_: the toolbar menu is where the Owner is when they want to change the look; the Appearance page lists it with the rest so Reset covers it).
- Building styles (`OfficeStyle`), each a palette for walls, wall caps, floors, hall tiles, desks and the plinth, in light and dark tones:
  - **Modern** (default, the look of today): white plaster, warm wooden planks, carpet tiles.
  - **Brick**: red brick walls with a cream cap, terracotta tile floors, a grey stone hall.
  - **Glass**: dark steel frames with pale blue-green tinted panels for walls, light concrete floors, a dark slate hall.
  - **Timber**: honey log walls, dark plank floors, a woven rug hall.
- Environments (`OfficeEnvironment`), what lies outside the building:
  - **City** (default, today's street): road, pavements, lamps, cars, cyclists, walkers.
  - **Park**: no road or cars; a wide lawn with a gravel path where the road was, flower beds, more trees, a pond beside the path, walkers and cyclists on the path.
  - **Snow**: white ground and snow-topped pavements, a dark cleared road with grey tracks, snow caps on the trees and hedges, a pale grey sky; the same travellers in winter coats (darker body colours).
- The page's sky colour follows the environment (and dark mode as before).
- A style or environment change rebuilds the rooms and the outside at once; Desks and figures stay (_my call_: the figures' colours do not depend on the style).

## The 3D model, improved

Concrete changes, all low-poly geometry in code as before (_my call_, picking what reads at the default camera):

- **Figures** are rigged: head on a neck, a torso, upper arms and forearms with hands, thighs and shins with shoes. The rig lets a figure sit, stand and walk (below). Seated figures keep today's look (hair, shirt, trousers, glasses, headphones).
- **Monitors** show a screen texture: dark with coloured lines of "code" while working (glowing cyan frame), an amber "?" screen while waiting, black when idle or exited.
- **Desks** get a little life, seeded by the Session id: a mug, a notebook or a small succulent, on one side.
- **Windows** on every outer wall (the building's north wall for far Rooms, the south wall of near Rooms and the side walls): pale glass panes with a frame, lit warm at night.
- **Entrance**: an awning over the path at the front wall, with a sign reading "Office" lying on it so the camera can read it (_my call_: no project name there, the Office is every project's; a door in the Center Room's wall would only exist when no near Room stands there).
- **Street**: a zebra crossing where the path meets the road, flower beds beside the path, a bench on the near pavement.

## Session titles

- Each Session carries a `title` (string or null) in `suica office --json` and the golden `contracts/office.v1.json` (additive; the Swift decoder reads it as optional).
  - Claude Code: `name` from `~/.claude/sessions/<pid>.json`; else the last `custom-title` entry in the transcript; else the first line of the first user prompt (_my call_, so every Session has a title; at most 60 characters, clipped with an ellipsis).
  - Codex: no title of its own; the first user prompt's first line (from the first `UserMessage` item, falling back to the first user `message` response item that is not an AGENTS.md or permissions preamble).
  - Gemini CLI: the first user message's first line that is not session context (`<session_context>` blocks are skipped).
  - Custom (`office.custom`) agents: null.
- In the Office, the title is the first line of the figure's bubble, smaller and lighter, over the activity, at most 28 characters (_my call_: a nameplate on the desk was hidden by the chair and the figure from the default camera; the bubble is where the eye already goes). The Chat Panel shows the full title as its heading, with the agent name under it.

## Chat window

- Clicking a figure (or its Desk) opens a **chat panel** on the right of the page (_my call_: 380 pt wide, full height under the title bar) instead of the small card at the bottom: a header with the agent colour, the title, the project path, the status and the start time, the **Open** button where the host app is known, and the conversation under it as chat bubbles: the Owner's prompts on the right in the accent colour, the agent's answers on the left; tool calls are not shown (the Last actions list stays, folded under the header). It scrolls to the newest message when it opens and whenever a new message arrives.
- It is read-only: the Office still only watches (`2026-10-21-virtual-office-design.md` non-goal). There is no input field.
- The conversation comes from a new CLI command, `suica office chat <agent> <sessionId> --json`, with its own golden `contracts/office-chat.v1.json`:

  ```json
  {"version":1,"agent":"claude","sessionId":"c1","title":"Office chat window","messages":[{"at":1792549940000,"role":"user","text":"..."},{"at":1792549960000,"role":"assistant","text":"..."}]}
  ```

  - At most the last 40 messages, oldest first, each at most 4,000 characters (clipped with an ellipsis), read from the tail of the transcript (_my call_: up to 64 MB back; a Claude Code transcript is mostly tool results, and the last 32 MB of one held nine messages, read in about 50 ms).
  - Claude Code: `user` entries whose content is a string or text blocks (tool results, meta entries and sidechains are skipped) and `assistant` entries' text blocks. The transcript is found under `~/.claude/projects/*/<sessionId>.jsonl`.
  - Codex: `UserMessage` items (falling back to user `message` response items that are not preambles) and assistant `message` response items (`output_text`). The rollout is the `rollout-*-<sessionId>.jsonl` under `~/.codex/sessions`.
  - Gemini CLI: `user` and `gemini` message entries (the `$set.messages` first line included), session context skipped. The chat is `session-*<sessionId>.jsonl` under `~/.gemini/tmp/*/chats`.
  - A custom agent, or a Session whose transcript cannot be found, gives an empty `messages` list and a null title, exit 0; the panel then says "No conversation to show."
- The app reads the chat when a figure is selected and again on every two-second poll while the panel is open, so the conversation follows the agent; a failed read keeps the last conversation and shows the error in the panel.

## Figures that move

- **Arriving**: a new Session's figure walks in through its Room's doorway and along the aisle to its Desk, then sits (about 1 m/s, _my call_). Where the figure walks is laid out by `OfficeLayout` (`SuicaCore`, testable): door → the aisle along the door wall → the gap beside its Desk → the chair.
- **Working**: typing — the forearms and hands tap over the keyboard, alternating, and the head bobs a little (replaces today's whole-figure bob).
- **Waiting for the Owner**: the figure stands up, steps into the gap beside its desk, faces the viewer (wherever the view is turned) and waves one arm; when the wait ends it walks back and sits (_my call_: a seated figure twisted round to face the camera clipped through its chair). Its monitor shows an amber question mark.
- **Idle**: the figure leans back with its arms down and nods off (a slow, deep head bob).
- **Left the office** (exited): the figure stands, walks out through the doorway and disappears; the Desk stays, greyed, with its "Left the office" bubble for the five-minute stay, as before. A Session that comes back walks in again.
- Everything follows Appearance → Animation: with Reduced or Off the figure appears seated and vanishes at once, as today, and nothing taps or waves.

## Not done

- Figures do not walk anywhere else (no coffee breaks, no visits to the Center Room): there is nothing in the agents' logs that would say so.
- A figure that is sent somewhere new while still on its way is set down at its previous goal first, then walks on: a figure never turns around mid-aisle (_my call_, rare).
- RealityKit culls a model that is disabled or scaled to nothing when it first draws, so a figure that is gone waits 3 m under the lawn instead.
- No talking: the chat panel shows the conversation, it does not send to it.
- Codex and Gemini CLI give no title of their own, so theirs is the first prompt's first line.

## Vocabulary (add to `CONTEXT.md`)

- **Session Title**: the name of a Session as its Coding Agent knows it (Claude Code's session name) or, failing that, the first line of its first prompt.
- **Chat Panel**: the read-only view of a Session's conversation that opens when its figure is clicked in the Office.

## Tests

- CLI: title detection per adapter (Claude name, custom-title, first prompt; Codex first prompt; Gemini skipping context); `office chat` per agent from fixtures, clipping, the preamble filter, an unknown session; the two goldens.
- `OfficeTests`: the golden with titles; the chat golden; the nameplate text at most 24 characters; the walk path starts at the door, stays inside the Room, ends at the chair and passes no Desk; the model loads a chat on selection and clears it on deselection.
- `AppearanceTests`: the two new choices start at their defaults, survive a restart, fall back on an unknown value and reset.
- The scene (styles, environments, rigs, animation poses) was checked by eye with the offscreen `RealityRenderer` harness in light and dark, the walk by stepping the scene clock in the harness (the figure comes in through the doorway and along the aisle); the Chat Panel was rendered alone in an `NSHostingView`. The harness cannot show RealityKit's own move animations (desks arriving) or the Liquid Glass material.
