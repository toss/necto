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
