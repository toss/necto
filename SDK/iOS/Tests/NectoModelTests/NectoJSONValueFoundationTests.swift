//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import Foundation
import Testing

@testable import NectoModel

@Test func bridgesFoundationJSONValues() throws {
    let value = NectoJSONValue(foundationValue: [
        "null": NSNull(),
        "bool": true,
        "number": NSNumber(value: 42.5),
        "string": "necto",
        "array": [1, "two", false],
    ])

    #expect(value == [
        "null": nil,
        "bool": true,
        "number": 42.5,
        "string": "necto",
        "array": [1, "two", false],
    ])

    let foundation = try #require(value?.foundationValue as? [String: Any])
    #expect(foundation["null"] is NSNull)
    #expect(foundation["bool"] as? Bool == true)
    #expect(foundation["number"] as? Double == 42.5)
    #expect(foundation["string"] as? String == "necto")
    #expect((foundation["array"] as? [Any])?.count == 3)
}

/// `NSNumber` casts to `Bool` whenever it holds 0 or 1, so a property-list integer
/// must be told from a real Boolean by its type rather than by the cast.
@Test func keepsFoundationNumbersThatLookLikeBooleans() {
    #expect(NectoJSONValue(foundationValue: NSNumber(value: 1)) == .number(1))
    #expect(NectoJSONValue(foundationValue: NSNumber(value: 0)) == .number(0))
    #expect(NectoJSONValue(foundationValue: NSNumber(value: 1.0)) == .number(1))
    #expect(NectoJSONValue(foundationValue: NSNumber(value: true)) == .bool(true))
    #expect(NectoJSONValue(foundationValue: NSNumber(value: false)) == .bool(false))
    #expect(NectoJSONValue(foundationValue: ["count": NSNumber(value: 1), "flags": [NSNumber(value: 0)]])
        == ["count": 1, "flags": [0]])
}

/// A `Double` holds every integer only below 2^53. Rounding a larger one would hand
/// back a different number as if it were the one that was stored.
@Test func refusesFoundationIntegersADoubleCannotHold() {
    #expect(NectoJSONValue(foundationValue: NSNumber(value: 9_007_199_254_740_991)) == .number(9_007_199_254_740_991))
    #expect(NectoJSONValue(foundationValue: NSNumber(value: -9_007_199_254_740_991)) == .number(-9_007_199_254_740_991))
    #expect(NectoJSONValue(foundationValue: NSNumber(value: 9_007_199_254_740_993)) == nil)
    #expect(NectoJSONValue(foundationValue: NSNumber(value: Int64.min)) == nil)
    #expect(NectoJSONValue(foundationValue: NSNumber(value: UInt64.max)) == nil)
    #expect(NectoJSONValue(foundationValue: ["id": NSNumber(value: 9_007_199_254_740_993)]) == nil)
    #expect(NectoJSONValue(foundationValue: NSNumber(value: 1e300)) == .number(1e300))
}

@Test func refusesValuesOutsideFoundationJSON() {
    #expect(NectoJSONValue(foundationValue: Date()) == nil)
    #expect(NectoJSONValue(foundationValue: [Date()]) == nil)
    #expect(NectoJSONValue(foundationValue: ["date": Date()]) == nil)
}

@Test func serializesJSONWithoutEachCallerBuildingAnEncoder() throws {
    let value: NectoJSONValue = ["name": "Necto", "enabled": true]

    #expect(try value.jsonString(options: [.sortedKeys]) == #"{"enabled":true,"name":"Necto"}"#)
    #expect(try NectoJSONValue.string("Necto").jsonString() == #""Necto""#)
}

@Test func refusesNonFiniteJSONNumbersBeforeFoundationSerialization() {
    let value = NectoJSONValue.number(.nan)

    #expect(throws: EncodingError.self) {
        try value.jsonData()
    }
}
