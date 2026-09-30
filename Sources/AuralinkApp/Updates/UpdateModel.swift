import AppKit
import AuralinkLocalization
import AuralinkUpdates
import Combine

/// Checks quietly in the background. Installation is always a user action.
@MainActor
final class UpdateModel: ObservableObject {
    enum State: Equatable {
        case idle, checking, upToDate
        case available(UpdateOffer)
        case downloading(UpdateOffer, received: Int64, total: Int64)
        case installing(UpdateOffer)
        case failed(String, UpdateOffer?)
    }

    @Published private(set) var state: State = .idle
    @Published var automaticChecks: Bool {
        didSet {
            defaults.set(automaticChecks, forKey: "AuralinkAutomaticUpdateChecks")
            scheduleChecks()
        }
    }
    let currentVersion: String
    private let defaults: UserDefaults
    private let configuration: Configuration?
    private var timer: Timer?
    private var delayedCheck: Task<Void, Never>?
    private var installTask: Task<Void, Never>?
    private var lastAttempt: Date?
    private var skippedVersion: String?

    /// The delegate restores real sound output here, after verification and just
    /// before the app swap. Throwing aborts installation without replacing files.
    var prepareForRestart: () throws -> Void = {}

    private struct Configuration {
        let feedURL: URL
        let publicKey: String
        let identifier: String
        let version: AppVersion
        let channel: UpdateChannel
        let appURL: URL
        let releasesPage: URL
    }

    init(bundle: Bundle = .main, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        automaticChecks = defaults.object(forKey: "AuralinkAutomaticUpdateChecks") as? Bool ?? true
        lastAttempt = defaults.object(forKey: "AuralinkLastUpdateAttempt") as? Date
        skippedVersion = defaults.string(forKey: "AuralinkSkippedUpdateVersion")
        let info = bundle.infoDictionary ?? [:]
        currentVersion = info["AuralinkUpdateVersion"] as? String ?? info["CFBundleShortVersionString"] as? String ?? "—"
        if let repository = info["AuralinkUpdateRepository"] as? String,
           let feed = ReleaseFeed.releasesURL(repository: repository),
           let key = info["AuralinkUpdatePublicKey"] as? String,
           UpdateSignature.isValidPublicKey(key),
           let identifier = bundle.bundleIdentifier,
           let version = AppVersion(currentVersion),
           let channel = (info["AuralinkReleaseChannel"] as? String).flatMap(UpdateChannel.init(rawValue:)),
           bundle.bundleURL.pathExtension == "app" {
            configuration = Configuration(feedURL: feed, publicKey: key, identifier: identifier,
                                          version: version, channel: channel, appURL: bundle.bundleURL,
                                          releasesPage: URL(string: "https://github.com/\(repository)/releases")!)
        } else { configuration = nil }
    }

    var offer: UpdateOffer? {
        switch state {
        case .available(let offer), .downloading(let offer, _, _), .installing(let offer), .failed(_, let offer?): return offer
        default: return nil
        }
    }
    var busy: Bool {
        switch state { case .checking, .downloading, .installing: return true; default: return false }
    }
    var canInstall: Bool { configuration != nil && offer?.signatureURL != nil && !busy }

    func start() { scheduleChecks() }
    func stop() { timer?.invalidate(); delayedCheck?.cancel(); installTask?.cancel() }

    private func scheduleChecks() {
        timer?.invalidate()
        delayedCheck?.cancel()
        guard automaticChecks, configuration != nil else { return }
        delayedCheck = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            await self?.checkIfDue()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.checkIfDue() }
        }
    }

    private func checkIfDue() async {
        guard automaticChecks, !busy, lastAttempt.map({ Date().timeIntervalSince($0) >= 24 * 3600 }) ?? true else { return }
        await check(userInitiated: false)
    }

    func checkNow() {
        guard !busy else { return }
        Task { await check(userInitiated: true) }
    }

    private func check(userInitiated: Bool) async {
        guard !busy else { return }
        guard let configuration else {
            if userInitiated { state = .failed(L10n.text("Updates are unavailable in this build. Use a packaged app with an update signing key."), nil) }
            return
        }
        let priorState = state
        state = .checking
        lastAttempt = Date()
        defaults.set(lastAttempt, forKey: "AuralinkLastUpdateAttempt")
        do {
            let releases = try await ReleaseFeed.fetchReleases(from: configuration.feedURL, userAgent: "Auralink-EQ/\(currentVersion)")
            if let offer = ReleaseFeed.newestOffer(in: releases, channel: configuration.channel),
               offer.version > configuration.version, userInitiated || offer.version.description != skippedVersion {
                state = .available(offer)
            } else { state = .upToDate }
        } catch {
            // Retain an already known update if a background recheck fails.
            state = userInitiated ? .failed(error.localizedDescription, nil) : priorState
        }
    }

    func skip() {
        guard !busy, let offer else { return }
        skippedVersion = offer.version.description
        defaults.set(skippedVersion, forKey: "AuralinkSkippedUpdateVersion")
        state = .idle
    }

    func openReleasePage() {
        guard let url = offer?.pageURL ?? configuration?.releasesPage ?? URL(string: "https://github.com/Simon-nhelix/auralink-eq/releases"),
              ReleaseFeed.isAllowed(url) else { return }
        NSWorkspace.shared.open(url)
    }

    func install() {
        guard canInstall, let configuration, let offer else { return }
        // Set synchronously so a double click cannot start two replacements.
        state = .downloading(offer, received: 0, total: offer.archiveSize)
        installTask = Task {
            let work = FileManager.default.temporaryDirectory.appendingPathComponent("Auralink-Update-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: work); installTask = nil }
            do {
                try UpdateInstaller.checkReplaceable(configuration.appURL)
                let preparer = UpdatePreparer(publicKey: configuration.publicKey, bundleIdentifier: configuration.identifier,
                                             currentVersion: configuration.version, workFolder: work)
                let newApp = try await preparer.prepare(offer) { [weak self] received, total in
                    Task { @MainActor in
                        guard let self, case .downloading = self.state else { return }
                        self.state = .downloading(offer, received: received, total: total > 0 ? total : offer.archiveSize)
                    }
                }
                try Task.checkCancellation()
                state = .installing(offer)
                try UpdateInstaller.commit(installedApp: configuration.appURL, with: newApp,
                                           beforeReplacement: prepareForRestart) { app, backup in
                    try UpdateInstaller.relaunchAfterExit(app: app, cleanup: backup)
                }
                NSApp.terminate(nil)
            } catch is CancellationError { state = .available(offer) }
            catch { state = .failed(error.localizedDescription, offer) }
        }
    }

    func cancelDownload() {
        if case .downloading = state { installTask?.cancel() }
    }
}
