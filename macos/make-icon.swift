// Draws the app icon, a penguin on an ice-blue tile, as a 1024 × 1024 PNG.
// usage: swiftc -parse-as-library macos/Suica/Sources/Suica/AppIconArt.swift macos/make-icon.swift -o make-icon
//        make-icon <out.png> [classic|watermelon|sunset|midnight|mono]
// scripts/install-macos-app.sh turns the classic PNG into AppIcon.icns. The drawing lives in
// AppIconArt.swift, which the app also uses for the icons picked in Appearance.
import AppKit

@main
enum MakeIcon {
    static func main() {
        let arguments = CommandLine.arguments
        let palettes: [String: AppIconArt.Palette] = [
            "classic": .classic, "watermelon": .watermelon, "sunset": .sunset, "midnight": .midnight, "mono": .mono,
        ]
        guard (2...3).contains(arguments.count), let palette = palettes[arguments.count == 3 ? arguments[2] : "classic"]
        else {
            FileHandle.standardError.write(Data("usage: make-icon <out.png> [\(palettes.keys.sorted().joined(separator: "|"))]\n".utf8))
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

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        AppIconArt.draw(palette)
        NSGraphicsContext.restoreGraphicsState()

        guard let png = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
        do {
            try png.write(to: URL(fileURLWithPath: arguments[1]))
        } catch {
            FileHandle.standardError.write(Data("make-icon: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}
