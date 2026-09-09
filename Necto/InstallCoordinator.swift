//
// Copyright (c) 2026 Viva Republica, Inc.
//

import AppKit
import Foundation
import Observation
import NectoCLIService
import NectoMacService
import NectoModel

/// Owns installation requests from every entry point through approval and registration.
@MainActor
@Observable
final class InstallCoordinator {
    private let shellAccess: NectoShellAccessController
    private let reload: @MainActor () async -> [NectoInstalledPlugin]
    private let present: @MainActor () throws -> Void
    private let delete: @MainActor (String) async throws -> NectoJSONValue
    private let logFailure: @MainActor (String, String) -> Void

    init(shellAccess: NectoShellAccessController,
         reload: @escaping @MainActor () async -> [NectoInstalledPlugin],
         present: @escaping @MainActor () throws -> Void,
         delete: @escaping @MainActor (String) async throws -> NectoJSONValue,
         logFailure: @escaping @MainActor (String, String) -> Void) {
        self.shellAccess = shellAccess
        self.reload = reload
        self.present = present
        self.delete = delete
        self.logFailure = logFailure
    }

    private(set) var isDeleting = false
    private(set) var isReloading = false
    var isBusy: Bool { isReloading || isDeleting || isCancelling || isCommitting || cliInstallation != nil || prompt != nil || isReadingRelease || isFetching || !fetchQueue.isEmpty }

    func reloadPlugins() async {
        guard !isBusy, !Task.isCancelled else { return }
        isReloading = true
        defer { isReloading = false }
        _ = await reload()
    }

    func deletePlugin(id: String) async throws -> NectoJSONValue {
        guard !isBusy else {
            throw NectoBridgeError(code: .operationUnavailable, message: "Finish the current plugin operation before deleting a plugin.")
        }
        try Task.checkCancellation()
        isDeleting = true
        defer { isDeleting = false }
        return try await delete(id)
    }

    @discardableResult
    func enqueueUpdate(offer: NectoReleaseSource.Offer, repository: NectoReleaseSource.Repository,
                       tag: String, expecting: String) -> Bool {
        guard !isBusy else { return false }
        fetchQueue.append(Fetch(offer: offer, repository: repository, tag: tag, expecting: expecting))
        scheduleNext()
        return true
    }

    /// A plugin unpacked and waiting for an answer. Nothing has been written to the
    /// plugins folder while this is set, so cancelling leaves nothing behind.
    private(set) var pendingInstall: PendingInstall?
    private(set) var installFailure: String?

    private struct CLIInstallation {
        let requestID: UUID
        var pluginID: String?
        let continuation: CheckedContinuation<NectoJSONValue, any Error>
    }
    @ObservationIgnored private var cliInstallation: CLIInstallation?
    @ObservationIgnored private var workTask: Task<Void, Never>?
    private(set) var isCancelling = false
    private(set) var isCommitting = false

    /// `sheet(item:)` needs identity, and a staged plugin is only ever one at a time.
    struct PendingInstall: Identifiable {
        let staged: NectoPluginInstaller.Staged
        /// Set when the files came from a repository. It is what the approval writes
        /// into the installation, so permissions belong to the source rather than to
        /// this Mac's record of a folder.
        let origin: NectoLocalPluginInstallation.Origin?
        var id: String { staged.manifest.id }
    }

    /// A release with more than one plugin in it, waiting for someone to say which.
    /// It outlives an install: the list is still worth looking at once one of them has
    /// been dealt with, and closing it is the person's to do.
    private(set) var pendingChoice: PendingChoice?

    /// What needs an answer right now. Only one thing can be asked at a time, and an
    /// approval outranks a list — the list is where it came from, and it will still be
    /// there afterwards.
    var prompt: Prompt? {
        if let pendingInstall { .approve(pendingInstall) }
        else if let pendingChoice { .choose(pendingChoice) }
        else if isAddingLink { .address }
        else { nil }
    }

    enum Prompt: Identifiable {
        case approve(PendingInstall)
        case choose(PendingChoice)
        case address

        var id: String {
            switch self {
            case let .approve(pending): "approve:\(pending.id)"
            case let .choose(choice): "choose:\(choice.id)"
            case .address: "address"
            }
        }
    }

    /// Someone is typing an address. It outranks nothing: the moment a release has been
    /// read, what was read is the more interesting question.
    private(set) var isAddingLink = false

