//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import Foundation
import ObjectiveC

/// Observes the original transfer; never reissues requests or changes delegates.
/// Private selectors stay in this optional capture module.
enum NectoURLSessionHooks {
    static func install() { _ = installed }

    // Swift's static initialization installs once, including concurrent callers.
    private static let installed: Void = {
        let hooks = Installer()
        for name in ["NSURLSessionTask", "__NSCFLocalSessionTask", "__NSCFLocalDataTask",
                     "__NSCFLocalDownloadTask", "__NSCFURLSessionTask", "NWURLSessionTask"] {
            hooks.resume(name)
        }
        for name in ["__NSCFLocalSessionTask", "__NSCFLocalDataTask", "__NSCFLocalDownloadTask"] {
            hooks.classicTask(name)
        }
        for name in ["NWURLSessionResponseConsumerDataCompletionHandler",
                     "NWURLSessionResponseConsumerDataDelegate", "NWURLSessionResponseConsumerDownload"] {
            hooks.networkConsumer(name)
        }
        for name in ["NSURLSession", "NWURLSession"] { hooks.taskCreation(name) }
    }()

    private final class Installer {
        private var replaced = Set<OpaquePointer>()

        /// Reject absent or incompatible methods before casting an IMP. An OS can
        /// still change a method's meaning without changing its ABI.
        private func method(_ name: String, _ selector: Selector, returns: Character, arguments: [Character]) -> Method? {
            guard let cls = NSClassFromString(name), let method = class_getInstanceMethod(cls, selector),
                  !replaced.contains(method), method_getNumberOfArguments(method) == arguments.count + 2 else { return nil }
            let result = method_copyReturnType(method)
            defer { free(result) }
            guard String(cString: result).first == returns else { return nil }
            for (index, expected) in arguments.enumerated() {
                guard let type = method_copyArgumentType(method, UInt32(index + 2)) else { return nil }
                defer { free(type) }
                guard String(cString: type).first == expected else { return nil }
            }
            replaced.insert(method)
            return method
        }

        func resume(_ name: String) {
            let selector = #selector(URLSessionTask.resume)
            guard let method = method(name, selector, returns: "v", arguments: []) else { return }
            typealias Call = @convention(c) (AnyObject, Selector) -> Void
            let original = unsafeBitCast(method_getImplementation(method), to: Call.self)
            let block: @convention(block) (AnyObject) -> Void = { object in
                if let task = object as? URLSessionTask { NectoSessionRecorder.shared.resume(task) }
                original(object, selector)
            }
            method_setImplementation(method, imp_implementationWithBlock(block))
        }

        func classicTask(_ name: String) {
            // Observe delivery to the task, after the connection's content sniffing
            // has finished. Hooking _didReceiveData: counts replayed sniff data twice.
            for (selectorName, isData) in [("connection:didReceiveData:completion:", true),
                                           ("connection:didReceiveResponse:completion:", false)] {
                let selector = NSSelectorFromString(selectorName)
                guard let method = method(name, selector, returns: "v", arguments: ["@", "@", "@"]) else { continue }
                typealias Call = @convention(c) (AnyObject, Selector, AnyObject?, AnyObject?, AnyObject?) -> Void
                let original = unsafeBitCast(method_getImplementation(method), to: Call.self)
                let block: @convention(block) (AnyObject, AnyObject?, AnyObject?, AnyObject?) -> Void = { object, connection, value, completion in
                    if let task = object as? URLSessionTask {
                        NectoSessionRecorder.shared.receive(task, data: isData ? value as? Data : nil,
                                                           response: isData ? nil : value as? URLResponse)
                    }
                    original(object, selector, connection, value, completion)
                }
                method_setImplementation(method, imp_implementationWithBlock(block))
            }
            let selector = NSSelectorFromString("connection:didFinishLoadingWithError:")
            if let method = method(name, selector, returns: "v", arguments: ["@", "@"]) {
                typealias Call = @convention(c) (AnyObject, Selector, AnyObject?, AnyObject?) -> Void
                let original = unsafeBitCast(method_getImplementation(method), to: Call.self)
                let block: @convention(block) (AnyObject, AnyObject?, AnyObject?) -> Void = { object, connection, error in
                    if let task = object as? URLSessionTask {
                        NectoSessionRecorder.shared.complete(task, error: error as? Error)
                    }
                    original(object, selector, connection, error)
                }
                method_setImplementation(method, imp_implementationWithBlock(block))
            }
        }

