//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import Foundation
import Testing

@testable import NectoMacService

private typealias Source = NectoReleaseSource

@Test func readsTheAddressABrowserShows() throws {
    let repository = try Source.repository(from: "https://github.com/toss/toss-necto")
    #expect(repository.host == "github.com")
    #expect(repository.owner == "toss")
    #expect(repository.name == "toss-necto")
    #expect(repository.tag == nil)
}

@Test func readsTheShorthandAGitHubPagePutsInItsTitle() throws {
    let repository = try Source.repository(from: "toss/toss-necto")
    #expect(repository.host == "github.com")
    #expect(repository.owner == "toss")
    #expect(repository.name == "toss-necto")
}

/// An Enterprise host is the reason any of this needs a login, so it has to survive
/// parsing rather than be assumed away.
@Test func keepsAHostThatIsNotGitHubCom() throws {
    let repository = try Source.repository(from: "https://github.example.com/example/sample-plugin")
    #expect(repository.host == "github.example.com")
    #expect(repository.owner == "example")
    #expect(repository.name == "sample-plugin")
}

@Test func acceptsACloneURL() throws {
    let repository = try Source.repository(from: "https://github.com/toss/toss-necto.git")
    #expect(repository.name == "toss-necto")
}

@Test func acceptsAHostWithNoScheme() throws {
    let repository = try Source.repository(from: "github.example.com/example/sample-app")
    #expect(repository.host == "github.example.com")
    #expect(repository.name == "sample-app")
}

@Test func namesOneReleaseTheWayAPackageManagerWould() throws {
    let repository = try Source.repository(from: "toss/toss-necto@v0.4.0")
    #expect(repository.name == "toss-necto")
    #expect(repository.tag == "v0.4.0")
}

/// The other address that names one release is the page a browser lands on when
/// someone clicks a tag, and people paste what is in front of them.
@Test func namesOneReleaseTheWayABrowserDoes() throws {
    let repository = try Source.repository(from: "https://github.com/toss/toss-necto/releases/tag/0.4.0")
    #expect(repository.name == "toss-necto")
    #expect(repository.tag == "0.4.0")
}

@Test func ignoresTrailingPathAfterTheRepository() throws {
    let repository = try Source.repository(from: "https://github.com/toss/toss-necto/releases")
    #expect(repository.name == "toss-necto")
    #expect(repository.tag == nil)
}

@Test func trimsWhatAPasteBringsWithIt() throws {
    let repository = try Source.repository(from: "  https://github.com/toss/toss-necto \n")
    #expect(repository.name == "toss-necto")
}

@Test(arguments: [
    "",
    "   ",
    "toss",
    "https://github.com/toss",
    "https://github.com/",
])
func refusesWhatIsNotARepository(_ text: String) {
    #expect(throws: Source.Failure.self) {
        try Source.repository(from: text)
    }
}

@Test func onlyGitHubComAnswersWithoutALogin() throws {
    #expect(try Source.repository(from: "toss/toss-necto").isPublic)
    #expect(try !Source.repository(from: "github.example.com/example/sample-app").isPublic)
}

/// Enterprise serves the same API from its own host. Getting this wrong sends every
/// request to the public GitHub, which answers about a repository that is not this
/// one — or about none at all.
@Test func addressesTheAPIWhereTheHostKeepsIt() throws {
    #expect(try Source.repository(from: "toss/toss-necto").apiRoot == "https://api.github.com")
    #expect(
        try Source.repository(from: "github.example.com/example/sample-app").apiRoot
            == "https://github.example.com/api/v3"
    )
}

/// Permissions are granted to a source, so the identity has to be the source and
/// nothing else. A tag in it would make every release a stranger.
@Test func identifiesASourceWithoutItsRelease() {
    let origin = NectoLocalPluginInstallation.Origin(
        host: "github.com",
        owner: "toss",
        repository: "toss-necto",
        tag: "0.4.0"
    )
    #expect(origin.identity == "git:github.com/toss/toss-necto")
}

