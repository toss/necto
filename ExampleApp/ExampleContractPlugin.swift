//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import NectoModel
import NectoSDK
import Foundation

/// Answers questions about this app, so the app bridge round trip has something real
/// to exercise.
///
/// The interesting half of the bridge: everything else in this app pushes, while this
/// waits to be asked. A plugin on the Mac calls its own operation id, the runtime
/// resolves that to `com.example.app.state@1`, and the request travels here.
struct ExampleContractPlugin: NectoPluginable {
    let id = "plugin-sample"

    // Carried in the app bundle rather than a package: the folder reference in the
    // Xcode project is the whole arrangement, which is the other way an app can
    // bring a panel along.
    var panel: NectoPluginPanel? {
        Bundle.main.url(forResource: "plugin-sample", withExtension: nil).map(NectoPluginPanel.init(root:))
    }

    func register(_ necto: NectoHandler) {
        necto.handle("com.example.app.state") { input in
            // The note is echoed back so a caller can prove the input reached the
            // device rather than being answered somewhere on the way.
            await [
                "appVersion": .string(Bundle.main.infoVersion),
                "deviceName": .string(MainActor.run { UIDeviceName.current }),
                "note": .string(input["note"]?.stringValue ?? ""),
            ]
        }

        necto.handle("com.example.app.counter") { input, out in
            for step in 1 ... max(1, Int(input["count"]?.numberValue ?? 3)) {
                await out.send(["step": .number(Double(step))])
                try await Task.sleep(for: .milliseconds(200))
            }
        }
    }
}

private extension Bundle {
    var infoVersion: String {
        object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }
}

#if canImport(UIKit)
import UIKit

private enum UIDeviceName {
    @MainActor static var current: String { UIDevice.current.name }
}
#else
private enum UIDeviceName {
    @MainActor static var current: String { ProcessInfo.processInfo.hostName }
}
#endif
