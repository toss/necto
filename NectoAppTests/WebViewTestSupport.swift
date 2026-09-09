//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import Foundation
import WebKit

@MainActor
func withTestWebsiteDataStore(_ body: (WKWebsiteDataStore) async throws -> Void) async throws {
    let identifier = UUID()
    var dataStore: WKWebsiteDataStore? = WKWebsiteDataStore(forIdentifier: identifier)
    let result: Result<Void, any Error>
    do {
        try await body(dataStore!)
        result = .success(())
    } catch {
        result = .failure(error)
    }
    await dataStore!.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
    dataStore = nil
    // WebKit releases its store after pending page teardown completes.
    let deadline = ContinuousClock.now + .seconds(5)
    while true {
        do {
            try await WKWebsiteDataStore.remove(forIdentifier: identifier)
            break
        } catch {
            guard ContinuousClock.now < deadline else { throw error }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
    try result.get()
}
