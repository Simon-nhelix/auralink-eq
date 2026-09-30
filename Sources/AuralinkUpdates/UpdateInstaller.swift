import CoreServices
import Foundation

// Adapted from MiSTer FTP (MIT); see third_party/licenses/MiSTer-FTP-LICENSE.

public struct AppBundleInfo: Equatable, Sendable {
    public let identifier: String
    public let version: AppVersion
}

/// Downloads a release, proves it is ours, and puts it in place of the running app.
public struct UpdatePreparer: Sendable {
    public let publicKey: String
    public let bundleIdentifier: String
    public let currentVersion: AppVersion
    public let workFolder: URL
    public let allowingLocalFiles: Bool

    public init(publicKey: String, bundleIdentifier: String, currentVersion: AppVersion, workFolder: URL, allowingLocalFiles: Bool = false) {
        self.publicKey = publicKey
        self.bundleIdentifier = bundleIdentifier
        self.currentVersion = currentVersion
        self.workFolder = workFolder
        self.allowingLocalFiles = allowingLocalFiles
    }

    /// Downloads the archive, checks its signature, unpacks it and checks the app inside.
    /// Returns the unpacked app, ready for `UpdateInstaller.swap`.
    public func prepare(_ offer: UpdateOffer, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> URL {
        guard let signatureURL = offer.signatureURL else { throw UpdateError.unsigned }
        guard ReleaseFeed.isAllowed(offer.archiveURL, allowingLocalFiles: allowingLocalFiles),
              ReleaseFeed.isAllowed(signatureURL, allowingLocalFiles: allowingLocalFiles) else { throw UpdateError.insecureURL }
        guard offer.version > currentVersion else { throw UpdateError.notNewer }
        guard offer.archiveSize >= 0, offer.archiveSize <= ReleaseFeed.maximumArchiveSize else { throw UpdateError.badResponse }
        try Task.checkCancellation()
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: workFolder)
        try fileManager.createDirectory(at: workFolder, withIntermediateDirectories: true)

        let signature = try await downloadText(signatureURL)
        let archive = workFolder.appendingPathComponent("update.zip")
        try await FileDownloader(destination: archive, maximumSize: ReleaseFeed.maximumArchiveSize, allowingLocalFiles: allowingLocalFiles, progress: progress).run(offer.archiveURL)
        try Task.checkCancellation()

        let data = try Data(contentsOf: archive, options: .mappedIfSafe)
        guard offer.archiveSize == 0 || data.count == offer.archiveSize else { throw UpdateError.badSignature }
        guard UpdateSignature.isValid(signature: signature, for: data, publicKey: publicKey) else {
            throw UpdateError.badSignature
        }
        let app = try UpdateInstaller.unpack(archive, into: workFolder.appendingPathComponent("unpacked"))
        let info = try UpdateInstaller.bundleInfo(of: app)
        guard info.identifier == bundleIdentifier, info.version == offer.version else { throw UpdateError.wrongApp }
        guard info.version > currentVersion else { throw UpdateError.notNewer }
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")), format: nil) as? [String: Any]
        // Key rotation needs an explicit migration. An accidental new/missing key
        // must not strand installed users after this update.
        guard plist?["AuralinkUpdatePublicKey"] as? String == publicKey else { throw UpdateError.wrongApp }
        try UpdateInstaller.checkSystemCompatibility(of: app)
        try UpdateInstaller.verifyCodeSignature(of: app)
        try Task.checkCancellation()
        return app
    }

    private func downloadText(_ url: URL) async throws -> String {
        let destination = workFolder.appendingPathComponent("update.sig")
        do {
            try await FileDownloader(destination: destination, maximumSize: 256, allowingLocalFiles: allowingLocalFiles, progress: { _, _ in }).run(url)
            let data = try Data(contentsOf: destination)
            guard let text = String(data: data, encoding: .utf8) else { throw UpdateError.badSignature }
            return text
        } catch is CancellationError { throw CancellationError()
        } catch let error as UpdateError {
            throw error
        } catch {
            throw UpdateError.download(error.localizedDescription)
        }
    }
}

