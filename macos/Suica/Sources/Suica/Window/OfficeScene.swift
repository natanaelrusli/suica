import AppKit
import RealityKit
import SuicaCore
import SwiftUI

/// Marks the entity a click on a Desk lands on.
struct DeskTag: Component {
    var id: String
}

/// The floor, wall and desk colours of one appearance.
private struct Palette {
    let floor: NSColor
    let hallFloor: NSColor
    let wall: NSColor
    let desk: NSColor
    let label: NSColor
    let bubble: NSColor
    let bubbleText: NSColor
    let background: NSColor
    let grass: NSColor
    let pavement: NSColor
    let road: NSColor
    /// The sun by day, the moon by night.
    let sun: NSColor
    let lampGlow: NSColor

    static let light = Palette(
        floor: NSColor(white: 0.88, alpha: 1), hallFloor: NSColor(red: 0.8, green: 0.84, blue: 0.9, alpha: 1),
        wall: NSColor(white: 0.78, alpha: 1),
        desk: NSColor(red: 0.78, green: 0.66, blue: 0.5, alpha: 1), label: NSColor(white: 0.25, alpha: 1),
        bubble: .white, bubbleText: NSColor(white: 0.12, alpha: 1),
        background: NSColor(white: 0.96, alpha: 1),
        grass: NSColor(red: 0.55, green: 0.75, blue: 0.42, alpha: 1), pavement: NSColor(white: 0.8, alpha: 1),
        road: NSColor(white: 0.36, alpha: 1), sun: NSColor(red: 1, green: 0.9, blue: 0.45, alpha: 1),
        lampGlow: NSColor(white: 0.92, alpha: 1))
    static let dark = Palette(
        floor: NSColor(white: 0.2, alpha: 1), hallFloor: NSColor(red: 0.16, green: 0.19, blue: 0.25, alpha: 1),
        wall: NSColor(white: 0.3, alpha: 1),
        desk: NSColor(red: 0.45, green: 0.37, blue: 0.28, alpha: 1), label: NSColor(white: 0.85, alpha: 1),
        bubble: NSColor(white: 0.32, alpha: 1), bubbleText: .white,
        background: NSColor(white: 0.11, alpha: 1),
        grass: NSColor(red: 0.17, green: 0.27, blue: 0.17, alpha: 1), pavement: NSColor(white: 0.32, alpha: 1),
        road: NSColor(white: 0.15, alpha: 1), sun: NSColor(red: 0.9, green: 0.92, blue: 0.98, alpha: 1),
        lampGlow: NSColor(red: 1, green: 0.85, blue: 0.5, alpha: 1))
}

