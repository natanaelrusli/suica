import CoreGraphics
import Foundation

/// The Lessons of the page as a graph. Each Lesson is a node and sits in the cluster of its
/// main Topic (the one most Lessons share, so clusters stay few and big); a cluster has its
/// heaviest Lesson in the middle and the rest on rings around it by weight. Two Lessons that
/// share a Topic are joined by an edge, heavier the more Topics they share. Positions are in
/// world points, the same for the same Lessons, so the graph does not reshuffle on refresh.
public struct LessonGraph: Equatable, Sendable {
    public struct Node: Equatable, Identifiable, Sendable {
        public let id: Int
        public let title: String
        public let weight: Double
        public let count: Int
        /// 0...1 within this graph's weights, for sizing.
        public let relativeWeight: Double
        /// Index into `clusters`.
        public let cluster: Int
        /// 0 for the heaviest Lesson of its cluster.
        public let rank: Int
        public var x: Double
        public var y: Double
    }

    public struct Edge: Equatable, Sendable {
        public let a: Int
        public let b: Int
        /// Topics the two Lessons share.
        public let shared: Int
    }

    public struct Cluster: Equatable, Sendable {
        /// Nil for the Lessons that have no Topic.
        public let topic: String?
        public let count: Int
        public let x: Double
        public let y: Double
        public let radius: Double
    }

    /// Distance between neighbouring nodes on a ring.
    public static let spacing = 44.0

    public let nodes: [Node]
    public let edges: [Edge]
    public let clusters: [Cluster]
    /// Everything the graph covers, cluster titles included, in world points.
    public let bounds: CGRect

    public init(lessons: [LessonSummary]) {
        let sorted = lessons.sorted { $0.id < $1.id }
        let weights = sorted.map(\.weight)
        let low = weights.min() ?? 0
        let span = (weights.max() ?? 0) - low

        var topicCounts: [String: Int] = [:]
        for lesson in sorted { for topic in Set(lesson.topics) { topicCounts[topic, default: 0] += 1 } }
        func mainTopic(_ lesson: LessonSummary) -> String? {
            lesson.topics.min { (topicCounts[$0] ?? 0, $1) > (topicCounts[$1] ?? 0, $0) }
        }

        var groups: [String?: [LessonSummary]] = [:]
        for lesson in sorted { groups[mainTopic(lesson), default: []].append(lesson) }
        // Big clusters first; the topicless one last whatever its size.
        let order = groups.keys.sorted { a, b in
            if (a == nil) != (b == nil) { return b == nil }
            let (ca, cb) = (groups[a]!.count, groups[b]!.count)
            return ca != cb ? ca > cb : (a ?? "") < (b ?? "")
        }

        // Rings: the heaviest in the middle, then 6, 12, 18… Lessons per ring.
        struct Pending { let topic: String?; let lessons: [LessonSummary]; let rings: Int }
        let pending = order.map { topic -> Pending in
            let lessons = groups[topic]!.sorted { ($0.weight, $1.id) > ($1.weight, $0.id) }
            var rings = 0, capacity = 1
            while capacity < lessons.count { rings += 1; capacity += 6 * rings }
            return Pending(topic: topic, lessons: lessons, rings: rings)
        }
        let gap = Self.spacing * 1.8
        let radii = pending.map { Double($0.rings) * Self.spacing + Self.spacing * 0.7 }

        // Shelf packing, widest target row about square.
        let area = radii.reduce(0) { $0 + pow(2 * $1 + gap, 2) }
        let target = max(area.squareRoot() * 1.25, 2 * (radii.max() ?? 0) + gap)
        var centers: [CGPoint] = []
        var cursorX = 0.0, rowY = 0.0, rowHeight = 0.0
        for radius in radii {
            let cell = 2 * radius + gap
            if cursorX > 0 && cursorX + cell > target { cursorX = 0; rowY += rowHeight; rowHeight = 0 }
            centers.append(CGPoint(x: cursorX + cell / 2, y: rowY + cell / 2))
            cursorX += cell
            rowHeight = max(rowHeight, cell)
        }

        var nodes: [Node] = []
        var clusters: [Cluster] = []
        for (index, group) in pending.enumerated() {
            let center = centers[index]
            clusters.append(
                Cluster(topic: group.topic, count: group.lessons.count, x: center.x, y: center.y, radius: radii[index]))
            var next = 0
            for ring in 0...group.rings {
                let size = ring == 0 ? 1 : 6 * ring
                let members = group.lessons[next..<min(next + size, group.lessons.count)]
                for (slot, lesson) in members.enumerated() {
                    let angle = -Double.pi / 2 + 2 * Double.pi * (Double(slot) + (ring % 2 == 0 ? 0.5 : 0)) / Double(size)
                    let distance = Double(ring) * Self.spacing
                    nodes.append(
                        Node(
                            id: lesson.id, title: lesson.title, weight: lesson.weight, count: lesson.count,
                            relativeWeight: span > 0 ? (lesson.weight - low) / span : 0.5, cluster: index,
                            rank: next + slot, x: center.x + distance * cos(angle), y: center.y + distance * sin(angle)))
                }
                next += size
            }
        }

        var edges: [Edge] = []
        for i in sorted.indices {
            let topics = Set(sorted[i].topics)
            for j in sorted.indices where j > i {
                let shared = topics.intersection(sorted[j].topics).count
                if shared > 0 { edges.append(Edge(a: sorted[i].id, b: sorted[j].id, shared: shared)) }
            }
        }

        self.nodes = nodes
        self.edges = edges
        self.clusters = clusters
        // Room above each cluster for its title.
        var bounds = CGRect.null
        for cluster in clusters {
            let box = CGRect(
                x: cluster.x - cluster.radius, y: cluster.y - cluster.radius - 28,
                width: 2 * cluster.radius, height: 2 * cluster.radius + 28)
            bounds = bounds.union(box)
        }
        self.bounds = bounds
    }

    public func node(_ id: Int) -> Node? { nodes.first { $0.id == id } }

    /// The Lessons joined to `id` by an edge.
    public func neighbours(of id: Int) -> Set<Int> {
        Set(edges.compactMap { $0.a == id ? $0.b : $0.b == id ? $0.a : nil })
    }

    /// The node nearest `point` (world points) within `reach`.
    public func node(near point: CGPoint, reach: Double) -> Node? {
        nodes
            .map { ($0, hypot($0.x - point.x, $0.y - point.y)) }
            .filter { $0.1 <= reach }
            .min { $0.1 < $1.1 }?.0
    }
}
