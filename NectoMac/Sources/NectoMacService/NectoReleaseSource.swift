//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import Foundation
import NectoModel

/// Reads a repository's releases, and takes a plugin out of one.
///
/// A published plugin is a folder with `manifest.json` at its root, zipped and
/// attached to a release. Nothing here requires it to be named a particular way or
/// to have been produced by our tooling: an author with `zip` and `gh` can publish
/// one, which is the only version of this an author on someone else's build system can
/// use.
///
/// What a release offers is read before anything large is downloaded. A release that
/// carries a manifest beside each archive can be described exactly; one that carries
/// only archives is still installable, it just cannot be described until a choice is
/// made. Both cases have to work, because only one of them is under our control.
public enum NectoReleaseSource {
    /// The public host is the one that answers without credentials. Everything else —
    /// an Enterprise install, a private repository — needs the developer's own login,
    /// and `gh` is where that already lives.
    static let publicHost = "github.com"

    public struct Repository: Equatable, Sendable {
        public let host: String
        public let owner: String
        public let name: String
        /// Nil asks for whatever is newest.
        public let tag: String?

        public init(host: String, owner: String, name: String, tag: String? = nil) {
            self.host = host
            self.owner = owner
            self.name = name
            self.tag = tag
        }

        public var label: String { "\(host)/\(owner)/\(name)" }

        var isPublic: Bool { host == NectoReleaseSource.publicHost }

        /// GitHub's own API lives on a separate host; every Enterprise install serves
        /// it from `/api/v3` on its own.
        var apiRoot: String {
            isPublic ? "https://api.github.com" : "https://\(host)/api/v3"
        }

        /// Every part of an address ends up in a request path, so every part is escaped
        /// into one segment. Leaving any of them interpolated makes the guarantee an
        /// accident of what the validator happened to allow.
        func apiPath(_ trailing: String?) -> String {
            let base = "repos/\(NectoReleaseSource.encoded(owner))/\(NectoReleaseSource.encoded(name))"
            return trailing.map { "\(base)/\($0)" } ?? base
        }
    }

    /// One installable thing in a release.
    public struct Offer: Equatable, Sendable, Identifiable {
        public let assetName: String
        public let downloadURL: URL
        /// Read from a manifest published beside the archive, when there is one. It is
        /// what lets a choice be made without downloading every archive first.
        public let manifest: NectoPluginManifest?

        public var id: String { assetName }
    }

    public struct Release: Equatable, Sendable {
        public let tag: String
        public let offers: [Offer]
    }

    /// Internal so the pairing below can be exercised without a network.
    struct Asset: Equatable {
        let name: String
        let url: URL
    }

    /// The cases are separate because the app says something different about each of
    /// them, in the reader's own language. The descriptions here are the fallback for
    /// anything that logs them.
    public enum Failure: Error, CustomStringConvertible, Equatable {
        case notARepositoryURL(String)
        case noSuchRepository(String)
        case noReleases(String)
        case noSuchRelease(label: String, tag: String)
        case noPlugins(String)
        case refused(status: Int)
        case needsLogin(host: String)
        case unreachable(String)

        public var description: String {
            switch self {
            case let .notARepositoryURL(text): "'\(text)' is not a GitHub repository address."
            case let .noSuchRepository(label): "Nothing at \(label) answered."
            case let .noReleases(label): "\(label) has published no releases."
            case let .noSuchRelease(label, tag): "\(label) has no release tagged \(tag)."
            case let .noPlugins(label): "The release of \(label) carries no plugin archive."
            case let .refused(status): "GitHub answered \(status)."
            case let .needsLogin(host): "gh is not installed, and \(host) needs a GitHub login to answer."
            case let .unreachable(detail): detail
            }
        }

        /// A repository that is private and one that does not exist answer an
        /// anonymous request the same way, on purpose. Both are worth a second try
        /// with a login behind it.
        var mightBeAnswerableWithALogin: Bool {
            if case .refused(404) = self { return true }
            return false
        }
    }

    // MARK: Addresses

