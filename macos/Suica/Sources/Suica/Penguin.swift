import AppKit
import SwiftUI

/// The menu bar icon: a penguin silhouette with the belly and eyes cut out. A template image, so
/// macOS tints it for light, dark and highlighted menu bars.
enum PenguinGlyph {
    static let image: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setFill()
            let body = NSBezierPath(ovalIn: NSRect(x: 3.5, y: 1.2, width: 11, height: 15.6))
            body.append(NSBezierPath(ovalIn: NSRect(x: 6, y: 2.2, width: 6, height: 8.6)))
            body.append(NSBezierPath(ovalIn: NSRect(x: 6.4, y: 11.6, width: 1.8, height: 2)))
            body.append(NSBezierPath(ovalIn: NSRect(x: 9.8, y: 11.6, width: 1.8, height: 2)))
            body.windingRule = .evenOdd
            body.fill()
            for x in [1.6, 13.8] {
                NSBezierPath(ovalIn: NSRect(x: x, y: 4.2, width: 2.6, height: 6.4)).fill()
            }
            for x in [4.8, 9.6] {
                NSBezierPath(ovalIn: NSRect(x: x, y: 0.2, width: 3.6, height: 1.8)).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Suica"
        return image
    }()
}

/// The app's own icon (drawn by macos/make-icon.swift), or the penguin glyph when run without a bundle.
struct AppIconView: View {
    var size: CGFloat = 32

    var body: some View {
        Image(nsImage: NSApp.applicationIconImage ?? PenguinGlyph.image)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// A small coloured capsule with an icon and a label.
struct Chip: View {
    let text: String
    let symbol: String
    let tint: AnyShapeStyle

    init(text: String, symbol: String, tint: some ShapeStyle) {
        self.text = text
        self.symbol = symbol
        self.tint = AnyShapeStyle(tint)
    }

    var body: some View {
        Label(text, systemImage: symbol)
            .labelStyle(.titleAndIcon)
            .font(.caption.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(tint.opacity(0.14), in: Capsule())
            .lineLimit(1)
            .fixedSize()
    }
}
