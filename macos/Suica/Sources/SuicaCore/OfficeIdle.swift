import Foundation

/// What an idle figure does for a while: at its desk, beside it, or out in the Center Room.
public enum OfficeIdleActivity: Equatable, Sendable {
    /// Seated, nodding off.
    case doze
    /// Seated, scrolling a phone.
    case phone
    /// Seated, playing a game on the monitor.
    case game
    /// Standing beside the desk, stretching.
    case stretch
    /// Out for a stroll: standing at `spot` in the Center Room, looking around.
    case stroll(spot: OfficePoint)
    /// Chatting with `partner` in the Center Room: standing at `spot`, facing the partner at `facing`.
    case chat(partner: String, spot: OfficePoint, facing: OfficePoint)

    /// Out of the Room, in the Center Room.
    public var spot: OfficePoint? {
        switch self {
        case .stroll(let spot), .chat(_, let spot, _): spot
        case .doze, .phone, .game, .stretch: nil
        }
    }
}

/// How idle figures pass the time. Every `turn` seconds each idle figure takes up something new,
/// picked from a seed of the turn so the same figures do the same thing on every redraw: some stay
/// at their desk (phone, a game, a nap), some stand up to stretch, some stroll into the Center Room
/// and some pair up there for a chat.
public enum OfficeIdle {
    /// How long an idle figure keeps at one activity, in seconds.
    public static let turn = 30.0
    /// Meeting spots along the Center Room are this far apart, so the nearest figures of two chats
    /// side by side still stand over a metre apart.
    static let spotSpacing = 2.0
    /// Two figures chatting stand this far either side of their spot.
    static let chatHalfGap = 0.45

    /// What each of `idle` (Session ids) does during `turn`. A figure only gets a spot in the
    /// Center Room while one is free; otherwise it stays at its desk.
    public static func plan(idle: [String], hall: PlacedRoom, turn: Int) -> [String: OfficeIdleActivity] {
        var seed = OfficeSeed("idle:\(turn)")
        var queue = idle.sorted().shuffled(using: &seed)
        var free = spots(in: hall).shuffled(using: &seed)
        var plan: [String: OfficeIdleActivity] = [:]
        while let id = queue.popLast() {
            let roll = Double.random(in: 0..<1, using: &seed)
            if roll < 0.35, let partner = queue.last, let spot = free.popLast() {
                queue.removeLast()
                let left = OfficePoint(x: spot.x - chatHalfGap, z: spot.z)
                let right = OfficePoint(x: spot.x + chatHalfGap, z: spot.z)
                plan[id] = .chat(partner: partner, spot: left, facing: right)
                plan[partner] = .chat(partner: id, spot: right, facing: left)
            } else if roll < 0.5, let spot = free.popLast() {
                plan[id] = .stroll(spot: spot)
            } else {
                let pick = Double.random(in: 0..<1, using: &seed)
                plan[id] = pick < 0.35 ? .phone : pick < 0.65 ? .game : pick < 0.85 ? .doze : .stretch
            }
        }
        return plan
    }

    /// Meeting spots along the middle of the Center Room, clear of the furniture at its ends and
    /// wide enough apart for a chat on each.
    public static func spots(in hall: PlacedRoom) -> [OfficePoint] {
        let reach = hall.width / 2 - OfficeLayout.furnitureSize - 0.2 - chatHalfGap
        guard reach >= 0 else { return [] }
        let count = Int(2 * reach / spotSpacing) + 1
        let first = -Double(count - 1) * spotSpacing / 2
        return (0..<count).map { OfficePoint(x: hall.center.x + first + Double($0) * spotSpacing, z: hall.center.z) }
    }

    /// From the doorway at the start of `way` out to `spot` in the Center Room: straight out to the
    /// middle of the hall, then along it.
    public static func hallWay(from way: OfficePath, to spot: OfficePoint) -> [OfficePoint] {
        guard let door = way.start else { return [spot] }
        return [door, OfficePoint(x: door.x, z: spot.z), spot]
    }
}
