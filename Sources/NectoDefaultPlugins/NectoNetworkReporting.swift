//
//  Copyright (c) 2026 Viva Republica, Inc.
//

/// Somewhere to report a request to.
///
/// A capture mechanism talks to this rather than to `DefaultNetworkPlugin`, so an app
/// whose traffic is encrypted, tunnelled or otherwise unreachable from `URLSession` can
/// report from wherever it already knows about a request, and a test can stand in for
/// the whole thing.
public protocol NectoNetworkReporting: AnyObject, Sendable {
    func report(_ record: NectoNetworkRecord)
}
