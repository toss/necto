//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import Testing

@testable import NectoModel

@Test func readsDirectlyDeclaredStringEnumInOrder() {
    let schema: NectoJSONValue = [
        "properties": [
            "method": ["enum": ["POST", " GET ", "", "\t", "\0"]],
            "empty": ["enum": []],
        ],
    ]

    #expect(NectoJSONSchema.declaredStringValues(for: "method", in: schema) == .values(["POST", " GET ", "", "\t", "\0"]))
    #expect(NectoJSONSchema.declaredStringValues(for: "empty", in: schema) == .values([]))
}

@Test func distinguishesMissingDirectPropertyAndEnum() {
    let schema: NectoJSONValue = [
        "properties": ["method": ["type": "string"]],
        "allOf": [["properties": ["fallback": ["enum": ["GET"]]]]],
    ]

    #expect(NectoJSONSchema.declaredStringValues(for: "method", in: [:]) == .unavailable(.propertyNotDeclared))
    #expect(NectoJSONSchema.declaredStringValues(for: "fallback", in: schema) == .unavailable(.propertyNotDeclared))
    #expect(NectoJSONSchema.declaredStringValues(for: "method", in: schema) == .unavailable(.enumNotDeclared))
}

@Test func reportsUnsupportedSchemaShapesForStringEnumLookup() {
    #expect(NectoJSONSchema.declaredStringValues(for: "method", in: true) == .unavailable(.unsupportedSchema))
    #expect(NectoJSONSchema.declaredStringValues(for: "method", in: ["properties": []]) == .unavailable(.unsupportedSchema))
    #expect(NectoJSONSchema.declaredStringValues(for: "method", in: ["properties": ["method": true]]) == .unavailable(.unsupportedSchema))
}

@Test func stringEnumLookupLeavesMixedEnumValidationAvailable() {
    let schema: NectoJSONValue = [
        "properties": [
            "method": ["enum": ["GET", 1]],
            "mode": ["enum": "read"],
        ],
    ]

    #expect(NectoJSONSchema.declaredStringValues(for: "method", in: schema) == .unavailable(.notStringEnum))
    #expect(NectoJSONSchema.declaredStringValues(for: "mode", in: schema) == .unavailable(.notStringEnum))
    #expect(NectoJSONSchema.validate(["method": 1], against: schema) == nil)
    #expect(NectoJSONSchema.validate(["method": "POST"], against: schema)?.path == "method")
}

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