    /// Accepts what people actually paste: a browser URL, a clone URL, or the
    /// `owner/name` shorthand every GitHub page shows in its title.
    ///
    /// A release can be named two ways, and both appear in the wild — the tag page a
    /// browser lands on, and the `@tag` suffix that package managers made ordinary.
    public static func repository(from text: String) throws -> Repository {
        var rest = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rest.isEmpty else { throw Failure.notARepositoryURL(text) }

        // GitHub's own address bar adds these the moment anyone clicks a tab, and they
        // are never part of a repository's name.
        if let cut = rest.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            rest = String(rest[..<cut])
        }

        var host = publicHost
        if let range = rest.range(of: "://") {
            let afterScheme = rest[range.upperBound...]
            guard let slash = afterScheme.firstIndex(of: "/") else { throw Failure.notARepositoryURL(text) }
            host = String(afterScheme[..<slash])
            rest = String(afterScheme[slash...])
        }
        // A host with no scheme is still a host, as long as something follows it.
        else if let slash = rest.firstIndex(of: "/"), rest[..<slash].contains(".") {
            host = String(rest[..<slash])
            rest = String(rest[slash...])
        }
        // Hosts are case-insensitive, and whether this one is the public GitHub decides
        // whether an anonymous request is even attempted.
        host = host.lowercased()
        // A trailing dot is the same host with its root spelled out, and `www.` is the
        // same host with a subdomain nobody meant. Both would otherwise be read as
        // somewhere private and send a public-repository user to install gh.
        if host.hasSuffix(".") { host.removeLast() }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        guard !host.isEmpty, !host.contains("/") else { throw Failure.notARepositoryURL(text) }

        // Strip a trailing `@tag` before splitting, so a tag containing slashes is not
        // mistaken for more path.
        var tag: String?
        if let at = rest.lastIndex(of: "@"), at > rest.startIndex {
            tag = String(rest[rest.index(after: at)...])
            rest = String(rest[..<at])
        }

        var components = rest.split(separator: "/").map(String.init)
        guard components.count >= 2 else { throw Failure.notARepositoryURL(text) }

        let owner = components.removeFirst()
        var name = components.removeFirst()
        if name.hasSuffix(".git") { name.removeLast(4) }
        guard isName(owner), isName(name) else { throw Failure.notARepositoryURL(text) }

        // `.../releases/tag/v1.0.0` — where a browser lands on one release.
        if tag == nil, components.count >= 3, components[0] == "releases", components[1] == "tag" {
            tag = components[2...].joined(separator: "/")
        }
        if let unwrapped = tag {
            guard isTag(unwrapped) else { throw Failure.notARepositoryURL(text) }
        }

