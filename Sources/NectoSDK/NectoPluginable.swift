//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import NectoModel
import Foundation

/// A bridge the app contributes to Necto.
///
/// Two things, and that is the whole protocol: a name, and a chance to say what the
/// plugin answers. Everything a plugin can do it does by registering handlers, so
/// adding a capability never changes this shape and never changes the SDK.
///
/// ```swift
/// struct ThingsPlugin: NectoPluginable {
///     let id = "com.example.things"
///
///     func register(_ necto: NectoHandler) {
///         necto.handle("things.list") { _ in ["things": .array(…)] }
///         necto.handle("things.observe") { _, out in
///             for await change in changes { await out.send(change) }
///         }
///     }
/// }
/// ```
///
/// Not `AnyObject`: a plugin that keeps no mutable state of its own, or keeps it behind
/// a reference, is fine as a `struct`.
public protocol NectoPluginable: Sendable {
    /// Stable and unique within the app, separate from the panel's display name.
    /// Lowercase reverse-domain IDs are recommended (for example `com.example.things`).
    var id: String { get }

    /// The plugin's own screen, when it ships one.
    ///
    /// A plugin that carries a panel is complete in a single package: the app links
    /// it, registers it, and the panel appears on the Mac when the app connects —
    /// there is nothing to install on the other side. `nil` means the Mac already
    /// knows how to show this plugin, or nothing does.
    var panel: NectoPluginPanel? { get }

    /// Called once per successful registration. To change what it offers, explicitly
    /// unregister the existing ID before registering the replacement.
    func register(_ necto: NectoHandler)
}

public extension NectoPluginable {
    var panel: NectoPluginPanel? { nil }
}

/// Where a plugin's built panel lives, usually inside the package that implements it.
///
/// ```swift
/// // Package.swift: resources: [.copy("Panel")]
/// var panel: NectoPluginPanel? { NectoPluginPanel(bundle: .module) }
/// ```
public struct NectoPluginPanel: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// The conventional spot: a `Panel` directory copied into the module's resources.
    public init?(bundle: Bundle, subdirectory: String = "Panel") {
        guard let root = bundle.url(forResource: subdirectory, withExtension: nil) else { return nil }
        self.root = root
    }
}

/// Collects what a plugin answers.
///
/// Only useful for the length of `register(_:)`. Nothing is called back through it, so
/// a plugin never has to hold on to it.
public final class NectoHandler: @unchecked Sendable {
    /// One registration: the contract and the work, in one place, so a name is written
    /// once rather than declared in one list and switched on in another.
    struct Registration {
        let descriptor: NectoBridgeDescriptor
        let body: Body

        enum Body {
            case once(@Sendable (NectoJSONValue) async throws -> NectoJSONValue)
            case stream(@Sendable (NectoJSONValue, Out) async throws -> Void)
        }
    }

    private(set) var registrations: [String: Registration] = [:]
    private(set) var hasDuplicateContracts = false

    init() {}

    /// Answers once. Whatever it returns is the answer.
    ///
    /// `name` is relative to `necto.device.`, which is also how a panel calls it:
    /// `handle("things.list")` here is `necto.device.send("things.list")` there.
    ///
    /// `version` counts breaking changes rather than releases. Adding a field to what
    /// this returns is not one — a reader written against the old shape still parses
    /// the new one — so it stays where it is until something really cannot be read.
    ///
    /// Nothing here says whether the operation writes. The name does, and a panel that
    /// wants to ask before it destroys something asks in its own words.
    public func handle(
        _ name: String,
        version: Int = 1,
        inputSchema: NectoJSONValue = .object([:]),
        outputSchema: NectoJSONValue = .object([:]),
        _ body: @escaping @Sendable (NectoJSONValue) async throws -> NectoJSONValue
    ) {
        add(
            name: name,
            version: version,
            kind: .once,
            inputSchema: inputSchema,
            outputSchema: outputSchema,
            body: .once(body)
        )
    }

    /// Answers as many times as it likes. Ends when the closure returns, or when the
    /// caller stops listening — the closure's task is cancelled then, so a `for await`
    /// inside it comes out on its own.
    public func handle(
        _ name: String,
        version: Int = 1,
        inputSchema: NectoJSONValue = .object([:]),
        outputSchema: NectoJSONValue = .object([:]),
        _ body: @escaping @Sendable (NectoJSONValue, Out) async throws -> Void
    ) {
        add(
            name: name,
            version: version,
            kind: .stream,
            inputSchema: inputSchema,
            outputSchema: outputSchema,
            body: .stream(body)
        )
    }

    private func add(
        name: String,
        version: Int,
        kind: NectoOperationKind,
        inputSchema: NectoJSONValue,
        outputSchema: NectoJSONValue,
        body: Registration.Body
    ) {
        let descriptor = NectoBridgeDescriptor(
            binding: NectoBridgeBinding(
                name: NectoBridgeKind.device.prefix + name,
                version: version
            ),
            kind: kind,
            inputSchema: inputSchema,
            outputSchema: outputSchema
        )
        guard registrations[descriptor.identity] == nil else {
            hasDuplicateContracts = true
            return
        }
        registrations[descriptor.identity] = Registration(descriptor: descriptor, body: body)
    }

    /// Where a handler sends what it has.
    public struct Out: Sendable {
        let yield: @Sendable (NectoJSONValue) async -> Void

        public func send(_ value: NectoJSONValue) async {
            await yield(value)
        }
    }
}
