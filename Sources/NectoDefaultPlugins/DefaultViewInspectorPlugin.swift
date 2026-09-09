//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import NectoModel
import NectoSDK
import Foundation

#if canImport(UIKit)
import UIKit
#endif

/// One view, as the inspector sees it.
///
/// Deliberately lean: a hierarchy is thousands of these, and a tree is read by
/// scanning class names down a column. What is only worth knowing about the selected
/// view still travels here — the panel shows it from the row without a second call.
public struct NectoViewNode: Sendable {
    /// Stable for the lifetime of the underlying view when the default UIKit walk is used.
    public let id: String?
    public let className: String
    /// What the view says, when it says anything: a label's text, a button's title.
    public let text: String?
    /// In window coordinates: x, y, width, height.
    public let frame: (x: Double, y: Double, width: Double, height: Double)
    public let isHidden: Bool
    public let alpha: Double
    public let children: [NectoViewNode]

    public init(
        id: String? = nil,
        className: String,
        text: String? = nil,
        frame: (x: Double, y: Double, width: Double, height: Double),
        isHidden: Bool = false,
        alpha: Double = 1,
        children: [NectoViewNode] = []
    ) {
        self.id = id
        self.className = className
        self.text = text
        self.frame = frame
        self.isHidden = isHidden
        self.alpha = alpha
        self.children = children
    }
}

/// The hierarchy on screen, read from Necto.
///
/// The walk is injected rather than baked in, for the same reason the network plugin
/// takes reports: how an app builds its UI is the app's business. The UIKit walk is
/// the default, and a test — or an app with its own scene setup — hands in its own.
///
/// ```swift
/// NectoSDK.register(DefaultViewInspectorPlugin())
/// ```
public final class DefaultViewInspectorPlugin: NectoPluginable, @unchecked Sendable {
    public let id = "view-inspector"

    public var panel: NectoPluginPanel? { NectoPluginPanel(bundle: .module, subdirectory: "Panels/view-inspector") }

    private let snapshot: @Sendable () async -> [NectoViewNode]
    private let action: (@Sendable (String, NectoJSONValue) async throws -> NectoJSONValue)?
    private let lock = NSLock()
    private var saved: [(id: String, windows: [NectoViewNode])] = []

    public init(snapshot: @escaping @Sendable () async -> [NectoViewNode]) {
        self.snapshot = snapshot
        action = nil
    }

    init(
        snapshot: @escaping @Sendable () async -> [NectoViewNode],
        action: @escaping @Sendable (String, NectoJSONValue) async throws -> NectoJSONValue
    ) {
        self.snapshot = snapshot
        self.action = action
    }

    #if canImport(UIKit)
    /// Walks every window of every connected scene, on the main thread, at the moment
    /// of the call. A snapshot rather than a stream: a hierarchy is inspected while
    /// reproducing something, not watched all day.
    public convenience init() {
        let runtime = NectoViewRuntime()
        self.init(
            snapshot: { await runtime.snapshot() },
            action: { operation, input in
                try await runtime.perform(operation, input: input)
            }
        )
    }

    @MainActor
    fileprivate static func node(from view: UIView) -> NectoViewNode {
        let inWindow = view.convert(view.bounds, to: nil)
        return NectoViewNode(
            id: NectoViewRuntime.id(for: view),
            className: String(describing: type(of: view)),
            text: (view as? UILabel)?.text
                ?? (view as? UIButton)?.title(for: .normal)
                ?? (view as? UITextField)?.placeholder,
            frame: (inWindow.origin.x, inWindow.origin.y, inWindow.width, inWindow.height),
            isHidden: view.isHidden,
            alpha: Double(view.alpha),
            children: view.subviews.map(node)
        )
    }
    #endif

