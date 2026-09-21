//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import CoreGraphics
import Foundation
import NectoModel
import NectoSDK
import Testing
@testable import NectoDefaultPlugins

@Suite("Control positions")
struct NectoControlGeometryTests {
    let frame = CGRect(x: 10, y: 20, width: 200, height: 400)

    @Test func relativePosition() throws {
        #expect(try NectoControlGeometry.position(nil, in: frame) == nil)
        #expect(try NectoControlGeometry.position(["x": 0.25, "y": 0.75], in: frame) == CGPoint(x: 60, y: 320))
        for point: NectoJSONValue in [["x": 0, "y": 0], ["x": 1, "y": 1]] {
            let result = try #require(try NectoControlGeometry.position(point, in: frame))
            #expect(frame.contains(result))
        }
        for input: NectoJSONValue in [.null, ["x": 0.5], ["x": -0.1, "y": 0], ["x": 0, "y": 1.1]] {
            #expect(throws: NectoBridgeError.self) { try NectoControlGeometry.position(input, in: frame) }
        }
    }

    @Test func swipeStartsAtPositionAndClipsEnd() throws {
        let start = CGPoint(x: 60, y: 320)
        #expect(try NectoControlGeometry.swipe(from: start, direction: "up", ratio: 0.5, in: frame) == CGPoint(x: 60, y: 120))
        #expect(try NectoControlGeometry.swipe(from: start, direction: "right", ratio: 0.9, in: frame) == CGPoint(x: 209.5, y: 320))
        #expect(throws: NectoBridgeError.self) {
            try NectoControlGeometry.swipe(from: CGPoint(x: 10.5, y: 20.5), direction: "up", ratio: 0.5, in: frame)
        }
    }

    @Test func multipleContactsStayCenteredAndInside() throws {
        let point = CGPoint(x: 20, y: 100)
        let contacts = try NectoControlGeometry.tapPoints(at: point, count: 5, in: frame)
        #expect(contacts.allSatisfy(frame.contains))
        #expect(contacts[2] == point)
        #expect(Set(contacts.map(\.x)).count == 5)
        #expect(throws: NectoBridgeError.self) {
            try NectoControlGeometry.tapPoints(at: CGPoint(x: 10.5, y: 100), count: 2, in: frame)
        }
    }
}
