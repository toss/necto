//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import Foundation

/// Semantic version used to compare plugin `version` values.
///
/// Prerelease and build metadata are parsed but ignored when ordering.
/// Compatibility gating only needs major, minor and patch.
public struct NectoSemanticVersion: Sendable, Hashable, Comparable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int
    public let prerelease: String?
    public let build: String?

    public init(major: Int, minor: Int, patch: Int, prerelease: String? = nil, build: String? = nil) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
        self.build = build
    }

    public init?(_ text: String) {
        var body = Substring(text)

        var build: String?
        if let plusIndex = body.firstIndex(of: "+") {
            build = String(body[body.index(after: plusIndex)...])
            body = body[..<plusIndex]
            if build?.isEmpty == true { return nil }
        }

        var prerelease: String?
        if let dashIndex = body.firstIndex(of: "-") {
            prerelease = String(body[body.index(after: dashIndex)...])
            body = body[..<dashIndex]
            if prerelease?.isEmpty == true { return nil }
        }

        let parts = body.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }

        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy(\.isNumber), let number = Int(part) else { return nil }
            if part.count > 1, part.first == "0" { return nil }
            numbers.append(number)
        }

        self.init(
            major: numbers[0],
            minor: numbers[1],
            patch: numbers[2],
            prerelease: prerelease,
            build: build
        )
    }

    public var description: String {
        var text = "\(major).\(minor).\(patch)"
        if let prerelease { text += "-\(prerelease)" }
        if let build { text += "+\(build)" }
        return text
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}