@Test func namesTheSourceOfAFetchedPluginAndTheRecordOfALocalOne() {
    let fetched = NectoLocalPluginInstallation(
        pluginID: "hello",
        directoryPath: "/tmp/hello",
        approvedContentHash: "abc",
        origin: .init(host: "github.com", owner: "toss", repository: "toss-necto", tag: "0.4.0")
    )
    #expect(fetched.principal.sourceIdentity == "git:github.com/toss/toss-necto")

    let local = NectoLocalPluginInstallation(
        pluginID: "hello",
        directoryPath: "/tmp/hello",
        approvedContentHash: "abc"
    )
    #expect(local.principal.sourceIdentity.hasPrefix("local:"))
}

private let anOrigin = NectoLocalPluginInstallation.Origin(
    host: "github.com",
    owner: "toss",
    repository: "toss-necto",
    tag: "0.4.1"
)

/// A plugin dragged in first and followed from its source later is the same
/// installation, and the approval that moved it is the one that says so.
@Test func anApprovalCanMoveAnInstallationToASource() {
    var installation = NectoLocalPluginInstallation(
        pluginID: "hello",
        directoryPath: "/tmp/hello",
        approvedContentHash: "before"
    )

    installation.approveUpdate(contentHash: "after", origin: anOrigin)
    #expect(installation.approvedContentHash == "after")
    #expect(installation.origin == anOrigin)
    #expect(installation.principal.sourceIdentity == "git:github.com/toss/toss-necto")
}

/// Files chosen on this Mac name no source. Leaving the old one in place would run
/// arbitrary local files under a repository's identity and hand them the permissions
/// that repository had been given.
@Test func approvingLocalFilesTakesTheSourceAwayAgain() {
    var installation = NectoLocalPluginInstallation(
        pluginID: "hello",
        directoryPath: "/tmp/hello",
        approvedContentHash: "before",
        origin: anOrigin
    )
    #expect(installation.principal.sourceIdentity == "git:github.com/toss/toss-necto")

    installation.approveUpdate(contentHash: "after", origin: nil)
    #expect(installation.origin == nil)
    #expect(installation.principal.sourceIdentity.hasPrefix("local:"))
}

// MARK: What a release offers

private func asset(_ name: String) -> Source.Asset {
    Source.Asset(name: name, url: URL(string: "https://example.com/\(name)")!)
}

private let manifest = Data("""
{
  "schemaVersion": 1,
  "id": "im.toss.necto.hello",
  "name": "Hello",
  "description": "A greeting",
  "version": "0.1.0",
  "author": "Toss",
  "icon": { "systemName": "hand.wave" },
  "assets": ["index.html"],
  "allowedOrigins": ["self"],
  "operations": [{
    "id": "host.info",
    "title": "Host",
    "description": "Which Necto is running",
    "kind": "once",
    "binding": { "name": "necto.desktop.info", "version": 1 },
    "inputSchema": { "type": "object" },
    "outputSchema": { "type": "object" },
    "timeoutMs": 1000
  }]
}
""".utf8)

/// Someone who ran `zip` and `gh release create` attached one file. That is a
/// complete, correct release, and refusing it would make our own tooling the price
/// of publishing.
@Test func offersAnArchiveThatCameWithNothingElse() {
    let offers = Source.offers(in: [asset("plugin.zip")], describedBy: [:])
    #expect(offers.count == 1)
    #expect(offers[0].assetName == "plugin.zip")
    #expect(offers[0].manifest == nil)
}

@Test func readsTheManifestPublishedBesideAnArchive() {
    let offers = Source.offers(
        in: [asset("hello-0.1.0.zip"), asset("hello-0.1.0.manifest.json")],
        describedBy: ["hello-0.1.0.manifest.json": manifest]
    )
    #expect(offers.count == 1)
    #expect(offers[0].manifest?.id == "im.toss.necto.hello")
    #expect(offers[0].manifest?.name == "Hello")
}

