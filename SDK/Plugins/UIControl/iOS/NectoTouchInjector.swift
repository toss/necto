//
//  Copyright (c) 2026 Viva Republica, Inc.
//

#if canImport(UIKit)
import Darwin
import UIKit

@MainActor
enum NectoTouchInjector {
    static let defaultDragSteps = 12
    static let defaultDragDuration = 0.28
    static let defaultSwipeBackSteps = 50
    static let defaultSwipeBackDuration = 0.85

    private static let objcSend = NectoRuntimeSymbols.symbol("objc_msgSend")
    private static let createDigitizerEvent = NectoRuntimeSymbols.symbol("IOHIDEventCreateDigitizerEvent")
    private static let createFingerEvent = NectoRuntimeSymbols.symbol("IOHIDEventCreateDigitizerFingerEvent")
    private static let createFingerEventWithQuality = NectoRuntimeSymbols.symbol("IOHIDEventCreateDigitizerFingerEventWithQuality")
    private static let setHIDIntegerValue = NectoRuntimeSymbols.symbol("IOHIDEventSetIntegerValue")
    private static let appendHIDEvent = NectoRuntimeSymbols.symbol("IOHIDEventAppendEvent")
    private static let enableAccessibility = NectoRuntimeSymbols.symbol("_AXSApplicationAccessibilitySetEnabled")
    private static var busy = false
    private static var accessibilityPrepared = false

    static func prepareAccessibility() {
        guard !accessibilityPrepared, let enableAccessibility else { return }
        // SwiftUI's virtual accessibility elements are unavailable until AX is enabled for the app.
        unsafeBitCast(enableAccessibility, to: (@convention(c) (Bool) -> Void).self)(true)
        accessibilityPrepared = true
    }

    static var isAvailable: Bool {
        objcSend != nil && createFingerEvent != nil && NSClassFromString("UITouch") != nil
    }

    static var unavailableReason: String {
        if objcSend == nil { return "objc_msgSend is unavailable" }
        if createFingerEvent == nil { return "IOHIDEventCreateDigitizerFingerEvent is unavailable" }
        if NSClassFromString("UITouch") == nil { return "UITouch runtime class is unavailable" }
        return "Runtime touch injection failed"
    }

    static func tap(points: [CGPoint], in window: UIWindow, tapCount: Int = 1) async throws -> Bool {
        try Task.checkCancellation()
        guard !busy, (1...5).contains(points.count), (1...3).contains(tapCount) else { return false }
        busy = true
        defer { busy = false }
        var touches: [NSObject] = []
        for point in points {
            guard let touch = makeTouch(window: window, point: point, phase: .began,
                                        isFirstTouch: true, isTap: true) else { return false }
            touches.append(touch)
        }
        var active = false
        defer {
            if active { _ = send(touches: touches, phase: .cancelled, points: points, resetPrevious: false) }
        }
        for index in 1...tapCount {
            guard send(touches: touches, phase: .began, points: points, resetPrevious: true, tapCount: index) else { return false }
            active = true
            try await Task.sleep(for: .milliseconds(25))
            guard send(touches: touches, phase: .ended, points: points, resetPrevious: false, tapCount: index) else { return false }
            active = false
            if index < tapCount { try await Task.sleep(for: .milliseconds(100)) }
        }
        return true
    }

    static func drag(from start: CGPoint, to end: CGPoint, in window: UIWindow,
                     steps: Int? = nil, duration: Double? = nil, isFromEdge: Bool = false) async throws -> Bool {
        try Task.checkCancellation()
        guard !busy else { return false }
        busy = true
        defer { busy = false }
        guard let touch = makeTouch(window: window, point: start, phase: .began,
                                    isFirstTouch: true, isTap: false, isFromEdge: isFromEdge) else { return false }
        let stepCount = max(1, steps ?? defaultDragSteps)
        let totalDuration = max(0.01, duration ?? defaultDragDuration)
        let delay = totalDuration / Double(stepCount)
        guard send(touches: [touch], phase: .began, points: [start], resetPrevious: true) else { return false }
        var active = true
        var point = start
        defer {
            if active { _ = send(touches: [touch], phase: .cancelled, points: [point], resetPrevious: false) }
        }
        for index in 1...stepCount {
            // Yield the main actor so app work scheduled by earlier touch handlers can run.
            try await Task.sleep(for: .seconds(delay))
            let progress = CGFloat(index) / CGFloat(stepCount)
            point = CGPoint(x: start.x + (end.x - start.x) * progress,
                            y: start.y + (end.y - start.y) * progress)
            guard send(touches: [touch], phase: index == stepCount ? .ended : .moved,
                       points: [point], resetPrevious: false) else { return false }
        }
        active = false
        return true
    }