private func material(_ colour: NSColor, roughness: Float = 0.7) -> SimpleMaterial {
    SimpleMaterial(color: colour, roughness: MaterialScalarParameter(floatLiteral: roughness), isMetallic: false)
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

/// One Desk: its furniture, its figure and its bubble.
private struct DeskNode {
    let entity: Entity
    let figure: Entity
    var parts: [FigurePart]
    let screen: ModelEntity
    let bubble: Entity
    let rug: ModelEntity
    var bubbleText: String
    var status: OfficeStatus
    var agent: String
    var dark: Bool
    var target: SIMD3<Float>
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
    /// The sun by day, the moon by night: carried by the camera, so it stays at the top of the view
    /// however the view is turned.
    private let sun = ModelEntity(mesh: .generateSphere(radius: 1.65), materials: [])
    private var rooms: [String: RoomNode] = [:]
    private var desks: [String: DeskNode] = [:]
    private var street: OfficeStreet?
    private var streetEntity: Entity?
    private var streetSignature = ""
    private var travellers: [TravellerNode] = []
    private var clock: Float = 0
    private var updates: EventSubscription?
    private var animate = true
    private var dark = false
    private var layoutExtent = SIMD2<Float>(8, 6)
    private static let doorWidth: Float = 1.4

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
        camera.addChild(sun)
        sun.addChild(ModelEntity(mesh: .generateSphere(radius: 2.55), materials: []))
        let key = DirectionalLight()
        key.light.intensity = 3_500
        key.look(at: .zero, from: [-4, 8, 6], relativeTo: nil)
        let fill = DirectionalLight()
        fill.light.intensity = 1_800
        fill.look(at: .zero, from: [6, 5, 3], relativeTo: nil)
        root.addChild(key)
        root.addChild(fill)
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

    private var fitDistance: Float {
        let vertical = camera.camera.fieldOfViewInDegrees * .pi / 180
        let horizontal = 2 * atan(tan(vertical / 2) * aspect)
        // What the floor covers on screen, turned by the camera's yaw and tilted by its pitch.
        let across = 0.5 * (layoutExtent.x * abs(cos(yaw)) + layoutExtent.y * abs(sin(yaw))) + 1.2
        let deep = 0.5 * (layoutExtent.x * abs(sin(yaw)) + layoutExtent.y * abs(cos(yaw)))
        let up = deep * sin(pitch) + 1.6 * cos(pitch) + 0.8
        return max(across / tan(horizontal / 2), up / tan(vertical / 2))
    }

    private func applyCamera() {
        let distance = max(3, fitDistance * zoom)
        let height = sin(pitch) * distance
        let ground = cos(pitch) * distance
        let eye = SIMD3<Float>(sin(yaw) * ground, height, cos(yaw) * ground)
        camera.look(at: focus, from: focus + eye, relativeTo: nil)
        // In the strip of sky along the top of the view, behind the whole scene: when the view is
        // turned so ground fills the top, the ground hides it.
        let depth: Float = 60
        let up = depth * tan(camera.camera.fieldOfViewInDegrees * .pi / 360)
        sun.position = [0.3 * up * aspect, 0.84 * up, -depth]
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

    func sync(layout: OfficeLayout, sessions: [OfficeSession], selected: String?, dark: Bool, animate: Bool) {
        self.animate = animate
        let darkChanged = self.dark != dark
        self.dark = dark
        let palette = dark ? Palette.dark : Palette.light
        layoutExtent = SIMD2(Float(layout.width), Float(layout.depth))
        if !adjusted { applyCamera() }

        // Rooms: the project Rooms and the Center Room they open onto.
        var liveRooms = Set<String>()
        for room in layout.all {
            liveRooms.insert(room.path)
            let walls = room.walls.map(\.rawValue).sorted().joined(separator: ",")
            let signature = "\(room.name)|\(room.width)|\(room.depth)|\(walls)|\(room.door?.rawValue ?? "")|\(dark)"
            if rooms[room.path]?.signature != signature {
                rooms[room.path]?.entity.removeFromParent()
                let entity = makeRoom(room, palette)
                root.addChild(entity)
                rooms[room.path] = RoomNode(entity: entity, signature: signature)
            }
            rooms[room.path]?.entity.position = [Float(room.center.x), 0, Float(room.center.z)]
        }
        for (path, node) in rooms where !liveRooms.contains(path) {
            node.entity.removeFromParent()
            rooms[path] = nil
        }

        // The street outside, laid out again only when the building's size or the appearance changes.
        let streetSignature = "\(layout.width)|\(layout.depth)|\(dark)"
        if streetSignature != self.streetSignature {
            self.streetSignature = streetSignature
            streetEntity?.removeFromParent()
            let street = OfficeStreet(layout: layout)
            let entity = makeStreet(street, layout: layout, palette)
            root.addChild(entity)
            self.street = street
            streetEntity = entity
            moveTravellers()
        }

        // Desks
        let sessionsById = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        var placed: [String: SIMD3<Float>] = [:]
        for room in layout.rooms {
            for desk in room.desks { placed[desk.sessionId] = [Float(desk.position.x), 0, Float(desk.position.z)] }
        }
        for (id, position) in placed {
            guard let session = sessionsById[id] else { continue }
            if desks[id] == nil {
                let node = makeDesk(session, palette)
                node.entity.position = position
                if animate {
                    node.entity.scale = [0.01, 0.01, 0.01]
                    root.addChild(node.entity)
                    node.entity.move(
                        to: Transform(scale: .one, translation: position), relativeTo: root, duration: 0.45,
                        timingFunction: .easeOut)
                } else {
                    root.addChild(node.entity)
                }
                desks[id] = node
            }
            guard var node = desks[id] else { continue }
            if node.target != position {
                node.target = position
                if animate {
                    node.entity.move(
                        to: Transform(scale: .one, translation: position), relativeTo: root, duration: 0.35)
                } else {
                    node.entity.position = position
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

    private func tick(_ delta: Float) {
        clock += delta
        guard animate else { return }
        moveTravellers()
        for node in desks.values where node.status == .working {
            node.figure.position.y = sin(clock * 5 + Float(abs(node.target.x))) * 0.025
        }
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

    /// A low wall along one side of a room, with a doorway in its middle when `door` is set.
    private func addWall(
        to entity: Entity, side: OfficeSide, room: PlacedRoom, palette: Palette
    ) {
        let width = Float(room.width)
        let depth = Float(room.depth)
        let thickness: Float = 0.06
        let height: Float = 0.5
        let walls = room.walls
        switch side {
        case .north, .south:
            let z = (side == .north ? -1 : 1) * (depth / 2 - thickness / 2)
            guard room.door == side else {
                entity.addChild(box([width, height, thickness], palette.wall, at: [0, height / 2, z]))
                return
            }
            let piece = (width - Self.doorWidth) / 2
            for direction: Float in [-1, 1] {
                entity.addChild(
                    box(
                        [piece, height, thickness], palette.wall,
                        at: [direction * (Self.doorWidth + piece) / 2, height / 2, z]))
            }
            // A mat in the doorway, so the way through reads from above.
            entity.addChild(box([Self.doorWidth, 0.014, 0.5], palette.desk, at: [0, 0.007, z]))
        case .west, .east:
            // Between the north and south walls, which run the whole width.
            let top = walls.contains(.north) ? thickness : 0
            let bottom = walls.contains(.south) ? thickness : 0
            let x = (side == .west ? -1 : 1) * (width / 2 - thickness / 2)
            entity.addChild(
                box(
                    [thickness, height, depth - top - bottom], palette.wall,
                    at: [x, height / 2, (top - bottom) / 2]))
        }
    }

    private func makeRoom(_ room: PlacedRoom, _ palette: Palette) -> Entity {
        let entity = Entity()
        let width = Float(room.width)
        let depth = Float(room.depth)
        entity.addChild(
            box([width, 0.06, depth], room.isCenter ? palette.hallFloor : palette.floor, at: [0, -0.03, 0]))
        for side in [OfficeSide.north, .south, .west, .east] where room.walls.contains(side) {
            addWall(to: entity, side: side, room: room, palette: palette)
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
            label.position = [x, 0.52 - bounds.min.y, depth / 2 - 0.03]
        }
        entity.addChild(label)
        return entity
    }

    private func makeDesk(_ session: OfficeSession, _ palette: Palette) -> DeskNode {
        let entity = Entity()
        // Furniture: a desk, a monitor facing the viewer, a chair.
        entity.addChild(box([1.2, 0.05, 0.6], palette.desk, at: [0, 0.72, -0.15]))
        entity.addChild(box([0.05, 0.72, 0.55], palette.desk, at: [-0.55, 0.36, -0.15]))
        entity.addChild(box([0.05, 0.72, 0.55], palette.desk, at: [0.55, 0.36, -0.15]))
        entity.addChild(box([0.05, 0.22, 0.05], .darkGray, at: [0, 0.86, -0.3]))
        let screen = ModelEntity(mesh: .generateBox(size: [0.56, 0.34, 0.03]), materials: [UnlitMaterial(color: .darkGray)])
        screen.position = [0, 1.1, -0.3]
        entity.addChild(screen)
        entity.addChild(
            box([0.42, 0.05, 0.42], NSColor(white: 0.3, alpha: 1), at: [0, 0.3, 0.55]))
        entity.addChild(box([0.05, 0.28, 0.05], NSColor(white: 0.3, alpha: 1), at: [0, 0.15, 0.55]))

        // The figure, dressed by its look, bobbing as one.
        let figure = Entity()
        entity.addChild(figure)

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
            entity: entity, figure: figure, parts: [], screen: screen, bubble: bubble, rug: rug,
            bubbleText: "", status: .idle, agent: "", dark: dark, target: entity.position)
        update(&node, with: session, palette: palette, force: true)
        return node
    }

    private func update(_ node: inout DeskNode, with session: OfficeSession, palette: Palette, force: Bool) {
        let live = session.status == .working || session.status == .waiting
        let text = session.bubble
        if node.agent != session.agent {
            for child in Array(node.figure.children) { child.removeFromParent() }
            node.parts = dress(node.figure, OfficeLook(session: session))
        }
        if force || node.status != session.status || node.agent != session.agent {
            for part in node.parts {
                part.entity.model?.materials = [material(nsColour(live ? part.colour : part.colour.greyed))]
            }
            let screen: NSColor =
                switch session.status {
                case .working: NSColor(red: 0.45, green: 0.85, blue: 1, alpha: 1)
                case .waiting: amber
                default: NSColor(white: 0.18, alpha: 1)
                }
            node.screen.model?.materials = [UnlitMaterial(color: screen)]
            if session.status != .working { node.figure.position.y = 0 }
        }
        if force || node.bubbleText != text || node.status != session.status {
            // A copy: removing while walking `children` skips every other one and the old text stays.
            for child in Array(node.bubble.children) { child.removeFromParent() }
            let mesh = textMesh(text, size: 0.15)
            let bounds = mesh.bounds
            let width = max(0.7, bounds.extents.x + 0.3)
            let background = session.status == .waiting ? amber : palette.bubble
            let plate = ModelEntity(
                mesh: .generatePlane(width: width, height: 0.32, cornerRadius: 0.1),
                materials: [UnlitMaterial(color: background)])
            let label = ModelEntity(
                mesh: mesh,
                materials: [UnlitMaterial(color: session.status == .waiting ? NSColor(white: 0.1, alpha: 1) : palette.bubbleText)])
            label.position = [-(bounds.min.x + bounds.extents.x / 2), -(bounds.min.y + bounds.extents.y / 2), 0.004]
            node.bubble.addChild(plate)
            node.bubble.addChild(label)
        }
        node.bubbleText = text
        node.status = session.status
        node.agent = session.agent
        node.dark = dark
    }

    /// Seats a figure dressed by `look` at the chair, facing its monitor (the viewer sees its back).
    private func dress(_ figure: Entity, _ look: OfficeLook) -> [FigurePart] {
        var parts: [FigurePart] = []
        func add(
            _ mesh: MeshResource, _ colour: OfficeColour, at position: SIMD3<Float>,
            turn: simd_quatf = simd_quatf(angle: 0, axis: [0, 1, 0]), scale: SIMD3<Float> = .one
        ) {
            let entity = ModelEntity(mesh: mesh, materials: [material(nsColour(colour))])
            entity.position = position
            entity.orientation = turn
            entity.scale = scale
            figure.addChild(entity)
            parts.append(FigurePart(entity: entity, colour: colour))
        }
        let alongZ = simd_quatf(angle: .pi / 2, axis: [1, 0, 0])
        let alongX = simd_quatf(angle: .pi / 2, axis: [0, 0, 1])
        let dark = OfficeColour(red: 0.12, green: 0.12, blue: 0.14)
        let head = SIMD3<Float>(0, 0.97, 0.55)

        // Seated legs: thighs on the chair, shins down under the desk.
        for x: Float in [-0.08, 0.08] {
            add(.generateBox(size: [0.12, 0.11, 0.38]), look.trousers, at: [x, 0.39, 0.36])
            add(.generateBox(size: [0.11, 0.36, 0.11]), look.trousers, at: [x, 0.18, 0.2])
        }
        add(.generateCylinder(height: 0.46, radius: 0.17), look.shirtColour, at: [0, 0.58, 0.55])
        switch look.shirt {
        case .tee: break
        case .stripe:
            add(
                .generateCylinder(height: 0.07, radius: 0.176), look.shirtColour.mixed(with: dark, 0.5),
                at: [0, 0.62, 0.55])
        case .hoodie:
            add(.generateSphere(radius: 0.12), look.shirtColour.mixed(with: dark, 0.2), at: [0, 0.8, 0.67])
        case .collar:
            add(
                .generateCylinder(height: 0.04, radius: 0.1), OfficeColour(red: 0.95, green: 0.95, blue: 0.95),
                at: [0, 0.82, 0.55])
        }
        // Arms reaching to the keyboard.
        for x: Float in [-0.19, 0.19] {
            add(.generateCylinder(height: 0.4, radius: 0.045), look.shirtColour, at: [x, 0.75, 0.36], turn: alongZ)
            add(.generateSphere(radius: 0.05), look.skin, at: [x * 0.9, 0.77, 0.14])
        }
        add(.generateSphere(radius: 0.14), look.skin, at: head)
        for x: Float in [-0.05, 0.05] { add(.generateSphere(radius: 0.018), dark, at: head + [x, 0.01, -0.13]) }

        // Hair sits up and back, leaving the face.
        let cap = head + [0, 0.035, 0.03]
        switch look.hair {
        case .bald: break
        case .short: add(.generateSphere(radius: 0.142), look.hairColour, at: cap)
        case .long:
            add(.generateSphere(radius: 0.142), look.hairColour, at: cap)
            add(.generateBox(size: [0.26, 0.3, 0.09]), look.hairColour, at: head + [0, -0.09, 0.09])
        case .bun:
            add(.generateSphere(radius: 0.142), look.hairColour, at: cap)
            add(.generateSphere(radius: 0.07), look.hairColour, at: head + [0, 0.12, 0.1])
        case .ponytail:
            add(.generateSphere(radius: 0.142), look.hairColour, at: cap)
            add(.generateCylinder(height: 0.22, radius: 0.04), look.hairColour, at: head + [0, -0.06, 0.17])
        case .spiky:
            add(.generateSphere(radius: 0.14), look.hairColour, at: cap)
            for (x, z): (Float, Float) in [(0, 0), (-0.07, 0.04), (0.07, 0.04), (-0.04, -0.06), (0.04, -0.06), (0, 0.09)] {
                add(
                    .generateBox(size: [0.05, 0.1, 0.05]), look.hairColour, at: head + [x, 0.15, z + 0.02],
                    turn: simd_quatf(angle: x * 4 - z * 3, axis: [0, 0, 1]) * simd_quatf(angle: z * 4, axis: [1, 0, 0]))
            }
        case .cap:
            // Worn backwards, so the brim shows from behind.
            add(.generateSphere(radius: 0.148), look.trousers, at: head + [0, 0.03, 0], scale: [1, 0.85, 1])
            add(.generateBox(size: [0.2, 0.02, 0.14]), look.trousers, at: head + [0, 0.06, 0.18])
        }
        switch look.extra {
        case .none: break
        case .glasses:
            for x: Float in [-0.055, 0.055] {
                add(.generateBox(size: [0.075, 0.05, 0.015]), dark, at: head + [x, 0.01, -0.135])
                add(.generateBox(size: [0.01, 0.015, 0.15]), dark, at: head + [x * 2.5, 0.01, -0.06])
            }
        case .headphones:
            add(.generateBox(size: [0.3, 0.025, 0.045]), dark, at: head + [0, 0.16, 0])
            for x: Float in [-0.145, 0.145] {
                add(.generateBox(size: [0.025, 0.12, 0.045]), dark, at: head + [x, 0.08, 0])
                add(.generateCylinder(height: 0.05, radius: 0.055), dark, at: head + [x, 0, 0], turn: alongX)
            }
        }
        return parts
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

    /// The ground around the building, the street in front of it, the sun (or the moon) behind it,
    /// and the people, bicycles and cars passing by.
    private func makeStreet(_ street: OfficeStreet, layout: OfficeLayout, _ palette: Palette) -> Entity {
        let entity = Entity()
        let length = Float(street.length)
        let width = Float(layout.width)
        let back = -Float(layout.depth) / 2
        let front = Float(street.pavements[1]) + Float(OfficeStreet.pavementWidth) / 2
        let grassEnd = front + 3
        let grassStart = back - 3.5
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
        entity.addChild(box([length + 6, 0.04, roadWidth], palette.road, at: [0, -0.05, road]))
        // A dashed centre line, and a solid line marking off each bike lane.
        let marking = NSColor(white: 0.95, alpha: 1)
        var x = -length / 2 - 3
        while x < length / 2 + 3 {
            entity.addChild(box([1, 0.005, 0.1], marking, at: [x + 0.5, -0.028, road]))
            x += 2.5
        }
        for side: Float in [-1, 1] {
            let z = road + side * (roadWidth / 2 - Float(OfficeStreet.bikeLaneWidth))
            entity.addChild(box([length + 6, 0.005, 0.05], marking, at: [0, -0.028, z]))
        }
        // A path from the door to the pavement.
        entity.addChild(box([1.4, 0.06, 0.42], palette.pavement, at: [0, -0.05, Float(layout.depth) / 2 + 0.21]))

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
            }
            entity.addChild(tree)
        }
        var step: Float = 0
        x = -width / 2 - 1
        while x <= width / 2 + 1 {
            tree(at: [x, -0.06, back - 1.6 - (step.truncatingRemainder(dividingBy: 2)) * 0.8], size: 1.1)
            x += 2.6
            step += 1
        }
        let edge = Float(street.pavements[1]) + Float(OfficeStreet.pavementWidth) / 2 - 0.3
        x = -length / 2 + 2
        step = 0
        let metal = NSColor(white: 0.3, alpha: 1)
        while x < length / 2 - 1 {
            if step.truncatingRemainder(dividingBy: 2) == 0 {
                tree(at: [x, 0, edge], size: 1)
            } else {
                entity.addChild(box([0.08, 2.6, 0.08], metal, at: [x, 1.3, edge]))
                entity.addChild(box([0.08, 0.06, 0.6], metal, at: [x, 2.6, edge - 0.27]))
                let lamp = ModelEntity(
                    mesh: .generateBox(size: [0.24, 0.1, 0.3]), materials: [UnlitMaterial(color: palette.lampGlow)])
                lamp.position = [x, 2.55, edge - 0.55]
                entity.addChild(lamp)
            }
            x += 4
            step += 1
        }

        sun.model?.materials = [UnlitMaterial(color: palette.sun)]
        var halo = UnlitMaterial(color: palette.sun)
        halo.blending = .transparent(opacity: 0.3)
        sun.children.first?.components[ModelComponent.self]?.materials = [halo]

        travellers = street.travellers.map { traveller in
            let node = makeTraveller(traveller)
            entity.addChild(node.entity)
            return node
        }
        return entity
    }

    /// A walker, a cyclist or a car, built facing east and turned round when it heads west.
    private func makeTraveller(_ traveller: OfficeTraveller) -> TravellerNode {
        let entity = Entity()
        entity.position = [0, 0, Float(traveller.z)]
        if traveller.speed < 0 { entity.orientation = simd_quatf(angle: .pi, axis: [0, 1, 0]) }
        let body = nsColour(traveller.body)
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
            add(.generateBox(size: [0.94, 0.06, 0.8]), body, at: [-0.12, 0.96, 0])
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

    var backgroundColour: NSColor { (dark ? Palette.dark : Palette.light).background }
}
