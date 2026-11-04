//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import Foundation
import NectoModel

/// Usage data handed to an exporter, separate from the host's diagnostic log.
public struct NectoEvent: Sendable, Equatable {
    public enum Channel: String, Sendable {
        case ui
        case cli
    }

    /// Established by the host, never read from plugin-supplied event properties.
    public enum Source: Sendable, Equatable {
        case device(id: String, version: String)
        case desktop(id: String, version: String)
        case necto(relatedPluginID: String? = nil)

        var collectionPluginID: String? {
            switch self {
            case let .device(id, _), let .desktop(id, _): id
            case let .necto(relatedPluginID): relatedPluginID
            }
        }
    }

    /// A common envelope; individual event names do not have registered schemas.
    public struct Input: Sendable, Equatable {
        public let eventName: String
        public let params: [String: NectoJSONValue]

        public init(eventName: String, params: [String: NectoJSONValue] = [:]) throws {
            guard !eventName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw NectoBridgeError(code: .invalidInput, message: "An event name must not be empty")
            }
            do {
                _ = try NectoJSONValue.object(params).jsonData()
            } catch {
                throw NectoBridgeError(code: .invalidInput, message: "Event parameters must be valid JSON")
            }
            self.eventName = eventName
            self.params = params
        }

        public init(jsonValue: NectoJSONValue) throws {
            guard let fields = jsonValue.objectValue,
                  Set(fields.keys).isSubset(of: ["eventName", "params"]),
                  let name = fields["eventName"]?.stringValue
            else {
                throw NectoBridgeError(code: .invalidInput, message: "Expected eventName and optional params")
            }
            let params: [String: NectoJSONValue]
            if let value = fields["params"] {
                guard let object = value.objectValue else {
                    throw NectoBridgeError(code: .invalidInput, message: "Event params must be an object")
                }
                params = object
            } else {
                params = [:]
            }
            try self.init(eventName: name, params: params)
        }
    }

    public let eventID: UUID
    /// Time the dispatcher accepts the record, not the collector's arrival time.
    public let occurredAt: Date
    public let installationID: String
    public let nectoVersion: String
    public let source: Source
    /// Nil for background or host activity that is not attributable to UI or CLI.
    public let channel: Channel?
    public let input: Input

    public var jsonValue: NectoJSONValue {
        var fields: [String: NectoJSONValue] = [
            "eventId": .string(eventID.uuidString),
            "occurredAt": .number(occurredAt.timeIntervalSince1970 * 1000),
            "installationId": .string(installationID),
            "nectoVersion": .string(nectoVersion),
            "eventName": .string(input.eventName),
            "params": .object(input.params),
        ]
        if let channel { fields["channel"] = .string(channel.rawValue) }
        switch source {
        case let .device(id, version):
            fields["origin"] = "device"
            fields["pluginId"] = .string(id)
            fields["pluginVersion"] = .string(version)
        case let .desktop(id, version):
            fields["origin"] = "desktop"
            fields["pluginId"] = .string(id)
            fields["pluginVersion"] = .string(version)
        case let .necto(relatedPluginID):
            fields["origin"] = "necto"
            if let relatedPluginID { fields["relatedPluginId"] = .string(relatedPluginID) }
        }
        return .object(fields)
    }
}
