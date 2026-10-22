# Icon themes, app icons and the ⌘Tab order — design

Status: written from the Owner's request on 2026-10-22 ("add a theme: icon theme (colorful, monochrome, etc.), multiple options of app icon; fix: Suica is put on the far right of the app switcher even when it has just been in focus"). The Owner was not asked questions, so every choice marked _my call_ is the builder's and can be changed. It extends the Appearance page ([appearance spec](2026-10-20-appearance-fun-design.md)).

## Goals

- **Icon style**: how the coloured icons of the sidebar, Overview and Statistics tiles, Configuration cards and popover quick actions are drawn. All of them go through one view, `SidebarIcon`, so one setting covers them all.
  - **Colourful** (default, today's look): a white symbol on a tile in the icon's own colour.
  - **Tinted**: the symbol in its colour on a pale tile of that colour.
  - **Accent**: every tile in the accent colour (_my call_: a middle way between colour and none).
  - **Monochrome**: a grey symbol on a faint grey tile.
- **App icon**: the penguin on five tiles: **Classic** (ice blue, the installed icon), **Watermelon** (pink flesh, seeds, a green rind), **Sunset** (orange to pink with a pale sun), **Midnight** (violet to navy with stars and a crescent moon), **Mono** (greys).
- **Presets** pick matching icons: Classic sets Colourful and Classic, Watermelon party Colourful and Watermelon, Midnight the Midnight icon, Sunrise the Sunset icon, Zen Monochrome and Mono.
- **⌘Tab fix**: opening the window puts Suica where the app you just used belongs in the switcher, not last.

## Non-goals

- Changing the icon Finder, Launchpad and Spotlight show (_my call_): that would mean writing a custom icon into the signed app bundle, which breaks its ad hoc signature. The picked icon shows in the Dock and the app switcher while the app runs (`NSApp.applicationIconImage`); Classic leaves the bundle's own icon in place.
- Icons other than the coloured tiles (toolbar buttons, chips, row symbols keep their look).

## Behaviour

1. Both choices are stored in the app's user defaults (`appearance.iconStyle`, `appearance.appIcon`), apply at once and go back to their defaults with **Restore defaults**. An unknown stored value falls back to the default.
2. The icons are drawn in code by `AppIconArt.swift` (AppKit only), so still no image is kept in git. `macos/make-icon.swift` draws the Classic one with the same code for `scripts/install-macos-app.sh` (compiled together with `swiftc`), and its output is byte-identical to the PNG the old script drew.
3. ⌘Tab: Suica is a menu bar app (`LSUIElement`) that turns into a regular app while its window is open. The popover or a `suica://` link has usually made it active already, so the window's `NSApp.activate()` changed nothing, and the system never recorded the newly regular app as frontmost: the switcher listed it last until another app activated it. The window now activates with `activate(ignoringOtherApps: true)`, which records it.

## Testing

- `AppearanceSettings`: defaults, persistence, reset and unknown values of the two choices; presets set the icons they name; every choice has a title.
- The ⌘Tab order cannot be tested in `swift test`. It was reproduced with a scratch app that does what the window does and a probe that prints LaunchServices' front-to-back application order (`_LSCopyApplicationArrayInFrontToBackOrder`, the order the switcher uses): with `activate()` the app was listed last every run, with `activate(ignoringOtherApps: true)` it was listed right after the app in front.
- The five icons were drawn to PNG and checked by eye.