    public func register(_ necto: NectoHandler) {
        necto.handle("views.tree") { [self] _ in
            ["windows": .array(await capture().map { Self.encode($0.node, path: $0.path) })]
        }

        necto.handle("views.snapshot") { [self] _ in
            let capture = await saveSnapshot()
            return [
                "snapshotID": .string(capture.id),
                "windows": .array(Self.indexed(capture.windows).map { Self.encode($0.node, path: $0.path) }),
            ]
        }

        necto.handle("views.search") { [self] input in
            let query = input["query"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let nodes = await capture()
            let matches = query.isEmpty ? nodes : nodes.filter {
                $0.node.className.localizedCaseInsensitiveContains(query)
                    || ($0.node.text?.localizedCaseInsensitiveContains(query) == true)
            }
            return ["matches": .array(matches.map { Self.encode($0.node, path: $0.path) })]
        }

        necto.handle("views.inspect") { [self] input in
            let id = try Self.requiredID(input)
            guard let node = await capture().first(where: { Self.id($0.node, path: $0.path) == id }) else {
                throw NectoBridgeError(code: .invalidInput, message: "View not found: \(id)")
            }
            return ["view": Self.encode(node.node, path: node.path)]
        }

        necto.handle("views.compare") { [self] input in
            guard let baselineID = input["baselineSnapshotID"]?.stringValue else {
                throw NectoBridgeError(code: .invalidInput, message: "baselineSnapshotID is required")
            }
            guard let baseline = lock.withLock({ saved.first(where: { $0.id == baselineID })?.windows }) else {
                throw NectoBridgeError(code: .invalidInput, message: "Snapshot not found: \(baselineID)")
            }
            let current = await saveSnapshot()
            return [
                "snapshotID": .string(current.id),
                "changes": .array(Self.compare(baseline, current.windows)),
            ]
        }

        for operation in ["highlight", "tap", "tapAt", "scroll", "swipe", "drag", "longPress", "inputText"] {
            necto.handle("views.\(operation)") { [self] input in
                guard let action else {
                    throw NectoBridgeError(code: .operationUnavailable, message: "View interaction requires the UIKit inspector")
                }
                return try await action(operation, input)
            }
        }
    }

    private func capture() async -> [(node: NectoViewNode, path: String)] {
        Self.indexed(await snapshot())
    }

    private func saveSnapshot() async -> (id: String, windows: [NectoViewNode]) {
        let item = (id: UUID().uuidString, windows: await snapshot())
        lock.withLock {
            saved.append(item)
            if saved.count > 10 { saved.removeFirst(saved.count - 10) }
        }
        return item
    }

    // MARK: Coding

    static func encode(_ node: NectoViewNode, path: String = "0") -> NectoJSONValue {
        var fields: [String: NectoJSONValue] = [
            "id": .string(id(node, path: path)),
            "className": .string(node.className),
            "frame": .array([
                .number(finite(node.frame.x)), .number(finite(node.frame.y)),
                .number(finite(node.frame.width)), .number(finite(node.frame.height)),
            ]),
            "children": .array(node.children.enumerated().map { index, child in
                encode(child, path: "\(path)/\(index)")
            }),
        ]
        // Present only when they say something: most views are visible and opaque,
        // and a tree of thousands should not carry two fields of noise each.
        if let text = node.text { fields["text"] = .string(text) }
        if node.isHidden { fields["isHidden"] = .bool(true) }
        if node.alpha != 1 { fields["alpha"] = .number(finite(node.alpha)) }
        return .object(fields)
    }

    /// Layout can leave a view with a NaN or infinite frame mid-flight, and JSON has
    /// no way to say either — encoding would fail, and a reply that fails to encode
    /// is a panel that waits forever. Zero is wrong too, but visibly wrong.
    static func finite(_ value: Double) -> Double {
        value.isFinite ? value : 0
    }

    private static func id(_ node: NectoViewNode, path: String) -> String { node.id ?? "path:\(path)" }

    private static func indexed(_ windows: [NectoViewNode]) -> [(node: NectoViewNode, path: String)] {
        var result: [(NectoViewNode, String)] = []
        func walk(_ nodes: [NectoViewNode], _ prefix: String) {
            for (index, node) in nodes.enumerated() {
                let path = prefix.isEmpty ? String(index) : "\(prefix)/\(index)"
                result.append((node, path))
                walk(node.children, path)
            }
        }
        walk(windows, "")
        return result
    }

    fileprivate static func requiredID(_ input: NectoJSONValue) throws -> String {
        guard let id = input["viewID"]?.stringValue, !id.isEmpty else {
            throw NectoBridgeError(code: .invalidInput, message: "viewID is required")
        }
        return id
    }

    private static func compare(_ before: [NectoViewNode], _ after: [NectoViewNode]) -> [NectoJSONValue] {
        var old: [String: (node: NectoViewNode, path: String)] = [:]
        var new: [String: (node: NectoViewNode, path: String)] = [:]
        for item in indexed(before) { old[id(item.node, path: item.path)] = item }
        for item in indexed(after) { new[id(item.node, path: item.path)] = item }
        return Set(old.keys).union(new.keys).sorted().compactMap { key in
            switch (old[key], new[key]) {
            case (.none, let value?):
                return ["id": .string(key), "change": .string("added"), "after": encode(value.node, path: value.path)]
            case (let value?, .none):
                return ["id": .string(key), "change": .string("removed"), "before": encode(value.node, path: value.path)]
            case (let lhs?, let rhs?) where signature(lhs.node) != signature(rhs.node):
                return ["id": .string(key), "change": .string("modified"), "before": encode(lhs.node, path: lhs.path), "after": encode(rhs.node, path: rhs.path)]
            default:
                return nil
            }
        }
    }

    private static func signature(_ node: NectoViewNode) -> String {
        "\(node.className)|\(node.text ?? "")|\(node.frame)|\(node.isHidden)|\(node.alpha)"
    }
}

#if canImport(UIKit)
private final class NectoViewRuntime: @unchecked Sendable {
    private final class WeakView { weak var value: UIView?; init(_ value: UIView) { self.value = value } }
    private var views: [String: WeakView] = [:]

