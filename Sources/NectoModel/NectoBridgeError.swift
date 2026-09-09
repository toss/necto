//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import Foundation

/// Standard codes for a failed plugin call.
///
/// The same code is produced whether the call came from web, CLI or HTTP.
public enum NectoBridgeErrorCode: String, Sendable, Codable, CaseIterable {
    case invalidInput = "INVALID_INPUT"
    case operationNotFound = "OPERATION_NOT_FOUND"
    case operationUnavailable = "OPERATION_UNAVAILABLE"
    case permissionDenied = "PERMISSION_DENIED"
    case targetDisconnected = "TARGET_DISCONNECTED"
    case timeout = "TIMEOUT"
    case cancelled = "CANCELLED"
    case providerFailed = "PROVIDER_FAILED"
    case invalidOutput = "INVALID_OUTPUT"
}

public struct NectoBridgeError: Sendable, Error, Codable, Hashable {
    public let code: NectoBridgeErrorCode
    public let message: String
    public let operationID: String?
    public let details: NectoJSONValue?

    public init(
        code: NectoBridgeErrorCode,
        message: String,
        operationID: String? = nil,
        details: NectoJSONValue? = nil
    ) {
        self.code = code
        self.message = message
        self.operationID = operationID
        self.details = details
    }
}

extension NectoBridgeError: CustomStringConvertible {
    public var description: String { "\(code.rawValue): \(message)" }
}