    func beginAddingLink() {
        guard !isBusy else { return }
        installFailure = nil
        isAddingLink = true
    }

    func cancelAddingLink() {
        if isReadingRelease { cancelWork(); return }
        isAddingLink = false
        installFailure = nil
    }

    /// For a dismissal that came from the window rather than from a button.
    func dismissPrompt() {
        if pendingInstall != nil { cancelInstall() }
        else if pendingChoice != nil { cancelChoice() }
        else { cancelAddingLink() }
    }

    struct PendingChoice: Identifiable {
        let repository: NectoReleaseSource.Repository
        let release: NectoReleaseSource.Release
        var id: String { "\(repository.label)@\(release.tag)" }
    }

    /// Reading a release is a round trip, and the button that started it should say so.
    private(set) var isReadingRelease = false

    /// Chosen plugins still to be fetched. They are approved one at a time, because an
    /// approval is a decision about one plugin and batching them would hide that.
    private var fetchQueue: [Fetch] = []

    /// Set for as long as something is being fetched. A download is a long suspension
    /// during which the page stays live, so without this two buttons start two
    /// downloads and the second approval screen replaces the first — losing an answer
    /// someone had already given.
    private(set) var isFetching = false

    /// The archive being fetched, so the row that started it can say so. A share of a
    /// download would be better and is not available: the Enterprise path goes through
    /// `gh`, which reports progress as text on its stderr and nothing a bar can read.
    private(set) var fetchingAsset: String?

    /// What is queued, so the same thing is not queued twice by two quick presses.
    var queuedAssets: Set<String> { Set(fetchQueue.map(\.offer.assetName)) }

    private struct Fetch {
        let offer: NectoReleaseSource.Offer
        let repository: NectoReleaseSource.Repository
        let tag: String
        /// Set when this is an update to something already installed, so a release that
        /// swapped its contents cannot arrive under the name of what it replaced.
        let expecting: String?
        let cliRequestID: UUID?

        init(
            offer: NectoReleaseSource.Offer,
            repository: NectoReleaseSource.Repository,
            tag: String,
            expecting: String? = nil,
            cliRequestID: UUID? = nil
        ) {
            self.offer = offer
            self.repository = repository
            self.tag = tag
            self.expecting = expecting
            self.cliRequestID = cliRequestID
        }
    }

