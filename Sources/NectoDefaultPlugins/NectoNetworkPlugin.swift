//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import NectoModel
import NectoSDK
import Foundation

/// The standard way to report network traffic to Necto.
///
/// This is an interface, not a capture mechanism. Necto does not know how an app makes
/// requests: it may use `URLSession`, a socket library, gRPC, or something obfuscated
/// past recognition. Deciding that for the app would make Necto useless everywhere the
/// guess is wrong, so the app reports and Necto only carries.
///
/// ```swift
/// let network = NectoNetworkPlugin()
/// NectoSDK.register(network)
/// NectoSDK.start()
///
/// // Wherever the app already knows about a request:
/// network.report(record)
/// ```
///
/// `NectoURLSessionCapture` is one ready-made source for apps that do use `URLSession`.
/// It is a separate module precisely so that using it stays the app's choice.
///
/// Shipped with Necto, and still an ordinary plugin: it declares contracts and answers
/// them, exactly as one written in an app would. Nothing on the Mac side knows this
/// plugin exists.
public final class NectoNetworkPlugin: NectoPluginable, NectoNetworkReporting, @unchecked Sendable {
    /// Keeps memory bounded on a long session. Older records fall off the end.
    public static let capacity = 2000

    public let id = "network-logger"

    public var panel: NectoPluginPanel? { NectoPluginPanel(bundle: .module, subdirectory: "Panels/network-logger") }


    private let lock = NSLock()
    private var records: [NectoNetworkRecord] = []
    private var observers: [UUID: NectoHandler.Out] = [:]

    public init() {}

    public func register(_ necto: NectoHandler) {
        necto.handle("network-records.list") { [self] input in
            let limit = Int(input["limit"]?.numberValue ?? 200)
            let page = lock.withLock { Array(records.prefix(limit)) }
            return ["records": .array(page.map(NectoNetworkRecordCoding.summary))]
        }

        necto.handle("network-records.detail") { [self] input in
            guard let recordID = input["recordID"]?.stringValue else {
                throw NectoBridgeError(code: .invalidInput, message: "recordID is required")
            }
            guard let record = lock.withLock({ records.first { $0.id == recordID } }) else {
                throw NectoBridgeError(code: .operationUnavailable, message: "No record '\(recordID)'")
            }
            return ["record": NectoNetworkRecordCoding.detail(record)]
        }

        necto.handle("network-records.observe") { [self] _, out in
            let token = UUID()
            lock.withLock { observers[token] = out }
            defer { lock.withLock { _ = observers.removeValue(forKey: token) } }

            // Held open until the caller stops listening; `report` does the sending.
            while !Task.isCancelled {
                try await Task.sleep(for: .seconds(60))
            }
        }

        necto.handle("network-records.clear") { [self] _ in
            lock.withLock { records.removeAll() }
            return ["cleared": .bool(true)]
        }
    }

    /// Reports one request. Safe to call from any thread, and whether or not a host is
    /// attached: the app keeps its own records, so it collects from the moment it
    /// starts rather than from the moment someone opens the panel.
    ///
    /// Send a record twice to show progress, once when the request starts and once
    /// when it ends, keeping the same `id`. Necto replaces rather than appends.
    public func report(_ record: NectoNetworkRecord) {
        let listeners = lock.withLock { () -> [NectoHandler.Out] in
            if let index = records.firstIndex(where: { $0.id == record.id }) {
                records[index] = record
            } else {
                records.insert(record, at: 0)
                if records.count > Self.capacity {
                    records.removeLast(records.count - Self.capacity)
                }
            }
            return Array(observers.values)
        }

        let event: NectoJSONValue = ["record": NectoNetworkRecordCoding.summary(record)]
        for out in listeners {
            Task { await out.send(event) }
        }
    }
}