    private static func makeTouch(window: UIWindow, point: CGPoint, phase: UITouch.Phase,
                                  isFirstTouch: Bool, isTap: Bool, isFromEdge: Bool = false) -> NSObject? {
        guard isAvailable, let touchClass = NSClassFromString("UITouch") as? NSObject.Type else { return nil }
        let touch = touchClass.init()
        let required = ["setWindow:", "setView:", "setTapCount:", "setTimestamp:", "setPhase:",
                        "_setLocationInWindow:resetPrevious:", "_setIsFirstTouchForView:", "_setHidEvent:"]
        guard required.allSatisfy({ touch.responds(to: NSSelectorFromString($0)) }),
              !isFromEdge || touch.responds(to: NSSelectorFromString("_setEdgeType:")) else { return nil }
        let view = window.hitTest(point, with: nil) ?? window
        setObject(touch, selector: "setWindow:", value: window)
        setObject(touch, selector: "setView:", value: view)
        setInteger(touch, selector: "setTapCount:", value: 1)
        setBoolIfResponds(touch, selector: "setIsTap:", value: isTap)
        setDouble(touch, selector: "setTimestamp:", value: ProcessInfo.processInfo.systemUptime)
        setInteger(touch, selector: "setPhase:", value: phase.rawValue)
        setPoint(touch, selector: "_setLocationInWindow:resetPrevious:", point: point, resetPrevious: true)
        setBool(touch, selector: "_setIsFirstTouchForView:", value: isFirstTouch)
        setIntegerIfResponds(touch, selector: "_setEdgeType:", value: isFromEdge ? 4 : 0)
        setObjectIfResponds(touch, selector: "setGestureView:", value: view)
        setGestureResponder(touch, hit: view, point: point)
        return touch
    }

    private static func setGestureResponder(_ touch: NSObject, hit: UIView, point: CGPoint) {
        guard let objcSend, let contextClass = NSClassFromString("_UIHitTestContext"),
              class_getClassMethod(contextClass, NSSelectorFromString("contextWithPoint:radius:")) != nil,
              touch.responds(to: NSSelectorFromString("_setResponder:")) else { return }
        typealias MakeContext = @convention(c) (AnyObject, Selector, CGPoint, CGFloat) -> Unmanaged<AnyObject>?
        typealias HitTest = @convention(c) (AnyObject, Selector, AnyObject) -> Unmanaged<AnyObject>?
        let make = unsafeBitCast(objcSend, to: MakeContext.self)
        guard let context = make(contextClass, NSSelectorFromString("contextWithPoint:radius:"), point, 0)?.takeUnretainedValue() else { return }
        let resolve = unsafeBitCast(objcSend, to: HitTest.self)
        var candidate: UIView? = hit
        // SwiftUI may handle a touch through a responder outside the hit UIView.
        while let view = candidate {
            if view.responds(to: NSSelectorFromString("_hitTestWithContext:")),
               let responder = resolve(view, NSSelectorFromString("_hitTestWithContext:"), context)?.takeUnretainedValue() {
                setObject(touch, selector: "_setResponder:", value: responder)
                return
            }
            candidate = view.superview
        }
    }

    private struct HIDFrame {
        let event: UnsafeMutableRawPointer
        // Composite events retain their children; these pointers stay valid until event is released.
        let fingers: [UnsafeMutableRawPointer]
    }

    private static func send(touches: [NSObject], phase: UITouch.Phase, points: [CGPoint],
                             resetPrevious: Bool, tapCount: Int = 1) -> Bool {
        let app = UIApplication.shared
        guard app.responds(to: NSSelectorFromString("_touchesEvent")),
              let event = getObject(app, selector: "_touchesEvent") as? UIEvent,
              ["_clearTouches", "_addTouch:forDelayedDelivery:", "_setHIDEvent:"].allSatisfy({
                  event.responds(to: NSSelectorFromString($0))
              }), let hid = makeHIDEvent(points: points, phase: phase) else { return false }
        defer {
            sendVoid(event, selector: "_clearTouches")
            setRawPointer(event, selector: "_setHIDEvent:", value: nil)
            Unmanaged<CFTypeRef>.fromOpaque(hid.event).release()
        }
        sendVoid(event, selector: "_clearTouches")
        for (index, touch) in touches.enumerated() {
            setDouble(touch, selector: "setTimestamp:", value: ProcessInfo.processInfo.systemUptime)
            setInteger(touch, selector: "setPhase:", value: phase.rawValue)
            setInteger(touch, selector: "setTapCount:", value: tapCount)
            setPoint(touch, selector: "_setLocationInWindow:resetPrevious:", point: points[index], resetPrevious: resetPrevious)
            setRawPointer(touch, selector: "_setHidEvent:", value: touches.count == 1 ? hid.event : hid.fingers[index])
            sendObjectBool(event, selector: "_addTouch:forDelayedDelivery:", value: touch, flag: false)
        }
        // Deliver every contact in one event so multi-finger recognizers see simultaneous touches.
        setRawPointer(event, selector: "_setHIDEvent:", value: hid.event)
        UIApplication.shared.sendEvent(event)
        return true
    }

