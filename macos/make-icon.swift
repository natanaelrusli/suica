// Draws the app icon, a penguin on an ice-blue tile, as a 1024 × 1024 PNG.
// usage: swift macos/make-icon.swift <out.png>
// scripts/install-macos-app.sh turns the PNG into AppIcon.icns.
import AppKit

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <out.png>\n".utf8))
    exit(2)
}

let size = 1024
guard
    let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0),
    let context = NSGraphicsContext(bitmapImageRep: bitmap)
else { exit(1) }

func rgb(_ hex: Int, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func oval(_ cx: CGFloat, _ cy: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSBezierPath {
    NSBezierPath(ovalIn: NSRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h))
}

func fill(_ path: NSBezierPath, _ color: NSColor) {
    color.setFill()
    path.fill()
}

/// A flipper: an oval turned around its own centre.
func flipper(_ cx: CGFloat, _ cy: CGFloat, degrees: CGFloat) -> NSBezierPath {
    let path = oval(0, 0, 100, 270)
    var transform = AffineTransform(translationByX: cx, byY: cy)
    transform.rotate(byDegrees: degrees)
    path.transform(using: transform)
    return path
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context

// Tile: the macOS icon grid leaves a 100 px margin around an 824 px rounded square.
let tile = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
NSGradient(starting: rgb(0x8FE3F5), ending: rgb(0x1C7FD6))?.draw(in: tile, angle: -90)
NSGraphicsContext.saveGraphicsState()
tile.addClip()
fill(oval(512, 150, 900, 260), rgb(0xFFFFFF, 0.35))  // snow drift
NSGraphicsContext.restoreGraphicsState()

let navy = rgb(0x1B2838)
let orange = rgb(0xFF9F1C)
fill(oval(512, 205, 400, 56), rgb(0x0B3A66, 0.25))  // shadow
fill(flipper(318, 440, degrees: -22), navy)
fill(flipper(706, 440, degrees: 22), navy)
fill(oval(512, 450, 450, 540), navy)  // body
fill(oval(512, 655, 390, 360), navy)  // head
fill(oval(512, 405, 310, 400), rgb(0xFFFFFF))  // belly
fill(oval(445, 192, 130, 54), orange)  // feet
fill(oval(579, 192, 130, 54), orange)
fill(oval(452, 640, 190, 190), rgb(0xFFFFFF))  // face
fill(oval(572, 640, 190, 190), rgb(0xFFFFFF))
fill(oval(418, 598, 52, 34), rgb(0xFF7A9A, 0.55))  // cheeks
fill(oval(606, 598, 52, 34), rgb(0xFF7A9A, 0.55))
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

NSGraphicsContext.restoreGraphicsState()

guard let png = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
do {
    try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
} catch {
    FileHandle.standardError.write(Data("make-icon: \(error.localizedDescription)\n".utf8))
    exit(1)
}
