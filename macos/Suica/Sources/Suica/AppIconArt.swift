import AppKit

/// Draws the app icon, a penguin on a rounded tile, in one of several palettes. Shared by the app
/// (the Dock icon picked in Appearance) and macos/make-icon.swift (the icon the app is installed
/// with), so it uses AppKit alone.
enum AppIconArt {
    /// What lies on the tile around the penguin.
    enum Scenery: Sendable { case none, seeds, sun, stars }

    /// Colours as 0xRRGGBB.
    struct Palette: Sendable {
        var tileTop: Int
        var tileBottom: Int
        var drift: Int
        var driftAlpha: CGFloat
        var shadow: Int
        var body: Int
        /// Feet and beak.
        var beak: Int
        var cheekAlpha: CGFloat
        var scenery: Scenery = .none

        static let classic = Palette(
            tileTop: 0x8FE3F5, tileBottom: 0x1C7FD6, drift: 0xFFFFFF, driftAlpha: 0.35, shadow: 0x0B3A66,
            body: 0x1B2838, beak: 0xFF9F1C, cheekAlpha: 0.55)
        static let watermelon = Palette(
            tileTop: 0xFF8FA3, tileBottom: 0xE5484D, drift: 0x2E9E4F, driftAlpha: 1, shadow: 0x0B3A1E,
            body: 0x1B2838, beak: 0xFF9F1C, cheekAlpha: 0.55, scenery: .seeds)
        static let sunset = Palette(
            tileTop: 0xFFC75F, tileBottom: 0xFF6F91, drift: 0xFFFFFF, driftAlpha: 0.35, shadow: 0x7A1F3D,
            body: 0x1B2838, beak: 0xFF7A1C, cheekAlpha: 0.55, scenery: .sun)
        static let midnight = Palette(
            tileTop: 0x4C3A8C, tileBottom: 0x0B1026, drift: 0xFFFFFF, driftAlpha: 0.16, shadow: 0x000000,
            body: 0x34466B, beak: 0xFF9F1C, cheekAlpha: 0.45, scenery: .stars)
        static let mono = Palette(
            tileTop: 0xF3F4F6, tileBottom: 0x9CA3AF, drift: 0xFFFFFF, driftAlpha: 0.5, shadow: 0x111827,
            body: 0x1F2937, beak: 0x6B7280, cheekAlpha: 0)
    }

    /// The icon at any size, drawn again for each resolution it is shown at.
    static func image(_ palette: Palette, size: CGFloat = 1024) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            NSGraphicsContext.current?.cgContext.scaleBy(x: rect.width / 1024, y: rect.height / 1024)
            draw(palette)
            return true
        }
    }

    /// Draws into the current graphics context, in a 1024 × 1024 space.
    static func draw(_ palette: Palette) {
        // Tile: the macOS icon grid leaves a 100 px margin around an 824 px rounded square.
        let tile = NSBezierPath(
            roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
        NSGradient(starting: rgb(palette.tileTop), ending: rgb(palette.tileBottom))?.draw(in: tile, angle: -90)
        NSGraphicsContext.saveGraphicsState()
        tile.addClip()
        drawScenery(palette.scenery)
        fill(oval(512, 150, 900, 260), rgb(palette.drift, palette.driftAlpha))  // snow drift, or a rind
        NSGraphicsContext.restoreGraphicsState()

        let navy = rgb(palette.body)
        let orange = rgb(palette.beak)
        fill(oval(512, 205, 400, 56), rgb(palette.shadow, 0.25))  // shadow
        fill(flipper(318, 440, degrees: -22), navy)
        fill(flipper(706, 440, degrees: 22), navy)
        fill(oval(512, 450, 450, 540), navy)  // body
        fill(oval(512, 655, 390, 360), navy)  // head
        fill(oval(512, 405, 310, 400), rgb(0xFFFFFF))  // belly
        fill(oval(445, 192, 130, 54), orange)  // feet
        fill(oval(579, 192, 130, 54), orange)
        fill(oval(452, 640, 190, 190), rgb(0xFFFFFF))  // face
        fill(oval(572, 640, 190, 190), rgb(0xFFFFFF))
        if palette.cheekAlpha > 0 {
            fill(oval(418, 598, 52, 34), rgb(0xFF7A9A, palette.cheekAlpha))  // cheeks
            fill(oval(606, 598, 52, 34), rgb(0xFF7A9A, palette.cheekAlpha))
        }
        for x in [458.0, 566.0] {
            fill(oval(x, 662, 58, 66), navy)  // eyes
            fill(oval(x + 10, 676, 20, 20), rgb(0xFFFFFF))
        }
        let beak = NSBezierPath()
        beak.move(to: NSPoint(x: 476, y: 618))
        beak.line(to: NSPoint(x: 548, y: 618))
        beak.line(to: NSPoint(x: 512, y: 576))
        beak.close()
        beak.lineJoinStyle = .round
        beak.lineWidth = 18
        orange.setStroke()
        beak.stroke()
        fill(beak, orange)
    }

    private static func drawScenery(_ scenery: Scenery) {
        switch scenery {
        case .none:
            break
        case .seeds:
            fill(oval(512, 170, 900, 300), rgb(0xF4FFE8))  // the pale band inside the rind
            for (x, y, degrees) in [(230.0, 790.0, -20.0), (185, 580, 15), (225, 390, -10), (795, 790, 20), (840, 580, -15), (800, 390, 10)] {
                let seed = oval(0, 0, 30, 48)
                var transform = AffineTransform(translationByX: x, byY: y)
                transform.rotate(byDegrees: degrees)
                seed.transform(using: transform)
                fill(seed, rgb(0x1B2838, 0.85))
            }
        case .sun:
            fill(oval(512, 600, 700, 700), rgb(0xFFF1C1, 0.45))
            fill(oval(512, 600, 520, 520), rgb(0xFFF1C1, 0.55))
        case .stars:
            for (x, y, d) in [(220.0, 820.0, 16.0), (330, 720, 10), (190, 600, 12), (300, 470, 8), (860, 520, 10), (810, 640, 8), (250, 300, 9), (840, 330, 11)] {
                fill(oval(x, y, d, d), rgb(0xFFFFFF, 0.9))
            }
            // A crescent: a disc drawn everywhere but inside another.
            NSGraphicsContext.saveGraphicsState()
            let outside = NSBezierPath(rect: NSRect(x: 0, y: 0, width: 1024, height: 1024))
            outside.append(oval(828, 828, 112, 112))
            outside.windingRule = .evenOdd
            outside.addClip()
            fill(oval(790, 800, 130, 130), rgb(0xFFF4C2))
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    private static func rgb(_ hex: Int, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    private static func oval(_ cx: CGFloat, _ cy: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSBezierPath {
        NSBezierPath(ovalIn: NSRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h))
    }

    private static func fill(_ path: NSBezierPath, _ color: NSColor) {
        color.setFill()
        path.fill()
    }

    /// A flipper: an oval turned around its own centre.
    private static func flipper(_ cx: CGFloat, _ cy: CGFloat, degrees: CGFloat) -> NSBezierPath {
        let path = oval(0, 0, 100, 270)
        var transform = AffineTransform(translationByX: cx, byY: cy)
        transform.rotate(byDegrees: degrees)
        path.transform(using: transform)
        return path
    }
}
