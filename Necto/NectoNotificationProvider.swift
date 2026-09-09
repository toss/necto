//
// Copyright (c) 2026 Viva Republica, Inc.
//

import CryptoKit
import Foundation
import NectoMacService
import NectoModel
import UserNotifications

struct NectoNotificationProvider: NectoOperationProvider {
    let descriptor: NectoBridgeDescriptor
    private let action: String
    init(action: String) {
        self.action = action
        descriptor = NectoBridgeDescriptor(binding: NectoBridgeBinding(name: "necto.desktop.notifications." + action, version: 1), kind: .once)
    }

    func invoke(input: NectoJSONValue, context: NectoInvocationContext) async throws -> NectoJSONValue {
        let center = UNUserNotificationCenter.current()
        if action == "requestAuthorization" {
            let granted = try await center.requestAuthorization(options: [.alert, .sound])
            return ["granted": .bool(granted)]
        }
        let settings = await center.notificationSettings()
        let granted = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
        if action == "status" { return ["granted": .bool(granted)] }
        guard granted else {
            throw NectoBridgeError(code: .permissionDenied, message: "Notifications are not allowed. Enable Necto in System Settings.")
        }
        guard let id = input["id"]?.stringValue, !id.isEmpty, id.count <= 256,
              let title = input["title"]?.stringValue, !title.isEmpty, title.count <= 160,
              let body = input["body"]?.stringValue, body.count <= 1000 else {
            throw NectoBridgeError(code: .invalidInput, message: "A bounded notification id, title and body are required.")
        }
        let identity = context.principal.sourceIdentity + "\0" + context.principal.pluginID + "\0" + id
        let identifier = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = context.principal.pluginID
        content.body = body
        content.sound = .default
        content.userInfo = ["pluginID": context.principal.pluginID, "sourceIdentity": context.principal.sourceIdentity]
        try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
        return ["submitted": true]
    }
}
