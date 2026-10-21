# Review requests under a Liquid Glass title bar

## Problem

On macOS 26 the Review requests page drew its title bar as an opaque band with a line under it,
then the list's segmented tab switch on its own strip with a second line. The page looked boxed in
next to the Office, whose content runs up under a floating title bar, and to the system's own
Liquid Glass apps.

## Decision

- The page sits in `UnderTitleBar` (in `Theme.swift`), the Office's ScrollView that never scrolls,
  now shared by both pages. It removes the band for the same reason as on the Office (see the
  [Liquid Glass spec](2026-10-21-liquid-glass-design.md)).
- The MR list runs to the top of the window. Its tab switch is a `safeAreaBar` below the title bar,
  with no line under it; rows scroll under both and the list's soft scroll edge effect blurs them,
  so the title and the tabs stay readable (my call: the switch stays over the list it filters
  rather than moving into the window toolbar, where it would sit apart from the list and crowd the
  title and the search field in a narrow window).
- The selected MR starts below the title bar, as before.
- `UnderTitleBar` hides only its own scroll edge effect and bounce (`basedOnSize`); scroll views
  inside the page get theirs back, so the list and the MR's tabs keep their edge effects and bounce.
- macOS 15: the tab switch keeps its strip and line, on the bar material, padded below the title bar.

## Checked

In a SwiftUI window scene harness on macOS 26, dark mode, active window: no band or line under the
title bar, and rows scrolled under the tab switch are blurred. The band from the bug report did not
reproduce in that harness on `main` either, so the fix rests on the Office's proven behaviour rather
than a before/after pair from the harness.
