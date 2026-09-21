//
//  Copyright (c) 2026 Viva Republica, Inc.
//

#if canImport(UIKit)
import UIKit

@MainActor
enum NectoAccessibilityReader {
    static func read(in window: UIWindow) -> [NectoAccessibilityItem] {
        var items: [NectoAccessibilityItem] = []
        var visited: Set<ObjectIdentifier> = []

        func walk(_ object: NSObject, owner: UIView) {
            guard visited.insert(ObjectIdentifier(object)).inserted else { return }
            let view = object as? UIView
            let container = view ?? owner
            guard isVisible(container, in: window), !object.accessibilityElementsHidden else { return }

            let field = view as? UITextField
            let textView = view as? UITextView
            let secure = field?.isSecureTextEntry ?? textView?.isSecureTextEntry ?? false
            if object.isAccessibilityElement {
                let frame: CGRect
                if let view {
                    frame = view.convert(view.bounds, to: window)
                } else {
                    frame = window.convert(object.accessibilityFrame, from: window.screen.coordinateSpace)
                }
                let bounds = clipped(frame, owner: container, in: window)
                if bounds.width > 1, bounds.height > 1, !bounds.isNull,
                   let hit = window.hitTest(CGPoint(x: bounds.midX, y: bounds.midY), with: nil),
                   hit === container || hit.isDescendant(of: container) || container.isDescendant(of: hit) {
                    let label = object.accessibilityLabel
                    let value = secure ? nil : object.accessibilityValue
                    let identifier = identifier(of: object)
                    if label != nil || value != nil || identifier != nil {
                        items.append(NectoAccessibilityItem(
                            role: role(of: object), label: label, identifier: identifier,
                            value: value, isSecure: secure
                        ))
                    }
                }
                // Secure fields and accessibility elements own their descendants.
                return
            }

            if secure { return }
            if let children = object.accessibilityElements {
                for case let child as NSObject in children { walk(child, owner: container) }
                return
            }
            let count = object.accessibilityElementCount()
            if count > 0, count != NSNotFound {
                for index in 0..<count {
                    if let child = object.accessibilityElement(at: index) as? NSObject {
                        walk(child, owner: container)
                    }
                }
                return
            }
            for child in view?.subviews ?? [] { walk(child, owner: container) }
        }

        walk(window, owner: window)
        return items
    }

    static func identifier(of object: NSObject) -> String? {
        // SwiftUI's virtual elements expose this public getter without necessarily
        // subclassing UIAccessibilityElement or declaring the identification protocol.
        let selector = NSSelectorFromString("accessibilityIdentifier")
        guard object.responds(to: selector) else { return nil }
        return object.perform(selector)?.takeUnretainedValue() as? String
    }

    private static func isVisible(_ view: UIView, in window: UIWindow) -> Bool {
        guard view.window === window || view === window else { return false }
        var ancestor: UIView? = view
        while let current = ancestor {
            if current.isHidden || current.alpha < 0.01 || current.accessibilityElementsHidden { return false }
            ancestor = current.superview
        }
        return true
    }

    private static func clipped(_ frame: CGRect, owner: UIView, in window: UIWindow) -> CGRect {
        var result = frame.intersection(window.bounds)
        var ancestor: UIView? = owner
        while let current = ancestor {
            if current.clipsToBounds {
                result = result.intersection(current.convert(current.bounds, to: window))
            }
            ancestor = current.superview
        }
        return result
    }

    private static func role(of object: NSObject) -> String {
        if object is UITextField || object is UITextView { return "textInput" }
        let traits = object.accessibilityTraits
        if traits.contains(.header) { return "heading" }
        if traits.contains(.link) { return "link" }
        if traits.contains(.button) || object is UIButton { return "button" }
        if traits.contains(.image) { return "image" }
        if traits.contains(.adjustable) { return "adjustable" }
        if traits.contains(.staticText) || object is UILabel { return "text" }
        return "element"
    }
}
#endif
