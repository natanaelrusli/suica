import SuicaCore
import SwiftUI

/// The app's own look and feel: accent colour, light or dark, density, animation, the menu bar
/// badge and where the window opens. Every choice applies at once.
struct AppearanceView: View {
    @Bindable var settings: AppearanceSettings
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    var body: some View {
        Form {
            Section {
                ThemePicker(selection: $settings.theme)
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
                LabeledContent(Copy.menuBarBadgePicker) {
                    HStack(spacing: 12) {
                        Picker(Copy.menuBarBadgePicker, selection: $settings.menuBarBadge) {
                            ForEach(MenuBarBadge.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                        MenuBarSample(badge: settings.menuBarBadge)
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
        .motion(value: settings.motion)
        .motion(value: systemReduceMotion)
    }

    private func heading(_ title: String, _ symbol: String) -> some View {
        Label(title, systemImage: symbol).font(.headline)
    }
}

/// The accent colours as swatches; the ring slides to the one picked.
private struct ThemePicker: View {
    @Binding var selection: AccentTheme
    @Namespace private var ring
    @Environment(\.motionLevel) private var motion

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ForEach(AccentTheme.allCases) { theme in
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
        }
        .padding(.vertical, 4)
    }
}

/// What the menu bar shows with three messages waiting.
private struct MenuBarSample: View {
    let badge: MenuBarBadge

    var body: some View {
        HStack(spacing: 3) {
            Image(nsImage: PenguinGlyph.image)
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