/// A release can hold plugins that were published with a manifest and plugins that
/// were not, and neither should shut the other out.
@Test func describesWhatItCanAndStillOffersTheRest() {
    let offers = Source.offers(
        in: [
            asset("hello-0.1.0.zip"),
            asset("hello-0.1.0.manifest.json"),
            asset("mystery.zip"),
        ],
        describedBy: ["hello-0.1.0.manifest.json": manifest]
    )
    #expect(offers.count == 2)
    #expect(offers.first { $0.assetName == "hello-0.1.0.zip" }?.manifest != nil)
    #expect(offers.first { $0.assetName == "mystery.zip" }?.manifest == nil)
}

/// A release carries whatever the publisher attached — checksums, notes, a dmg. Only
/// the archives are plugins.
@Test func ignoresWhatIsNotAnArchive() {
    let offers = Source.offers(
        in: [asset("Necto-0.4.0.dmg"), asset("SHA256SUMS"), asset("notes.txt")],
        describedBy: [:]
    )
    #expect(offers.isEmpty)
}

@Test func doesNotTrustAManifestThatWillNotDecode() {
    let offers = Source.offers(
        in: [asset("hello.zip"), asset("hello.manifest.json")],
        describedBy: ["hello.manifest.json": Data("not json".utf8)]
    )
    #expect(offers.count == 1)
    #expect(offers[0].manifest == nil)
}

/// Only manifests that belong to an archive are worth a round trip.
@Test func fetchesOnlyTheManifestsThatNameAnArchive() {
    let names = Source.sidecars(in: [
        asset("hello-0.1.0.zip"),
        asset("hello-0.1.0.manifest.json"),
        asset("orphan.manifest.json"),
        asset("nothing.zip"),
    ])
    #expect(names == ["hello-0.1.0.manifest.json"])
}

// MARK: Addresses that must not be trusted

/// Every part of an address is written into a request path. A part that can carry a
/// path can address a repository other than the one the approval screen names, and
/// the person would be agreeing to a plugin from somewhere they never saw.
@Test(arguments: [
    "https://github.com/toss/toss-necto/releases/tag/../../../../evil/repo/releases/latest",
    "https://github.com/toss/toss-necto@../../evil/repo/releases/latest",
    "https://github.com/toss/toss-necto@..",
    "https://github.com/toss/../../etc/repo",
    "https://github.com/../evil/repo",
    "https://github.com/toss/..",
])
func refusesAnAddressThatCouldReachAnotherRepository(_ text: String) {
    #expect(throws: Source.Failure.self) {
        try Source.repository(from: text)
    }
}

/// `release/1.0` is an ordinary tag. Only the parts that climb out of a path are
/// refused, so a slash on its own has to survive.
@Test func keepsATagThatSimplyContainsASlash() throws {
    let repository = try Source.repository(from: "toss/toss-necto@release/1.0")
    #expect(repository.name == "toss-necto")
    #expect(repository.tag == "release/1.0")
}

/// Hosts are case-insensitive, and this one decides whether an anonymous request is
/// tried at all. Left as typed, a capitalised paste sends a public-repository user to
/// install gh for no reason.
@Test func readsAHostHoweverItWasTyped() throws {
    let repository = try Source.repository(from: "HTTPS://GitHub.com/toss/toss-necto")
    #expect(repository.host == "github.com")
    #expect(repository.isPublic)
}

/// What GitHub's own address bar produces after a click. Left on, the request asks
/// about a repository whose name ends in `?tab=readme-ov-file`.
@Test(arguments: [
    "https://github.com/toss/toss-necto?tab=readme-ov-file",
    "https://github.com/toss/toss-necto#readme",
])
func dropsWhatABrowserAppendsToAnAddress(_ text: String) throws {
    let repository = try Source.repository(from: text)
    #expect(repository.name == "toss-necto")
}

// MARK: What an update check is worth asking for

/// Installing shows a list to choose from, so every archive has to be described.
@Test func readsEveryManifestWhenNothingNarrowsIt() {
    let names = Source.sidecars(in: [
        asset("a-1.0.0.zip"), asset("a-1.0.0.manifest.json"),
        asset("b-1.0.0.zip"), asset("b-1.0.0.manifest.json"),
    ])
    #expect(names.sorted() == ["a-1.0.0.manifest.json", "b-1.0.0.manifest.json"])
}