    private static func makeHIDEvent(points: [CGPoint], phase: UITouch.Phase) -> HIDFrame? {
        if let event = makeCompositeHIDEvent(points: points, phase: phase) { return event }
        guard points.count == 1, let event = makeFingerHIDEvent(point: points[0], phase: phase) else { return nil }
        return HIDFrame(event: event, fingers: [event])
    }

    private static func makeCompositeHIDEvent(points: [CGPoint], phase: UITouch.Phase) -> HIDFrame? {
        guard let createDigitizerEvent, let createFingerEventWithQuality,
              let setHIDIntegerValue, let appendHIDEvent else { return nil }
        typealias CreateDigitizerEvent = @convention(c) (CFAllocator?, UInt64, UInt32, UInt32, UInt32, UInt32, UInt32,
                                                        Double, Double, Double, Double, Double, UInt8, UInt8, UInt32) -> UnsafeMutableRawPointer?
        typealias CreateFingerEventWithQuality = @convention(c) (CFAllocator?, UInt64, UInt32, UInt32, UInt32,
                                                                Double, Double, Double, Double, Double,
                                                                Double, Double, Double, Double, Double,
                                                                UInt8, UInt8, UInt32) -> UnsafeMutableRawPointer?
        typealias SetIntegerValue = @convention(c) (UnsafeMutableRawPointer, UInt32, Int32) -> Void
        typealias AppendEvent = @convention(c) (UnsafeMutableRawPointer, UnsafeMutableRawPointer, UInt32) -> Void
        let createDigitizer = unsafeBitCast(createDigitizerEvent, to: CreateDigitizerEvent.self)
        let createFinger = unsafeBitCast(createFingerEventWithQuality, to: CreateFingerEventWithQuality.self)
        let setInteger = unsafeBitCast(setHIDIntegerValue, to: SetIntegerValue.self)
        let append = unsafeBitCast(appendHIDEvent, to: AppendEvent.self)
        let active: UInt8 = (phase == .ended || phase == .cancelled) ? 0 : 1
        let time = mach_absolute_time()
        guard let event = createDigitizer(kCFAllocatorDefault, time, NectoHIDDigitizer.transducerHand,
                                          0, 0, NectoHIDDigitizer.maskTouch, 0, 0, 0, 0, 0, 0, 0, 1, 0) else { return nil }
        setInteger(event, NectoHIDDigitizer.fieldIsDisplayIntegrated, 1)
        var fingers: [UnsafeMutableRawPointer] = []
        for (index, point) in points.enumerated() {
            guard let finger = createFinger(kCFAllocatorDefault, time, UInt32(index + 1), UInt32(index + 2),
                                            NectoHIDDigitizer.eventMask(for: phase), point.x, point.y,
                                            0, 0, 0, 5, 5, 1, 1, 1, active, active, 0) else {
                Unmanaged<CFTypeRef>.fromOpaque(event).release()
                return nil
            }
            setInteger(finger, NectoHIDDigitizer.fieldIsDisplayIntegrated, 1)
            append(event, finger, 0)
            fingers.append(finger)
            Unmanaged<CFTypeRef>.fromOpaque(finger).release()
        }
        return HIDFrame(event: event, fingers: fingers)
    }

    private static func makeFingerHIDEvent(point: CGPoint, phase: UITouch.Phase) -> UnsafeMutableRawPointer? {
        guard let createFingerEvent else { return nil }
        typealias CreateFingerEvent = @convention(c) (CFAllocator?, UInt64, UInt32, UInt32, UInt32,
                                                     Double, Double, Double, Double, Double, Bool, Bool, UInt32) -> UnsafeMutableRawPointer?
        let create = unsafeBitCast(createFingerEvent, to: CreateFingerEvent.self)
        let active = phase != .ended && phase != .cancelled
        return create(kCFAllocatorDefault, mach_absolute_time(), 0, 2, NectoHIDDigitizer.eventMask(for: phase),
                      point.x, point.y, 0, 0, 0, active, active, 0)
    }

