import Testing

@testable import SuicaCore

private let layout = OfficeLayout.make([])

@Test func theStreetRunsAlongTheFrontOfTheBuilding() {
    let street = OfficeStreet(layout: layout)
    #expect(street.length > layout.width)
    #expect(street.pavements[0] - OfficeStreet.pavementWidth / 2 > layout.depth / 2)
    #expect(street.pavements[0] < street.road && street.road < street.pavements[1])
    let kinds = Set(street.travellers.map { "\($0.kind)" })
    #expect(kinds == ["walker", "bicycle", "car"])
    for traveller in street.travellers {
        let lane = traveller.kind == .walker
            ? street.pavements.map { abs(traveller.z - $0) }.min()! <= OfficeStreet.pavementWidth / 2
            : abs(traveller.z - street.road) <= OfficeStreet.roadWidth / 2
        #expect(lane)
    }
}

@Test func theStreetLooksTheSameEachTime() {
    #expect(OfficeStreet(layout: layout) == OfficeStreet(layout: layout))
}

@Test func travellersWrapAroundTheStreet() {
    let street = OfficeStreet(layout: layout)
    for traveller in street.travellers {
        for time in stride(from: 0.0, through: 600, by: 7.3) {
            let x = street.x(of: traveller, at: time)
            #expect(x >= -street.length / 2 && x < street.length / 2)
        }
        // One lap later it is back where it started.
        let lap = street.length / abs(traveller.speed)
        #expect(abs(street.x(of: traveller, at: lap) - street.x(of: traveller, at: 0)) < 1e-6)
    }
}

@Test func carsInOneLaneNeverMeet() {
    let street = OfficeStreet(layout: layout)
    let cars = street.travellers.filter { $0.kind == .car }
    for time in stride(from: 0.0, through: 120, by: 0.5) {
        for (a, first) in cars.enumerated() {
            for second in cars[(a + 1)...] where second.z == first.z {
                let gap = abs(street.x(of: first, at: time) - street.x(of: second, at: time))
                #expect(min(gap, street.length - gap) > 4)
            }
        }
    }
}