public enum UpdateInstaller {
    /// Throws when the running app cannot be replaced where it is.
    public static func checkReplaceable(_ app: URL) throws {
        // Gatekeeper runs apps opened straight from a download from a read-only copy.
        if app.path.contains("/AppTranslocation/") { throw UpdateError.translocated }
        guard app.pathExtension == "app", !((try? app.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink ?? true) else { throw UpdateError.install("not an app bundle") }
        let parent = app.deletingLastPathComponent()
        let fileManager = FileManager.default
        guard fileManager.isWritableFile(atPath: parent.path), fileManager.isWritableFile(atPath: app.path) else {
            throw UpdateError.notWritable(fileManager.displayName(atPath: parent.path))
        }
    }

    public static func bundleInfo(of app: URL) throws -> AppBundleInfo {
        let plistURL = app.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let identifier = plist["CFBundleIdentifier"] as? String,
              let versionText = (plist["AuralinkUpdateVersion"] ?? plist["CFBundleShortVersionString"]) as? String,
              let version = AppVersion(versionText) else {
            throw UpdateError.wrongApp
        }
        return AppBundleInfo(identifier: identifier, version: version)
    }

    public static func checkSystemCompatibility(of app: URL, systemVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion) throws {
        let data = try Data(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        guard let text = plist?["LSMinimumSystemVersion"] as? String else { return }
        guard let minimum = AppVersion(text),
              let current = AppVersion("\(systemVersion.majorVersion).\(systemVersion.minorVersion).\(systemVersion.patchVersion)"), current >= minimum else {
            throw UpdateError.unsupportedSystem
        }
    }

    /// Unzips with ditto, which keeps the bundle's symlinks, permissions and signature.
    public static func unpack(_ archive: URL, into folder: URL) throws -> URL {
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try run("/usr/bin/ditto", ["-x", "-k", archive.path, folder.path], failure: .noAppInArchive)
        let apps = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            .filter {
                let values = try? $0.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                return $0.pathExtension == "app" && values?.isDirectory == true && values?.isSymbolicLink == false
            }
        guard apps.count == 1 else { throw UpdateError.noAppInArchive }
        return apps[0]
    }

    public static func verifyCodeSignature(of app: URL) throws {
        try run("/usr/bin/codesign", ["--verify", "--strict", app.path], failure: .codeSignature)
    }

    /// Puts `newApp` at `installedApp` in one atomic swap. The old copy ends up in the
    /// returned temporary folder, which `relaunchAfterExit` deletes.
    ///
    /// Swapping directory entries never writes into the running app's files, so the
    /// running process keeps working until it quits.
    public static func swap(installedApp: URL, with newApp: URL) throws -> URL {
        let fileManager = FileManager.default
        let staging: URL
        do {
            // A temporary folder on the same volume, so the swap is a rename.
            staging = try fileManager.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: installedApp, create: true)
        } catch {
            throw UpdateError.install(error.localizedDescription)
        }
        let staged = staging.appendingPathComponent(installedApp.lastPathComponent)
        do {
            try fileManager.moveItem(at: newApp, to: staged)
        } catch {
            try? fileManager.removeItem(at: staging)
            throw UpdateError.install(error.localizedDescription)
        }
        if renamex_np(staged.path, installedApp.path, UInt32(RENAME_SWAP)) != 0 {
            let reason = String(cString: strerror(errno))
            try? fileManager.removeItem(at: staging)
            throw UpdateError.install(reason)
        }
        // Launch Services still remembers the old version at this path.
        LSRegisterURL(installedApp as CFURL, true)
        return staging
    }

    /// Audio must be restored before replacement. If launching the helper fails,
    /// restore the old directory entry so this running app still matches its bundle.
    public static func commit(installedApp: URL, with newApp: URL,
                              beforeReplacement: () throws -> Void,
                              scheduleRelaunch: (URL, URL) throws -> Void) throws {
        try checkReplaceable(installedApp)
        try beforeReplacement()
        let backup = try swap(installedApp: installedApp, with: newApp)
        do { try scheduleRelaunch(installedApp, backup) }
        catch {
            let oldApp = backup.appendingPathComponent(installedApp.lastPathComponent)
            if renamex_np(oldApp.path, installedApp.path, UInt32(RENAME_SWAP)) == 0 {
                LSRegisterURL(installedApp as CFURL, true)
                try? FileManager.default.removeItem(at: backup)
            }
            throw UpdateError.install(error.localizedDescription)
        }
    }

    /// Starts a small shell process that waits for `processID` to end, deletes
    /// `cleanup`, then opens `app`. Tests may suppress opening their fixture app.
    public static func relaunchAfterExit(app: URL, cleanup: URL?, processID: Int32 = getpid(), openApp: Bool = true) throws {
        let cleanupPath = cleanup.flatMap { isTemporaryFolder($0) ? $0.path : nil } ?? ""
        let script = """
        pid="$1"; app="$2"; cleanup="$3"
        attempts=0
        while kill -0 "$pid" 2>/dev/null; do
          attempts=$((attempts + 1))
          if [ "$attempts" -ge 600 ]; then exit 1; fi
          sleep 0.2
        done
        if [ -n "$cleanup" ]; then rm -rf "$cleanup"; fi
        if [ "$4" = "yes" ]; then /usr/bin/open "$app"; fi
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "auralink-update", String(processID), app.path, cleanupPath, openApp ? "yes" : "no"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    /// Only folders the system makes for replacing items are deleted automatically.
    static func isTemporaryFolder(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return path.contains("/TemporaryItems/") || path.hasPrefix(FileManager.default.temporaryDirectory.standardizedFileURL.path + "/")
    }

    private static func run(_ tool: String, _ arguments: [String], failure: UpdateError) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw failure
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw failure }
    }
}
