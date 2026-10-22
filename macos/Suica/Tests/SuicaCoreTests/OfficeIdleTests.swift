import Foundation
import Testing

@testable import SuicaCore

private func layout(_ counts: [Int]) -> OfficeLayout {
    let rooms = counts.enumerated().map { index, count in
        let path = "/work/project-\(index)"
        return OfficeRoom(
            path: path, name: "project-\(index)",
            sessions: (0..<count).map { desk in
                OfficeSession(
                    agent: "claude", sessionId: "\(index)-\(desk)", title: nil, cwd: path, status: .idle,
                    activity: "", recentActions: [], startedAt: nil, updatedAt: 0, pid: nil, room: path,
                    roomName: "project-\(index)", hostApp: nil)
            })
    }
    return OfficeLayout.make(rooms)
}

private let ids = (0..<12).map { "claude/idle-\($0)" }

@Test func theIdlePlanIsTheSameEachTimeAndChangesWithTheTurn() {
    let hall = layout([3, 4, 2, 3]).center
    let plan = OfficeIdle.plan(idle: ids, hall: hall, turn: 7)
    #expect(plan == OfficeIdle.plan(idle: ids.reversed(), hall: hall, turn: 7))
    #expect(Set(plan.keys) == Set(ids))
    let turns = (0..<20).map { OfficeIdle.plan(idle: ids, hall: hall, turn: $0) }
    #expect(Set(turns.map { $0.description }).count > 1)
}

@Test func overManyTurnsIdleFiguresDoEveryKindOfThing() {
    let hall = layout([3, 4, 2, 3]).center
    var kinds = Set<String>()
    for turn in 0..<60 {
        for activity in OfficeIdle.plan(idle: ids, hall: hall, turn: turn).values {
            kinds.insert(String(describing: activity).prefix { $0 != "(" }.description)
        }
    }
    #expect(kinds == ["doze", "phone", "game", "stretch", "stroll", "chat"])
}

@Test func chatsComeInPairsFacingEachOtherAndNoTwoFiguresShareASpot() {
    let hall = layout([3, 4, 2, 3]).center
    for turn in 0..<60 {
        let plan = OfficeIdle.plan(idle: ids, hall: hall, turn: turn)
        var taken: [OfficePoint] = []
        for (id, activity) in plan {
            if case .chat(let partner, let spot, let facing) = activity {
                guard case .chat(let back, let theirs, let theirFacing) = plan[partner] else {
                    Issue.record("\(partner) is not chatting back")
                    continue
                }
                #expect(back == id && theirs == facing && theirFacing == spot)
                #expect(abs(abs(spot.x - facing.x) - 2 * OfficeIdle.chatHalfGap) < 1e-9 && spot.z == facing.z)
            }
            if let spot = activity.spot { taken.append(spot) }
        }
        for (index, spot) in taken.enumerated() {
            for other in taken[(index + 1)...] {
                #expect(abs(spot.x - other.x) >= 0.89 || spot.z != other.z, "\(taken) in turn \(turn): \(plan)")
            }
        }
    }
}

@Test func meetingSpotsStayInTheMiddleOfTheCenterRoomClearOfItsFurniture() {
    for counts in [[], [1], [3, 4], [2, 5, 1, 3]] {
        let hall = layout(counts).center
        let spots = OfficeIdle.spots(in: hall)
        #expect(!spots.isEmpty)
        for spot in spots {
            #expect(spot.z == hall.center.z)
            let edge = hall.width / 2 - OfficeLayout.furnitureSize - 0.2
            #expect(abs(spot.x - hall.center.x) + OfficeIdle.chatHalfGap <= edge + 1e-9)
        }
    }
}

@Test func withNoRoomToMeetEveryoneStaysAtTheirDesk() {
    let narrow = PlacedRoom(
        path: "", name: "Hall", center: OfficePoint(x: 0, z: 0), width: 1.5, depth: 2.6, desks: [],
        walls: [.west, .east], door: nil, isCenter: true)
    for turn in 0..<20 {
        #expect(OfficeIdle.plan(idle: ids, hall: narrow, turn: turn).values.allSatisfy { $0.spot == nil })
    }
}

@Test func theWayToTheHallLeavesByTheDoorAndCrossesOnlyTheCenterRoom() {
    let office = layout([3, 4])
    let hall = office.center
    for room in office.rooms {
        for desk in room.desks {
            let way = OfficeLayout.walk(in: room, to: desk)
            let spot = OfficeIdle.spots(in: hall)[0]
            let points = OfficeIdle.hallWay(from: way, to: spot)
            #expect(points.first == way.start && points.last == spot)
            // Past the doorway every point is inside the Center Room.
            for point in points.dropFirst() {
                #expect(abs(point.z - hall.center.z) <= hall.depth / 2)
                #expect(abs(point.x - hall.center.x) <= hall.width / 2)
            }
        }
    }
}