        return Repository(host: host, owner: owner, name: name, tag: tag)
    }

    /// Every part of an address ends up in a request path, so a part that can carry a
    /// path is a part that can address a different repository than the one shown. The
    /// name in the approval screen has to be the name that was asked for.
    private static func isName(_ value: String) -> Bool {
        !value.isEmpty
            && value != "." && value != ".."
            && value.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }
    }

    /// Tags are freer than names — `release/1.0` is an ordinary tag — so this allows a
    /// slash and refuses only what would climb out of the path it is written into.
    private static func isTag(_ value: String) -> Bool {
        !value.isEmpty
            && !value.hasPrefix("/")
            && !value.split(separator: "/").contains { $0 == "." || $0 == ".." }
    }

    // MARK: Reading a release

    /// `describing` narrows which manifests are worth a round trip.
    ///
    /// Installing needs every archive described, because the person is choosing among
    /// them. Checking for updates needs only the ones already installed, and a release
    /// holding a dozen plugins would otherwise cost a dozen requests to compare one —
    /// against a limit of sixty an hour. The ids are a hint, not a rule: a publisher
    /// who names archives some other way still gets all of them read.
    public static func release(
        of repository: Repository,
        describing wanted: Set<String> = []
    ) async throws -> Release {
        // Encoded, not interpolated: a tag may legitimately hold a slash, and a path
        // built by interpolation is a path the tag gets to steer.
        let path = repository.tag
            .map { "releases/tags/\(encoded($0))" } ?? "releases/latest"

        let data: Data
        do {
            data = try await get(repository.apiPath(path), from: repository)
        } catch let failure as Failure where failure.mightBeAnswerableWithALogin {
            // Three different things answer the same way: a repository that is not
            // there, one that has never cut a release, and a tag that does not name
            // one. Asking about the repository itself separates the first from the
            // other two, and the tag we asked for separates those. Each is a different
            // mistake with a different thing to do about it, and one more request is
            // worth telling someone which they made.
            guard (try? await get(repository.apiPath(nil), from: repository)) != nil else {
                throw Failure.noSuchRepository(repository.label)
            }
            if let tag = repository.tag {
                throw Failure.noSuchRelease(label: repository.label, tag: tag)
            }
            throw Failure.noReleases(repository.label)
        }

        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = object["tag_name"] as? String else {
            throw Failure.noReleases(repository.label)
        }

        let assets = (object["assets"] as? [[String: Any]] ?? []).compactMap { asset -> Asset? in
            guard let name = asset["name"] as? String,
                  let address = asset["browser_download_url"] as? String,
                  let url = URL(string: address) else { return nil }
            return Asset(name: name, url: url)
        }

        guard assets.contains(where: { $0.name.hasSuffix(".zip") }) else {
            throw Failure.noPlugins(repository.label)
        }

        var published: [String: Data] = [:]
        for name in sidecars(in: assets, describing: wanted) {
            published[name] = try? await read(asset: name, in: assets, from: repository)
        }

        return Release(tag: tag, offers: offers(in: assets, describedBy: published))
    }

    /// The manifests worth fetching: one beside an archive, named after it.
    ///
    /// With ids to look for, archives whose name begins with one of them are preferred
    /// — the shape `plugin pack` writes.
    ///
    /// The narrowing applies only when every id was found. A release where some archives
    /// follow that shape and some were named by hand would otherwise lose the
    /// hand-named ones: the guess was right about enough of them to look right, and the
    /// plugins it was wrong about would go unasked about for good.
    static func sidecars(in assets: [Asset], describing wanted: Set<String> = []) -> [String] {
        let names = Set(assets.map(\.name))
        let archives = assets.filter { $0.name.hasSuffix(".zip") }

        let everyoneFound = !wanted.isEmpty && wanted.allSatisfy { id in
            archives.contains { $0.name.hasPrefix(id) }
        }
        let chosen = everyoneFound
            ? archives.filter { asset in wanted.contains { asset.name.hasPrefix($0) } }
            : archives

        return chosen
            .map { String($0.name.dropLast(4)) + ".manifest.json" }
            .filter(names.contains)
    }

    /// Pairs every archive in a release with the manifest published beside it.
    ///
    /// A release is whatever its publisher attached. Ours carries a manifest next to
    /// each archive, which is what lets a list be drawn before anything is downloaded;
    /// someone who ran `zip` and `gh release create` attached one file, and that has to
    /// work too. So a missing manifest is not an error — the row falls back to the file
    /// name, and the archive describes itself on the approval screen that follows.
    static func offers(in assets: [Asset], describedBy manifests: [String: Data]) -> [Offer] {
        assets
            .filter { $0.name.hasSuffix(".zip") }
            .map { asset in
                let sidecar = String(asset.name.dropLast(4)) + ".manifest.json"
                let manifest = manifests[sidecar]
                    .flatMap { try? JSONDecoder().decode(NectoPluginManifest.self, from: $0) }
                return Offer(assetName: asset.name, downloadURL: asset.url, manifest: manifest)
            }
    }

    // MARK: Taking one out

    /// Writes the chosen archive to a new directory and returns the file.
    ///
    /// The caller installs from it through the same path a dragged-in zip takes, so
    /// nothing downstream has to know an archive arrived over the network.
    public static func download(_ offer: Offer, from repository: Repository, tag: String) async throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "necto-plugin-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // The caller owns the directory once this returns; until then it is ours to
        // clean up, and every path out of here below throws.
        var succeeded = false
        defer { if !succeeded { try? FileManager.default.removeItem(at: directory) } }

        let file = directory.appending(path: offer.assetName)
        if repository.isPublic {
            do {
                try await fetch(offer.downloadURL).write(to: file)
                succeeded = true
                return file
            } catch let failure as Failure {
                // Same rule as the listing: a refusal a login would not lift is the
                // real answer, and `gh` is about to get the same one.
                guard failure.mightBeAnswerableWithALogin else { throw failure }
            }
        }

        // The tag comes from the release's own JSON, so it is the publisher's string,
        // not ours. Last and after `--`, so one that begins with a dash is read as the
        // tag it is rather than as a flag.
        _ = try await gh(
            [
                "release", "download",
                "--repo", repository.label,
                "--pattern", literalPattern(offer.assetName),
                "--dir", directory.path,
                "--", tag,
            ],
            on: repository.host
        )
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw Failure.unreachable("'\(offer.assetName)' was not in the release.")
        }
        succeeded = true
        return file
    }

    private static func encoded(_ segment: String) -> String {
        // RFC 3986 unreserved. Anything else, `/` and `.` included, is escaped, so the
        // result is one path segment whatever it started as.
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_~")
        return segment.addingPercentEncoding(withAllowedCharacters: unreserved) ?? segment
    }

    // MARK: Transport

    /// Anonymous HTTPS first, because that is all a public repository needs and it
    /// asks nothing of the person installing. Anything else goes through the
    /// developer's own `gh`, which is where a login for an Enterprise host already
    /// is. A private repository answers an anonymous request with 404 rather than
    /// 403, so a refusal and an absence look the same here and both are worth a
    /// second try.
    private static func get(_ path: String, from repository: Repository) async throws -> Data {
        var anonymous: Failure?
        if repository.isPublic, let url = URL(string: "\(repository.apiRoot)/\(path)") {
            do {
                return try await fetch(url)
            } catch let failure as Failure {
                // A refusal a login would not lift — a rate limit, an outage — is the
                // real answer, and `gh` will get the same one. Reporting the fallback
                // instead sends people to install a tool that would not have helped.
                guard failure.mightBeAnswerableWithALogin else { throw failure }
                anonymous = failure
            }
        }

        do {
            return try await gh(["api", "--hostname", repository.host, path], on: repository.host)
        } catch {
            throw anonymous ?? error
        }
    }

    private static func read(asset name: String, in assets: [Asset], from repository: Repository) async throws -> Data {
        guard let url = assets.first(where: { $0.name == name })?.url else {
            throw Failure.unreachable("'\(name)' was not in the release.")
        }
        if repository.isPublic { return try await fetch(url) }

        let directory = FileManager.default.temporaryDirectory
            .appending(path: "necto-manifest-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        _ = try await gh(
            [
                "release", "download", "--repo", repository.label,
                "--pattern", literalPattern(name), "--dir", directory.path,
            ],
            on: repository.host
        )
        return try Data(contentsOf: directory.appending(path: name))
    }

    /// `--pattern` is matched as a glob, so an asset named with `*`, `?` or `[` would
    /// bring its siblings along. The publisher chose that name, not us.
    static func literalPattern(_ name: String) -> String {
        name.reduce(into: "") { pattern, character in
            if "*?[]\\".contains(character) { pattern.append("\\") }
            pattern.append(character)
        }
    }

    private static func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            throw Failure.refused(status: (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return data
    }

    /// Private plugin repositories use the developer's existing gh login. Finder
    /// launches do not necessarily include Homebrew in PATH.
    private static func gh(_ arguments: [String], on host: String) async throws -> Data {
        let candidates = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"]
        guard let gh = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw Failure.needsLogin(host: host)
        }
        return try await run(gh, arguments)
    }

    private static func run(_ path: String, _ arguments: [String]) async throws -> Data {
        do {
            let output = try await NectoProcessRunner.run(path, arguments: arguments)
            guard output.exitCode == 0 else {
                let detail = String(decoding: output.stderr, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                throw Failure.unreachable(detail.isEmpty
                    ? "\(URL(filePath: path).lastPathComponent) exited \(output.exitCode)." : detail)
            }
            return output.stdout
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Failure.unreachable(String(describing: error))
        }
    }
}
