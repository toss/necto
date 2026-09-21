//
//  Copyright (c) 2026 Viva Republica, Inc.
//

#if canImport(UIKit)
import NectoModel
import NectoSDK
import NectoTouchInjection
import UIKit

@MainActor
final class NectoControlRuntime {
    nonisolated init() {}

    private struct Target {
        weak var view: UIView?
        let element: NSObject?
        var object: NSObject? { element ?? view }
        weak var owner: UIView?
        let frame: CGRect
        let label: String?
        let actions: [String]
    }

    private var targets: [String: Target] = [:]
    private let identities = NSMapTable<NSObject, NSString>(keyOptions: [.weakMemory, .objectPointerPersonality], valueOptions: .strongMemory)
    private var performing = false

    private var activeWindow: UIWindow? {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }.flatMap(\.windows)
            .first(where: \.isKeyWindow)
    }

    func readAccessibility() -> [NectoAccessibilityItem] {
        guard let window = activeWindow else { return [] }
        NectoAccessibilityLoader.prepare()
        return NectoAccessibilityReader.read(in: window)
    }

    private func children(of object: NSObject) -> [NSObject] {
        if let elements = object.accessibilityElements { return elements.compactMap { $0 as? NSObject } }
        let count = object.accessibilityElementCount()
        if count > 0, count != NSNotFound {
            return (0..<count).compactMap { object.accessibilityElement(at: $0) as? NSObject }
        }
        // Public UIAccessibility does not expose every intermediate hosting view as a container.
        // Bridge those gaps to reach native text inputs and scroll containers as well.
        return (object as? UIView)?.subviews ?? []
    }

    private func actions(for object: NSObject) -> [String] {
        guard !object.accessibilityElementsHidden, !object.accessibilityTraits.contains(.notEnabled) else { return [] }
        if let control = object as? UIControl, !control.isEnabled { return [] }
        if object is UIWindow { return ["tap", "swipe", "back"] }
        if let field = object as? UITextField { return field.isEnabled ? ["tap", "input"] : [] }
        if let field = object as? UITextView { return field.isEditable ? ["tap", "input", "swipe"] : ["swipe"] }
        if let scroll = object as? UIScrollView { return scroll.isScrollEnabled ? ["swipe"] : [] }
        guard object.isAccessibilityElement else { return [] }
        let traits = object.accessibilityTraits
        if traits.contains(.button) || traits.contains(.link) || traits.contains(.keyboardKey) { return ["tap"] }
        if !tapGestures(for: object).isEmpty { return ["tap"] }
        return []
    }

    private func tapGestures(for object: NSObject) -> [NectoControlTapGesture] {
        guard let view = object as? UIView else { return [] }
        var result: [NectoControlTapGesture] = []
        for case let recognizer as UITapGestureRecognizer in view.gestureRecognizers ?? [] {
            guard recognizer.isEnabled, (1...5).contains(recognizer.numberOfTouchesRequired),
                  (1...3).contains(recognizer.numberOfTapsRequired) else { continue }
            let gesture = NectoControlTapGesture(touchCount: recognizer.numberOfTouchesRequired,
                                                 tapCount: recognizer.numberOfTapsRequired)
            if !result.contains(gesture) { result.append(gesture) }
        }
        return result
    }

    private func frame(of object: NSObject, owner: UIView, in window: UIWindow) -> CGRect {
        guard owner === window || owner.window === window else { return .null }
        var frame = window.convert(object.accessibilityFrame, from: window.screen.coordinateSpace)
        // Containers are often not individual accessibility elements and have no AX frame.
        if frame.isEmpty, let view = object as? UIView { frame = view.convert(view.bounds, to: window) }
        frame = frame.intersection(window.bounds)
        var ancestor: UIView? = owner
        while let view = ancestor {
            if view.isHidden || view.alpha < 0.01 || !view.isUserInteractionEnabled || view.accessibilityElementsHidden { return .null }
            if view.clipsToBounds { frame = frame.intersection(view.convert(view.bounds, to: window)) }
            ancestor = view.superview
        }
        return frame
    }

    private func entries(in window: UIWindow) -> [(NSObject, UIView, CGRect)] {
        var result: [(NSObject, UIView, CGRect)] = []
        var visited: Set<ObjectIdentifier> = []
        func walk(_ object: NSObject, owner: UIView) {
            guard visited.insert(ObjectIdentifier(object)).inserted, !object.accessibilityElementsHidden else { return }
            let owner = (object as? UIView) ?? owner
            let rect = frame(of: object, owner: owner, in: window)
            if !rect.isNull, rect.width > 1, rect.height > 1 { result.append((object, owner, rect)) }
            if object.isAccessibilityElement { return }
            for child in children(of: object) { walk(child, owner: owner) }
        }
        walk(window, owner: window)
        return result
    }

    func snapshot() -> [NectoControlTarget] {
        targets.removeAll()
        guard !performing, let window = activeWindow else { return [] }
        NectoAccessibilityLoader.prepare()
        return entries(in: window).compactMap { object, owner, frame in
            let actions = actions(for: object)
            guard !actions.isEmpty,
                  let hit = window.hitTest(CGPoint(x: frame.midX, y: frame.midY), with: nil),
                  hit === owner || hit.isDescendant(of: owner) || owner.isDescendant(of: hit) else { return nil }
            let id = (identities.object(forKey: object) as String?) ?? UUID().uuidString
            identities.setObject(id as NSString, forKey: object)
            targets[id] = Target(view: object as? UIView, element: object is UIView ? nil : object, owner: owner, frame: frame, label: object.accessibilityLabel, actions: actions)
            let role = object is UIWindow ? "screen" : actions.contains("input") ? "textInput" : actions.contains("swipe") ? "scrollArea" : "button"
            let secure = (object as? UITextField)?.isSecureTextEntry ?? (object as? UITextView)?.isSecureTextEntry ?? false
            return NectoControlTarget(
                id: id, role: role, label: object.accessibilityLabel,
                identifier: NectoAccessibilityReader.identifier(of: object),
                frame: (frame.minX, frame.minY, frame.width, frame.height), actions: actions,
                tapGestures: tapGestures(for: object),
                value: object.accessibilityValue, isSecure: secure
            )
        }
    }

    func perform(_ operation: String, _ input: NectoJSONValue) async throws -> NectoJSONValue {
        guard !performing else { throw unavailable("Another action is in progress") }
        guard let id = input["targetID"]?.stringValue, let target = targets[id],
              let object = target.object, let owner = target.owner, let window = activeWindow,
              target.actions.contains(operation), actions(for: object).contains(operation),
              entries(in: window).contains(where: { $0.0 === object }),
              object.accessibilityLabel == target.label else {
            throw unavailable("The target changed. Refresh Control before acting.")
        }
        let current = frame(of: object, owner: owner, in: window)
        guard current == target.frame else { throw unavailable("The element moved. Refresh Control before acting.") }
        let center = CGPoint(x: current.midX, y: current.midY)
        let position = try NectoControlGeometry.position(input["position"], in: current)
        guard let hit = window.hitTest(position ?? center, with: nil),
              hit === owner || hit.isDescendant(of: owner) || owner.isDescendant(of: hit) else {
            throw unavailable("The target is covered by another view. Refresh Control before acting.")
        }
        performing = true
        targets.removeAll()
        defer { performing = false }
        let before = readAccessibility().map(\.json)
        let method: String
        switch operation {
        case "tap":
            let fingers = input["touchCount"]?.numberValue ?? 1
            let taps = input["tapCount"]?.numberValue ?? 1
            guard (1...5).contains(fingers), fingers.rounded() == fingers,
                  (1...3).contains(taps), taps.rounded() == taps else {
                throw NectoBridgeError(code: .invalidInput, message: "Use 1–5 fingers and 1–3 taps")
            }
            // Spread contacts inside the visible target and verify every contact before sending any.
            let points = try NectoControlGeometry.tapPoints(at: position ?? center, count: Int(fingers), in: current)
            guard points.allSatisfy({ point in
                guard let hit = window.hitTest(point, with: nil) else { return false }
                return hit === owner || hit.isDescendant(of: owner) || owner.isDescendant(of: hit)
            }) else { throw unavailable("The target is covered by another view. Refresh Control before acting.") }
            method = "touch"
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                NectoTouchInjector.tap(in: window, points: points.map { NSValue(cgPoint: $0) }, tapCount: UInt(taps)) { error in
                    if let error { continuation.resume(throwing: NectoBridgeError(code: .operationUnavailable, message: error)) }
                    else { continuation.resume() }
                }
            }
        case "swipe":
            let ratio = input["distanceRatio"]?.numberValue ?? 0.6
            let milliseconds = input["durationMs"]?.numberValue ?? 400
            guard ratio.isFinite, (0.1...0.9).contains(ratio), milliseconds.isFinite,
                  (100...2000).contains(milliseconds) else {
                throw NectoBridgeError(code: .invalidInput, message: "Use distanceRatio 0.1–0.9 and durationMs 100–2000")
            }
            let rect = current.insetBy(dx: min(12, current.width / 10), dy: min(12, current.height / 10))
            var start = CGPoint(x: rect.midX, y: rect.midY)
            var end = start
            if let position {
                start = position
                end = try NectoControlGeometry.swipe(from: start, direction: input["direction"]?.stringValue ?? "",
                                                     ratio: ratio, in: current)
            } else {
                let dx = rect.width * ratio / 2, dy = rect.height * ratio / 2
                switch input["direction"]?.stringValue {
                case "up": start.y += dy; end.y -= dy
                case "down": start.y -= dy; end.y += dy
                case "left": start.x += dx; end.x -= dx
                case "right": start.x -= dx; end.x += dx
                default: throw NectoBridgeError(code: .invalidInput, message: "Choose up, down, left, or right")
                }
            }
            guard let hit = window.hitTest(start, with: nil),
                  hit === owner || hit.isDescendant(of: owner) || owner.isDescendant(of: hit) else {
                throw unavailable("The target is covered by another view. Refresh Control before acting.")
            }
            method = "touch"
            try await send(in: window, from: start, to: end, duration: milliseconds / 1000)
        case "back":
            // An edge swipe requests navigation; it does not force a controller pop.
            method = "edgeSwipe"
            let start = CGPoint(x: window.bounds.minX + 1, y: window.bounds.midY)
            let end = CGPoint(x: window.bounds.minX + window.bounds.width * 0.8, y: start.y)
            try await send(in: window, from: start, to: end, duration: 0.4, edge: true)
        case "input":
            guard let text = input["text"]?.stringValue, let editor = object as? UIView & UITextInput,
                  let keyInput = object as? UIKeyInput else {
                throw unavailable("This target does not support text input")
            }
            let mode = input["mode"]?.stringValue ?? "replace"
            guard mode == "replace" || mode == "append" else {
                throw NectoBridgeError(code: .invalidInput, message: "Choose replace or append")
            }
            method = "textInput"
            try await send(in: window, from: center, to: center, duration: 0.08)
            try await Task.sleep(for: .milliseconds(250))
            guard editor.isFirstResponder, editor.window === window else {
                throw unavailable("The text field did not receive focus. Refresh Control before acting.")
            }
            let start = mode == "replace" ? editor.beginningOfDocument : editor.endOfDocument
            guard let range = editor.textRange(from: start, to: editor.endOfDocument) else {
                throw unavailable("The text field did not provide an editable range")
            }
            editor.selectedTextRange = range
            if mode == "replace", text.isEmpty { keyInput.deleteBackward() }
            else { keyInput.insertText(text) }
        default:
            throw unavailable("This operation is not supported")
        }
        try await Task.sleep(for: .milliseconds(600))
        return ["dispatched": true, "method": .string(method),
                "contentChanged": .bool(before != readAccessibility().map(\.json))]
    }

    private func send(in window: UIWindow, from start: CGPoint, to end: CGPoint,
                      duration: TimeInterval, edge: Bool = false) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NectoTouchInjector.send(in: window, from: start, to: end, duration: duration, edge: edge) { error in
                if let error { continuation.resume(throwing: NectoBridgeError(code: .operationUnavailable, message: error)) }
                else { continuation.resume() }
            }
        }
    }

    private func unavailable(_ message: String) -> NectoBridgeError {
        NectoBridgeError(code: .operationUnavailable, message: message)
    }
}
#endif