        func networkConsumer(_ name: String) {
            let responseSelector = NSSelectorFromString("task:deliverResponse:completionHandler:")
            if let method = method(name, responseSelector, returns: "v", arguments: ["@", "@", "@"]) {
                typealias Call = @convention(c) (AnyObject, Selector, AnyObject?, AnyObject?, AnyObject?) -> Void
                let original = unsafeBitCast(method_getImplementation(method), to: Call.self)
                let block: @convention(block) (AnyObject, AnyObject?, AnyObject?, AnyObject?) -> Void = { object, task, response, handler in
                    if let task = task as? URLSessionTask {
                        NectoSessionRecorder.shared.receive(task, response: response as? URLResponse)
                    }
                    original(object, responseSelector, task, response, handler)
                }
                method_setImplementation(method, imp_implementationWithBlock(block))
            }
            let dataSelector = NSSelectorFromString("task:deliverData:complete:error:completionHandler:")
            if let method = method(name, dataSelector, returns: "v", arguments: ["@", "@", "B", "@", "@"]) {
                typealias Call = @convention(c) (AnyObject, Selector, AnyObject?, AnyObject?, Bool, AnyObject?, AnyObject?) -> Void
                let original = unsafeBitCast(method_getImplementation(method), to: Call.self)
                let block: @convention(block) (AnyObject, AnyObject?, AnyObject?, Bool, AnyObject?, AnyObject?) -> Void = { object, task, data, complete, error, handler in
                    if let task = task as? URLSessionTask {
                        NectoSessionRecorder.shared.receive(task, data: data as? Data)
                        if complete { NectoSessionRecorder.shared.complete(task, error: error as? Error) }
                    }
                    original(object, dataSelector, task, data, complete, error, handler)
                }
                method_setImplementation(method, imp_implementationWithBlock(block))
            }
        }

        func taskCreation(_ name: String) {
            // Async uploads use the private delegate variant instead of the public
            // completion-handler API. Arguments and returned tasks are unchanged.
            for selectorName in ["dataTaskWithRequest:", "dataTaskWithRequest:completionHandler:",
                                 "_dataTaskWithRequest:delegate:", "_dataTaskWithRequest:delegate:completionHandler:",
                                 "uploadTaskWithRequest:fromData:", "uploadTaskWithRequest:fromData:completionHandler:",
                                 "_uploadTaskWithRequest:fromData:delegate:completionHandler:"] {
                let selector = NSSelectorFromString(selectorName)
                let count = selectorName.filter { $0 == ":" }.count
                guard let method = method(name, selector, returns: "@", arguments: Array(repeating: "@", count: count)) else { continue }
                let implementation = method_getImplementation(method)
                let upload = selectorName.contains("fromData:")
                switch count {
                case 1:
                    typealias Call = @convention(c) (AnyObject, Selector, AnyObject) -> AnyObject
                    let original = unsafeBitCast(implementation, to: Call.self)
                    let block: @convention(block) (AnyObject, AnyObject) -> AnyObject = { object, request in
                        let task = original(object, selector, request)
                        Self.prepare(task, request: request)
                        return task
                    }
                    method_setImplementation(method, imp_implementationWithBlock(block))
                case 2:
                    typealias Call = @convention(c) (AnyObject, Selector, AnyObject, AnyObject?) -> AnyObject
                    let original = unsafeBitCast(implementation, to: Call.self)
                    let block: @convention(block) (AnyObject, AnyObject, AnyObject?) -> AnyObject = { object, request, arg in
                        let task = original(object, selector, request, arg)
                        Self.prepare(task, request: request, body: upload ? arg as? Data : nil)
                        return task
                    }
                    method_setImplementation(method, imp_implementationWithBlock(block))
                case 3:
                    typealias Call = @convention(c) (AnyObject, Selector, AnyObject, AnyObject?, AnyObject?) -> AnyObject
                    let original = unsafeBitCast(implementation, to: Call.self)
                    let block: @convention(block) (AnyObject, AnyObject, AnyObject?, AnyObject?) -> AnyObject = { object, request, arg, handler in
                        let task = original(object, selector, request, arg, handler)
                        Self.prepare(task, request: request, body: upload ? arg as? Data : nil)
                        return task
                    }
                    method_setImplementation(method, imp_implementationWithBlock(block))
                case 4:
                    typealias Call = @convention(c) (AnyObject, Selector, AnyObject, AnyObject?, AnyObject?, AnyObject?) -> AnyObject
                    let original = unsafeBitCast(implementation, to: Call.self)
                    let block: @convention(block) (AnyObject, AnyObject, AnyObject?, AnyObject?, AnyObject?) -> AnyObject = { object, request, data, delegate, handler in
                        let task = original(object, selector, request, data, delegate, handler)
                        Self.prepare(task, request: request, body: data as? Data)
                        return task
                    }
                    method_setImplementation(method, imp_implementationWithBlock(block))
                default: break
                }
            }
        }

        private static func prepare(_ object: AnyObject, request: AnyObject, body: Data? = nil) {
            if let task = object as? URLSessionTask, let request = request as? URLRequest {
                NectoSessionRecorder.shared.prepare(task, request: request, body: body)
            }
        }
    }
}
