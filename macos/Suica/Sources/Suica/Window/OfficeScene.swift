import AppKit
import RealityKit
import SuicaCore
import SwiftUI

/// Marks the entity a click on a Desk lands on.
struct DeskTag: Component {
    var id: String
}

/// The colours of one building style, environment and appearance.
private struct Palette {
    let floor: NSColor
    /// Every other plank of a project Room's floor.
    let plank: NSColor
    let hallFloor: NSColor
    /// Every other tile of the Center Room's floor.
    let hallTile: NSColor
    let wall: NSColor
    /// The dark top of a wall, where it is cut away to show the room.
    let wallCap: NSColor
    /// The concrete slab the building stands on.
    let plinth: NSColor
    let desk: NSColor
    let deskTop: NSColor
    let deskFrame: NSColor
    let chair: NSColor
    let hedge: NSColor
    let label: NSColor
    let bubble: NSColor
    let bubbleText: NSColor
    let background: NSColor
    let grass: NSColor
    let pavement: NSColor
    let road: NSColor
    let lampGlow: NSColor
    /// A window pane by day; lit warm at night.
    let glass: NSColor
    let windowFrame: NSColor
    let awning: NSColor

    static let light = Palette(
        floor: NSColor(red: 0.86, green: 0.71, blue: 0.52, alpha: 1),
        plank: NSColor(red: 0.81, green: 0.65, blue: 0.46, alpha: 1),
        hallFloor: NSColor(red: 0.74, green: 0.79, blue: 0.84, alpha: 1),
        hallTile: NSColor(red: 0.68, green: 0.74, blue: 0.8, alpha: 1),
        wall: NSColor(white: 0.97, alpha: 1), wallCap: NSColor(white: 0.24, alpha: 1),
        plinth: NSColor(white: 0.72, alpha: 1),
        desk: NSColor(red: 0.78, green: 0.66, blue: 0.5, alpha: 1), deskTop: NSColor(white: 0.96, alpha: 1),
        deskFrame: NSColor(white: 0.42, alpha: 1), chair: NSColor(white: 0.2, alpha: 1),
        hedge: NSColor(red: 0.3, green: 0.56, blue: 0.27, alpha: 1),
        label: NSColor(white: 0.25, alpha: 1),
        bubble: .white, bubbleText: NSColor(white: 0.12, alpha: 1),
        background: NSColor(white: 0.96, alpha: 1),
        grass: NSColor(red: 0.5, green: 0.76, blue: 0.36, alpha: 1), pavement: NSColor(white: 0.84, alpha: 1),
        road: NSColor(white: 0.36, alpha: 1), lampGlow: NSColor(white: 0.92, alpha: 1),
        glass: NSColor(red: 0.72, green: 0.85, blue: 0.93, alpha: 1), windowFrame: NSColor(white: 0.5, alpha: 1),
        awning: NSColor(red: 0.16, green: 0.42, blue: 0.5, alpha: 1))
    static let dark = Palette(
        floor: NSColor(red: 0.42, green: 0.33, blue: 0.24, alpha: 1),
        plank: NSColor(red: 0.38, green: 0.29, blue: 0.21, alpha: 1),
        hallFloor: NSColor(red: 0.2, green: 0.24, blue: 0.31, alpha: 1),
        hallTile: NSColor(red: 0.17, green: 0.21, blue: 0.28, alpha: 1),
        wall: NSColor(white: 0.62, alpha: 1), wallCap: NSColor(white: 0.12, alpha: 1),
        plinth: NSColor(white: 0.3, alpha: 1),
        desk: NSColor(red: 0.45, green: 0.37, blue: 0.28, alpha: 1), deskTop: NSColor(white: 0.66, alpha: 1),
        deskFrame: NSColor(white: 0.25, alpha: 1), chair: NSColor(white: 0.12, alpha: 1),
        hedge: NSColor(red: 0.13, green: 0.25, blue: 0.14, alpha: 1),
        label: NSColor(white: 0.85, alpha: 1),
        bubble: NSColor(white: 0.32, alpha: 1), bubbleText: .white,
        background: NSColor(white: 0.11, alpha: 1),
        grass: NSColor(red: 0.17, green: 0.27, blue: 0.17, alpha: 1), pavement: NSColor(white: 0.32, alpha: 1),
        road: NSColor(white: 0.15, alpha: 1), lampGlow: NSColor(red: 1, green: 0.85, blue: 0.5, alpha: 1),
        glass: NSColor(red: 1, green: 0.88, blue: 0.62, alpha: 1), windowFrame: NSColor(white: 0.2, alpha: 1),
        awning: NSColor(red: 0.1, green: 0.26, blue: 0.32, alpha: 1))

    /// The base appearance with the style's walls, floors and desks and the environment's ground.
    static func make(style: OfficeStyle, environment: OfficeEnvironment, dark: Bool) -> Palette {
        let base = dark ? Palette.dark : Palette.light
        func rgb(_ red: Double, _ green: Double, _ blue: Double) -> NSColor {
            NSColor(red: red, green: green, blue: blue, alpha: 1)
        }
        func pick(_ light: NSColor, _ night: NSColor) -> NSColor { dark ? night : light }
        var wall = base.wall
        var wallCap = base.wallCap
        var floor = base.floor
        var plank = base.plank
        var hallFloor = base.hallFloor
        var hallTile = base.hallTile
        var desk = base.desk
        var deskTop = base.deskTop
        var deskFrame = base.deskFrame
        var plinth = base.plinth
        var windowFrame = base.windowFrame
        var awning = base.awning
        switch style {
        case .modern: break
        case .brick:
            wall = pick(rgb(0.72, 0.33, 0.26), rgb(0.42, 0.2, 0.16))
            wallCap = pick(rgb(0.93, 0.88, 0.78), rgb(0.5, 0.46, 0.4))
            floor = pick(rgb(0.8, 0.5, 0.36), rgb(0.4, 0.26, 0.19))
            plank = pick(rgb(0.74, 0.45, 0.32), rgb(0.36, 0.23, 0.17))
            hallFloor = pick(rgb(0.7, 0.69, 0.66), rgb(0.24, 0.24, 0.23))
            hallTile = pick(rgb(0.64, 0.63, 0.6), rgb(0.2, 0.2, 0.19))
            desk = pick(rgb(0.5, 0.36, 0.26), rgb(0.3, 0.22, 0.16))
            deskTop = pick(rgb(0.9, 0.85, 0.76), rgb(0.5, 0.46, 0.4))
            plinth = pick(rgb(0.6, 0.55, 0.5), rgb(0.26, 0.24, 0.22))
            windowFrame = pick(rgb(0.93, 0.88, 0.78), rgb(0.5, 0.46, 0.4))
            awning = pick(rgb(0.16, 0.3, 0.2), rgb(0.1, 0.18, 0.13))
        case .glass:
            wall = pick(rgb(0.7, 0.86, 0.9), rgb(0.3, 0.42, 0.48))
            wallCap = pick(rgb(0.2, 0.22, 0.25), rgb(0.08, 0.09, 0.1))
            floor = pick(NSColor(white: 0.78, alpha: 1), NSColor(white: 0.36, alpha: 1))
            plank = pick(NSColor(white: 0.74, alpha: 1), NSColor(white: 0.33, alpha: 1))
            hallFloor = pick(rgb(0.3, 0.32, 0.36), rgb(0.14, 0.15, 0.18))
            hallTile = pick(rgb(0.26, 0.28, 0.32), rgb(0.11, 0.12, 0.15))
            desk = pick(NSColor(white: 0.6, alpha: 1), NSColor(white: 0.3, alpha: 1))
            deskTop = pick(NSColor(white: 0.98, alpha: 1), NSColor(white: 0.7, alpha: 1))
            deskFrame = pick(NSColor(white: 0.3, alpha: 1), NSColor(white: 0.18, alpha: 1))
            plinth = pick(NSColor(white: 0.62, alpha: 1), NSColor(white: 0.26, alpha: 1))
            windowFrame = wallCap
            awning = wallCap
        case .timber:
            wall = pick(rgb(0.78, 0.58, 0.36), rgb(0.4, 0.3, 0.18))
            wallCap = pick(rgb(0.45, 0.3, 0.17), rgb(0.22, 0.15, 0.09))
            floor = pick(rgb(0.52, 0.36, 0.24), rgb(0.28, 0.19, 0.13))
            plank = pick(rgb(0.46, 0.31, 0.2), rgb(0.24, 0.16, 0.11))
            hallFloor = pick(rgb(0.7, 0.3, 0.28), rgb(0.35, 0.15, 0.14))
            hallTile = pick(rgb(0.62, 0.26, 0.24), rgb(0.3, 0.13, 0.12))
            desk = pick(rgb(0.55, 0.38, 0.24), rgb(0.3, 0.21, 0.13))
            deskTop = pick(rgb(0.76, 0.58, 0.4), rgb(0.45, 0.34, 0.23))
            deskFrame = pick(rgb(0.4, 0.28, 0.17), rgb(0.2, 0.14, 0.09))
            plinth = pick(rgb(0.6, 0.58, 0.54), rgb(0.26, 0.25, 0.23))
            windowFrame = wallCap
            awning = pick(rgb(0.55, 0.2, 0.18), rgb(0.3, 0.12, 0.1))
        }
        var grass = base.grass
        var pavement = base.pavement
        var road = base.road
        var hedge = base.hedge
        switch environment {
        case .city: break
        case .park:
            grass = pick(rgb(0.48, 0.74, 0.34), rgb(0.16, 0.27, 0.16))
            pavement = pick(rgb(0.8, 0.78, 0.72), rgb(0.3, 0.29, 0.27))
            road = pick(rgb(0.8, 0.74, 0.62), rgb(0.32, 0.3, 0.26))
        case .snow:
            grass = pick(rgb(0.95, 0.96, 0.98), rgb(0.4, 0.42, 0.48))
            pavement = pick(rgb(0.9, 0.91, 0.93), rgb(0.36, 0.37, 0.4))
            road = pick(NSColor(white: 0.3, alpha: 1), NSColor(white: 0.12, alpha: 1))
            hedge = pick(rgb(0.26, 0.42, 0.24), rgb(0.12, 0.2, 0.12))
        }
        return Palette(
            floor: floor, plank: plank, hallFloor: hallFloor, hallTile: hallTile, wall: wall, wallCap: wallCap,
            plinth: plinth, desk: desk, deskTop: deskTop, deskFrame: deskFrame, chair: base.chair, hedge: hedge,
            label: base.label, bubble: base.bubble, bubbleText: base.bubbleText, background: base.background,
            grass: grass, pavement: pavement, road: road, lampGlow: base.lampGlow, glass: base.glass,
            windowFrame: windowFrame, awning: awning)
    }
}

private func material(_ colour: NSColor, roughness: Float = 0.7) -> SimpleMaterial {
    SimpleMaterial(color: colour, roughness: MaterialScalarParameter(floatLiteral: roughness), isMetallic: false)
}

/// A see-through pane, for the glass style's walls.
private func glassMaterial(_ colour: NSColor, opacity: Float) -> PhysicallyBasedMaterial {
    var pane = PhysicallyBasedMaterial()
    pane.baseColor = .init(tint: colour)
    pane.roughness = .init(floatLiteral: 0.2)
    pane.blending = .transparent(opacity: .init(floatLiteral: opacity))
    return pane
}

/// A square texture painted with Core Graphics, on a flat card: the sun, the moon, a lamp's haze
/// or a monitor's screen. `paint` draws around the centre; the second argument is the card's half
/// width. Unlit and kept out of tone mapping, so a bright yellow stays yellow rather than olive. If
/// the texture cannot be made the card is left invisible: a plain colour would draw a square.
@MainActor
private func paintedCard(_ paint: (CGContext, CGFloat) -> Void) -> UnlitMaterial {
    var card = UnlitMaterial(applyPostProcessToneMap: false)
    card.blending = .transparent(opacity: .init(floatLiteral: 0))
    let size = 512
    guard
        let space = CGColorSpace(name: CGColorSpace.sRGB),
        let context = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 16, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue)
    else { return card }
    context.translateBy(x: CGFloat(size) / 2, y: CGFloat(size) / 2)
    paint(context, CGFloat(size) / 2)
    guard let image = context.makeImage(),
        let texture = try? TextureResource(image: image, options: .init(semantic: .color))
    else { return card }
    card.color = .init(tint: .white, texture: .init(texture))
    card.blending = .transparent(opacity: .init(floatLiteral: 1))
    return card
}

/// Fills `radius` around the centre with `colour`, its opacity falling off through `stops`
/// (fraction of the radius, opacity).
private func radialFill(_ context: CGContext, radius: CGFloat, _ colour: NSColor, _ stops: [(CGFloat, CGFloat)]) {
    let colours = stops.map { colour.withAlphaComponent($0.1).cgColor } as CFArray
    guard let gradient = CGGradient(colorsSpace: context.colorSpace, colors: colours, locations: stops.map(\.0))
    else { return }
    context.drawRadialGradient(
        gradient, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: radius, options: [])
}

/// A solid disc, lighter in the middle than at its rim.
private func disc(_ context: CGContext, radius: CGFloat, centre: NSColor, rim: NSColor) {
    let colours = [centre.cgColor, rim.cgColor] as CFArray
    guard let gradient = CGGradient(colorsSpace: context.colorSpace, colors: colours, locations: [0, 1]) else { return }
    context.saveGState()
    context.addEllipse(in: CGRect(x: -radius, y: -radius, width: 2 * radius, height: 2 * radius))
    context.clip()
    context.drawRadialGradient(
        gradient, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: radius, options: [])
    context.restoreGState()
}

/// A bright disc in a warm haze that fades into the sky.
@MainActor private let sunFace = paintedCard { context, half in
    radialFill(
        context, radius: half, NSColor(red: 1, green: 0.92, blue: 0.6, alpha: 1),
        [(0, 0.95), (0.3, 0.85), (0.4, 0.5), (0.6, 0.18), (0.8, 0.05), (1, 0)])
    disc(
        context, radius: 0.3 * half, centre: NSColor(red: 1, green: 0.99, blue: 0.9, alpha: 1),
        rim: NSColor(red: 1, green: 0.86, blue: 0.4, alpha: 1))
}