    private static func getObject(_ object: AnyObject, selector name: String) -> AnyObject? {
        guard let objcSend else { return nil }
        typealias Function = @convention(c) (AnyObject, Selector) -> AnyObject?
        let function = unsafeBitCast(objcSend, to: Function.self)
        return function(object, NSSelectorFromString(name))
    }

    private static func sendVoid(_ object: AnyObject, selector name: String) {
        guard let objcSend else { return }
        typealias Function = @convention(c) (AnyObject, Selector) -> Void
        let function = unsafeBitCast(objcSend, to: Function.self)
        function(object, NSSelectorFromString(name))
    }

    private static func setObject(_ object: AnyObject, selector name: String, value: AnyObject?) {
        guard let objcSend else { return }
        typealias Function = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
        let function = unsafeBitCast(objcSend, to: Function.self)
        function(object, NSSelectorFromString(name), value)
    }

    private static func setRawPointer(_ object: AnyObject, selector name: String, value: UnsafeMutableRawPointer?) {
        guard let objcSend else { return }
        typealias Function = @convention(c) (AnyObject, Selector, UnsafeMutableRawPointer?) -> Void
        let function = unsafeBitCast(objcSend, to: Function.self)
        function(object, NSSelectorFromString(name), value)
    }

    private static func setInteger(_ object: AnyObject, selector name: String, value: Int) {
        guard let objcSend else { return }
        typealias Function = @convention(c) (AnyObject, Selector, Int) -> Void
        let function = unsafeBitCast(objcSend, to: Function.self)
        function(object, NSSelectorFromString(name), value)
    }

    private static func setDouble(_ object: AnyObject, selector name: String, value: Double) {
        guard let objcSend else { return }
        typealias Function = @convention(c) (AnyObject, Selector, Double) -> Void
        let function = unsafeBitCast(objcSend, to: Function.self)
        function(object, NSSelectorFromString(name), value)
    }

    private static func setBool(_ object: AnyObject, selector name: String, value: Bool) {
        guard let objcSend else { return }
        typealias Function = @convention(c) (AnyObject, Selector, Bool) -> Void
        let function = unsafeBitCast(objcSend, to: Function.self)
        function(object, NSSelectorFromString(name), value)
    }

    private static func setObjectIfResponds(_ object: NSObject, selector name: String, value: AnyObject?) {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector) else { return }
        setObject(object, selector: name, value: value)
    }

    private static func setBoolIfResponds(_ object: NSObject, selector name: String, value: Bool) {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector) else { return }
        setBool(object, selector: name, value: value)
    }

    private static func setIntegerIfResponds(_ object: NSObject, selector name: String, value: Int) {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector) else { return }
        setInteger(object, selector: name, value: value)
    }

    private static func setPoint(_ object: AnyObject, selector name: String, point: CGPoint, resetPrevious: Bool) {
        guard let objcSend else { return }
        typealias Function = @convention(c) (AnyObject, Selector, CGPoint, Bool) -> Void
        let function = unsafeBitCast(objcSend, to: Function.self)
        function(object, NSSelectorFromString(name), point, resetPrevious)
    }

    private static func sendObjectBool(_ object: AnyObject, selector name: String, value: AnyObject, flag: Bool) {
        guard let objcSend else { return }
        typealias Function = @convention(c) (AnyObject, Selector, AnyObject, Bool) -> Void
        let function = unsafeBitCast(objcSend, to: Function.self)
        function(object, NSSelectorFromString(name), value, flag)
    }
}

private enum NectoHIDDigitizer {
    static let transducerHand: UInt32 = 3
    static let maskRange: UInt32 = 0x0000_0001
    static let maskTouch: UInt32 = 0x0000_0002
    static let maskPosition: UInt32 = 0x0000_0004
    static let eventTypeDigitizer: UInt32 = 11
    static let fieldIsDisplayIntegrated: UInt32 = (eventTypeDigitizer << 16) + 25

    static func eventMask(for phase: UITouch.Phase) -> UInt32 {
        phase == .moved ? maskPosition : (maskRange | maskTouch)
    }
}

@MainActor
private enum NectoRuntimeSymbols {
    static func symbol(_ name: String) -> UnsafeMutableRawPointer? {
        if let handle = dlopen(nil, RTLD_NOW), let symbol = dlsym(handle, name) {
            return symbol
        }
        for path in [
            "/System/Library/Frameworks/IOKit.framework/IOKit",
            "/System/Library/PrivateFrameworks/IOKit.framework/IOKit"
        ] {
            if let handle = dlopen(path, RTLD_NOW), let symbol = dlsym(handle, name) {
                return symbol
            }
        }
        return nil
    }
}

#endif
