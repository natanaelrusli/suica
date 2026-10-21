import Foundation

// MARK: - The street outside

public enum OfficeTravellerKind: Sendable {
    case walker, bicycle, car
}

/// Someone or something passing the building: where it travels and how it looks. A car uses only
/// `body`; a walker or a cyclist wears all four colours.
public struct OfficeTraveller: Equatable, Sendable {
    public let kind: OfficeTravellerKind
    /// The line it travels along, across the street.
    public let z: Double
    /// Metres per second along x; negative travels west.
    public let speed: Double
    /// Where it is at time zero.
    public let start: Double
    public let body: OfficeColour
    public let skin: OfficeColour
    public let hair: OfficeColour
    public let legs: OfficeColour
}

/// The street along the building's front (south, toward the viewer): a pavement, a road with a
/// bike lane each side, a far pavement, and the people, bicycles and cars passing on them. Laid
/// out from the building's size; the travellers are seeded, so the street looks the same each launch.
public struct OfficeStreet: Equatable, Sendable {
    public static let pavementWidth = 1.4
    public static let roadWidth = 4.0
    public static let bikeLaneWidth = 0.6
    /// How far the street runs past each side of the building.
    static let overhang = 12.0

    public let length: Double
    /// The centre lines of the near and far pavements.
    public let pavements: [Double]
    public let road: Double
    public let travellers: [OfficeTraveller]

    public init(layout: OfficeLayout) {
        length = layout.width + 2 * Self.overhang
        let near = layout.depth / 2 + 0.4 + Self.pavementWidth / 2
        road = near + Self.pavementWidth / 2 + Self.roadWidth / 2
        let far = road + Self.roadWidth / 2 + Self.pavementWidth / 2
        pavements = [near, far]

        var seed = OfficeSeed("street")
        let shirts = [
            OfficeColour(0.85, 0.3, 0.28), OfficeColour(0.25, 0.5, 0.82), OfficeColour(0.95, 0.78, 0.3),
            OfficeColour(0.3, 0.62, 0.42), OfficeColour(0.92, 0.92, 0.9), OfficeColour(0.55, 0.38, 0.7),
        ]
        let paints = [
            OfficeColour(0.82, 0.2, 0.2), OfficeColour(0.2, 0.42, 0.78), OfficeColour(0.95, 0.95, 0.95),
            OfficeColour(0.18, 0.18, 0.2), OfficeColour(0.95, 0.75, 0.2), OfficeColour(0.4, 0.65, 0.6),
        ]
        let length = length
        func traveller(_ kind: OfficeTravellerKind, z: Double, speed: Double, start: Double) -> OfficeTraveller {
            OfficeTraveller(
                kind: kind, z: z, speed: speed, start: start,
                body: (kind == .car ? paints : shirts).randomElement(using: &seed)!,
                skin: OfficeLook.skins.randomElement(using: &seed)!,
                hair: OfficeLook.hairColours.randomElement(using: &seed)!,
                legs: OfficeLook.trouserColours.randomElement(using: &seed)!)
        }
        func spread(_ count: Int) -> [Double] {
            // Evenly spaced and shifted as one, so travellers on one line at one speed never meet.
            let shift = Double.random(in: 0..<1, using: &seed)
            return (0..<count).map { (Double($0) + shift) / Double(count) * length - length / 2 }
        }
        var travellers: [OfficeTraveller] = []
        // Cars: the lane nearer the building heads west, the far one east.
        let carLane = Self.bikeLaneWidth / 2 + (Self.roadWidth / 2 - Self.bikeLaneWidth) / 2
        for x in spread(2) { travellers.append(traveller(.car, z: road - carLane, speed: -4.5, start: x)) }
        for x in spread(2) { travellers.append(traveller(.car, z: road + carLane, speed: 5, start: x)) }
        let bikeLane = Self.roadWidth / 2 - Self.bikeLaneWidth / 2
        for x in spread(1) { travellers.append(traveller(.bicycle, z: road - bikeLane, speed: -2.2, start: x)) }
        for x in spread(1) { travellers.append(traveller(.bicycle, z: road + bikeLane, speed: 2.4, start: x)) }
        // Walkers keep to the right half of a pavement for their direction.
        let side = Self.pavementWidth / 4
        for (z, speed, count) in [
            (near - side, -0.8, 3), (near + side, 0.7, 2), (far - side, -0.75, 2), (far + side, 0.85, 2),
        ] {
            for x in spread(count) { travellers.append(traveller(.walker, z: z, speed: speed, start: x)) }
        }
        self.travellers = travellers
    }

    /// Where `traveller` is along the street at `time`: it leaves one end and comes back at the other.
    public func x(of traveller: OfficeTraveller, at time: Double) -> Double {
        var x = (traveller.start + traveller.speed * time + length / 2).truncatingRemainder(dividingBy: length)
        if x < 0 { x += length }
        return x - length / 2
    }
}