/// Long and short rays, alternating, that fade as they reach out; they turn slowly behind the sun.
@MainActor private let sunRays = paintedCard { context, half in
    let count = 12
    for index in 0..<count {
        let angle = CGFloat(index) / CGFloat(count) * 2 * .pi
        let length = (index.isMultiple(of: 2) ? 0.95 : 0.72) * half
        let spread: CGFloat = 0.07
        context.move(to: CGPoint(x: cos(angle - spread) * 0.3 * half, y: sin(angle - spread) * 0.3 * half))
        context.addLine(to: CGPoint(x: cos(angle) * length, y: sin(angle) * length))
        context.addLine(to: CGPoint(x: cos(angle + spread) * 0.3 * half, y: sin(angle + spread) * 0.3 * half))
        context.closePath()
    }
    context.clip()
    radialFill(
        context, radius: half, NSColor(red: 1, green: 0.88, blue: 0.55, alpha: 1),
        [(0, 0.55), (0.3, 0.5), (0.6, 0.18), (1, 0)])
}

/// A pale disc with a cool glow around it.
@MainActor private let moonFace = paintedCard { context, half in
    radialFill(
        context, radius: half, NSColor(red: 0.72, green: 0.8, blue: 1, alpha: 1),
        [(0, 0.6), (0.27, 0.5), (0.4, 0.2), (0.62, 0.06), (1, 0)])
    disc(
        context, radius: 0.27 * half, centre: NSColor(red: 0.98, green: 0.98, blue: 1, alpha: 1),
        rim: NSColor(red: 0.84, green: 0.87, blue: 0.95, alpha: 1))
}

/// The haze round a lit street lamp. It writes no depth, so its clear rim hides nothing behind it.
@MainActor private let lampHalo: UnlitMaterial = {
    var card = paintedCard { context, half in
        radialFill(
            context, radius: half, NSColor(red: 1, green: 0.82, blue: 0.5, alpha: 1),
            [(0, 0.9), (0.1, 0.75), (0.25, 0.32), (0.5, 0.1), (0.75, 0.03), (1, 0)])
    }
    card.writesDepth = false
    return card
}()

/// A monitor at work: a dark editor with lines of code in a few colours, under a cyan glow at the
/// edge. The lines are the same on every monitor; they are too small to tell apart.
@MainActor private let screenWorking = paintedCard { context, half in
    context.setFillColor(NSColor(red: 0.08, green: 0.12, blue: 0.2, alpha: 1).cgColor)
    context.fill(CGRect(x: -half, y: -half, width: 2 * half, height: 2 * half))
    context.setStrokeColor(NSColor(red: 0.45, green: 0.85, blue: 1, alpha: 1).cgColor)
    context.setLineWidth(half * 0.06)
    context.stroke(CGRect(x: -half, y: -half, width: 2 * half, height: 2 * half))
    let inks = [
        NSColor(red: 0.55, green: 0.8, blue: 1, alpha: 1), NSColor(red: 1, green: 0.78, blue: 0.4, alpha: 1),
        NSColor(red: 0.7, green: 0.9, blue: 0.6, alpha: 1), NSColor(red: 0.95, green: 0.6, blue: 0.75, alpha: 1),
        NSColor(white: 0.8, alpha: 1),
    ]
    var seed = OfficeSeed("screen")
    let rows = 11
    for row in 0..<rows {
        let y = half * 0.78 - CGFloat(row) * half * 1.6 / CGFloat(rows)
        let indent = CGFloat(Int.random(in: 0...3, using: &seed)) * half * 0.12
        var x = -half * 0.8 + indent
        let words = Int.random(in: 1...4, using: &seed)
        for _ in 0..<words {
            let width = CGFloat(Int.random(in: 2...7, using: &seed)) * half * 0.055
            context.setFillColor(inks[Int.random(in: 0..<inks.count, using: &seed)].cgColor)
            context.fill(CGRect(x: x, y: y, width: width, height: half * 0.08))
            x += width + half * 0.05
            if x > half * 0.8 { break }
        }
    }
}

/// A monitor with a game on: a night sky over a row of coloured blocks, a little hero mid-jump and a
/// coin above, so it reads as play rather than work from across the room.
@MainActor private let screenGame = paintedCard { context, half in
    context.setFillColor(NSColor(red: 0.1, green: 0.06, blue: 0.22, alpha: 1).cgColor)
    context.fill(CGRect(x: -half, y: -half, width: 2 * half, height: 2 * half))
    context.setStrokeColor(NSColor(red: 0.95, green: 0.45, blue: 0.85, alpha: 1).cgColor)
    context.setLineWidth(half * 0.06)
    context.stroke(CGRect(x: -half, y: -half, width: 2 * half, height: 2 * half))
    let blocks = [
        NSColor(red: 0.95, green: 0.35, blue: 0.4, alpha: 1), NSColor(red: 1, green: 0.8, blue: 0.25, alpha: 1),
        NSColor(red: 0.35, green: 0.85, blue: 0.5, alpha: 1), NSColor(red: 0.35, green: 0.65, blue: 1, alpha: 1),
    ]
    let size = half * 0.25
    for column in 0..<8 {
        context.setFillColor(blocks[column % blocks.count].cgColor)
        context.fill(CGRect(x: -half + CGFloat(column) * size, y: -half, width: size * 0.92, height: size * 0.92))
    }
    context.setFillColor(NSColor.white.cgColor)
    context.fill(CGRect(x: -half * 0.2, y: -half * 0.35, width: half * 0.2, height: half * 0.3))
    context.setFillColor(NSColor(red: 1, green: 0.85, blue: 0.3, alpha: 1).cgColor)
    context.fillEllipse(in: CGRect(x: half * 0.3, y: half * 0.3, width: half * 0.18, height: half * 0.18))
}

/// A monitor waiting for the Owner: amber, with a question mark.
@MainActor private let screenWaiting = paintedCard { context, half in
    context.setFillColor(NSColor(red: 1, green: 0.72, blue: 0.2, alpha: 1).cgColor)
    context.fill(CGRect(x: -half, y: -half, width: 2 * half, height: 2 * half))
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    let text = "?" as NSString
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: half * 1.5, weight: .bold), .foregroundColor: NSColor(white: 0.12, alpha: 1),
    ]
    let size = text.size(withAttributes: attributes)
    text.draw(at: NSPoint(x: -size.width / 2, y: -size.height / 2), withAttributes: attributes)
    NSGraphicsContext.restoreGraphicsState()
}

private func nsColour(_ colour: OfficeColour) -> NSColor {
    NSColor(red: colour.red, green: colour.green, blue: colour.blue, alpha: 1)
}

private let amber = NSColor(red: 1.0, green: 0.72, blue: 0.2, alpha: 1)

/// A Room's floor, walls and name.
private struct RoomNode {
    let entity: Entity
    let signature: String
}

/// A part of a figure and the colour it has while its Session is live.
private struct FigurePart {
    let entity: ModelEntity
    let colour: OfficeColour
}

/// A figure's joints. Each is a pivot: its limb hangs down from it, so a turn about x swings the
/// limb forward (the figure faces -z at yaw 0) and a turn about z swings it out to the side.
private struct FigureRig {
    /// On the floor, under the figure; turned to face where it walks.
    let root: Entity
    /// At hip height: lower when seated, bouncing a little when walking.
    let pelvis: Entity
    let torso: Entity
    /// At the neck.
    let head: Entity
    /// Left then right.
    let shoulders: [Entity]
    let elbows: [Entity]
    let hips: [Entity]
    let knees: [Entity]
    let parts: [FigurePart]
    /// A phone in the right hand, parked far below it while the figure does not hold one.
    let phone: Entity

    static let standingHip: Float = 0.7
    /// Where the phone sits in the right hand, along the forearm past the fingers.
    static let phoneInHand = SIMD3<Float>(0, -0.3, 0)
    static let seatedHip: Float = 0.4
}

/// How a figure holds itself: the hip height and a turn per joint.
private struct Pose {
    var hip: Float = FigureRig.standingHip
    var torsoPitch: Float = 0
    var torsoYaw: Float = 0
    var headPitch: Float = 0
    var headYaw: Float = 0
    /// Per arm: forward swing and sideways lift.
    var shoulderPitch: [Float] = [0, 0]
    var shoulderRoll: [Float] = [0, 0]
    var elbow: [Float] = [0, 0]
    var hipPitch: [Float] = [0, 0]
    var knee: [Float] = [0, 0]

    static let standing = Pose()

    /// On the chair, legs under the desk, elbows low and the forearms up to the keyboard.
    static let seated = Pose(
        hip: FigureRig.seatedHip, torsoPitch: -0.08, shoulderPitch: [1.0, 1.0], elbow: [0.95, 0.95],
        hipPitch: [.pi / 2, .pi / 2], knee: [-.pi / 2, -.pi / 2])

    /// Typing: the forearms tap in turn and the head bobs a little.
    static func typing(at time: Float) -> Pose {
        var pose = seated
        pose.elbow = [0.95 + 0.12 * sin(time * 9), 0.95 + 0.12 * sin(time * 9 + .pi)]
        pose.headPitch = 0.04 * sin(time * 2.3)
        return pose
    }

    /// Nodding off: leaning back, arms in the lap, the head sinking and lifting slowly.
    static func dozing(at time: Float) -> Pose {
        var pose = seated
        pose.torsoPitch = 0.22
        pose.shoulderPitch = [0.2, 0.2]
        pose.elbow = [0.7, 0.7]
        pose.headPitch = 0.3 + 0.12 * sin(time * 1.3)
        return pose
    }

    /// Standing beside the desk, one arm up, waving.
    static func waving(at time: Float) -> Pose {
        var pose = standing
        pose.shoulderRoll = [0, 2.7]
        pose.elbow = [0, 0.5 + 0.35 * sin(time * 6)]
        pose.shoulderPitch = [0.1, 0]
        return pose
    }

    /// Standing, hands behind the back, the head tilting now and then: the boss listening.
    static func listening(at time: Float) -> Pose {
        var pose = standing
        pose.shoulderPitch = [-0.35, -0.35]
        pose.shoulderRoll = [0.12, 0.12]
        pose.elbow = [0.55, 0.55]
        pose.headPitch = 0.06 + 0.04 * sin(time * 0.8)
        return pose
    }

    /// Talking to the worker: the right hand points, the left rests at the side, the head nods.
    static func instructing(at time: Float) -> Pose {
        var pose = standing
        pose.torsoPitch = -0.05
        pose.shoulderPitch = [0.15, 1.25 + 0.15 * sin(time * 5)]
        pose.elbow = [0.35, 0.2 + 0.1 * sin(time * 5 + 1)]
        pose.headPitch = 0.08 * sin(time * 3.2)
        return pose
    }

    /// Holding a phone up in front of the chest with both hands, the head bowed to it, the thumb
    /// scrolling now and then.
    static func phoning(at time: Float, seated: Bool) -> Pose {
        var pose = seated ? Pose.seated : Pose.standing
        pose.shoulderPitch = [0.45, 0.3]
        pose.shoulderRoll = [-0.25, -0.15]
        pose.elbow = [1.7, 2.05 + 0.05 * sin(time * 3)]
        pose.headPitch = 0.35 + 0.03 * sin(time * 0.7)
        if seated { pose.torsoPitch = 0.05 }
        return pose
    }

    /// Playing a game on the monitor: leaning in, hands hammering the keys, swaying with the play.
    static func gaming(at time: Float) -> Pose {
        var pose = seated
        pose.torsoPitch = -0.16
        pose.torsoYaw = 0.07 * sin(time * 1.7)
        pose.shoulderPitch = [1.15, 1.15]
        pose.elbow = [0.85 + 0.1 * sin(time * 15), 0.85 + 0.1 * sin(time * 13 + 1)]
        pose.headPitch = -0.05 + 0.05 * sin(time * 4)
        return pose
    }

    /// Standing beside the desk, both arms up, leaning one way then the other.
    static func stretching(at time: Float) -> Pose {
        var pose = standing
        let sway = sin(time * 0.9)
        pose.shoulderRoll = [2.75 + 0.15 * sway, 2.75 - 0.15 * sway]
        pose.elbow = [0.3, 0.3]
        pose.torsoPitch = 0.08 + 0.04 * sin(time * 1.8)
        pose.torsoYaw = 0.12 * sway
        pose.headPitch = 0.15
        return pose
    }

    /// Chatting, facing the partner. The one speaking talks with a hand and the head; the other
    /// nods along with its hands loosely together in front.
    static func talking(at time: Float, speaking: Bool) -> Pose {
        var pose = standing
        if speaking {
            pose.shoulderPitch = [0.1, 0.55 + 0.2 * sin(time * 2.6)]
            pose.shoulderRoll = [0, 0.25 + 0.1 * sin(time * 1.9)]
            pose.elbow = [0.2, 1.1 + 0.35 * sin(time * 3.4)]
            pose.headPitch = 0.06 * sin(time * 3)
            pose.headYaw = 0.1 * sin(time * 1.3)
        } else {
            pose.shoulderPitch = [0.35, 0.35]
            pose.shoulderRoll = [-0.2, -0.2]
            pose.elbow = [0.9, 0.9]
            pose.headPitch = 0.08 + 0.06 * sin(time * 1.6)
        }
        return pose
    }

    /// Out for a stroll and standing still for a moment: hands behind the back, looking round.
    static func lookingAround(at time: Float) -> Pose {
        var pose = listening(at: time)
        pose.headYaw = 0.6 * sin(time * 0.45)
        pose.torsoYaw = 0.15 * sin(time * 0.45)
        return pose
    }

    /// One stride: the legs swing against the arms, a knee bends on the back swing.
    static func walking(phase: Float) -> Pose {
        var pose = standing
        let swing = sin(phase)
        pose.hip = FigureRig.standingHip + 0.02 * abs(cos(phase))
        pose.hipPitch = [0.45 * swing, -0.45 * swing]
        pose.knee = [0.5 * max(0, -swing), 0.5 * max(0, swing)]
        pose.shoulderPitch = [-0.35 * swing, 0.35 * swing]
        pose.elbow = [0.3, 0.3]
        return pose
    }
}

/// Where a figure is going: its chair, a spot beside the desk, a spot in the Center Room (facing
/// a point there, or the viewer when there is none) or out of the office.
private enum FigureGoal: Equatable {
    case seated, standingBy, gone
    case away(OfficePoint, facing: OfficePoint?)
}

/// A figure on its way: along `path`, `walked` metres so far, to `goal`.
private struct Walk {
    let path: OfficePath
    var walked: Float
    let goal: FigureGoal
}

/// One Desk: its furniture, its figure and its bubble.
private struct DeskNode {
    let entity: Entity
    var rig: FigureRig
    let screen: ModelEntity
    let bubble: Entity
    let rug: ModelEntity
    var bubbleText: String
    var status: OfficeStatus
    var agent: String
    var dark: Bool
    var target: SIMD3<Float>
    /// The way from the Room's doorway to the chair.
    var way: OfficePath
    /// Where the figure stands or sits now, when it is not walking.
    var at: FigureGoal
    var walk: Walk?
    /// The stride cycle while walking.
    var stride: Float
    /// What the figure does while its Session is idle; nil otherwise, and before its first turn.
    var activity: OfficeIdleActivity?
}

