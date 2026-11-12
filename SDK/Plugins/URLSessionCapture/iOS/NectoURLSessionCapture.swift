//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import NectoNetworkPlugin
import NectoModel
import NectoSDK
import Foundation

/// The network plugin with `URLSession` capture already wired.
///
/// For the app that just wants its traffic in Necto:
///
/// ```swift
/// NectoSDK.register(URLSessionNetworkPlugin())
/// ```
///
/// Capture starts when the plugin is registered — the two are one decision, so they
/// are one line. An app that reports some requests itself as well reaches the plugin
/// through `network`.
public struct URLSessionNetworkPlugin: NectoPlugin {
    public let network = NectoNetworkPlugin()

    public var id: String { network.id }

    public var panel: NectoPluginPanel? { network.panel }

    public init() {}

    public func register(_ necto: NectoRegistrar) {
        network.register(necto)
        NectoURLSessionCapture.install(reporting: network)
    }
}

/// Captures `URLSession` traffic and reports it to whatever takes reports.
///
/// One possible source of network records, offered because many apps do use
/// `URLSession` and wiring it up by hand is tedious. It is a module of its own so
/// that an app which routes traffic some other way never links it, and so that Necto
/// never assumes this is how requests are made.
///
/// `URLSessionNetworkPlugin` above is the one-liner; these entry points are for an
/// app that pairs the capture with a reporter of its own.
public enum NectoURLSessionCapture {
    /// Starts automatic capture in any build configuration. Uses private Foundation hooks;
    /// do not include this product in apps that prohibit private APIs.
    public static func install(reporting reporter: any NectoNetworkReporting) {
        NectoURLSessionHooks.install()
        NectoSessionRecorder.shared.install(reporter)
    }

    /// Stops recording. Installed hooks remain as pass-throughs so other SDKs' hooks
    /// are not overwritten when capture stops or starts again.
    public static func uninstall() {
        NectoSessionRecorder.shared.uninstall()
    }

    @available(*, deprecated, renamed: "uninstall()")
    public static func remove() { uninstall() }

    /// Retained for source compatibility. This protocol never handles requests.
    @available(*, deprecated, message: "Automatic capture no longer needs protocolClasses registration")
    public static var protocolClass: AnyClass { NectoInactiveNetworkProtocol.self }
}

private final class NectoInactiveNetworkProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { false }
    override class func canInit(with task: URLSessionTask) -> Bool { false }
}
