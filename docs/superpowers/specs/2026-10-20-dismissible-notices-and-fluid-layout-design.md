# Closable notices and pages that follow the sidebar — design

Status: written on 2026-10-20 from the Owner's request to make the alert bar at the top closable, animated when it shows and hides, and to make every page adapt its size and layout when the sidebar opens or closes rather than only sliding left. Choices marked _my call_ are the builder's and can be changed.

## What was wrong

On macOS 26 the sidebar floats over the detail column, and AppKit reports its width to the page as a leading safe area. It changes that inset frame by frame while the sidebar opens or closes, but the scrolling pages picked the change up only at the end: the page slid over, then jumped to its new width. Overview, Statistics and Token usage also stopped at 1400 pt and the Statistics pages, the review tabs and the template editor at 860–900 pt, pinned to the left, so in a wide window the space the sidebar gave back stayed empty on the right.

## Behaviour

**Sidebar.** The detail column reads the inset from a `GeometryReader` that keeps the safe area, ignores the system's leading inset and gives the page the same width as `safeAreaPadding`, on every frame. The page therefore resizes and reflows with the sidebar's own animation. The reader's size is the column's whatever the page asks for (_my call_: the first try measured a view sized by the page, and on Review requests the padding fed back into the reading in an endless layout loop).

**Width.** The 1400 pt and 900 pt caps are gone: pages use the full width beside the sidebar. Statistics puts its four tiles in one row when it is wide (two by two otherwise), and Message templates shows the preview beside the editor above 1000 pt (_my call_). Configuration and Appearance are grouped forms; they keep the system's centred width, which re-centres with the sidebar. The Review requests list stays 300 pt.

**Notices.** Every `NoticeBox` has × (help "Close"). Closing animates (fade, fold up, the content below moves up), and a new notice drops in from just above its place. Where the notice comes from a model's one-off outcome (`WindowModel`, `MenuModel`, `ConfigEditorModel`, `TemplateEditorModel` banners, `ReviewsModel` Agent Review and approval outcomes, the Overview and popover action outcomes), × clears it in the model, so it stays closed after leaving the page, until the next action sets one. The errors in the Messages and Review requests lists are cleared in the model too and come back if the next refresh still fails. Any other notice is hidden in place while its text stays the same (_my call_: errors a refresh sets again every 2 or 30 seconds would otherwise reappear at once). A failure that is the whole page (Configuration or Message templates that did not load, an unknown log folder) has no ×, since closing it would leave the page blank.

## Not changed

The menu bar popover keeps its fixed size; its notices gain × like the rest.
