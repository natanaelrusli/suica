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
    let wall: NSColor
    let desk: NSColor
    let label: NSColor
    let bubble: NSColor
    let bubbleText: NSColor
    let figureIdle: NSColor
    let background: NSColor

    static let light = Palette(
        floor: NSColor(white: 0.88, alpha: 1), wall: NSColor(white: 0.78, alpha: 1),
        desk: NSColor(red: 0.78, green: 0.66, blue: 0.5, alpha: 1), label: NSColor(white: 0.25, alpha: 1),
        bubble: .white, bubbleText: NSColor(white: 0.12, alpha: 1), figureIdle: NSColor(white: 0.66, alpha: 1),
        background: NSColor(white: 0.96, alpha: 1))
    static let dark = Palette(
        floor: NSColor(white: 0.2, alpha: 1), wall: NSColor(white: 0.3, alpha: 1),
        desk: NSColor(red: 0.45, green: 0.37, blue: 0.28, alpha: 1), label: NSColor(white: 0.85, alpha: 1),
        bubble: NSColor(white: 0.32, alpha: 1), bubbleText: .white, figureIdle: NSColor(white: 0.45, alpha: 1),
        background: NSColor(white: 0.11, alpha: 1))
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

/// One Desk: its furniture, its figure and its bubble.
private struct DeskNode {
    let entity: Entity
    let figure: Entity
    let body: ModelEntity
    let head: ModelEntity
    let screen: ModelEntity
    let bubble: Entity
    let rug: ModelEntity
    var bubbleText: String
    var status: OfficeStatus
    var agent: String
    var dark: Bool
    var target: SIMD3<Float>
}

/// Builds and updates the RealityKit scene from the model: a Room per project, a Desk per
/// Session. It owns the camera, so the page can orbit, zoom and reset it.
@MainActor
final class OfficeSceneController {
    let root = Entity()
    let camera = PerspectiveCamera()
    private var rooms: [String: RoomNode] = [:]
    private var desks: [String: DeskNode] = [:]
    private var clock: Float = 0
    private var updates: EventSubscription?
    private var animate = true
    private var dark = false
    private var layoutExtent = SIMD2<Float>(8, 6)

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
        focus.z = min(layoutExtent.y / 2 + 2, max(-layoutExtent.y / 2 - 2, focus.z))
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

        // Rooms
        var liveRooms = Set<String>()
        // An office with nobody in it is one bare room.
        let floors =
            layout.rooms.isEmpty
            ? [PlacedRoom.bare(width: layout.width, depth: layout.depth)]
            : layout.rooms
        for room in floors {
            liveRooms.insert(room.path)
            let signature = "\(room.name)|\(room.width)|\(room.depth)|\(dark)"
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

    private func makeRoom(_ room: PlacedRoom, _ palette: Palette) -> Entity {
        let entity = Entity()
        let width = Float(room.width)
        let depth = Float(room.depth)
        entity.addChild(box([width, 0.06, depth], palette.floor, at: [0, -0.03, 0]))
        entity.addChild(box([width, 0.5, 0.06], palette.wall, at: [0, 0.25, -depth / 2 + 0.03]))
        entity.addChild(box([0.06, 0.5, depth - 0.06], palette.wall, at: [-width / 2 + 0.03, 0.25, 0.03]))
        guard !room.name.isEmpty else { return entity }
        let mesh = textMesh(room.name, size: 0.3)
        let label = ModelEntity(mesh: mesh, materials: [UnlitMaterial(color: palette.label)])
        let bounds = mesh.bounds
        // Flat on the floor at the front, where no bubble covers it.
        label.orientation = simd_quatf(angle: -.pi / 2, axis: [1, 0, 0])
        label.position = [-width / 2 + 0.35 - bounds.min.x, 0.012, depth / 2 - 0.25]
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

        // The figure: a body and a head, bobbing as one.
        let figure = Entity()
        let body = ModelEntity(mesh: .generateCylinder(height: 0.46, radius: 0.17), materials: [material(.gray)])
        body.position = [0, 0.58, 0.55]
        let head = ModelEntity(mesh: .generateSphere(radius: 0.14), materials: [material(.gray)])
        head.position = [0, 0.97, 0.55]
        figure.addChild(body)
        figure.addChild(head)
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
            entity: entity, figure: figure, body: body, head: head, screen: screen, bubble: bubble, rug: rug,
            bubbleText: "", status: .idle, agent: "", dark: dark, target: entity.position)
        update(&node, with: session, palette: palette, force: true)
        return node
    }

    private func update(_ node: inout DeskNode, with session: OfficeSession, palette: Palette, force: Bool) {
        let live = session.status == .working || session.status == .waiting
        let text = session.bubble
        if force || node.status != session.status || node.agent != session.agent {
            let colour = live ? nsColour(OfficeAgent(kind: session.agent).colour) : palette.figureIdle
            node.body.model?.materials = [material(colour)]
            node.head.model?.materials = [material(colour)]
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