/// Checking for updates compares one plugin. A release holding a dozen would otherwise
/// cost a dozen requests to answer a question about one of them, against sixty an hour.
@Test func readsOnlyWhatAnUpdateCheckIsAbout() {
    let names = Source.sidecars(
        in: [
            asset("im.toss.necto.hello-1.0.0.zip"), asset("im.toss.necto.hello-1.0.0.manifest.json"),
            asset("im.toss.necto.other-1.0.0.zip"), asset("im.toss.necto.other-1.0.0.manifest.json"),
        ],
        describing: ["im.toss.necto.hello"]
    )
    #expect(names == ["im.toss.necto.hello-1.0.0.manifest.json"])
}

/// The ids are a hint about how we name archives, not a rule about how anyone else
/// does. A guess that matches nothing must not hide the release.
@Test func readsEverythingWhenTheNamesWereSomebodyElsesIdea() {
    let names = Source.sidecars(
        in: [asset("plugin.zip"), asset("plugin.manifest.json")],
        describing: ["im.toss.necto.hello"]
    )
    #expect(names == ["plugin.manifest.json"])
}

/// `--pattern` is matched as a glob, and the publisher chose the asset's name.
@Test func passesAnAssetNameToGhAsTheLiteralItIs() {
    #expect(Source.literalPattern("plugin-1.0.0.zip") == "plugin-1.0.0.zip")
    #expect(Source.literalPattern("plugin[1].zip") == "plugin\\[1\\].zip")
    #expect(Source.literalPattern("*.zip") == "\\*.zip")
}

/// The public GitHub written the other ways a person writes it. Read as somewhere
/// private, each one sends someone to install gh for a repository that needs nothing.
@Test(arguments: ["https://www.github.com/toss/toss-necto", "https://github.com./toss/toss-necto"])
func recognisesThePublicHostHoweverItIsSpelled(_ text: String) throws {
    #expect(try Source.repository(from: text).isPublic)
}

/// A release where some archives follow `plugin pack`'s naming and some were named by
/// hand: the guess is right about enough of them to look right, and the ones it is
/// wrong about would go unasked about for good.
@Test func readsEverythingWhenTheGuessOnlyPartlyFits() {
    let names = Source.sidecars(
        in: [
            asset("im.toss.necto.hello-1.0.0.zip"), asset("im.toss.necto.hello-1.0.0.manifest.json"),
            asset("legacy.zip"), asset("legacy.manifest.json"),
        ],
        describing: ["im.toss.necto.hello", "im.toss.necto.legacy"]
    )
    #expect(names.sorted() == ["im.toss.necto.hello-1.0.0.manifest.json", "legacy.manifest.json"])
}

/// Narrowing is only safe when every plugin asked about was found.
@Test func narrowsOnlyWhenEveryIdWasAccountedFor() {
    let assets = [
        asset("a-1.0.0.zip"), asset("a-1.0.0.manifest.json"),
        asset("b-1.0.0.zip"), asset("b-1.0.0.manifest.json"),
    ]
    #expect(Source.sidecars(in: assets, describing: ["a", "b"]).sorted()
        == ["a-1.0.0.manifest.json", "b-1.0.0.manifest.json"])
    #expect(Source.sidecars(in: assets, describing: ["a"]) == ["a-1.0.0.manifest.json"])
}

/// An `Origin` carries the release it came from, so two plugins installed out of one
/// repository at different times are unequal. Anything asking "same source?" has to ask
/// the identity, or the second plugin is never checked for updates again.
@Test func twoPluginsFromOneRepositoryShareASourceWhateverReleaseTheyCameFrom() {
    let first = NectoLocalPluginInstallation.Origin(
        host: "github.com", owner: "acme", repository: "panels", tag: "v1"
    )
    let later = NectoLocalPluginInstallation.Origin(
        host: "github.com", owner: "acme", repository: "panels", tag: "v2"
    )

    #expect(first != later)
    #expect(first.identity == later.identity)
}
