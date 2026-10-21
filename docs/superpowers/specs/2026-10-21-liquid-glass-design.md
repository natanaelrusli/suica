# Liquid Glass surfaces and a full-height Office

## Problem

The window mixed two looks. System controls (the segmented tabs on Review requests, the toolbar)
are Liquid Glass on macOS 26, while the Office drew its floating summary, empty state and detail
card in the older `.regularMaterial` with a hairline border, and the menu bar popover's hand-drawn
tab switch used square-cornered pills. The Office's 3D scene also stopped under an opaque title bar
band with a line below it, so the page looked boxed in.

## Decision

- `View.glass(in:)` in `Theme.swift`: `glassEffect(.regular, in:)` on macOS 26, the regular material
  on macOS 15. It is for what floats over a page (Office overlays, the notification banner preview),
  not for the cards that make up a page, which stay opaque as Apple's guidance asks (my call).
- The Office scene runs to the top of the window. A vignette fades its top edge into the window
  background so the title and toolbar buttons read over a bright sky or a busy room.
- **Reset view** moves from a floating button into the toolbar beside **Refresh**, so the page's
  actions sit in one glass group (my call).
- The popover's tab switch uses capsules, matching the system segmented control.

## The title bar band

On macOS 26 AppKit draws a "hard" scroll pocket (an opaque band and a one-point line) under the
title bar of a split view column whose top is not a scroll view. `toolbarBackgroundVisibility`,
`scrollEdgeEffectStyle` and `scrollEdgeEffectHidden` on a plain view do not remove it. The Office
therefore sits in a `ScrollView` that never scrolls (its content is exactly the page's size) with
`scrollEdgeEffectHidden(true, for: .top)`; AppKit then hands the edge to that scroll view, whose
effect is hidden. `scrollDisabled(true)` must not be used: a disabled scroll view does not take the
edge over and the band comes back. The scene's own scroll handling (`ScrollControl`) consumes wheel
and trackpad events before the scroll view sees them.

## Not done

- The other pages keep their current title bar; the Office and Review requests (see the
  [Review requests title bar spec](2026-10-21-reviews-glass-top-bar-design.md)) run under it.
- No custom glass on content cards, tiles or rows.
