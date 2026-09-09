//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import Testing

@testable import NectoModel

@Test func acceptsValueMatchingSchema() {
    let schema: NectoJSONValue = [
        "type": "object",
        "required": ["limit"],
        "additionalProperties": false,
        "properties": [
            "limit": ["type": "integer", "minimum": 1, "maximum": 500],
            "method": ["type": "string", "enum": ["GET", "POST"]],
        ],
    ]

    #expect(NectoJSONSchema.validate(["limit": 50, "method": "GET"], against: schema) == nil)
}

@Test func reportsMissingRequiredProperty() {
    let schema: NectoJSONValue = ["type": "object", "required": ["limit"]]
    let failure = NectoJSONSchema.validate(["method": "GET"], against: schema)

    #expect(failure?.path == "limit")
}

@Test func rejectsUndeclaredPropertyWhenAdditionalDisallowed() {
    let schema: NectoJSONValue = [
        "type": "object",
        "additionalProperties": false,
        "properties": ["limit": ["type": "integer"]],
    ]
    let failure = NectoJSONSchema.validate(["limit": 1, "unexpected": true], against: schema)

    #expect(failure?.path == "unexpected")
}

@Test func distinguishesIntegerFromNumber() {
    let schema: NectoJSONValue = ["type": "integer"]

    #expect(NectoJSONSchema.validate(3, against: schema) == nil)
    #expect(NectoJSONSchema.validate(3.5, against: schema) != nil)
}

@Test func validatesArrayItemsAndBounds() {
    let schema: NectoJSONValue = [
        "type": "array",
        "minItems": 1,
        "items": ["type": "string"],
    ]

    #expect(NectoJSONSchema.validate(["a", "b"], against: schema) == nil)
    #expect(NectoJSONSchema.validate([], against: schema) != nil)
    #expect(NectoJSONSchema.validate(["a", 1], against: schema)?.path == "[1]")
}

@Test func reportsNestedPath() {
    let schema: NectoJSONValue = [
        "type": "object",
        "properties": [
            "filter": [
                "type": "object",
                "properties": ["status": ["type": "integer"]],
            ],
        ],
    ]
    let failure = NectoJSONSchema.validate(["filter": ["status": "200"]], against: schema)

    #expect(failure?.path == "filter.status")
}

@Test func parsesAndComparesSemanticVersions() {
    #expect(NectoSemanticVersion("1.2.3") == NectoSemanticVersion(major: 1, minor: 2, patch: 3))
    #expect(NectoSemanticVersion("1.0.0-beta.1")?.prerelease == "beta.1")
    #expect(NectoSemanticVersion("1.2") == nil)
    #expect(NectoSemanticVersion("1.2.x") == nil)
    #expect(NectoSemanticVersion("01.2.3") == nil)
    #expect(NectoSemanticVersion("1.2.3")! < NectoSemanticVersion("1.10.0")!)
}
