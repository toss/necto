//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import CoreGraphics
import Foundation
import NectoModel
import NectoSDK

/// Geometry shared by validation and touch delivery. Coordinates refer to visible target bounds.
enum NectoControlGeometry {
    static func position(_ input: NectoJSONValue?, in frame: CGRect) throws -> CGPoint? {
        guard let input else { return nil }
        guard let x = input["x"]?.numberValue, let y = input["y"]?.numberValue,
              (0...1).contains(x), (0...1).contains(y) else {
            throw NectoBridgeError(code: .invalidInput, message: "Use position.x and position.y between 0 and 1")
        }
        let bounds = interior(frame)
        return CGPoint(x: min(bounds.maxX, max(bounds.minX, frame.minX + frame.width * x)),
                       y: min(bounds.maxY, max(bounds.minY, frame.minY + frame.height * y)))
    }

    static func swipe(from start: CGPoint, direction: String, ratio: Double, in frame: CGRect) throws -> CGPoint {
        let bounds = interior(frame)
        var end = start
        switch direction {
        case "up": end.y = max(bounds.minY, start.y - frame.height * ratio)
        case "down": end.y = min(bounds.maxY, start.y + frame.height * ratio)
        case "left": end.x = max(bounds.minX, start.x - frame.width * ratio)
        case "right": end.x = min(bounds.maxX, start.x + frame.width * ratio)
        default: throw NectoBridgeError(code: .invalidInput, message: "Choose up, down, left, or right")
        }
        guard hypot(end.x - start.x, end.y - start.y) >= 1 else {
            throw NectoBridgeError(code: .invalidInput, message: "There is no room to swipe in that direction")
        }
        return end
    }

    static func tapPoints(at point: CGPoint, count: Int, in frame: CGRect) throws -> [CGPoint] {
        guard count > 1 else { return [point] }
        let half = Double(count - 1) / 2
        let room = min(point.x - frame.minX, frame.maxX - point.x)
        let spacing = min(24, frame.width / Double(count + 1), (room - 0.5) / half)
        guard spacing >= 1 else {
            throw NectoBridgeError(code: .invalidInput, message: "There is not enough room for these fingers at this position")
        }
        return (0..<count).map { CGPoint(x: point.x + (Double($0) - half) * spacing, y: point.y) }
    }

    private static func interior(_ frame: CGRect) -> CGRect {
        frame.insetBy(dx: min(0.5, frame.width / 4), dy: min(0.5, frame.height / 4))
    }
}
