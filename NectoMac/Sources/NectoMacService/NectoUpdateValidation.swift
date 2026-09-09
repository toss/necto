//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import Foundation
import NectoModel

/// Checks bundle integrity and compatibility. The release repository is the trust source;
/// an ad-hoc signature does not authenticate a publisher.
public enum NectoUpdateValidation {
    public static func verify(candidate: URL, installed: URL, expectedVersion: NectoSemanticVersion) async throws {
        let installedInfo = try info(at: installed)
        let candidateInfo = try info(at: candidate)
        try validateMetadata(installed: installedInfo, candidate: candidateInfo, expectedVersion: expectedVersion)

        try await check("/usr/bin/codesign", [
            "--verify", "--deep", "--strict", "--all-architectures", candidate.path,
        ])
    }

    static func validateMetadata(
        installed: [String: Any], candidate: [String: Any], expectedVersion: NectoSemanticVersion
    ) throws {
        guard let identifier = installed["CFBundleIdentifier"] as? String, !identifier.isEmpty,
              candidate["CFBundleIdentifier"] as? String == identifier,
              candidate["CFBundleShortVersionString"] as? String == expectedVersion.description,
              let current = (installed["CFBundleShortVersionString"] as? String).flatMap(NectoSemanticVersion.init),
              expectedVersion > current else { throw Failure.wrongApplication }
    }

    private static func info(at app: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: app.appending(path: "Contents/Info.plist"))
        guard let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw Failure.wrongApplication
        }
        return info
    }

    private static func check(_ path: String, _ arguments: [String]) async throws {
        let output = try await NectoProcessRunner.run(path, arguments: arguments)
        guard output.exitCode == 0 else { throw Failure.invalidSignature }
    }

    public enum Failure: Error, Equatable {
        case invalidSignature
        case wrongApplication
    }
}