/// How the Owner wants the office shown, beyond its style and environment.
struct OfficeSceneOptions: Equatable {
    var bubbles = OfficeBubbles.all
    /// Walkers, cyclists and cars on the street.
    var streetLife = true
    /// The camera turns slowly round the office (only with animation).
    var slowTurn = false
}

/// Where the boss should be: at a Desk (by Session id), saying something or listening.
struct OfficeBossOrder: Equatable {
    let deskId: String
    /// What the boss says, already short enough for a bubble; nil while the Owner is still writing.
    let speech: String?
}

/// Where the boss is going: to the spot beside a worker's desk, or out of the Room.
private enum BossGoal: Equatable {
    case attending, out
}

/// The boss: one figure, kept under the lawn until the Owner writes to an agent.
private struct BossNode {
    let rig: FigureRig
    /// Above the head, facing the camera; under the lawn while the boss says nothing.
    let bubble: Entity
    /// The Desk the boss is at or on the way to or from.
    var deskId: String?
    var at = BossGoal.out
    var path: OfficePath?
    var walked: Float = 0
    var goal = BossGoal.out
    var stride: Float = 0
    var speech: String?
}

/// One traveller on the street, with the limbs that swing and the wheels that turn as it goes.
private struct TravellerNode {
    let entity: Entity
    let traveller: OfficeTraveller
    let limbs: [Entity]
    let wheels: [Entity]
}

/// Builds and updates the RealityKit scene from the model: a Room per project, a Desk per
/// Session. It owns the camera, so the page can orbit, zoom and reset it.
@MainActor
final class OfficeSceneController {
    let root = Entity()
    let camera = PerspectiveCamera()
    /// The sun by day, the moon by night: a flat card fixed in the sky where the default view shows
    /// it at the top, so it stays put while the view is turned, like the rest of the scene. It is
    /// turned to face the camera each time the view moves.
    private let sun = ModelEntity(mesh: .generatePlane(width: 10, height: 10), materials: [])
    /// The sun's rays, behind its face; hidden at night.
    private let rays = ModelEntity(mesh: .generatePlane(width: 10, height: 10), materials: [sunRays])
    /// The sun by day, a dimmer moon by night, so the street lamps' light shows on the ground.
    private let key = DirectionalLight()
    private let fill = DirectionalLight()
    /// The haze round each lit street lamp, turned to face the camera like the sun.
    private var halos: [Entity] = []
    private var rooms: [String: RoomNode] = [:]
    private var desks: [String: DeskNode] = [:]
    private var street: OfficeStreet?
    private var streetEntity: Entity?
    private var streetSignature = ""
    private var travellers: [TravellerNode] = []
    private var options = OfficeSceneOptions()
    private var boss: BossNode?
    /// The Center Room, where idle figures meet.
    private var hall: PlacedRoom?
    /// The idle turn the activities were last picked for.
    private var idleTurn = -1
    private var clock: Float = 0
    private var updates: EventSubscription?
    private var animate = true
    private var dark = false
    private var style = OfficeStyle.modern
    private var environment = OfficeEnvironment.city
    private var layoutExtent = SIMD2<Float>(8, 6)
    private static let doorWidth: Float = 1.4
    private static let wallHeight: Float = 0.55
    /// How fast a figure walks, in metres per second, and how many strides it takes per metre.
    private static let walkSpeed: Float = 1.0
    private static let strideRate: Float = 6.5

    // The camera: where it looks, how it is turned and how far it stands.
    static let defaultYaw: Float = 0.42
    static let defaultPitch: Float = 0.66
    private(set) var yaw = OfficeSceneController.defaultYaw
    private(set) var pitch = OfficeSceneController.defaultPitch
    private var zoom: Float = 1
    /// The floor point the camera looks at.
    private var focus = SIMD3<Float>.zero
    private var aspect: Float = 1.6
    /// The Owner moved the camera: stop refitting it when the office changes.
    private(set) var adjusted = false

    init() {
        camera.camera.fieldOfViewInDegrees = 35
        camera.camera.near = 0.1
        camera.camera.far = 200
        root.addChild(camera)
        root.addChild(sun)
        rays.position.z = -0.2
        sun.addChild(rays)
        key.light.intensity = 3_800
        // Soft shadows under the desks, figures and furniture give the floor plan its depth.
        key.shadow = DirectionalLightComponent.Shadow(maximumDistance: 60, depthBias: 3)
        key.look(at: .zero, from: [-4, 8, 6], relativeTo: nil)
        fill.light.intensity = 1_500
        fill.look(at: .zero, from: [6, 5, 3], relativeTo: nil)
        root.addChild(key)
        root.addChild(fill)
        let rig = dress(OfficeLook.boss)
        // A tie, so the boss reads as the boss from afar.
        let tie = ModelEntity(
            mesh: .generateBox(size: [0.05, 0.22, 0.02]),
            materials: [material(NSColor(red: 0.75, green: 0.12, blue: 0.15, alpha: 1))])
        tie.position = [0, 0.33, -0.165]
        rig.torso.addChild(tie)
        apply(.standing, to: rig)
        rig.root.position.y = Self.hidden
        root.addChild(rig.root)
        let bubble = Entity()
        bubble.position = [0, Self.hidden, 0]
        bubble.components.set(BillboardComponent())
        rig.root.addChild(bubble)
        boss = BossNode(rig: rig, bubble: bubble)
        applyCamera()
    }

    func install(into content: inout RealityViewCameraContent) {
        content.camera = .virtual
        content.add(root)
        updates = content.subscribe(to: SceneEvents.Update.self) { [weak self] event in
            let delta = Float(event.deltaTime)
            Task { @MainActor in self?.tick(delta) }
        }
    }

    // MARK: Camera

    private var fitDistance: Float { fitDistance(yaw: yaw, pitch: pitch) }

    private func fitDistance(yaw: Float, pitch: Float) -> Float {
        let vertical = camera.camera.fieldOfViewInDegrees * .pi / 180
        let horizontal = 2 * atan(tan(vertical / 2) * aspect)
        // What the floor covers on screen, turned by the camera's yaw and tilted by its pitch.
        let across = 0.5 * (layoutExtent.x * abs(cos(yaw)) + layoutExtent.y * abs(sin(yaw))) + 1.2
        let deep = 0.5 * (layoutExtent.x * abs(sin(yaw)) + layoutExtent.y * abs(cos(yaw)))
        let up = deep * sin(pitch) + 1.6 * cos(pitch) + 0.8
        return max(across / tan(horizontal / 2), up / tan(vertical / 2))
    }

    /// Where the camera stands, looking at `focus`, for a yaw, a pitch and a distance.
    private static func eye(yaw: Float, pitch: Float, distance: Float) -> SIMD3<Float> {
        let ground = cos(pitch) * distance
        return [sin(yaw) * ground, sin(pitch) * distance, cos(yaw) * ground]
    }

    private func applyCamera() {
        let eye = Self.eye(yaw: yaw, pitch: pitch, distance: max(3, fitDistance * zoom))
        camera.look(at: focus, from: focus + eye, relativeTo: nil)
        placeSun()
        faceHalos()
        faceStandingFigures()
    }

    private func faceHalos() {
        let facing = camera.orientation(relativeTo: nil)
        for halo in halos { halo.setOrientation(facing, relativeTo: nil) }
    }

    /// A figure standing beside its desk looks at the viewer, wherever the view is turned.
    private func faceStandingFigures() {
        for node in desks.values where node.at == .standingBy && node.walk == nil {
            node.rig.root.orientation = simd_quatf(angle: .pi + yaw, axis: [0, 1, 0])
        }
        for node in desks.values where node.walk == nil {
            if case .away(_, facing: nil) = node.at {
                node.rig.root.orientation = simd_quatf(angle: .pi + yaw, axis: [0, 1, 0])
            }
        }
    }

    /// In the top right of the sky of the default view, behind the whole scene, its glow clear of
    /// that view's edges and its face above the trees, and fixed there: orbiting, panning and
    /// zooming move the view past it. When the view is turned so ground fills the top, the ground
    /// hides it. The card faces the camera wherever it is.
    private func placeSun() {
        let from = Self.eye(
            yaw: Self.defaultYaw, pitch: Self.defaultPitch,
            distance: max(3, fitDistance(yaw: Self.defaultYaw, pitch: Self.defaultPitch)))
        let forward = normalize(-from)
        let right = normalize(cross(forward, [0, 1, 0]))
        let up = cross(right, forward)
        let depth: Float = 60
        let half = depth * tan(camera.camera.fieldOfViewInDegrees * .pi / 360)
        sun.position = from + forward * depth + right * (0.4 * half * aspect) + up * (0.85 * half)
        sun.orientation = camera.orientation(relativeTo: nil)
    }

    func setAspect(_ value: Float) {
        guard value.isFinite, value > 0, abs(value - aspect) > 0.01 else { return }
        aspect = value
        applyCamera()
    }

    func orbit(deltaX: Float, deltaY: Float) {
        adjusted = true
        yaw -= deltaX * 0.008
        pitch = min(1.35, max(0.15, pitch + deltaY * 0.006))
        applyCamera()
    }

    /// Slides the view over the floor, by screen points: the scene follows the pointer.
    func pan(deltaX: Float, deltaY: Float) {
        adjusted = true
        let scale = max(3, fitDistance * zoom) * 0.0011
        let right = SIMD3<Float>(cos(yaw), 0, -sin(yaw))
        let away = SIMD3<Float>(-sin(yaw), 0, -cos(yaw))
        focus -= right * deltaX * scale
        focus += away * deltaY * scale
        // Not further than the floor's edge, so the office cannot be lost off screen.
        focus.x = min(layoutExtent.x / 2 + 2, max(-layoutExtent.x / 2 - 2, focus.x))
        let front = street.map { Float($0.pavements[1]) } ?? layoutExtent.y / 2
        focus.z = min(front + 1, max(-layoutExtent.y / 2 - 2, focus.z))
        applyCamera()
    }

    func zoom(by factor: Float) {
        adjusted = true
        zoom = min(2.2, max(0.25, zoom / factor))
        applyCamera()
    }

    func resetCamera() {
        adjusted = false
        yaw = Self.defaultYaw
        pitch = Self.defaultPitch
        zoom = 1
        focus = .zero
        applyCamera()
    }

    // MARK: Sync

    func sync(
        layout: OfficeLayout, sessions: [OfficeSession], selected: String?, style: OfficeStyle,
        environment: OfficeEnvironment, dark: Bool, animate: Bool, options: OfficeSceneOptions = .init(),
        boss order: OfficeBossOrder? = nil
    ) {
        self.animate = animate
        self.options = options
        let darkChanged = self.dark != dark
        self.dark = dark
        self.style = style
        self.environment = environment
        let palette = Palette.make(style: style, environment: environment, dark: dark)
        layoutExtent = SIMD2(Float(layout.width), Float(layout.depth))
        if !adjusted { applyCamera() }
        if hall != layout.center {
            hall = layout.center
            // Meeting spots move with the Center Room: pick again for the new one.
            idleTurn = -1
        }

        // Rooms: the project Rooms and the Center Room they open onto. A wall on the building's
        // edge is an outer wall and gets windows.
        var liveRooms = Set<String>()
        for room in layout.all {
            liveRooms.insert(room.path)
            var outer = Set<OfficeSide>()
            if abs(room.center.z - room.depth / 2 + layout.depth / 2) < 0.01 { outer.insert(.north) }
            if abs(room.center.z + room.depth / 2 - layout.depth / 2) < 0.01 { outer.insert(.south) }
            if abs(room.center.x - room.width / 2 + layout.width / 2) < 0.01 { outer.insert(.west) }
            if abs(room.center.x + room.width / 2 - layout.width / 2) < 0.01 { outer.insert(.east) }
            outer = outer.intersection(room.walls)
            let walls = room.walls.map(\.rawValue).sorted().joined(separator: ",")
            let outerWalls = outer.map(\.rawValue).sorted().joined(separator: ",")
            let signature =
                "\(room.name)|\(room.width)|\(room.depth)|\(walls)|\(outerWalls)|\(room.door?.rawValue ?? "")|\(dark)|\(style)"
            if rooms[room.path]?.signature != signature {
                rooms[room.path]?.entity.removeFromParent()
                let entity = makeRoom(room, outer: outer, palette)
                root.addChild(entity)
                rooms[room.path] = RoomNode(entity: entity, signature: signature)
            }
            rooms[room.path]?.entity.position = [Float(room.center.x), 0, Float(room.center.z)]
        }
        for (path, node) in rooms where !liveRooms.contains(path) {
            node.entity.removeFromParent()
            rooms[path] = nil
        }

        // The street outside, laid out again only when the building's size or the look changes.
        let streetSignature = "\(layout.width)|\(layout.depth)|\(dark)|\(style)|\(environment)|\(options.streetLife)"
        if streetSignature != self.streetSignature {
            self.streetSignature = streetSignature
            streetEntity?.removeFromParent()
            let street = OfficeStreet(layout: layout)
            let entity = makeStreet(street, layout: layout, palette)
            root.addChild(entity)
            self.street = street
            streetEntity = entity
            faceHalos()
            moveTravellers()
        }

        // Desks
        let sessionsById = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        var placed: [String: (position: SIMD3<Float>, way: OfficePath)] = [:]
        for room in layout.rooms {
            for desk in room.desks {
                placed[desk.sessionId] = (
                    [Float(desk.position.x), 0, Float(desk.position.z)], OfficeLayout.walk(in: room, to: desk)
                )
            }
        }
        for (id, place) in placed {
            guard let session = sessionsById[id] else { continue }
            // Without animation nobody wanders: idle figures sit at their desks as before.
            if !animate { desks[id]?.activity = nil }
            if desks[id] == nil {
                let node = makeDesk(session, at: place.position, way: place.way, palette)
                if animate {
                    node.entity.scale = [0.01, 0.01, 0.01]
                    root.addChild(node.entity)
                    node.entity.move(
                        to: Transform(scale: .one, translation: place.position), relativeTo: root, duration: 0.45,
                        timingFunction: .easeOut)
                } else {
                    root.addChild(node.entity)
                }
                desks[id] = node
            }
            guard var node = desks[id] else { continue }
            node.way = place.way
            if node.target != place.position {
                node.target = place.position
                if animate {
                    node.entity.move(
                        to: Transform(scale: .one, translation: place.position), relativeTo: root, duration: 0.35)
                } else {
                    node.entity.position = place.position
                }
            }
            update(&node, with: session, palette: palette, force: darkChanged)
            desks[id] = node
        }
        for (id, node) in desks where placed[id] == nil || sessionsById[id] == nil {
            desks[id] = nil
            remove(node.entity)
        }

        // Selection: the selected Desk stands on a blue rug.
        // Hidden by sinking it into the floor slab: a model that starts disabled or at zero scale is
        // culled by its first bounds and never shows.
        for (id, node) in desks { node.rug.position.y = id == selected ? 0.02 : -0.03 }
        // Bubbles as the Owner chose: all, the selected one only, or none (sunk under the lawn).
        for (id, node) in desks {
            node.bubble.position.y = options.bubbles.shows(selected: id == selected) ? 1.6 : Self.hidden
        }
        direct(boss: order, palette: palette)
    }

