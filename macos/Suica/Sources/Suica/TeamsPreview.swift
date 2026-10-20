import AppKit
import SuicaCore
import SwiftUI

/// A message as the recipient's Teams chat will show it: the chat header with their initials and
/// name, then your message on the right in Teams' own-message bubble, its Markdown drawn as Teams
/// draws it (links in Teams' link colour, line breaks kept). Colours follow Teams' light and dark
/// themes.
struct TeamsMessagePreview: View {
    let recipient: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(DisplayText.initials(recipient))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(TeamsColor.avatarText)
                    .frame(width: 26, height: 26)
                    .background(TeamsColor.avatar, in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 0) {
                    Text(DisplayText.clean(recipient, max: 80)).font(.callout.weight(.semibold)).lineLimit(1)
                    Text(Copy.teamsChatSubtitle).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            Divider()
            VStack(alignment: .trailing, spacing: 3) {
                Text(Copy.teamsNow).font(.caption2).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(TemplatePreview.segments(text).enumerated()), id: \.offset) { _, segment in
                        switch segment {
                        case .text(let part):
                            MarkdownText.inline(DisplayText.cleanLines(part), projectURL: nil)
                                .font(.system(size: 13))
                                .foregroundStyle(TeamsColor.bubbleText)
                                .tint(TeamsColor.link)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        case .image(let alt, let url):
                            RemoteImage(url: url, alt: alt)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(TeamsColor.ownBubble, in: RoundedRectangle(cornerRadius: 6))
                // Links open only when they are http(s).
                .environment(\.openURL, OpenURLAction { url in
                    DisplayText.safeURL(url.absoluteString) == nil ? .discarded : .systemAction
                })
            }
            .padding(.leading, 36)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .background(TeamsColor.chatBackground)
        }
        .background(TeamsColor.chatBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator.opacity(0.6)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Copy.teamsPreviewHeading)
    }
}

/// Teams' chat colours, light and dark.
private enum TeamsColor {
    static let ownBubble = dynamic(light: 0xE8EBFA, dark: 0x2F2F4A)
    static let bubbleText = dynamic(light: 0x242424, dark: 0xFFFFFF)
    static let chatBackground = dynamic(light: 0xF5F5F5, dark: 0x1F1F1F)
    static let link = dynamic(light: 0x5B5FC7, dark: 0x7F85F5)
    static let avatar = dynamic(light: 0xDCE0FA, dark: 0x3D3E66)
    static let avatarText = dynamic(light: 0x444791, dark: 0xC5CBFA)

    private static func dynamic(light: Int, dark: Int) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(
                srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }
}
