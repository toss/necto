//
// Copyright (c) 2026 Viva Republica, Inc.
//

import NectoSDK

public struct __PLUGIN_MODULE__: NectoPluginable {
    public let id = "__PLUGIN_ID__"

    public init() {}

    public var panel: NectoPluginPanel? {
        NectoPluginPanel(bundle: .module)
    }

    public func register(_ necto: NectoHandler) {
        necto.handle(
            "message.get",
            outputSchema: [
                "type": "object",
                "properties": [
                    "message": ["type": "string"],
                ],
                "required": ["message"],
                "additionalProperties": false,
            ]
        ) { _ in
            ["message": .string("Hello from __DISPLAY_NAME__")]
        }
    }
}