    private func remove(_ entity: Entity) {
        guard animate else {
            entity.removeFromParent()
            return
        }
        entity.move(
            to: Transform(scale: [0.01, 0.01, 0.01], translation: entity.position), relativeTo: root,
            duration: 0.3, timingFunction: .easeIn)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            entity.removeFromParent()
        }
    }

    func tick(_ delta: Float) {
        clock += delta
        guard animate else { return }
        if options.slowTurn {
            yaw -= delta * 0.06
            applyCamera()
        }
        moveBoss(by: delta)
        moveTravellers()
        // The sun's rays turn slowly and breathe a little.
        if rays.isEnabled {
            rays.orientation = simd_quatf(angle: clock * 0.05, axis: [0, 0, 1])
            rays.scale = .init(repeating: 1 + 0.04 * sin(clock * 0.9))
        }
        let turn = Int(clock / Float(OfficeIdle.turn))
        if turn != idleTurn {
            idleTurn = turn
            planIdle(turn: turn)
        }
        for (id, node) in desks {
            var node = node
            var holdsPhone = false
            if node.walk != nil {
                advance(&node, by: delta)
            } else {
                // Each figure keeps its own beat, so a room never moves in step.
                let time = clock + Float(abs(node.target.x)) + Float(abs(node.target.z)) * 0.7
                switch (node.at, node.status, node.activity) {
                case (.seated, .working, _): apply(.typing(at: time), to: node.rig)
                case (.seated, .idle, .phone):
                    apply(.phoning(at: time, seated: true), to: node.rig)
                    holdsPhone = true
                case (.seated, .idle, .game): apply(.gaming(at: time), to: node.rig)
                case (.seated, _, _): apply(.dozing(at: time), to: node.rig)
                case (.standingBy, .idle, .stretch): apply(.stretching(at: time), to: node.rig)
                case (.standingBy, _, _): apply(.waving(at: clock), to: node.rig)
                case (.away, _, .chat(let partner, _, _)):
                    if let other = desks[partner], other.walk == nil, case .chat(id, _, _) = other.activity {
                        // Turns to speak, a few seconds each; the pair agree on whose turn it is.
                        let beat = Int((clock + 2) / 4) % 2 == 0
                        apply(.talking(at: time, speaking: beat == (id < partner)), to: node.rig)
                    } else {
                        // The partner has gone back to work: wait on the phone.
                        apply(.phoning(at: time, seated: false), to: node.rig)
                        holdsPhone = true
                    }
                case (.away, _, _): apply(.lookingAround(at: time), to: node.rig)
                case (.gone, _, _): break
                }
            }
            node.rig.phone.position = holdsPhone ? FigureRig.phoneInHand : Self.parkedProp
            desks[id] = node
        }
    }

    /// A prop out of use waits far below the hand that holds it: a model that is disabled or scaled
    /// to nothing when it first draws is culled by those bounds and never shows again.
    private static let parkedProp = SIMD3<Float>(0, -40, 0)

    /// Picks what each idle figure does this turn and sends it there. A figure still walking keeps
    /// what it was doing until the next turn, and the one the boss is visiting stays at its desk.
    private func planIdle(turn: Int) {
        guard animate, let hall else { return }
        let visited = boss?.deskId
        let free = desks.filter { $0.value.status == .idle && $0.value.walk == nil && $0.key != visited }
        let plan = OfficeIdle.plan(idle: Array(free.keys), hall: hall, turn: turn)
        for (id, activity) in plan {
            guard var node = desks[id] else { continue }
            setActivity(&node, activity)
            desks[id] = node
        }
    }

    /// Where an idle figure goes for `activity`.
    private static func goal(for activity: OfficeIdleActivity?) -> FigureGoal {
        switch activity {
        case .stroll(let spot): .away(spot, facing: nil)
        case .chat(_, let spot, let facing): .away(spot, facing: facing)
        case .stretch: .standingBy
        case .doze, .phone, .game, nil: .seated
        }
    }

    /// Starts `activity`: the monitor shows the game or goes dark, and the figure walks to its place.
    private func setActivity(_ node: inout DeskNode, _ activity: OfficeIdleActivity?) {
        let wasGame = node.activity == .game
        node.activity = activity
        if (activity == .game) != wasGame {
            node.screen.model?.materials = [activity == .game ? screenGame : UnlitMaterial(color: NSColor(white: 0.12, alpha: 1))]
        }
        send(&node, to: Self.goal(for: activity))
    }

    // MARK: Figures on the move

    /// Where a figure stands or sits for `goal`, in the office (world) frame: its chair, the spot
    /// in the gap beside the desk, or the doorway.
    private func spot(_ goal: FigureGoal, of node: DeskNode) -> OfficePoint {
        let chair = node.way.end ?? OfficePoint(x: Double(node.target.x), z: Double(node.target.z) + OfficeLayout.chairOffset)
        switch goal {
        case .seated: return chair
        case .standingBy:
            // The gap the figure walked down, beside the chair.
            let gap = node.way.points.count >= 2 ? node.way.points[node.way.points.count - 2].x : chair.x + 0.7
            return OfficePoint(x: gap, z: chair.z)
        case .gone: return node.way.start ?? chair
        case .away(let point, _): return point
        }
    }

    /// The way from the doorway to where `goal` puts the figure: down the Room to its chair or the
    /// gap beside its desk, or across the Center Room to its spot there.
    private func fromDoor(_ node: DeskNode, to goal: FigureGoal) -> [OfficePoint] {
        switch goal {
        case .gone: return Array(node.way.points.prefix(1))
        case .seated: return node.way.points
        case .standingBy: return node.way.points.dropLast() + [spot(.standingBy, of: node)]
        case .away(let point, _): return OfficeIdle.hallWay(from: node.way, to: point)
        }
    }

    /// The way from `from` to `goal`: straight across when both are beside the desk or both in the
    /// Center Room, else by the doorway.
    private func route(_ node: DeskNode, from: FigureGoal, to goal: FigureGoal) -> OfficePath {
        switch (from, goal) {
        case (.seated, .standingBy), (.standingBy, .seated), (.away, .away):
            return OfficePath([spot(from, of: node), spot(goal, of: node)])
        default:
            return OfficePath(fromDoor(node, to: from).reversed() + fromDoor(node, to: goal))
        }
    }

    /// A figure that is gone waits under the lawn: a model that is disabled or scaled to nothing
    /// when it first draws is culled by those bounds and never shows again.
    private static let hidden: Float = -3

    /// Puts the figure at `point` (an office point), facing `heading` or, when there is none, its
    /// monitor.
    private func place(_ node: DeskNode, at point: OfficePoint, heading: OfficePoint?) {
        node.rig.root.position = [Float(point.x) - node.target.x, 0, Float(point.z) - node.target.z]
        let yaw = heading.map { atan2(-Float($0.x), -Float($0.z)) } ?? 0
        node.rig.root.orientation = simd_quatf(angle: yaw, axis: [0, 1, 0])
    }

    /// Sets the figure down where `goal` puts it, with the pose that goes with it.
    private func settle(_ node: inout DeskNode, at goal: FigureGoal) {
        node.at = goal
        node.walk = nil
        place(node, at: spot(goal, of: node), heading: nil)
        switch goal {
        case .seated: apply(.seated, to: node.rig)
        case .standingBy:
            apply(.waving(at: 0), to: node.rig)
            node.rig.root.orientation = simd_quatf(angle: .pi + yaw, axis: [0, 1, 0])
        case .gone: node.rig.root.position.y = Self.hidden
        case .away(let point, let facing):
            apply(.standing, to: node.rig)
            if let facing {
                place(node, at: point, heading: OfficePoint(x: facing.x - point.x, z: facing.z - point.z))
            } else {
                node.rig.root.orientation = simd_quatf(angle: .pi + yaw, axis: [0, 1, 0])
            }
        }
    }

    /// Sends the figure to `goal`: walking there with animation on, or at once without. A figure
    /// already on its way somewhere else is set down there first.
    private func send(_ node: inout DeskNode, to goal: FigureGoal) {
        if let walk = node.walk, walk.goal != goal { settle(&node, at: walk.goal) }
        guard node.walk == nil, node.at != goal else { return }
        guard animate else {
            settle(&node, at: goal)
            return
        }
        let path = route(node, from: node.at, to: goal)
        node.walk = Walk(path: path, walked: 0, goal: goal)
        advance(&node, by: 0)
    }

    private func advance(_ node: inout DeskNode, by delta: Float) {
        guard var walk = node.walk else { return }
        walk.walked += delta * Self.walkSpeed
        if Double(walk.walked) >= walk.path.length {
            settle(&node, at: walk.goal)
            return
        }
        node.walk = walk
        node.stride += delta * Self.walkSpeed * Self.strideRate
        let now = walk.path.position(at: Double(walk.walked))
        place(node, at: now.point, heading: now.heading)
        apply(.walking(phase: node.stride), to: node.rig)
    }

    private func apply(_ pose: Pose, to rig: FigureRig) {
        let x = SIMD3<Float>(1, 0, 0)
        let y = SIMD3<Float>(0, 1, 0)
        let z = SIMD3<Float>(0, 0, 1)
        rig.pelvis.position.y = pose.hip
        rig.torso.orientation = simd_quatf(angle: pose.torsoYaw, axis: y) * simd_quatf(angle: pose.torsoPitch, axis: x)
        rig.head.orientation = simd_quatf(angle: pose.headYaw, axis: y) * simd_quatf(angle: pose.headPitch, axis: x)
        for side in 0..<2 {
            // The left arm lifts out to -x, the right to +x.
            let roll = (side == 0 ? -1 : 1) * pose.shoulderRoll[side]
            rig.shoulders[side].orientation =
                simd_quatf(angle: roll, axis: z) * simd_quatf(angle: pose.shoulderPitch[side], axis: x)
            rig.elbows[side].orientation = simd_quatf(angle: pose.elbow[side], axis: x)
            rig.hips[side].orientation = simd_quatf(angle: pose.hipPitch[side], axis: x)
            rig.knees[side].orientation = simd_quatf(angle: pose.knee[side], axis: x)
        }
    }

    // MARK: The boss

    /// Beside the worker's desk, in the gap the worker walks down, a step nearer the monitor than
    /// the chair: in view of the default camera and facing the worker.
    private func bossSpot(at node: DeskNode) -> OfficePoint {
        let worker = spot(.standingBy, of: node)
        return OfficePoint(x: worker.x, z: worker.z - 0.6)
    }

    /// From the Room's doorway down the worker's way to the boss's spot, or back.
    private func bossRoute(at node: DeskNode, to goal: BossGoal) -> OfficePath {
        let inward = Array(node.way.points.dropLast()) + [bossSpot(at: node)]
        return OfficePath(goal == .attending ? inward : inward.reversed())
    }

    /// Takes the page's order: walk to a Desk, say something there, or leave.
    private func direct(boss order: OfficeBossOrder?, palette: Palette) {
        guard var boss else { return }
        // A Desk that is gone takes the boss with it.
        if let id = boss.deskId, desks[id] == nil { settle(&boss, at: .out) }
        let target = order.flatMap { desks[$0.deskId] == nil ? nil : $0.deskId }
        // The worker the boss visits comes back to its desk from wherever it is passing the time.
        if let target, var worker = desks[target], worker.activity != nil, worker.activity != .phone {
            setActivity(&worker, .phone)
            desks[target] = worker
        }
        if target != boss.deskId {
            if let target {
                // Called to another Desk: leave this one at once and walk to the new one.
                if boss.deskId != nil { settle(&boss, at: .out) }
                boss.deskId = target
                walk(&boss, to: .attending)
            } else if boss.deskId != nil, boss.goal != .out {
                // Not already on the way out.
                walk(&boss, to: .out)
            }
        } else if target != nil, boss.at == .attending, boss.path == nil {
            // The Desk may have moved since the boss got there.
            settle(&boss, at: .attending)
        }
        let speech = target == nil ? nil : order?.speech
        if speech != boss.speech {
            boss.speech = speech
            draw(speech, in: boss.bubble, palette: palette)
        }
        boss.bubble.position.y = speech == nil ? Self.hidden : 2.45
        self.boss = boss
    }

    private func draw(_ speech: String?, in bubble: Entity, palette: Palette) {
        for child in Array(bubble.children) { child.removeFromParent() }
        guard let speech else { return }
        let mesh = textMesh("“\(speech)”", size: 0.13)
        let bounds = mesh.bounds
        let navy = NSColor(red: 0.15, green: 0.19, blue: 0.32, alpha: 1)
        let plate = ModelEntity(
            mesh: .generatePlane(width: max(0.6, bounds.extents.x + 0.3), height: 0.3, cornerRadius: 0.1),
            materials: [UnlitMaterial(color: navy)])
        bubble.addChild(plate)
        let label = ModelEntity(mesh: mesh, materials: [UnlitMaterial(color: .white)])
        label.position = [-(bounds.min.x + bounds.extents.x / 2), -(bounds.min.y + bounds.extents.y / 2), 0.004]
        bubble.addChild(label)
    }

    private func walk(_ boss: inout BossNode, to goal: BossGoal) {
        guard let id = boss.deskId, let node = desks[id] else {
            settle(&boss, at: .out)
            return
        }
        guard animate else {
            settle(&boss, at: goal)
            return
        }
        // Coming in, the boss starts at the doorway; going out, from wherever it stands.
        let route = bossRoute(at: node, to: goal)
        boss.path = route
        boss.walked = 0
        boss.goal = goal
        if goal == .out, boss.at != .attending {
            // Still on the way in: go straight back out from here.
            settle(&boss, at: .out)
            return
        }
        moveBoss(&boss, by: 0)
    }

    private func settle(_ boss: inout BossNode, at goal: BossGoal) {
        boss.path = nil
        boss.at = goal
        boss.goal = goal
        switch goal {
        case .out:
            boss.deskId = nil
            boss.rig.root.position = [0, Self.hidden, 0]
            apply(.standing, to: boss.rig)
        case .attending:
            guard let id = boss.deskId, let node = desks[id] else { return settle(&boss, at: .out) }
            let at = bossSpot(at: node)
            let worker = spot(node.at == .standingBy ? .standingBy : .seated, of: node)
            placeBoss(boss, at: at, heading: OfficePoint(x: worker.x - at.x, z: worker.z - at.z))
            apply(boss.speech == nil ? .listening(at: clock) : .instructing(at: clock), to: boss.rig)
        }
    }

    private func placeBoss(_ boss: BossNode, at point: OfficePoint, heading: OfficePoint?) {
        boss.rig.root.position = [Float(point.x), 0, Float(point.z)]
        let yaw = heading.map { atan2(-Float($0.x), -Float($0.z)) } ?? 0
        boss.rig.root.orientation = simd_quatf(angle: yaw, axis: [0, 1, 0])
    }

    private func moveBoss(by delta: Float) {
        guard var boss else { return }
        moveBoss(&boss, by: delta)
        self.boss = boss
    }

    private func moveBoss(_ boss: inout BossNode, by delta: Float) {
        guard let path = boss.path else {
            if boss.at == .attending {
                apply(boss.speech == nil ? .listening(at: clock) : .instructing(at: clock), to: boss.rig)
            }
            return
        }
        boss.walked += delta * Self.walkSpeed
        if Double(boss.walked) >= path.length {
            settle(&boss, at: boss.goal)
            return
        }
        boss.stride += delta * Self.walkSpeed * Self.strideRate
        let now = path.position(at: Double(boss.walked))
        placeBoss(boss, at: now.point, heading: now.heading)
        apply(.walking(phase: boss.stride), to: boss.rig)
    }

    // MARK: Building

    private func box(_ size: SIMD3<Float>, _ colour: NSColor, at position: SIMD3<Float>) -> ModelEntity {
        let entity = ModelEntity(mesh: .generateBox(size: size), materials: [material(colour)])
        entity.position = position
        return entity
    }

    private func textMesh(_ text: String, size: CGFloat) -> MeshResource {
        .generateText(
            text, extrusionDepth: 0.002, font: .systemFont(ofSize: size, weight: .semibold),
            containerFrame: .zero, alignment: .center, lineBreakMode: .byTruncatingTail)
    }

    /// A piece of wall in the building's style, with the cut-away cap along its top. The style
    /// decides what it is made of: plaster, brick with mortar lines, a tinted pane in a steel
    /// frame, or stacked logs.
    private func wallPiece(_ size: SIMD3<Float>, at position: SIMD3<Float>, to entity: Entity, _ palette: Palette) {
        let height = Self.wallHeight
        let along = size.x > size.z
        switch style {
        case .modern:
            entity.addChild(box(size, palette.wall, at: position))
        case .brick:
            entity.addChild(box(size, palette.wall, at: position))
            // Mortar lines on both faces, so the brick reads from any side.
            var y: Float = 0.09
            while y < height - 0.04 {
                let line: SIMD3<Float> = along ? [size.x, 0.012, size.z + 0.004] : [size.x + 0.004, 0.012, size.z]
                entity.addChild(box(line, palette.wallCap, at: [position.x, y, position.z]))
                y += 0.09
            }
        case .glass:
            let pane = ModelEntity(mesh: .generateBox(size: size), materials: [glassMaterial(palette.wall, opacity: 0.45)])
            pane.position = position
            entity.addChild(pane)
            // Steel posts every 1.2 m and a rail along the foot.
            let length = along ? size.x : size.z
            var offset = -length / 2
            while offset <= length / 2 + 0.01 {
                let at: SIMD3<Float> = along ? [position.x + offset, height / 2, position.z] : [position.x, height / 2, position.z + offset]
                entity.addChild(box([0.05, height, 0.05], palette.wallCap, at: at))
                offset += 1.2
            }
            let foot: SIMD3<Float> = along ? [size.x, 0.04, size.z + 0.02] : [size.x + 0.02, 0.04, size.z]
            entity.addChild(box(foot, palette.wallCap, at: [position.x, 0.02, position.z]))
        case .timber:
            // Four logs, every other one a shade darker, so the wall looks stacked.
            let logs = 4
            let radius = height / Float(logs) / 2
            for index in 0..<logs {
                let shade = index.isMultiple(of: 2) ? palette.wall : palette.wall.blended(withFraction: 0.12, of: .black) ?? palette.wall
                let log = ModelEntity(
                    mesh: .generateCylinder(height: along ? size.x : size.z, radius: radius * 1.08), materials: [material(shade)])
                log.orientation = along ? simd_quatf(angle: .pi / 2, axis: [0, 0, 1]) : simd_quatf(angle: .pi / 2, axis: [1, 0, 0])
                log.position = [position.x, radius + Float(index) * 2 * radius, position.z]
                entity.addChild(log)
            }
        }
        entity.addChild(box([size.x + 0.004, 0.025, size.z + 0.004], palette.wallCap, at: [position.x, height, position.z]))
    }

    /// Windows along an outer wall: panes in a frame, every 1.4 m, kept off a near wall's first
    /// metres where the Room's name stands.
    private func addWindows(to entity: Entity, side: OfficeSide, room: PlacedRoom, palette: Palette) {
        let width = Float(room.width)
        let depth = Float(room.depth)
        let length = side == .north || side == .south ? width : depth
        let start: Float = side == .south ? -length / 2 + 2.4 : -length / 2 + 0.9
        let pane: SIMD3<Float> = [0.7, 0.26, 0.09]
        var glass: any RealityKit.Material = material(palette.glass, roughness: 0.3)
        if dark {
            var warm = UnlitMaterial(applyPostProcessToneMap: false)
            warm.color = .init(tint: palette.glass)
            glass = warm
        }
        var offset = start
        while offset + pane.x / 2 < length / 2 - 0.5 {
            let window = Entity()
            let model = ModelEntity(mesh: .generateBox(size: pane), materials: [glass])
            model.position = [0, 0.33, 0]
            window.addChild(model)
            // The frame: a sill and a lintel, two jambs and a mullion.
            for (size, at) in [
                (SIMD3<Float>(0.78, 0.03, 0.1), SIMD3<Float>(0, 0.185, 0)), ([0.78, 0.03, 0.1], [0, 0.475, 0]),
                ([0.03, 0.3, 0.1], [-0.37, 0.33, 0]), ([0.03, 0.3, 0.1], [0.37, 0.33, 0]), ([0.02, 0.26, 0.1], [0, 0.33, 0]),
            ] {
                window.addChild(box(size, palette.windowFrame, at: at))
            }
            switch side {
            case .north: window.position = [offset, 0, -depth / 2 + 0.03]
            case .south: window.position = [offset, 0, depth / 2 - 0.03]
            case .west:
                window.position = [-width / 2 + 0.03, 0, offset]
                window.orientation = simd_quatf(angle: .pi / 2, axis: [0, 1, 0])
            case .east:
                window.position = [width / 2 - 0.03, 0, offset]
                window.orientation = simd_quatf(angle: .pi / 2, axis: [0, 1, 0])
            }
            entity.addChild(window)
            offset += 1.4
        }
    }

    /// A low wall along one side of a room, with a doorway in its middle when `door` is set.
    private func addWall(
        to entity: Entity, side: OfficeSide, room: PlacedRoom, palette: Palette
    ) {
        let width = Float(room.width)
        let depth = Float(room.depth)
        let thickness: Float = 0.06
        let height = Self.wallHeight
        let walls = room.walls
        switch side {
        case .north, .south:
            let z = (side == .north ? -1 : 1) * (depth / 2 - thickness / 2)
            guard room.door == side else {
                wallPiece([width, height, thickness], at: [0, height / 2, z], to: entity, palette)
                return
            }
            let side = (width - Self.doorWidth) / 2
            for direction: Float in [-1, 1] {
                wallPiece([side, height, thickness], at: [direction * (Self.doorWidth + side) / 2, height / 2, z], to: entity, palette)
            }
            // A mat in the doorway, so the way through reads from above.
            entity.addChild(box([Self.doorWidth, 0.014, 0.5], palette.desk, at: [0, 0.007, z]))
        case .west, .east:
            // Between the north and south walls, which run the whole width.
            let top = walls.contains(.north) ? thickness : 0
            let bottom = walls.contains(.south) ? thickness : 0
            let x = (side == .west ? -1 : 1) * (width / 2 - thickness / 2)
            wallPiece([thickness, height, depth - top - bottom], at: [x, height / 2, (top - bottom) / 2], to: entity, palette)
        }
    }

    private func makeRoom(_ room: PlacedRoom, outer: Set<OfficeSide>, _ palette: Palette) -> Entity {
        let entity = Entity()
        let width = Float(room.width)
        let depth = Float(room.depth)
        entity.addChild(
            box([width, 0.06, depth], room.isCenter ? palette.hallFloor : palette.floor, at: [0, -0.03, 0]))
        if room.isCenter {
            // Carpet tiles in two tones, laid as a chequerboard.
            let tile: Float = 0.8
            for column in 0..<Int((width / tile).rounded(.up)) {
                for row in 0..<Int((depth / tile).rounded(.up)) where (column + row).isMultiple(of: 2) {
                    let x = -width / 2 + Float(column) * tile
                    let z = -depth / 2 + Float(row) * tile
                    let size = SIMD2(min(tile, width / 2 - x), min(tile, depth / 2 - z))
                    entity.addChild(
                        box([size.x, 0.004, size.y], palette.hallTile, at: [x + size.x / 2, 0.002, z + size.y / 2]))
                }
            }
        } else {
            // Planks across the room, every other one a shade darker.
            let plank: Float = 0.3
            var z = -depth / 2 + plank
            while z < depth / 2 {
                let size = min(plank, depth / 2 - z)
                entity.addChild(box([width, 0.004, size], palette.plank, at: [0, 0.002, z + size / 2]))
                z += 2 * plank
            }
        }
        for side in [OfficeSide.north, .south, .west, .east] where room.walls.contains(side) {
            addWall(to: entity, side: side, room: room, palette: palette)
            if outer.contains(side) { addWindows(to: entity, side: side, room: room, palette: palette) }
        }
        for piece in room.furniture {
            let item = makeFurniture(piece, palette)
            item.position = [Float(piece.position.x - room.center.x), 0, Float(piece.position.z - room.center.z)]
            entity.addChild(item)
        }
        guard !room.name.isEmpty else { return entity }
        let mesh = textMesh(room.name, size: 0.3)
        let label = ModelEntity(mesh: mesh, materials: [UnlitMaterial(color: palette.label)])
        let bounds = mesh.bounds
        let x = -width / 2 + 0.35 - bounds.min.x
        if room.isCenter {
            // Flat on the floor: nothing stands in the hall to cover it.
            label.orientation = simd_quatf(angle: -.pi / 2, axis: [1, 0, 0])
            label.position = [x, 0.012, 0.3]
        } else {
            // Standing on the near wall, which faces the viewer: a name on the floor would be hidden
            // behind that wall or behind the Desks.
            label.position = [x, Self.wallHeight + 0.02 - bounds.min.y, depth / 2 - 0.03]
        }
        entity.addChild(label)
        return entity
    }

    /// A Desk at `position` (in the office), with its figure on its way in.
    private func makeDesk(_ session: OfficeSession, at position: SIMD3<Float>, way: OfficePath, _ palette: Palette) -> DeskNode {
        let entity = Entity()
        entity.position = position
        // Furniture: a light desk on a metal frame, a monitor facing the viewer with a keyboard in
        // front of it, and an office chair on wheels.
        entity.addChild(box([1.2, 0.04, 0.6], palette.deskTop, at: [0, 0.72, -0.15]))
        entity.addChild(box([1.2, 0.015, 0.6], palette.deskFrame, at: [0, 0.693, -0.15]))
        for x: Float in [-0.56, 0.56] {
            entity.addChild(box([0.04, 0.69, 0.04], palette.deskFrame, at: [x, 0.345, -0.15]))
            entity.addChild(box([0.05, 0.02, 0.55], palette.deskFrame, at: [x, 0.01, -0.15]))
        }
        entity.addChild(box([1.08, 0.3, 0.02], palette.deskFrame, at: [0, 0.53, -0.43]))
        entity.addChild(box([0.18, 0.015, 0.12], palette.deskFrame, at: [0, 0.748, -0.32]))
        entity.addChild(box([0.04, 0.2, 0.04], palette.deskFrame, at: [0, 0.85, -0.32]))
        entity.addChild(box([0.6, 0.38, 0.025], NSColor(white: 0.1, alpha: 1), at: [0, 1.1, -0.31]))
        // The screen: a painted card just in front of the bezel, swapped with the status.
        let screen = ModelEntity(mesh: .generatePlane(width: 0.54, height: 0.32), materials: [UnlitMaterial(color: .darkGray)])
        screen.position = [0, 1.1, -0.296]
        entity.addChild(screen)
        entity.addChild(box([0.44, 0.015, 0.14], NSColor(white: 0.22, alpha: 1), at: [0, 0.748, 0.0]))
        // Something of the Session's own on the desk: a mug, a notebook or a succulent.
        var seed = OfficeSeed("desk:\(session.id)")
        switch Int.random(in: 0..<3, using: &seed) {
        case 0:
            let mugs = [NSColor.systemRed, .systemBlue, .white, NSColor(red: 0.95, green: 0.8, blue: 0.3, alpha: 1)]
            let colour = mugs[Int.random(in: 0..<mugs.count, using: &seed)]
            let mug = ModelEntity(mesh: .generateCylinder(height: 0.08, radius: 0.035), materials: [material(colour)])
            mug.position = [0.44, 0.78, -0.2]
            entity.addChild(mug)
            entity.addChild(box([0.015, 0.04, 0.03], colour, at: [0.485, 0.78, -0.2]))
        case 1:
            let covers = [NSColor(red: 0.2, green: 0.35, blue: 0.6, alpha: 1), NSColor(red: 0.7, green: 0.25, blue: 0.2, alpha: 1), NSColor(white: 0.25, alpha: 1)]
            entity.addChild(box([0.15, 0.016, 0.2], covers[Int.random(in: 0..<covers.count, using: &seed)], at: [-0.42, 0.748, -0.18]))
            entity.addChild(box([0.012, 0.01, 0.14], NSColor(white: 0.95, alpha: 1), at: [-0.34, 0.76, -0.2]))
        default:
            let pot = ModelEntity(
                mesh: .generateCylinder(height: 0.06, radius: 0.04),
                materials: [material(NSColor(red: 0.76, green: 0.42, blue: 0.3, alpha: 1))])
            pot.position = [0.46, 0.77, -0.3]
            entity.addChild(pot)
            let leaves = ModelEntity(
                mesh: .generateSphere(radius: 0.045), materials: [material(NSColor(red: 0.35, green: 0.62, blue: 0.35, alpha: 1))])
            leaves.position = [0.46, 0.83, -0.3]
            entity.addChild(leaves)
        }
        // The chair: a five-spoke base on wheels, a column, a padded seat and a low back.
        for spoke in 0..<5 {
            let angle = Float(spoke) * 2 * .pi / 5
            let leg = box([0.24, 0.03, 0.04], palette.chair, at: [0, 0.06, 0])
            leg.orientation = simd_quatf(angle: angle, axis: [0, 1, 0])
            leg.position = [cos(angle) * 0.12, 0.06, 0.55 - sin(angle) * 0.12]
            entity.addChild(leg)
            let wheel = ModelEntity(mesh: .generateSphere(radius: 0.03), materials: [material(palette.chair)])
            wheel.position = [cos(angle) * 0.24, 0.03, 0.55 - sin(angle) * 0.24]
            entity.addChild(wheel)
        }
        entity.addChild(box([0.05, 0.22, 0.05], palette.deskFrame, at: [0, 0.18, 0.55]))
        for (size, position) in [
            (SIMD3<Float>(0.46, 0.06, 0.44), SIMD3<Float>(0, 0.31, 0.55)), ([0.42, 0.3, 0.05], [0, 0.55, 0.78]),
        ] {
            let pad = ModelEntity(mesh: .generateBox(size: size, cornerRadius: 0.025), materials: [material(palette.chair)])
            pad.position = position
            entity.addChild(pad)
        }

        // The figure, dressed by its look, on its own root so it can walk about.
        let rig = dress(OfficeLook(session: session))
        rig.root.position = [0, 0, Float(OfficeLayout.chairOffset)]
        entity.addChild(rig.root)

        // The bubble above it, always facing the camera.
        let bubble = Entity()
        bubble.position = [0, 1.6, 0.55]
        bubble.components.set(BillboardComponent())
        entity.addChild(bubble)

        let rug = ModelEntity(
            mesh: .generateBox(size: [1.5, 0.03, 1.7]),
            materials: [UnlitMaterial(color: NSColor(red: 0.45, green: 0.68, blue: 1, alpha: 1))])
        rug.position = [0, -0.03, 0.2]
        entity.addChild(rug)

        // One box over the whole Desk takes the click.
        let hit = Entity()
        hit.components.set(CollisionComponent(shapes: [.generateBox(size: [1.3, 1.5, 1.4])]))
        hit.components.set(InputTargetComponent())
        hit.components.set(DeskTag(id: session.id))
        hit.position = [0, 0.75, 0.25]
        entity.addChild(hit)

        var node = DeskNode(
            entity: entity, rig: rig, screen: screen, bubble: bubble, rug: rug, bubbleText: "", status: .idle,
            agent: "", dark: dark, target: entity.position, way: way, at: .gone, walk: nil, stride: 0)
        // A new figure walks in from the doorway; without animation it is seated at once.
        node.rig.root.position.y = Self.hidden
        update(&node, with: session, palette: palette, force: true)
        return node
    }

    /// Fits the figure with a click target, tagged with its Session, so a walking figure is clickable too.
    private func tag(_ rig: FigureRig, _ id: String) {
        let hit = Entity()
        hit.components.set(CollisionComponent(shapes: [.generateBox(size: [0.5, 1.6, 0.5])]))
        hit.components.set(InputTargetComponent())
        hit.components.set(DeskTag(id: id))
        hit.position = [0, 0.8, 0]
        rig.root.addChild(hit)
    }

    private func update(_ node: inout DeskNode, with session: OfficeSession, palette: Palette, force: Bool) {
        let live = session.status == .working || session.status == .waiting
        let text = session.bubble
        let title = session.bubbleTitle
        let bubbleText = "\(title)\n\(text)"
        if node.agent != session.agent {
            if !node.agent.isEmpty {
                // The agent of a Session never changes; this guards the id staying while the type does.
                node.rig.root.removeFromParent()
                let rig = dress(OfficeLook(session: session))
                node.entity.addChild(rig.root)
                node.rig = rig
                node.at = .gone
                node.walk = nil
            }
            tag(node.rig, session.id)
        }
        if force || node.status != session.status || node.agent != session.agent {
            for part in node.rig.parts {
                part.entity.model?.materials = [material(nsColour(live ? part.colour : part.colour.greyed))]
            }
            let screen: any RealityKit.Material =
                switch session.status {
                case .working: screenWorking
                case .waiting: screenWaiting
                case .idle where node.activity == .game && session.status == node.status: screenGame
                default: UnlitMaterial(color: NSColor(white: 0.12, alpha: 1))
                }
            node.screen.model?.materials = [screen]
        }
        if force || node.bubbleText != bubbleText || node.status != session.status {
            // A copy: removing while walking `children` skips every other one and the old text stays.
            for child in Array(node.bubble.children) { child.removeFromParent() }
            let mesh = textMesh(text, size: 0.15)
            let bounds = mesh.bounds
            let titleMesh = title.isEmpty ? nil : textMesh(title, size: 0.1)
            let titleBounds = titleMesh?.bounds
            let width = max(0.7, bounds.extents.x + 0.3, (titleBounds?.extents.x ?? 0) + 0.3)
            let height: Float = titleMesh == nil ? 0.32 : 0.5
            let background = session.status == .waiting ? amber : palette.bubble
            let ink = session.status == .waiting ? NSColor(white: 0.1, alpha: 1) : palette.bubbleText
            let plate = ModelEntity(
                mesh: .generatePlane(width: width, height: height, cornerRadius: 0.1),
                materials: [UnlitMaterial(color: background)])
            node.bubble.addChild(plate)
            let label = ModelEntity(mesh: mesh, materials: [UnlitMaterial(color: ink)])
            let lift: Float = titleMesh == nil ? 0 : -0.08
            label.position = [-(bounds.min.x + bounds.extents.x / 2), lift - (bounds.min.y + bounds.extents.y / 2), 0.004]
            node.bubble.addChild(label)
            if let titleMesh, let titleBounds {
                // The Session Title above the activity, a little lighter.
                let heading = ModelEntity(
                    mesh: titleMesh, materials: [UnlitMaterial(color: ink.blended(withFraction: 0.35, of: background) ?? ink)])
                heading.position = [
                    -(titleBounds.min.x + titleBounds.extents.x / 2), 0.12 - (titleBounds.min.y + titleBounds.extents.y / 2), 0.004,
                ]
                node.bubble.addChild(heading)
            }
        }
        node.bubbleText = bubbleText
        // Only an idle figure passes the time; one that gets work goes back to its desk.
        if session.status != .idle { node.activity = nil }
        node.status = session.status
        node.agent = session.agent
        node.dark = dark
        // Where the figure should be: at its chair, standing by for the Owner, or gone.
        let goal: FigureGoal =
            switch session.status {
            case .exited: .gone
            case .waiting: .standingBy
            case .working: .seated
            case .idle: Self.goal(for: node.activity)
            }
        send(&node, to: goal)
    }

    /// Builds a figure dressed by `look`, standing on its root and facing -z.
    private func dress(_ look: OfficeLook) -> FigureRig {
        var parts: [FigurePart] = []
        func add(
            _ mesh: MeshResource, _ colour: OfficeColour, at position: SIMD3<Float>, to parent: Entity,
            turn: simd_quatf = simd_quatf(angle: 0, axis: [0, 1, 0]), scale: SIMD3<Float> = .one
        ) {
            let entity = ModelEntity(mesh: mesh, materials: [material(nsColour(colour))])
            entity.position = position
            entity.orientation = turn
            entity.scale = scale
            parent.addChild(entity)
            parts.append(FigurePart(entity: entity, colour: colour))
        }
        func pivot(at position: SIMD3<Float>, under parent: Entity) -> Entity {
            let joint = Entity()
            joint.position = position
            parent.addChild(joint)
            return joint
        }
        let alongX = simd_quatf(angle: .pi / 2, axis: [0, 0, 1])
        let dark = OfficeColour(red: 0.12, green: 0.12, blue: 0.14)
        let shoe = OfficeColour(red: 0.16, green: 0.12, blue: 0.1)

        let root = Entity()
        let pelvis = pivot(at: [0, FigureRig.standingHip, 0], under: root)
        // Legs: a thigh from each hip, a shin from each knee, a shoe at the end.
        var hips: [Entity] = []
        var knees: [Entity] = []
        for x: Float in [-0.08, 0.08] {
            let hip = pivot(at: [x, 0, 0], under: pelvis)
            add(.generateBox(size: [0.12, 0.36, 0.12]), look.trousers, at: [0, -0.18, 0], to: hip)
            let knee = pivot(at: [0, -0.36, 0], under: hip)
            add(.generateBox(size: [0.11, 0.34, 0.11]), look.trousers, at: [0, -0.17, 0], to: knee)
            add(.generateBox(size: [0.12, 0.06, 0.2]), shoe, at: [0, -0.34, -0.04], to: knee)
            hips.append(hip)
            knees.append(knee)
        }
        // The torso from the pelvis up, with the shirt's details on it.
        let torso = pivot(at: .zero, under: pelvis)
        add(.generateCylinder(height: 0.46, radius: 0.17), look.shirtColour, at: [0, 0.23, 0], to: torso)
        switch look.shirt {
        case .tee: break
        case .stripe:
            add(.generateCylinder(height: 0.07, radius: 0.176), look.shirtColour.mixed(with: dark, 0.5), at: [0, 0.27, 0], to: torso)
        case .hoodie:
            add(.generateSphere(radius: 0.12), look.shirtColour.mixed(with: dark, 0.2), at: [0, 0.45, 0.12], to: torso)
        case .collar:
            add(.generateCylinder(height: 0.04, radius: 0.1), OfficeColour(red: 0.95, green: 0.95, blue: 0.95), at: [0, 0.47, 0], to: torso)
        }
        // Arms: an upper arm from each shoulder, a forearm with a hand from each elbow.
        var shoulders: [Entity] = []
        var elbows: [Entity] = []
        for x: Float in [-0.19, 0.19] {
            let shoulder = pivot(at: [x, 0.42, 0], under: torso)
            add(.generateCylinder(height: 0.26, radius: 0.045), look.shirtColour, at: [0, -0.13, 0], to: shoulder)
            let elbow = pivot(at: [0, -0.26, 0], under: shoulder)
            add(.generateCylinder(height: 0.24, radius: 0.04), look.shirtColour, at: [0, -0.12, 0], to: elbow)
            add(.generateSphere(radius: 0.05), look.skin, at: [0, -0.26, 0], to: elbow)
            shoulders.append(shoulder)
            elbows.append(elbow)
        }
        // The head on a neck; hair sits up and back, leaving the face.
        let neck = pivot(at: [0, 0.46, 0], under: torso)
        add(.generateCylinder(height: 0.06, radius: 0.05), look.skin, at: [0, 0.02, 0], to: neck)
        let head = SIMD3<Float>(0, 0.16, 0)
        add(.generateSphere(radius: 0.14), look.skin, at: head, to: neck)
        add(.generateSphere(radius: 0.025), look.skin.mixed(with: dark, 0.15), at: head + [0, -0.02, -0.14], to: neck)
        for x: Float in [-0.05, 0.05] { add(.generateSphere(radius: 0.018), dark, at: head + [x, 0.01, -0.13], to: neck) }
        let cap = head + [0, 0.035, 0.03]
        switch look.hair {
        case .bald: break
        case .short: add(.generateSphere(radius: 0.142), look.hairColour, at: cap, to: neck)
        case .long:
            add(.generateSphere(radius: 0.142), look.hairColour, at: cap, to: neck)
            add(.generateBox(size: [0.26, 0.3, 0.09]), look.hairColour, at: head + [0, -0.09, 0.09], to: neck)
        case .bun:
            add(.generateSphere(radius: 0.142), look.hairColour, at: cap, to: neck)
            add(.generateSphere(radius: 0.07), look.hairColour, at: head + [0, 0.12, 0.1], to: neck)
        case .ponytail:
            add(.generateSphere(radius: 0.142), look.hairColour, at: cap, to: neck)
            add(.generateCylinder(height: 0.22, radius: 0.04), look.hairColour, at: head + [0, -0.06, 0.17], to: neck)
        case .spiky:
            add(.generateSphere(radius: 0.14), look.hairColour, at: cap, to: neck)
            for (x, z): (Float, Float) in [(0, 0), (-0.07, 0.04), (0.07, 0.04), (-0.04, -0.06), (0.04, -0.06), (0, 0.09)] {
                add(
                    .generateBox(size: [0.05, 0.1, 0.05]), look.hairColour, at: head + [x, 0.15, z + 0.02], to: neck,
                    turn: simd_quatf(angle: x * 4 - z * 3, axis: [0, 0, 1]) * simd_quatf(angle: z * 4, axis: [1, 0, 0]))
            }
        case .cap:
            // Worn backwards, so the brim shows from behind.
            add(.generateSphere(radius: 0.148), look.trousers, at: head + [0, 0.03, 0], to: neck, scale: [1, 0.85, 1])
            add(.generateBox(size: [0.2, 0.02, 0.14]), look.trousers, at: head + [0, 0.06, 0.18], to: neck)
        }
        switch look.extra {
        case .none: break
        case .glasses:
            for x: Float in [-0.055, 0.055] {
                add(.generateBox(size: [0.075, 0.05, 0.015]), dark, at: head + [x, 0.01, -0.135], to: neck)
                add(.generateBox(size: [0.01, 0.015, 0.15]), dark, at: head + [x * 2.5, 0.01, -0.06], to: neck)
            }
        case .headphones:
            add(.generateBox(size: [0.3, 0.025, 0.045]), dark, at: head + [0, 0.16, 0], to: neck)
            for x: Float in [-0.145, 0.145] {
                add(.generateBox(size: [0.025, 0.12, 0.045]), dark, at: head + [x, 0.08, 0], to: neck)
                add(.generateCylinder(height: 0.05, radius: 0.055), dark, at: head + [x, 0, 0], to: neck, turn: alongX)
            }
        }
        // A phone in the right hand: a dark slab with a lit face toward the eyes when held up.
        let phone = ModelEntity(mesh: .generateBox(size: [0.075, 0.13, 0.014], cornerRadius: 0.006), materials: [material(nsColour(dark))])
        let face = ModelEntity(
            mesh: .generatePlane(width: 0.062, height: 0.11),
            materials: [UnlitMaterial(color: NSColor(red: 0.55, green: 0.8, blue: 1, alpha: 1))])
        face.position = [0, 0, -0.008]
        face.orientation = simd_quatf(angle: .pi, axis: [0, 1, 0])
        phone.addChild(face)
        phone.position = Self.parkedProp
        elbows[1].addChild(phone)
        let rig = FigureRig(
            root: root, pelvis: pelvis, torso: torso, head: neck, shoulders: shoulders, elbows: elbows, hips: hips,
            knees: knees, parts: parts, phone: phone)
        apply(.seated, to: rig)
        return rig
    }

    // MARK: Street

    /// Puts every traveller where the street says it is now, swinging its limbs and turning its wheels.
    private func moveTravellers() {
        guard let street else { return }
        let time = Double(clock)
        for node in travellers {
            let speed = Float(abs(node.traveller.speed))
            node.entity.position.x = Float(street.x(of: node.traveller, at: time))
            // Walkers stride, cyclists pedal: each limb swings opposite the one before it.
            let stride: Float = node.traveller.kind == .walker ? 5 : 2.6
            for (index, limb) in node.limbs.enumerated() {
                let swing = sin(clock * speed * stride) * (index.isMultiple(of: 2) ? 0.4 : -0.4)
                limb.orientation = simd_quatf(angle: swing, axis: [0, 0, 1])
            }
            for wheel in node.wheels {
                let radius: Float = node.traveller.kind == .car ? 0.2 : 0.32
                wheel.orientation = simd_quatf(angle: -clock * speed / radius, axis: [0, 0, 1])
            }
        }
    }

    /// The ground around the building, the street (or the park path) in front of it, the sun (or
    /// the moon) behind it, and the people, bicycles and cars passing by.
    private func makeStreet(_ street: OfficeStreet, layout: OfficeLayout, _ palette: Palette) -> Entity {
        let entity = Entity()
        let length = Float(street.length)
        let width = Float(layout.width)
        let back = -Float(layout.depth) / 2
        let front = Float(street.pavements[1]) + Float(OfficeStreet.pavementWidth) / 2
        let grassEnd = front + 3
        let grassStart = back - 3.5
        let snow = environment == .snow
        let park = environment == .park
        let white = NSColor(white: 0.96, alpha: 1)
        // The lawn sits just under the office floor; the road just above the lawn.
        entity.addChild(
            box(
                [length + 6, 0.04, grassEnd - grassStart], palette.grass,
                at: [0, -0.08, (grassEnd + grassStart) / 2]))
        for z in street.pavements {
            entity.addChild(
                box([length + 6, 0.08, Float(OfficeStreet.pavementWidth)], palette.pavement, at: [0, -0.04, Float(z)]))
        }
        let road = Float(street.road)
        let roadWidth = Float(OfficeStreet.roadWidth)
        // A road in the city and under snow; a gravel path through the park.
        entity.addChild(box([length + 6, 0.04, park ? roadWidth * 0.6 : roadWidth], palette.road, at: [0, -0.05, road]))
        let marking = NSColor(white: 0.95, alpha: 1)
        let carLane = Float(OfficeStreet.bikeLaneWidth / 2 + (OfficeStreet.roadWidth / 2 - OfficeStreet.bikeLaneWidth) / 2)
        switch environment {
        case .city:
            // A dashed centre line, and a solid line marking off each bike lane.
            var x = -length / 2 - 3
            while x < length / 2 + 3 {
                entity.addChild(box([1, 0.005, 0.1], marking, at: [x + 0.5, -0.028, road]))
                x += 2.5
            }
            for side: Float in [-1, 1] {
                let z = road + side * (roadWidth / 2 - Float(OfficeStreet.bikeLaneWidth))
                entity.addChild(box([length + 6, 0.005, 0.05], marking, at: [0, -0.028, z]))
            }
        case .snow:
            // Tyre tracks in the slush along each lane.
            let track = palette.road.blended(withFraction: 0.35, of: white) ?? palette.road
            for side: Float in [-1, 1] {
                for wheel: Float in [-0.35, 0.35] {
                    entity.addChild(box([length + 6, 0.004, 0.18], track, at: [0, -0.028, road + side * carLane + wheel]))
                }
            }
        case .park: break
        }
        if !park {
            // A zebra crossing where the path meets the road.
            var x: Float = -0.9
            while x <= 0.9 {
                entity.addChild(box([0.22, 0.005, roadWidth - 0.3], marking, at: [x, -0.027, road]))
                x += 0.36
            }
        }
        // The concrete slab the building stands on, a step proud of the lawn, and a path from its
        // edge to the pavement.
        let depth = Float(layout.depth)
        let rim: Float = 0.15
        entity.addChild(box([width + 2 * rim, 0.09, depth + 2 * rim], palette.plinth, at: [0, -0.055, 0]))
        entity.addChild(box([1.4, 0.06, 0.4 - rim], palette.pavement, at: [0, -0.05, depth / 2 + rim + (0.4 - rim) / 2]))
        // The entrance: an awning over the path, with the Office's sign on it.
        for x: Float in [-0.85, 0.85] {
            entity.addChild(box([0.06, 0.9, 0.06], palette.windowFrame, at: [x, 0.45, depth / 2 + 0.32]))
        }
        let canopy = box([1.9, 0.05, 0.75], palette.awning, at: [0, 0.92, depth / 2 + 0.2])
        canopy.orientation = simd_quatf(angle: 0.18, axis: [1, 0, 0])
        entity.addChild(canopy)
        // The sign lies on the canopy, read from above like the Center Room's name.
        let signMesh = textMesh(Copy.officeEntranceSign, size: 0.22)
        let sign = ModelEntity(mesh: signMesh, materials: [UnlitMaterial(color: white)])
        let signBounds = signMesh.bounds
        sign.orientation = simd_quatf(angle: -.pi / 2 + 0.18, axis: [1, 0, 0])
        sign.position = [-(signBounds.min.x + signBounds.extents.x / 2), 0.955, depth / 2 + 0.2 + (signBounds.min.y + signBounds.extents.y / 2)]
        entity.addChild(sign)
        // Flower beds either side of the path; under snow they are just mounds.
        for side: Float in [-1, 1] {
            let bed = SIMD3<Float>(side * 1.1, 0, depth / 2 + 0.26)
            entity.addChild(box([0.5, 0.12, 0.22], snow ? white : NSColor(red: 0.36, green: 0.26, blue: 0.18, alpha: 1), at: bed + [0, 0.04, 0]))
            if !snow {
                let blooms = [NSColor.systemPink, .systemYellow, .systemRed, .white, .systemPurple]
                for (index, x) in [-0.16, 0, 0.16].enumerated() {
                    let stem = box([0.015, 0.14, 0.015], NSColor(red: 0.3, green: 0.55, blue: 0.3, alpha: 1), at: bed + [Float(x), 0.16, 0])
                    entity.addChild(stem)
                    let bloom = ModelEntity(
                        mesh: .generateSphere(radius: 0.04), materials: [material(blooms[(index + Int(side + 1)) % blooms.count])])
                    bloom.position = bed + [Float(x), 0.25, 0]
                    entity.addChild(bloom)
                }
            }
        }
        // A bench on the near pavement, facing the road.
        let benchWood = NSColor(red: 0.55, green: 0.38, blue: 0.22, alpha: 1)
        let benchZ = Float(street.pavements[0]) - 0.35
        for x: Float in [-0.55, 0.55] {
            entity.addChild(box([0.05, 0.42, 0.4], NSColor(white: 0.25, alpha: 1), at: [2.8 + x, 0.21, benchZ]))
        }
        entity.addChild(box([1.2, 0.05, 0.4], benchWood, at: [2.8, 0.44, benchZ]))
        entity.addChild(box([1.2, 0.35, 0.05], benchWood, at: [2.8, 0.6, benchZ - 0.2]))
        if snow { entity.addChild(box([1.2, 0.03, 0.4], white, at: [2.8, 0.48, benchZ])) }
        // Low clipped hedges along the back and the sides, clear of the street side so they hide no Desk.
        func hedge(_ size: SIMD3<Float>, at position: SIMD3<Float>) {
            let model = ModelEntity(
                mesh: .generateBox(size: size, cornerRadius: 0.1), materials: [material(palette.hedge, roughness: 0.9)])
            model.position = position
            entity.addChild(model)
            if snow { entity.addChild(box([size.x, 0.05, size.z], white, at: position + [0, size.y / 2, 0])) }
        }
        hedge([width + 1.2, 0.4, 0.4], at: [0, 0.14, back - 0.5])
        for side: Float in [-1, 1] { hedge([0.4, 0.4, depth - 0.4], at: [side * (width / 2 + 0.5), 0.14, -0.2]) }
        // A pond on the park's lawn, past the far path.
        let pondX = -width / 2 - 6
        if park {
            let pondZ = front + 1.6
            let water = ModelEntity(
                mesh: .generateCylinder(height: 0.03, radius: 1.5),
                materials: [material(dark ? NSColor(red: 0.12, green: 0.2, blue: 0.32, alpha: 1) : NSColor(red: 0.45, green: 0.7, blue: 0.86, alpha: 1), roughness: 0.1)])
            water.position = [pondX, -0.06, pondZ]
            water.scale = [1.3, 1, 0.8]
            entity.addChild(water)
            let bank = ModelEntity(mesh: .generateCylinder(height: 0.04, radius: 1.65), materials: [material(palette.pavement)])
            bank.position = [pondX, -0.07, pondZ]
            bank.scale = [1.3, 1, 0.8]
            entity.addChild(bank)
            for (dx, dz) in [(-0.6, 0.3), (0.5, -0.2), (0.1, 0.5)] {
                let lily = ModelEntity(mesh: .generateCylinder(height: 0.01, radius: 0.12), materials: [material(NSColor(red: 0.3, green: 0.6, blue: 0.32, alpha: 1))])
                lily.position = [pondX + Float(dx) * 1.3, -0.04, pondZ + Float(dz) * 0.8]
                entity.addChild(lily)
            }
        }

        // Trees behind the building and along the far pavement, street lamps between them. Nothing
        // tall stands between the building and the road, so the Desks stay in view.
        let leaf = NSColor(red: 0.3, green: 0.58, blue: 0.3, alpha: 1)
        let leafDark = NSColor(red: 0.2, green: 0.45, blue: 0.25, alpha: 1)
        let bark = NSColor(red: 0.42, green: 0.3, blue: 0.2, alpha: 1)
        func tree(at position: SIMD3<Float>, size: Float) {
            let tree = Entity()
            tree.position = position
            tree.addChild(box([0.16 * size, 1.1 * size, 0.16 * size], bark, at: [0, 0.55 * size, 0]))
            for (offset, radius, colour) in [
                (SIMD3<Float>(0, 1.4, 0), Float(0.55), leafDark), ([0.25, 1.75, 0.1], 0.4, leaf),
                ([-0.22, 1.65, -0.12], 0.38, leaf),
            ] {
                let crown = ModelEntity(mesh: .generateSphere(radius: radius * size), materials: [material(colour)])
                crown.position = offset * size
                tree.addChild(crown)
                if snow {
                    // A cap of snow on each crown.
                    let cap = ModelEntity(mesh: .generateSphere(radius: radius * size * 0.95), materials: [material(white)])
                    cap.position = offset * size + [0, radius * size * 0.3, 0]
                    cap.scale = [1, 0.4, 1]
                    tree.addChild(cap)
                }
            }
            entity.addChild(tree)
        }
        var step: Float = 0
        var x = -width / 2 - 1
        while x <= width / 2 + 1 {
            tree(at: [x, -0.06, back - 1.6 - (step.truncatingRemainder(dividingBy: 2)) * 0.8], size: 1.1)
            x += 2.6
            step += 1
        }
        let edge = Float(street.pavements[1]) + Float(OfficeStreet.pavementWidth) / 2 - 0.3
        x = -length / 2 + 2
        step = 0
        let metal = NSColor(white: 0.3, alpha: 1)
        // At night the lamps are lit: a real light over the road and the pavement, so the ground,
        // the trees and the travellers passing under it take its warm colour, and a haze round it.
        var lens = UnlitMaterial(applyPostProcessToneMap: !dark)
        lens.color = .init(tint: palette.lampGlow)
        halos = []
        while x < length / 2 - 1 {
            if step.truncatingRemainder(dividingBy: 2) == 0 {
                if !(park && abs(x - pondX) < 2.2) { tree(at: [x, 0, edge], size: 1) }
                // The park has a second row of trees behind the first.
                if park { tree(at: [x + 1.8, 0, edge + 2.2], size: 0.85) }
            } else {
                entity.addChild(box([0.08, 2.6, 0.08], metal, at: [x, 1.3, edge]))
                entity.addChild(box([0.08, 0.06, 0.6], metal, at: [x, 2.6, edge - 0.27]))
                entity.addChild(box([0.26, 0.08, 0.32], metal, at: [x, 2.58, edge - 0.55]))
                if snow { entity.addChild(box([0.28, 0.04, 0.34], white, at: [x, 2.64, edge - 0.55])) }
                let bulb = SIMD3<Float>(x, 2.53, edge - 0.55)
                let glass = ModelEntity(mesh: .generateBox(size: [0.22, 0.02, 0.28]), materials: [lens])
                glass.position = bulb
                entity.addChild(glass)
                if dark {
                    let light = SpotLight()
                    light.light = SpotLightComponent(
                        color: palette.lampGlow, intensity: 600_000, innerAngleInDegrees: 45,
                        outerAngleInDegrees: 110, attenuationRadius: 12)
                    light.shadow = SpotLightComponent.Shadow()
                    // Down and a little out over the road.
                    light.look(at: bulb + [0, -2.5, -0.6], from: bulb + [0, -0.05, 0], relativeTo: entity)
                    entity.addChild(light)
                    let halo = ModelEntity(mesh: .generatePlane(width: 1.6, height: 1.6), materials: [lampHalo])
                    halo.position = bulb + [0, -0.05, 0]
                    entity.addChild(halo)
                    halos.append(halo)
                }
            }
            x += 4
            step += 1
        }

        sun.model?.materials = [dark ? moonFace : sunFace]
        rays.isEnabled = !dark
        key.light.intensity = dark ? 2_200 : 3_800
        key.light.color = dark ? NSColor(red: 0.72, green: 0.8, blue: 1, alpha: 1) : .white
        fill.light.intensity = dark ? 900 : 1_500
        fill.light.color = key.light.color

        // No cars in the park; winter coats under snow.
        travellers = street.travellers.filter { options.streetLife && !(park && $0.kind == .car) }.map { traveller in
            let node = makeTraveller(traveller, coats: snow)
            entity.addChild(node.entity)
            return node
        }
        return entity
    }

    /// A walker, a cyclist or a car, built facing east and turned round when it heads west.
    private func makeTraveller(_ traveller: OfficeTraveller, coats: Bool) -> TravellerNode {
        let entity = Entity()
        entity.position = [0, 0, Float(traveller.z)]
        if traveller.speed < 0 { entity.orientation = simd_quatf(angle: .pi, axis: [0, 1, 0]) }
        let body = nsColour(coats && traveller.kind != .car ? traveller.body.mixed(with: OfficeColour(red: 0, green: 0, blue: 0), 0.35) : traveller.body)
        let skin = nsColour(traveller.skin)
        let legs = nsColour(traveller.legs)
        let dark = NSColor(white: 0.12, alpha: 1)
        var limbs: [Entity] = []
        var wheels: [Entity] = []
        func add(_ mesh: MeshResource, _ colour: NSColor, at position: SIMD3<Float>, to parent: Entity? = nil) {
            let model = ModelEntity(mesh: mesh, materials: [material(colour)])
            model.position = position
            (parent ?? entity).addChild(model)
        }
        /// A limb hanging from `joint`, swinging about it.
        func limb(_ size: SIMD3<Float>, _ colour: NSColor, joint: SIMD3<Float>, turn: Float = 0) {
            let pivot = Entity()
            pivot.position = joint
            let piece = box(size, colour, at: [0, -size.y / 2, 0])
            if turn != 0 {
                // Bent forward from the joint (a cyclist's arm reaching to the bars).
                piece.orientation = simd_quatf(angle: turn, axis: [0, 0, 1])
                piece.position = [sin(turn) * size.y / 2, -cos(turn) * size.y / 2, 0]
            }
            pivot.addChild(piece)
            entity.addChild(pivot)
            limbs.append(pivot)
        }
        func wheel(at position: SIMD3<Float>, radius: Float, thickness: Float) {
            let pivot = Entity()
            pivot.position = position
            let tyre = ModelEntity(
                mesh: .generateCylinder(height: thickness, radius: radius), materials: [material(dark)])
            tyre.orientation = simd_quatf(angle: .pi / 2, axis: [1, 0, 0])
            pivot.addChild(tyre)
            // A spoke across the tyre's face shows it turning.
            let spoke = box([radius * 1.8, 0.03, thickness + 0.01], NSColor(white: 0.7, alpha: 1), at: .zero)
            pivot.addChild(spoke)
            entity.addChild(pivot)
            wheels.append(pivot)
        }
        func head(at position: SIMD3<Float>) {
            add(.generateSphere(radius: 0.13), skin, at: position)
            add(.generateSphere(radius: 0.132), nsColour(traveller.hair), at: position + [-0.02, 0.035, 0])
            // A woolly hat in the snow.
            if coats { add(.generateSphere(radius: 0.136), body, at: position + [-0.02, 0.05, 0]) }
        }

        switch traveller.kind {
        case .walker:
            for z: Float in [-0.07, 0.07] { limb([0.1, 0.78, 0.11], legs, joint: [0, 0.78, z]) }
            add(.generateCylinder(height: 0.55, radius: 0.15), body, at: [0, 1.06, 0])
            for z: Float in [0.19, -0.19] { limb([0.08, 0.5, 0.08], body, joint: [0, 1.3, z]) }
            head(at: [0, 1.48, 0])
        case .bicycle:
            for x: Float in [-0.5, 0.5] { wheel(at: [x, 0.32, 0], radius: 0.32, thickness: 0.04) }
            add(.generateBox(size: [0.9, 0.05, 0.05]), body, at: [0, 0.62, 0])
            add(.generateBox(size: [0.05, 0.4, 0.05]), body, at: [-0.22, 0.6, 0])
            add(.generateBox(size: [0.05, 0.5, 0.05]), body, at: [0.42, 0.7, 0])
            add(.generateBox(size: [0.06, 0.03, 0.46]), dark, at: [0.42, 0.95, 0])
            add(.generateBox(size: [0.22, 0.04, 0.12]), dark, at: [-0.24, 0.82, 0])
            for z: Float in [-0.08, 0.08] { limb([0.1, 0.62, 0.1], legs, joint: [-0.2, 0.86, z]) }
            let torso = box([0.22, 0.55, 0.3], body, at: [-0.08, 1.1, 0])
            torso.orientation = simd_quatf(angle: -0.4, axis: [0, 0, 1])
            entity.addChild(torso)
            for z: Float in [-0.17, 0.17] {
                let arm = box([0.07, 0.5, 0.07], body, at: [0.2, 1.12, z])
                arm.orientation = simd_quatf(angle: 1.0, axis: [0, 0, 1])
                entity.addChild(arm)
            }
            head(at: [0.08, 1.48, 0])
        case .car:
            add(.generateBox(size: [1.8, 0.42, 0.9], cornerRadius: 0.08), body, at: [0, 0.42, 0])
            add(
                .generateBox(size: [1.0, 0.32, 0.84], cornerRadius: 0.06), NSColor(red: 0.22, green: 0.3, blue: 0.4, alpha: 1),
                at: [-0.12, 0.78, 0])
            add(.generateBox(size: [0.94, 0.06, 0.8]), coats ? NSColor(white: 0.96, alpha: 1) : body, at: [-0.12, 0.96, 0])
            for x: Float in [-0.58, 0.58] {
                for z: Float in [-0.42, 0.42] { wheel(at: [x, 0.2, z], radius: 0.2, thickness: 0.12) }
            }
            for (x, colour) in [(Float(0.9), NSColor(red: 1, green: 0.96, blue: 0.8, alpha: 1)), (-0.9, NSColor.systemRed)] {
                for z: Float in [-0.3, 0.3] {
                    let light = ModelEntity(
                        mesh: .generateBox(size: [0.02, 0.08, 0.16]), materials: [UnlitMaterial(color: colour)])
                    light.position = [x, 0.48, z]
                    entity.addChild(light)
                }
            }
        }
        return TravellerNode(entity: entity, traveller: traveller, limbs: limbs, wheels: wheels)
    }

    // MARK: Furniture

    /// One piece, its back on the wall it stands against.
    private func makeFurniture(_ piece: PlacedFurniture, _ palette: Palette) -> Entity {
        let entity = Entity()
        func add(_ size: SIMD3<Float>, _ colour: NSColor, at position: SIMD3<Float>) {
            entity.addChild(box(size, colour, at: position))
        }
        func add(_ mesh: MeshResource, _ colour: NSColor, at position: SIMD3<Float>, scale: SIMD3<Float> = .one) {
            let model = ModelEntity(mesh: mesh, materials: [material(colour)])
            model.position = position
            model.scale = scale
            entity.addChild(model)
        }
        func pick(_ colours: [NSColor]) -> NSColor { colours[piece.variant % colours.count] }
        let leaf = NSColor(red: 0.3, green: 0.6, blue: 0.32, alpha: 1)
        let leafDark = NSColor(red: 0.2, green: 0.47, blue: 0.26, alpha: 1)
        let pots = [
            NSColor(red: 0.76, green: 0.42, blue: 0.3, alpha: 1), NSColor(white: 0.92, alpha: 1),
            NSColor(white: 0.25, alpha: 1), NSColor(red: 0.6, green: 0.68, blue: 0.56, alpha: 1),
        ]
        let fabrics = [
            NSColor(red: 0.2, green: 0.55, blue: 0.58, alpha: 1), NSColor(red: 0.88, green: 0.68, blue: 0.24, alpha: 1),
            NSColor(red: 0.72, green: 0.34, blue: 0.24, alpha: 1), NSColor(red: 0.38, green: 0.44, blue: 0.56, alpha: 1),
        ]
        let metal = NSColor(white: 0.35, alpha: 1)

        switch piece.kind {
        case .plant:
            add(.generateCylinder(height: 0.3, radius: 0.16), pick(pots), at: [0, 0.15, 0])
            add(.generateSphere(radius: 0.2), leaf, at: [0, 0.45, 0])
            add(.generateSphere(radius: 0.14), leafDark, at: [0.08, 0.6, 0.02])
            add(.generateSphere(radius: 0.12), leaf, at: [-0.09, 0.56, -0.04])
        case .tree:
            add(.generateCylinder(height: 0.36, radius: 0.2), pick(pots), at: [0, 0.18, 0])
            add(.generateCylinder(height: 0.75, radius: 0.035), NSColor(red: 0.42, green: 0.3, blue: 0.2, alpha: 1), at: [0, 0.72, 0])
            add(.generateSphere(radius: 0.3), leafDark, at: [0, 1.15, 0])
            add(.generateSphere(radius: 0.22), leaf, at: [0.12, 1.38, 0.05])
            add(.generateSphere(radius: 0.2), leaf, at: [-0.14, 1.3, -0.06])
        case .bookshelf:
            add([0.76, 1.5, 0.04], palette.desk, at: [0, 0.75, -0.38])
            for x: Float in [-0.36, 0.36] { add([0.04, 1.5, 0.32], palette.desk, at: [x, 0.75, -0.24]) }
            let shelves: [Float] = [0.02, 0.4, 0.78, 1.16, 1.49]
            for y in shelves { add([0.72, 0.03, 0.3], palette.desk, at: [0, y, -0.24]) }
            let books = [
                NSColor(red: 0.75, green: 0.25, blue: 0.22, alpha: 1), NSColor(red: 0.2, green: 0.4, blue: 0.7, alpha: 1),
                NSColor(red: 0.9, green: 0.75, blue: 0.3, alpha: 1), NSColor(red: 0.25, green: 0.55, blue: 0.4, alpha: 1),
                NSColor(white: 0.9, alpha: 1), NSColor(red: 0.5, green: 0.3, blue: 0.6, alpha: 1),
            ]
            for (shelf, y) in shelves.dropLast().enumerated() {
                var x: Float = -0.32
                var index = shelf * 3 + piece.variant
                // Each shelf ends a little earlier, so the rows of books do not line up.
                while x < 0.3 - Float((shelf + piece.variant) % 3) * 0.08 {
                    let width: Float = [0.05, 0.07, 0.06][index % 3]
                    let height: Float = [0.26, 0.3, 0.22, 0.28][index % 4]
                    add([width, height, 0.22], books[(index * 7) % books.count], at: [x + width / 2, y + 0.015 + height / 2, -0.24])
                    x += width + 0.005
                    index += 1
                }
            }
        case .cabinet:
            let colours = [
                NSColor(white: 0.6, alpha: 1), NSColor(red: 0.45, green: 0.52, blue: 0.62, alpha: 1),
                NSColor(red: 0.8, green: 0.75, blue: 0.66, alpha: 1), NSColor(white: 0.3, alpha: 1),
            ]
            add([0.5, 0.78, 0.5], pick(colours), at: [0, 0.39, -0.15])
            for y: Float in [0.26, 0.52] { add([0.46, 0.012, 0.01], metal, at: [0, y, 0.105]) }
            for y: Float in [0.13, 0.39, 0.65] { add([0.12, 0.025, 0.02], metal, at: [0, y, 0.11]) }
        case .waterCooler:
            add([0.32, 0.95, 0.32], NSColor(white: 0.92, alpha: 1), at: [0, 0.475, -0.2])
            add(.generateCylinder(height: 0.42, radius: 0.14), NSColor(red: 0.6, green: 0.8, blue: 0.95, alpha: 1), at: [0, 1.16, -0.2])
            add([0.04, 0.05, 0.04], NSColor(red: 0.3, green: 0.5, blue: 0.9, alpha: 1), at: [-0.06, 0.75, -0.03])
            add([0.04, 0.05, 0.04], NSColor(red: 0.85, green: 0.3, blue: 0.25, alpha: 1), at: [0.06, 0.75, -0.03])
        case .lamp:
            add(.generateCylinder(height: 0.03, radius: 0.16), metal, at: [0, 0.015, -0.15])
            add(.generateCylinder(height: 1.45, radius: 0.018), metal, at: [0, 0.74, -0.15])
            let shade = ModelEntity(
                mesh: .generateCylinder(height: 0.26, radius: 0.2),
                materials: [UnlitMaterial(color: NSColor(red: 1, green: 0.9, blue: 0.7, alpha: 1))])
            shade.position = [0, 1.5, -0.15]
            entity.addChild(shade)
        case .whiteboard:
            for x: Float in [-0.36, 0.36] {
                add([0.04, 1.5, 0.04], metal, at: [x, 0.75, -0.3])
                add([0.04, 0.03, 0.4], metal, at: [x, 0.015, -0.2])
            }
            add([0.8, 0.57, 0.03], metal, at: [0, 1.15, -0.29])
            let board = ModelEntity(
                mesh: .generateBox(size: [0.76, 0.53, 0.01]), materials: [UnlitMaterial(color: NSColor(white: 0.97, alpha: 1))])
            board.position = [0, 1.15, -0.27]
            entity.addChild(board)
            let ink = [NSColor.systemBlue, .systemRed, .systemGreen, .darkGray]
            for line in 0..<3 {
                let width: Float = [0.5, 0.36, 0.44][(line + piece.variant) % 3]
                let scribble = ModelEntity(
                    mesh: .generateBox(size: [width, 0.02, 0.004]),
                    materials: [UnlitMaterial(color: ink[(line + piece.variant) % ink.count])])
                scribble.position = [-0.3 + width / 2, 1.3 - Float(line) * 0.12, -0.262]
                entity.addChild(scribble)
            }
        case .armchair:
            let fabric = pick(fabrics)
            add([0.56, 0.22, 0.6], fabric, at: [0, 0.2, 0])
            add([0.66, 0.55, 0.16], fabric, at: [0, 0.45, -0.3])
            for x: Float in [-0.33, 0.33] { add([0.1, 0.38, 0.6], fabric, at: [x, 0.3, 0]) }
            add([0.48, 0.06, 0.42], fabric.blended(withFraction: 0.25, of: .white) ?? fabric, at: [0, 0.34, 0.06])
        case .beanBag:
            add(.generateSphere(radius: 0.32), pick(fabrics), at: [0, 0.2, 0], scale: [1, 0.62, 1])
        case .bin:
            add(.generateCylinder(height: 0.36, radius: 0.14), pick([metal, NSColor(red: 0.3, green: 0.45, blue: 0.35, alpha: 1)]), at: [0, 0.18, 0])
            add(.generateSphere(radius: 0.05), NSColor(white: 0.95, alpha: 1), at: [0.03, 0.37, 0.02])
        }
        let turn: Float =
            switch piece.against {
            case .north: 0
            case .south: .pi
            case .west: .pi / 2
            case .east: -.pi / 2
            }
        entity.orientation = simd_quatf(angle: turn, axis: [0, 1, 0])
        return entity
    }

    /// The Desk a tap landed on, from the entity that was hit.
    static func deskId(of entity: Entity) -> String? {
        var current: Entity? = entity
        while let candidate = current {
            if let tag = candidate.components[DeskTag.self] { return tag.id }
            current = candidate.parent
        }
        return nil
    }

    var backgroundColour: NSColor { Palette.make(style: style, environment: environment, dark: dark).background }
}