    static func id(for view: UIView) -> String { "view-\(UInt(bitPattern: ObjectIdentifier(view)))" }

    @MainActor
    func snapshot() -> [NectoViewNode] {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        views = [:]
        func remember(_ view: UIView) {
            views[Self.id(for: view)] = WeakView(view)
            view.subviews.forEach(remember)
        }
        windows.forEach(remember)
        return windows.map(DefaultViewInspectorPlugin.node)
    }

    @MainActor
    func perform(_ operation: String, input: NectoJSONValue) async throws -> NectoJSONValue {
        switch operation {
        case "highlight":
            let view = try requiredView(input)
            guard let window = view.window else {
                throw NectoBridgeError(code: .operationUnavailable, message: "View is not in a window")
            }
            let overlay = UIView(frame: view.convert(view.bounds, to: window))
            overlay.isUserInteractionEnabled = false
            overlay.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.12)
            overlay.layer.borderColor = UIColor.systemBlue.cgColor
            overlay.layer.borderWidth = 2
            window.addSubview(overlay)
            let duration = min(max(input["duration"]?.numberValue ?? 1, 0.1), 10)
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(duration))
                overlay.removeFromSuperview()
            }
            return ["highlighted": .bool(true)]
        case "tap":
            return try activate(requiredView(input))
        case "tapAt":
            let point = try requiredPoint(input, x: "x", y: "y")
            return try activate(hitView(at: point), point: point)
        case "scroll":
            let scroll = try requiredScrollView(from: requiredView(input))
            let amount = input["amount"]?.numberValue ?? Double(scroll.bounds.height * 0.8)
            let direction = input["direction"]?.stringValue ?? "down"
            let offset = move(scroll, direction: direction, amount: amount)
            return ["offset": .array([.number(offset.x), .number(offset.y)])]
        case "swipe":
            let view = try requiredView(input)
            let scroll = try requiredScrollView(from: view)
            let direction = input["direction"]?.stringValue ?? "up"
            let amount = input["amount"]?.numberValue ?? Double(
                direction == "left" || direction == "right" ? scroll.bounds.width * 0.8 : scroll.bounds.height * 0.8
            )
            // A finger moving up moves the scroll view's content down, and vice versa.
            let scrollDirection: String = switch direction {
            case "up": "down"
            case "down": "up"
            case "left": "right"
            default: "left"
            }
            let offset = move(scroll, direction: scrollDirection, amount: amount)
            return [
                "offset": .array([.number(offset.x), .number(offset.y)]),
                "method": .string("contentOffset"),
            ]
        case "drag":
            let start = try requiredPoint(input, x: "fromX", y: "fromY")
            let end = try requiredPoint(input, x: "toX", y: "toY")
            let scroll = try requiredScrollView(from: hitView(at: start))
            let offset = move(scroll, delta: CGPoint(x: start.x - end.x, y: start.y - end.y))
            return [
                "offset": .array([.number(offset.x), .number(offset.y)]),
                "method": .string("contentOffset"),
            ]
        case "longPress":
            let view = try requiredView(input)
            guard let control = sequence(first: view, next: { $0.superview }).first(where: { $0 is UIControl }) as? UIControl else {
                throw NectoBridgeError(
                    code: .operationUnavailable,
                    message: "Public UIKit can only hold controls; gesture recognizers require runtime touch injection"
                )
            }
            let duration = min(max(input["duration"]?.numberValue ?? 0.6, 0.1), 10)
            control.sendActions(for: .touchDown)
            defer { control.sendActions(for: .touchUpInside) }
            try await Task.sleep(for: .seconds(duration))
            return [
                "pressed": .bool(true),
                "duration": .number(duration),
                "method": .string("controlEvents"),
            ]
        case "inputText":
            let view = try requiredView(input)
            guard let text = input["text"]?.stringValue else {
                throw NectoBridgeError(code: .invalidInput, message: "text is required")
            }
            guard let target = textInput(in: view), target.becomeFirstResponder() else {
                throw NectoBridgeError(code: .operationUnavailable, message: "View does not accept text input")
            }
            let replace = input["replace"]?.boolValue ?? true
            if replace {
                if let field = target as? UITextField {
                    field.text = ""
                } else if let textView = target as? UITextView {
                    textView.text = ""
                } else {
                    for _ in 0 ..< 1_000 where target.hasText { target.deleteBackward() }
                    guard !target.hasText else {
                        throw NectoBridgeError(code: .operationUnavailable, message: "Text input could not be cleared")
                    }
                }
            }
            target.insertText(text)
            if let control = target as? UIControl {
                control.sendActions(for: .editingChanged)
            }
            return [
                "inserted": .bool(true),
                "length": .number(Double(text.count)),
                "method": .string("UIKeyInput"),
            ]
        default:
            throw NectoBridgeError(code: .operationUnavailable, message: operation)
        }
    }

    @MainActor
    private func requiredView(_ input: NectoJSONValue) throws -> UIView {
        let id = try DefaultViewInspectorPlugin.requiredID(input)
        guard let view = views[id]?.value else {
            throw NectoBridgeError(code: .invalidInput, message: "View not found: \(id)")
        }
        return view
    }

    @MainActor
    private func requiredPoint(_ input: NectoJSONValue, x: String, y: String) throws -> CGPoint {
        guard let x = input[x]?.numberValue, let y = input[y]?.numberValue else {
            throw NectoBridgeError(code: .invalidInput, message: "\(x) and \(y) are required")
        }
        return CGPoint(x: x, y: y)
    }

    @MainActor
    private func hitView(at screenPoint: CGPoint) throws -> UIView {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive }
            .flatMap(\.windows)
            .filter { !$0.isHidden && $0.alpha > 0 }
            .sorted { $0.windowLevel.rawValue > $1.windowLevel.rawValue }
        for window in windows {
            let point = window.convert(screenPoint, from: nil)
            if window.bounds.contains(point), let view = window.hitTest(point, with: nil) {
                return view
            }
        }
        throw NectoBridgeError(code: .invalidInput, message: "No view at \(screenPoint.x), \(screenPoint.y)")
    }

    @MainActor
    private func activate(_ view: UIView, point: CGPoint? = nil) throws -> NectoJSONValue {
        let method: String
        if view.accessibilityActivate() {
            method = "accessibilityActivate"
        } else if let control = sequence(first: view, next: { $0.superview }).first(where: { $0 is UIControl }) as? UIControl {
            control.sendActions(for: .primaryActionTriggered)
            method = "primaryAction"
        } else {
            throw NectoBridgeError(code: .operationUnavailable, message: "View has no public activation action")
        }
        var output: [String: NectoJSONValue] = ["tapped": .bool(true), "method": .string(method)]
        if let point {
            output["x"] = .number(point.x)
            output["y"] = .number(point.y)
        }
        return .object(output)
    }

    @MainActor
    private func requiredScrollView(from view: UIView) throws -> UIScrollView {
        guard let scroll = sequence(first: view, next: { $0.superview })
            .first(where: { $0 is UIScrollView }) as? UIScrollView,
              scroll.isScrollEnabled else {
            throw NectoBridgeError(code: .operationUnavailable, message: "View is not inside an enabled scroll view")
        }
        return scroll
    }

    @MainActor
    private func move(_ scroll: UIScrollView, direction: String, amount: Double) -> CGPoint {
        let delta: CGPoint = switch direction {
        case "up": CGPoint(x: 0, y: -amount)
        case "left": CGPoint(x: -amount, y: 0)
        case "right": CGPoint(x: amount, y: 0)
        default: CGPoint(x: 0, y: amount)
        }
        return move(scroll, delta: delta)
    }

    @MainActor
    private func move(_ scroll: UIScrollView, delta: CGPoint) -> CGPoint {
        let minX = -scroll.adjustedContentInset.left
        let maxX = max(minX, scroll.contentSize.width - scroll.bounds.width + scroll.adjustedContentInset.right)
        let minY = -scroll.adjustedContentInset.top
        let maxY = max(minY, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
        let offset = CGPoint(
            x: min(max(scroll.contentOffset.x + delta.x, minX), maxX),
            y: min(max(scroll.contentOffset.y + delta.y, minY), maxY)
        )
        scroll.setContentOffset(offset, animated: false)
        return offset
    }

    @MainActor
    private func textInput(in view: UIView) -> (UIView & UIKeyInput)? {
        if let input = view as? (UIView & UIKeyInput) { return input }
        for child in view.subviews {
            if let input = textInput(in: child) { return input }
        }
        return nil
    }
}
#endif