    func installPluginFromCLI(source: NectoPluginInstallSource) async throws -> NectoJSONValue {
        guard !isBusy,
              NSApplication.shared.modalWindow == nil,
              !NSApplication.shared.windows.contains(where: { $0.attachedSheet != nil }) else {
            throw NectoBridgeError(code: .operationUnavailable, message: "Finish the current installation or prompt in Necto first.")
        }
        try Task.checkCancellation()
        try present()
        let requestID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                cliInstallation = CLIInstallation(requestID: requestID, continuation: continuation)
                switch source {
                case let .localPath(path):
                    stageLocal(from: URL(filePath: path), cliRequestID: requestID)
                case let .repositoryURL(url):
                    beginInstallFromLink(url, cliRequestID: requestID)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelCLIInstallation(requestID: requestID) }
        }
    }

    private func cancelCLIInstallation(requestID: UUID) {
        guard cliInstallation?.requestID == requestID else { return }
        cancelWork(cliRequestID: requestID)
    }

    private func cancelWork(cliRequestID: UUID? = nil) {
        guard !isCommitting, !isCancelling else { return }
        isCancelling = true
        let active = workTask
        active?.cancel()
        fetchQueue.removeAll { cliRequestID == nil || $0.cliRequestID == cliRequestID }
        pendingInstall = nil
        pendingChoice = nil
        isAddingLink = false
        Task {
            await active?.value
            if let cliRequestID {
                completeCLIInstallation(requestID: cliRequestID, result: .failure(CancellationError()))
            }
            workTask = nil
            isReadingRelease = false
            isFetching = false
            isCancelling = false
            scheduleNext()
        }
    }

    private func scheduleNext() {
        guard !isCancelling, !isCommitting, !isFetching, pendingInstall == nil, !fetchQueue.isEmpty else { return }
        // Reserve ownership before the task starts so a second enqueue cannot
        // replace the task that cancellation must await.
        isFetching = true
        workTask = Task { await fetchNext() }
    }

    private func completeCLIInstallation(requestID: UUID, result: Result<NectoJSONValue, any Error>) {
        guard let request = cliInstallation, request.requestID == requestID else { return }
        cliInstallation = nil
        workTask = nil
        pendingChoice = nil
        request.continuation.resume(with: result)
    }

    private func failCLIInstallation(requestID: UUID) {
        completeCLIInstallation(requestID: requestID, result: .failure(
            NectoBridgeError(code: .providerFailed, message: installFailure ?? "The plugin could not be installed.")
        ))
    }

    func beginInstallFromFile(updating plugin: NectoInstalledPlugin? = nil) {
        guard !isBusy else { return }
        let panel = NSOpenPanel()
        panel.message = NectoL10n.text("Choose a plugin folder or a zip of one.")
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.zip]
        panel.allowsOtherFileTypes = false
        panel.treatsFilePackagesAsDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }
        stageLocal(from: url, expectedPluginID: plugin?.id)
    }

    func review(_ plugin: NectoInstalledPlugin) {
        guard !isBusy else { return }
        stageLocal(from: plugin.rootURL, expectedPluginID: plugin.id)
    }

    private func stageLocal(from source: URL, expectedPluginID: String? = nil, cliRequestID: UUID? = nil) {
        isFetching = true
        workTask = Task {
            defer { isFetching = false }
            await stage(from: source, expectedPluginID: expectedPluginID, cliRequestID: cliRequestID)
            guard !Task.isCancelled else { return }
            if let cliRequestID, pendingInstall == nil { failCLIInstallation(requestID: cliRequestID) }
        }
    }

    private func stage(
        from source: URL,
        expectedPluginID: String? = nil,
        origin: NectoLocalPluginInstallation.Origin? = nil,
        cliRequestID: UUID? = nil
    ) async {
        if let cliRequestID, cliInstallation?.requestID != cliRequestID { return }
        guard cliInstallation == nil || cliInstallation?.requestID == cliRequestID else {
            installFailure = NectoL10n.text("Finish the current CLI installation first.")
            return
        }
        installFailure = nil
        do {
            let staged = try await NectoPluginInstaller.stage(
                from: source,
                installed: NectoPluginLibrary.loadInstalled().plugins,
                expectedPluginID: expectedPluginID,
                describedAs: origin.map { "\($0.label) \($0.tag)" }
            )
            try Task.checkCancellation()
            if let cliRequestID, cliInstallation?.requestID != cliRequestID { return }
            pendingInstall = PendingInstall(staged: staged, origin: origin)
            if let cliRequestID, cliInstallation?.requestID == cliRequestID {
                cliInstallation?.pluginID = staged.manifest.id
            }
        } catch {
            if Task.isCancelled { return }
            installFailure = error.localizedDescription
            logFailure("Could not read the plugin", error.localizedDescription)
        }
    }

    // MARK: Installing from a repository

    /// Takes whatever someone pasted and turns it into a decision.
    ///
    /// A release with one plugin in it goes straight to the approval screen, because
    /// asking which of one is a question with no information in it. A release with
    /// several asks first, and what it shows comes from the manifests published beside
    /// the archives — nothing large is downloaded to draw that list.
    func beginInstallFromLink(_ text: String, cliRequestID: UUID? = nil) {
        guard !isReloading, !isDeleting, !isCancelling, !isCommitting, !isFetching,
              pendingInstall == nil, pendingChoice == nil, fetchQueue.isEmpty else { return }
        guard cliInstallation == nil || cliInstallation?.requestID == cliRequestID else { return }
        installFailure = nil
        guard !isReadingRelease else { return }
        // Set here rather than inside the task: a flag a second caller cannot see yet
        // is not a guard.
        isReadingRelease = true

        let task = Task {
            defer { isReadingRelease = false }
            do {
                let repository = try NectoReleaseSource.repository(from: text)
                let release = try await NectoReleaseSource.release(of: repository)
                try Task.checkCancellation()
                if let cliRequestID, cliInstallation?.requestID != cliRequestID { return }

                // Read, so the question it was asking has been answered.
                isAddingLink = false

                if release.offers.count == 1 {
                    fetchQueue.append(
                        Fetch(offer: release.offers[0], repository: repository, tag: release.tag, cliRequestID: cliRequestID)
                    )
                    isFetching = true
                    await fetchNext()
                } else {
                    pendingChoice = PendingChoice(repository: repository, release: release)
                }
            } catch {
                if Task.isCancelled { return }
                if let cliRequestID, cliInstallation?.requestID != cliRequestID { return }
                report(error)
                if let cliRequestID { failCLIInstallation(requestID: cliRequestID) }
            }
        }
        workTask = task
    }

    func cancelChoice() {
        if let request = cliInstallation { cancelCLIInstallation(requestID: request.requestID) }
        else { cancelWork() }
    }

    /// Installs one of what a release offered, leaving the list open behind it.
    func install(_ offer: NectoReleaseSource.Offer) {
        guard !isCancelling, !isCommitting else { return }
        guard let choice = pendingChoice else { return }
        let cliRequestID = cliInstallation?.requestID
        if cliRequestID != nil {
            guard !isFetching, fetchQueue.isEmpty, pendingInstall == nil else { return }
        }
        // Two presses before the first one is visibly under way is one plugin, not two.
        guard offer.assetName != fetchingAsset, !queuedAssets.contains(offer.assetName) else { return }
        fetchQueue.append(
            Fetch(offer: offer, repository: choice.repository, tag: choice.release.tag, cliRequestID: cliRequestID)
        )
        scheduleNext()
    }

    /// One at a time: an approval screen answers for one plugin, so the next is not
    /// fetched until the last has been answered.
    ///
    /// One that cannot be fetched does not strand the rest, and does not disappear
    /// either. The loop only goes round again after something failed, and `stage`
    /// clears the last message on its way in — so a failure collected here rather than
    /// left in place is the difference between someone who chose three plugins being
    /// told that one of them could not be read, and receiving two with no explanation.
    private func fetchNext() async {
        defer { isFetching = false }
        // An empty queue is not a drain. Without this the callers that only ever ask
        // whether anything is waiting — a cancel, a successful install — would reach
        // the line at the end and erase a message that belongs to something else,
        // including the one `confirmInstall` had just set about its own failure.
        guard !Task.isCancelled, pendingInstall == nil, !fetchQueue.isEmpty else { return }

        var failures: [String] = []

        while pendingInstall == nil, !fetchQueue.isEmpty {
            let next = fetchQueue.removeFirst()
            fetchingAsset = next.offer.assetName
            defer { fetchingAsset = nil }
            do {
                let archive = try await NectoReleaseSource.download(
                    next.offer,
                    from: next.repository,
                    tag: next.tag
                )
                // `stage` reads the bytes into memory before it returns, so the file has
                // done its work by the time this runs.
                defer { try? FileManager.default.removeItem(at: archive.deletingLastPathComponent()) }
                try Task.checkCancellation()
                if let requestID = next.cliRequestID, cliInstallation?.requestID != requestID { return }
                await stage(
                    from: archive,
                    expectedPluginID: next.expecting,
                    origin: NectoLocalPluginInstallation.Origin(
                        host: next.repository.host,
                        owner: next.repository.owner,
                        repository: next.repository.name,
                        tag: next.tag
                    ),
                    cliRequestID: next.cliRequestID
                )
            } catch {
                if Task.isCancelled { return }
                if let requestID = next.cliRequestID, cliInstallation?.requestID != requestID { return }
                report(error)
            }

            if let failure = installFailure {
                // Named, because this notice can be read while a different plugin's
                // approval screen is open, and an unattributed one reads as being
                // about that plugin.
                failures.append("\(next.offer.manifest?.name ?? next.offer.assetName): \(failure)")
            }
            if let requestID = next.cliRequestID, pendingInstall == nil {
                failCLIInstallation(requestID: requestID)
                return
            }
        }

        installFailure = failures.isEmpty ? nil : failures.joined(separator: "\n")
    }

    /// Says what went wrong in the reader's language, and keeps the detail for the log.
    func report(_ error: any Error) {
        let message: String
        switch error {
        case let failure as NectoReleaseSource.Failure:
            message = switch failure {
            case let .notARepositoryURL(text):
                NectoL10n.format("'%@' is not a GitHub repository address.", text)
            case let .noSuchRepository(label):
                NectoL10n.format(
                    "Nothing at %@ answered. Either the address is wrong, or the repository is private and needs a GitHub login through gh.",
                    label
                )
            case let .noReleases(label):
                NectoL10n.format(
                    "%@ has published no releases yet. A folder or zip of one can still be installed with Choose….",
                    label
                )
            case let .noSuchRelease(label, tag):
                NectoL10n.format("%@ has no release tagged %@.", label, tag)
            case let .noPlugins(label):
                NectoL10n.format("The release of %@ carries no plugin archive.", label)
            case let .refused(status):
                NectoL10n.format("GitHub answered %@ and would not say more.", String(status))
            case let .needsLogin(host):
                NectoL10n.format(
                    "%@ answers no one without a GitHub login, and gh is not installed. Install it with Homebrew, then run gh auth login.",
                    host
                )
            case let .unreachable(detail):
                detail
            }
        default:
            message = error.localizedDescription
        }

        installFailure = message
        logFailure("Could not read the release", String(describing: error))
    }

    func cancelInstall() {
        guard !isCommitting else { return }
        if let request = cliInstallation { cancelCLIInstallation(requestID: request.requestID); return }
        pendingInstall = nil
        scheduleNext()
    }

    func confirmInstall() {
        guard let pending = pendingInstall else { return }
        let staged = pending.staged
        isCommitting = true
        let cliRequest = cliInstallation
        pendingInstall = nil

        do {
            guard NectoPluginLibrary.installations[staged.manifest.id] == staged.previous?.installation else {
                throw NectoLocalPluginFiles.Failure.changedSinceReview
            }
            let installed = try NectoPluginInstaller.commit(staged, into: NectoPluginLibrary.directory)
            let origin = pending.origin
            var record = staged.previous?.installation ?? NectoLocalPluginInstallation(
                pluginID: staged.manifest.id,
                directoryPath: installed.path,
                approvedContentHash: staged.archive.contentHash,
                origin: origin
            )
            // An installation that stops being a repository's should stop holding what
            // that repository was given. Approving replaces the grants under the new
            // identity, but the old one would otherwise sit there waiting to be
            // reclaimed by the next install that happens to take the same name.
            let previousPrincipal = record.principal
            record.approveUpdate(contentHash: staged.archive.contentHash, origin: origin)
            if record.principal != previousPrincipal {
                var stale = NectoPluginLibrary.grants
                stale.revoke(previousPrincipal)
                NectoPluginLibrary.grants = stale
                // The approval screen re-asks about bridges. It does not re-ask about
                // the exact commands someone allowed, so those have to go with the
                // identity that was given them — or they come back on their own the
                // day the same name is installed from the same place again.
                Task { await shellAccess.forget(previousPrincipal) }
            }
            var records = NectoPluginLibrary.installations
            records[record.pluginID] = record
            NectoPluginLibrary.installations = records

            // Recorded here and nowhere else: this is the one moment someone said yes.
            var grants = NectoPluginLibrary.grants
            grants.grant(
                Set(staged.manifest.operations.map(\.binding.identity)),
                to: record.principal
            )
            NectoPluginLibrary.grants = grants

            shellAccess.cancelRequests(for: record.principal)
            workTask = Task {
                let plugins = await reload()
                isCommitting = false
                if let cliRequest {
                    if let plugin = plugins.first(where: { $0.id == staged.manifest.id && $0.contentIdentity == staged.archive.contentHash }) {
                        completeCLIInstallation(requestID: cliRequest.requestID, result: .success([
                            "installed": true,
                            "pluginID": .string(plugin.id),
                            "name": .string(plugin.manifest.name),
                            "version": .string(plugin.manifest.version),
                            "enabled": .bool(!NectoPluginLibrary.disabledIDs.contains(plugin.id)),
                        ]))
                    } else {
                        completeCLIInstallation(requestID: cliRequest.requestID, result: .failure(
                            NectoBridgeError(code: .providerFailed, message: "Files were installed, but the plugin did not load. Check Necto Settings.")
                        ))
                    }
                }
                // Whatever else was chosen from the same release is still waiting.
                scheduleNext()
            }
        } catch {
            isCommitting = false
            installFailure = error.localizedDescription
            if let cliRequest {
                completeCLIInstallation(requestID: cliRequest.requestID, result: .failure(
                    NectoBridgeError(code: .providerFailed, message: error.localizedDescription)
                ))
            }
            scheduleNext()
        }
    }

}
