# Office Chat Panel as a sidebar — design

Status: written from the Owner's request on 2026-10-22 ("Improve the chat UI when clicking a worker 3d model, open it in a right sidebar and make sure scrolling dont move the camera in the 3d office"). Choices marked _my call_ are the builder's. Revises the Chat window section of `2026-10-22-office-life-design.md`; vocabulary is in `CONTEXT.md`.

## What was wrong

- The Chat Panel floated over the scene, so it covered part of the office and its conversation could not be scrolled: the scene's scroll catcher took every wheel event inside the scene's bounds, the panel's included, and zoomed or panned the camera instead.
- The agent's answers were plain text, so code, lists and links from the agent came out as one block.

## Now

- The Chat Panel is a trailing sidebar (SwiftUI `inspector`) beside the scene, 320 to 560 pt wide, 400 by default (_my call_). It opens when a figure is clicked, a **Conversation** button in the toolbar hides and shows it while a figure stays selected, and closing it (its ✕ or the system's) deselects the figure. The scene keeps the rest of the window.
- Scrolling over the panel scrolls the panel. The catcher now also hands back any wheel event whose pointer is over a scroll view other than the page's own, so a scroll view that floats over the scene (a notice) keeps its scroll too (_my call_).
- The panel: the agent's initial on its colour, the Session Title, the agent name with a status pill (green working, orange waiting), project and start time, Last actions folded away with **Open** beside it, then the conversation: a message count, the Owner's prompts on the right in the accent colour, the agent's answers on the left as Markdown (`MarkdownText`, the review page's renderer: code blocks, lists, quotes, links). Messages of one side in a row sit tight with the time under the last one; every bubble has a Copy context menu. The view keeps to the bottom as messages arrive (`defaultScrollAnchor(.bottom)`).

## Tests

No model change: `swift test` still passes (332). The panel was rendered alone in an `NSHostingView` in light and dark; the sidebar and the scrolling were not driven in the harness (the offscreen renderer cannot host the inspector), so they are checked in the installed app.
