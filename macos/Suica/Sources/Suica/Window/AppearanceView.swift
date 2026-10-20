import SuicaCore
import SwiftUI

/// The app's own look and feel: accent colour, light or dark, density, animation, the menu bar
/// badge and where the window opens. Every choice applies at once.
struct AppearanceView: View {
    @Bindable var settings: AppearanceSettings
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.motionLevel) private var motion
    @Environment(CelebrationCounter.self) private var celebrations: CelebrationCounter?

    var body: some View {
        Form {
            Section {
                PresetRow(settings: settings)
                Text(Copy.presetsHint).font(.caption).foregroundStyle(.secondary)
            } header: {
                heading(Copy.presetsHeading, "sparkles.rectangle.stack")
            }

            Section {
                ThemePicker(selection: $settings.theme, custom: customColor)
                Text(Copy.accentHint).font(.caption).foregroundStyle(.secondary)
            } header: {
                heading(Copy.accentHeading, "paintpalette")
            }

            Section {
                Picker(Copy.modeHeading, selection: $settings.mode) {
                    ForEach(AppearanceMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker(Copy.densityHeading, selection: $settings.density) {
                    ForEach(Density.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Text(Copy.densityHint).font(.caption).foregroundStyle(.secondary)
            } header: {
                heading(Copy.lookHeading, "circle.lefthalf.filled")
            }

            Section {
                BackdropPicker(selection: $settings.backdrop)
                Text(Copy.backdropHint).font(.caption).foregroundStyle(.secondary)
            } header: {
                heading(Copy.backdropHeading, "square.2.layers.3d.top.filled")
            }

            Section {
                Picker(Copy.motionHeading, selection: $settings.motion) {
                    ForEach(MotionLevel.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Text(Copy.motionHint).font(.caption).foregroundStyle(.secondary)
                if systemReduceMotion && settings.motion == .full {
                    Label(Copy.systemReducesMotion, systemImage: "figure.walk.motion")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } header: {
                heading(Copy.motionHeading, "wand.and.stars")
            }

            Section {
                Toggle(Copy.celebrationsToggle, isOn: $settings.celebrations)
                if settings.celebrations && motion != .full {
                    Label(Copy.celebrationsNoMotion, systemImage: "figure.walk.motion").font(.caption).foregroundStyle(.orange)
                }
                LabeledContent(Copy.soundPicker) {
                    HStack {
                        Picker(Copy.soundPicker, selection: $settings.sound) {
                            ForEach(SoundEffect.allCases) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                        Button(Copy.celebrateTry) { celebrations?.celebrate() }
                            .disabled(celebrations == nil || (!settings.celebrations && settings.sound == .off))
                    }
                }
                Text(Copy.soundHint).font(.caption).foregroundStyle(.secondary)
            } header: {
                heading(Copy.funHeading, "party.popper")
            }

            Section {
                LabeledContent(Copy.menuBarIconPicker) {
                    HStack(spacing: 12) {
                        Picker(Copy.menuBarIconPicker, selection: $settings.menuBarIcon) {
                            ForEach(MenuBarIcon.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                        if settings.menuBarIcon == .emoji {
                            TextField(Copy.menuBarEmojiField, text: $settings.menuBarEmoji)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 44)
                                .multilineTextAlignment(.center)
                                .help(Copy.menuBarEmojiHint)
                        }
                    }
                }
                if settings.menuBarIcon == .emoji {
                    Text(Copy.menuBarEmojiHint).font(.caption).foregroundStyle(.secondary)
                }
                LabeledContent(Copy.menuBarBadgePicker) {
                    HStack(spacing: 12) {
                        Picker(Copy.menuBarBadgePicker, selection: $settings.menuBarBadge) {
                            ForEach(MenuBarBadge.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                        MenuBarSample(badge: settings.menuBarBadge, icon: settings.menuBarIcon, emoji: settings.menuBarEmoji)
                    }
                }
                Text(Copy.menuBarBadgeHint).font(.caption).foregroundStyle(.secondary)
                Toggle(Copy.popoverCounters, isOn: $settings.showsPopoverCounters)
            } header: {
                heading(Copy.menuBarHeading, "menubar.rectangle")
            }

            Section {
                Picker(Copy.startPagePicker, selection: $settings.startPage) {
                    ForEach(StartPage.allCases) { Text($0.title).tag($0) }
                }
            } header: {
                heading(Copy.windowHeading, "macwindow")
            }

            Section {
                AppearancePreview()
            } header: {
                heading(Copy.previewHeading, "eye")
            }

            Section {
                HStack(alignment: .firstTextBaseline) {
                    Text(Copy.appearanceNote).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(Copy.resetAppearance) { settings.reset() }
                        .disabled(settings.isDefault)
                }
            }
        }
        .formStyle(.grouped)
        .motion(value: settings.menuBarIcon)
        .motion(value: settings.celebrations)
        .motion(value: settings.motion)
        .motion(value: systemReduceMotion)
    }

    /// The custom accent colour, as the colour well edits it; editing it picks the custom theme.
    private var customColor: Binding<Color> {
        Binding(
            get: { Color(hex: settings.customAccent) },
            set: { color in
                if let hex = color.hex { settings.customAccent = hex }
                settings.theme = .custom
            })
    }

    private func heading(_ title: String, _ symbol: String) -> some View {
        Label(title, systemImage: symbol).font(.headline)
    }
}

/// The accent colours as swatches; the ring slides to the one picked.
private struct ThemePicker: View {
    @Binding var selection: AccentTheme
    @Binding var custom: Color
    @Namespace private var ring
    @Environment(\.motionLevel) private var motion

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ForEach(AccentTheme.allCases.filter { $0 != .custom }) { theme in
                Button {
                    withMotion(.snappy(duration: 0.3), motion) { selection = theme }
                } label: {
                    VStack(spacing: 6) {
                        ZStack {
                            Circle()
                                .fill(theme.swatch.gradient)
                                .frame(width: 26, height: 26)
                                .overlay {
                                    // System is the system's accent: half its colour, half grey, as in System Settings.
                                    if theme == .system {
                                        Circle().trim(from: 0.5, to: 1).fill(Color.gray.gradient).rotationEffect(.degrees(45))
                                    }
                                }
                            if selection == theme {
                                Circle()
                                    .strokeBorder(theme.swatch, lineWidth: 2)
                                    .frame(width: 34, height: 34)
                                    .matchedGeometryEffect(id: "ring", in: ring)
                                Image(systemName: "checkmark")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(.white)
                                    .transition(.scale.combined(with: .opacity))
                            }
                        }
                        .frame(width: 36, height: 36)
                        Text(theme.title)
                            .font(.caption2)
                            .foregroundStyle(selection == theme ? .primary : .secondary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(theme.title)
                .accessibilityAddTraits(selection == theme ? .isSelected : [])
            }
            Divider().frame(height: 36)
            VStack(spacing: 6) {
                ColorPicker(Copy.customColor, selection: $custom, supportsOpacity: false)
                    .labelsHidden()
                    .frame(width: 36, height: 36)
                    .overlay {
                        if selection == .custom {
                            Circle().strokeBorder(custom, lineWidth: 2).frame(width: 40, height: 40).allowsHitTesting(false)
                        }
                    }
                Text(Copy.customColor)
                    .font(.caption2)
                    .foregroundStyle(selection == .custom ? .primary : .secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            .accessibilityAddTraits(selection == .custom ? .isSelected : [])
        }
        .padding(.vertical, 4)
    }
}

/// One-click presets, each a big emoji over its name.
private struct PresetRow: View {
    let settings: AppearanceSettings
    @Environment(\.motionLevel) private var motion

    var body: some View {
        HStack(spacing: 10) {
            ForEach(AppearancePreset.allCases) { preset in
                Button {
                    withMotion(.snappy(duration: 0.35), motion) { preset.apply(to: settings) }
                } label: {
                    VStack(spacing: 4) {
                        Text(preset.emblem).font(.system(size: 26))
                        Text(preset.title).font(.caption).lineLimit(1).fixedSize()
                    }
                    .frame(width: 104, height: 64)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                    .contentShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(preset.title)
            }
        }
        .padding(.vertical, 4)
    }
}

/// The backdrops as small cards that show their gradient.
private struct BackdropPicker: View {
    @Binding var selection: Backdrop
    @Environment(\.motionLevel) private var motion

    var body: some View {
        HStack(spacing: 10) {
            ForEach(Backdrop.allCases) { backdrop in
                Button {
                    withMotion(.snappy(duration: 0.3), motion) { selection = backdrop }
                } label: {
                    VStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(.background)
                            .overlay { BackdropView(backdrop: backdrop, strength: 0.9).clipShape(RoundedRectangle(cornerRadius: 8)) }
                            .overlay {
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(selection == backdrop ? AnyShapeStyle(.tint) : AnyShapeStyle(.separator), lineWidth: selection == backdrop ? 2 : 1)
                            }
                            .frame(width: 70, height: 44)
                        Text(backdrop.title)
                            .font(.caption2)
                            .foregroundStyle(selection == backdrop ? .primary : .secondary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(backdrop.title)
                .accessibilityAddTraits(selection == backdrop ? .isSelected : [])
            }
        }
        .padding(.vertical, 4)
    }
}

/// What the menu bar shows with three messages waiting.
private struct MenuBarSample: View {
    let badge: MenuBarBadge
    let icon: MenuBarIcon
    let emoji: String

    var body: some View {
        HStack(spacing: 3) {
            MenuBarIconView(icon: icon, emoji: emoji)
            if let label = badge.label(for: 3) {
                Text(label).font(label == "●" ? .system(size: 7) : .system(size: 13, weight: .medium))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 5))
        .accessibilityHidden(true)
    }
}

/// A few controls in the chosen colour, density and motion.
private struct AppearancePreview: View {
    @State private var on = true

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            StatTile(
                title: Copy.reviewRequests, value: on ? "3" : "4", symbol: "person.crop.circle.badge.questionmark",
                tint: .purple, caption: Copy.previewSample, action: { on.toggle() }
            )
            .frame(maxWidth: 260)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button(Copy.confirmSend) { on.toggle() }.buttonStyle(.borderedProminent)
                    Button(Copy.skip) { on.toggle() }
                }
                Toggle(Copy.previewHeading, isOn: $on).toggleStyle(.switch).controlSize(.small).labelsHidden()
                Badge(text: Copy.agentReviewTab, tint: .tint)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }
}
