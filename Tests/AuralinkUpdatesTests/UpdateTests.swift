// Adapted from MiSTer FTP (MIT); see third_party/licenses/MiSTer-FTP-LICENSE.
import CryptoKit
import XCTest
@testable import AuralinkUpdates

final class AuralinkUpdatesTests: XCTestCase {
    // MARK: Versions

    func testVersionParsingAndOrder() throws {
        XCTAssertEqual(AppVersion("v1.0.1")?.description, "1.0.1")
        XCTAssertEqual(AppVersion("1.2.0-beta.1")?.description, "1.2.0-beta.1")
        XCTAssertEqual(AppVersion("1.0"), AppVersion("1.0.0"))
        XCTAssertLessThan(try XCTUnwrap(AppVersion("1.0.0")), try XCTUnwrap(AppVersion("1.0.1")))
        XCTAssertLessThan(try XCTUnwrap(AppVersion("1.9.9")), try XCTUnwrap(AppVersion("1.10")))
        XCTAssertLessThan(try XCTUnwrap(AppVersion("0.9")), try XCTUnwrap(AppVersion("1")))
        XCTAssertFalse(try XCTUnwrap(AppVersion("2.0")) < XCTUnwrap(AppVersion("2.0.0")))
        for bad in ["", "v", "1..0", "1.a", "-1.0", "1.2.3.4.5", "１.0"] {
            XCTAssertNil(AppVersion(bad), bad)
        }
    }

    func testPrereleasePrecedenceAndBuildMetadata() throws {
        let versions = ["0.1.0-alpha.1", "0.1.0-alpha.2", "0.1.0-alpha.10", "0.1.0-beta.1", "0.1.0-rc.1", "0.1.0", "0.1.1-alpha.1"]
        let parsed = try versions.map { try XCTUnwrap(AppVersion($0)) }
        XCTAssertEqual(parsed.reversed().sorted(), parsed)
        XCTAssertEqual(AppVersion("0.1.0+12"), AppVersion("0.1.0+13"))
        XCTAssertEqual(AppVersion("0.1.0-alpha.1+test")?.description, "0.1.0-alpha.1")
        for bad in ["1.0.0-", "1.0.0+", "1.0.0-alpha..1", "1.0.0-alpha.01", "1.0.0-한글", "1.0.0+a+b"] {
            XCTAssertNil(AppVersion(bad), bad)
        }
        XCTAssertEqual(Set([AppVersion("1.0")!, AppVersion("1.0.0+1")!]).count, 1)
    }

    private func release(version: String = "1.0.1", prerelease: Bool = false,
                         edit: (inout [String: Any]) -> Void = { _ in }) throws -> GitHubRelease {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(releaseJSON.utf8)) as? [String: Any])
        object["tag_name"] = "v" + version
        object["prerelease"] = prerelease
        var assets = object["assets"] as! [[String: Any]]
        for index in assets.indices {
            assets[index]["name"] = (assets[index]["name"] as! String).replacingOccurrences(of: "1.0.1", with: version)
        }
        object["assets"] = assets
        edit(&object)
        return try JSONDecoder().decode(GitHubRelease.self, from: JSONSerialization.data(withJSONObject: object))
    }

    func testReleaseChannelsSelectHighestCompatibleVersion() throws {
        let releases = try [release(version: "1.0.1"), release(version: "1.1.0-alpha.2", prerelease: true),
                            release(version: "1.1.0-beta.1", prerelease: true), release(version: "1.0.2")]
        XCTAssertEqual(ReleaseFeed.newestOffer(in: releases, channel: .stable)?.version, AppVersion("1.0.2"))
        XCTAssertEqual(ReleaseFeed.newestOffer(in: releases, channel: .beta)?.version, AppVersion("1.1.0-beta.1"))
        XCTAssertEqual(ReleaseFeed.newestOffer(in: releases, channel: .alpha)?.version, AppVersion("1.1.0-beta.1"))
        XCTAssertNil(ReleaseFeed.offer(from: try release(version: "1.1.0-nightly.1", prerelease: true), channel: .alpha))
        XCTAssertNil(ReleaseFeed.offer(from: try release(version: "1.1.0-alpha.2", prerelease: true)))
    }

    func testFeedRejectsMismatchedArchivesAndUnsafeAssets() throws {
        XCTAssertNil(ReleaseFeed.offer(from: try release(version: "1.0.2") { object in
            var assets = object["assets"] as! [[String: Any]]
            assets[0]["name"] = "Auralink-EQ-1.0.1.zip"
            object["assets"] = assets
        }))
        for size: Int64 in [-1, 0, ReleaseFeed.maximumArchiveSize + 1] {
            XCTAssertNil(ReleaseFeed.offer(from: try release { object in
                var assets = object["assets"] as! [[String: Any]]
                assets[0]["size"] = size; object["assets"] = assets
            }))
        }
        XCTAssertNil(ReleaseFeed.offer(from: try release { $0["html_url"] = "javascript:alert(1)" }))
        XCTAssertNil(ReleaseFeed.offer(from: try release { object in
            var assets = object["assets"] as! [[String: Any]]
            assets[0]["browser_download_url"] = "http://example.com/a.zip"
            object["assets"] = assets
        }))
        for repository in ["", "owner", "owner/repo/extra", "owner/../repo", "owner/repo?bad", "owner/repo#bad"] {
            XCTAssertNil(ReleaseFeed.releasesURL(repository: repository))
        }
    }

    // MARK: Release feed

    private let releaseJSON = """
    {
      "tag_name": "v1.0.1",
      "name": "Auralink EQ 1.0.1",
      "body": "- Improve audio recovery.\\n- In-app updates.",
      "html_url": "https://github.com/Simon-nhelix/auralink-eq/releases/tag/v1.0.1",
      "draft": false,
      "prerelease": false,
      "assets": [
        {"name": "Auralink-EQ-1.0.1.zip", "size": 2187894,
         "browser_download_url": "https://github.com/Simon-nhelix/auralink-eq/releases/download/v1.0.1/Auralink-EQ-1.0.1.zip"},
        {"name": "Auralink-EQ-1.0.1.zip.sig", "size": 89,
         "browser_download_url": "https://github.com/Simon-nhelix/auralink-eq/releases/download/v1.0.1/Auralink-EQ-1.0.1.zip.sig"}
      ]
    }
    """

    func testReleaseDecodingAndOffer() throws {
        let release = try JSONDecoder().decode(GitHubRelease.self, from: Data(releaseJSON.utf8))
        let offer = try XCTUnwrap(ReleaseFeed.offer(from: release))
        XCTAssertEqual(offer.version, AppVersion("1.0.1"))
        XCTAssertEqual(offer.title, "Auralink EQ 1.0.1")
        XCTAssertEqual(offer.archiveSize, 2_187_894)
        XCTAssertEqual(offer.archiveURL.lastPathComponent, "Auralink-EQ-1.0.1.zip")
        XCTAssertEqual(offer.signatureURL?.lastPathComponent, "Auralink-EQ-1.0.1.zip.sig")
        XCTAssertTrue(offer.notes.hasPrefix("- Improve audio"))
        XCTAssertEqual(ReleaseFeed.releasesURL(repository: "Simon-nhelix/auralink-eq")?.absoluteString,
                       "https://api.github.com/repos/Simon-nhelix/auralink-eq/releases?per_page=100")
    }

    func testOfferRules() throws {
        func release(_ edit: (inout [String: Any]) -> Void) throws -> GitHubRelease {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(releaseJSON.utf8)) as? [String: Any])
            edit(&object)
            return try JSONDecoder().decode(GitHubRelease.self, from: JSONSerialization.data(withJSONObject: object))
        }
        XCTAssertNil(ReleaseFeed.offer(from: try release { $0["draft"] = true }))
        XCTAssertNil(ReleaseFeed.offer(from: try release { $0["prerelease"] = true }))
        XCTAssertNil(ReleaseFeed.offer(from: try release { $0["tag_name"] = "latest" }))
        XCTAssertNil(ReleaseFeed.offer(from: try release { $0["assets"] = [] }))
        // A release without the signature file can still be offered, but only as a link.
        let unsigned = try release { object in
            object["assets"] = (object["assets"] as! [[String: Any]]).filter { !($0["name"] as! String).hasSuffix(".sig") }
        }
        XCTAssertNil(try XCTUnwrap(ReleaseFeed.offer(from: unsigned)).signatureURL)
    }

    func testOnlySafeDownloadAddresses() {
        XCTAssertTrue(ReleaseFeed.isAllowed(URL(string: "https://github.com/a.zip")!))
        XCTAssertFalse(ReleaseFeed.isAllowed(URL(string: "http://127.0.0.1:8765/a.zip")!))
        XCTAssertFalse(ReleaseFeed.isAllowed(URL(fileURLWithPath: "/tmp/a.zip")))
        XCTAssertTrue(ReleaseFeed.isAllowed(URL(fileURLWithPath: "/tmp/a.zip"), allowingLocalFiles: true))
        XCTAssertFalse(ReleaseFeed.isAllowed(URL(string: "http://github.com/a.zip")!))
        XCTAssertFalse(ReleaseFeed.isAllowed(URL(string: "ftp://example.com/a.zip")!))
    }

    func testFeedDistinguishesNoReleasesFromHTTPAndDecodeFailures() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReleaseResponseStub.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let url = ReleaseFeed.releasesURL(repository: "owner/repo")!
        ReleaseResponseStub.status = 200
        ReleaseResponseStub.body = Data("[]".utf8)
        let releases = try await ReleaseFeed.fetchReleases(from: url, userAgent: "Auralink-test", session: session)
        XCTAssertTrue(releases.isEmpty)
        ReleaseResponseStub.status = 404
        await assertThrows(.server(404)) { _ = try await ReleaseFeed.fetchReleases(from: url, userAgent: "test", session: session) }
        ReleaseResponseStub.status = 429
        await assertThrows(.rateLimited) { _ = try await ReleaseFeed.fetchReleases(from: url, userAgent: "test", session: session) }
        ReleaseResponseStub.status = 200
        ReleaseResponseStub.body = Data("not JSON".utf8)
        await assertThrows(.badResponse) { _ = try await ReleaseFeed.fetchReleases(from: url, userAgent: "test", session: session) }
    }

    func testCancelledPreparationLeavesInstalledAppUntouched() async throws {
        let installed = try makeApp(in: root.appendingPathComponent("installed"), version: "1.0.0")
        let newApp = try makeApp(in: root.appendingPathComponent("new"), version: "1.0.1")
        let offer = try makeOffer(for: newApp, version: "1.0.1")
        let ready = self.preparer(current: "1.0.0")
        let task = Task {
            // Ensure cancellation is already requested before download/preparation.
            while !Task.isCancelled { await Task.yield() }
            return try await ready.prepare(offer) { _, _ in }
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("cancelled preparation should not succeed") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(try UpdateInstaller.bundleInfo(of: installed).version, AppVersion("1.0.0"))
    }

    // MARK: Signatures

    func testSignatures() throws {
        let key = Curve25519.Signing.PrivateKey()
        let privateKey = key.rawRepresentation.base64EncodedString()
        let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
        let data = Data("Auralink-EQ-1.0.1.zip".utf8)
        let signature = try UpdateSignature.sign(data, privateKey: privateKey)

        XCTAssertTrue(UpdateSignature.isValid(signature: signature, for: data, publicKey: publicKey))
        XCTAssertTrue(UpdateSignature.isValid(signature: signature + "\n", for: data, publicKey: publicKey + "\n"))
        XCTAssertFalse(UpdateSignature.isValid(signature: signature, for: data + Data([0]), publicKey: publicKey))
        let otherKey = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        XCTAssertFalse(UpdateSignature.isValid(signature: signature, for: data, publicKey: otherKey))
        XCTAssertFalse(UpdateSignature.isValid(signature: "not base64", for: data, publicKey: publicKey))
        XCTAssertFalse(UpdateSignature.isValid(signature: signature, for: data, publicKey: ""))
    }

    // MARK: Download, check, swap

    private var root: URL!
    private let signingKey = Curve25519.Signing.PrivateKey()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("AuralinkUpdatesTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// A tiny signed app bundle whose executable is a copy of /usr/bin/true.
    private func makeApp(in folder: URL, identifier: String = "com.example.auralink-test", version: String, extra: [String: Any] = [:]) throws -> URL {
        let app = folder.appendingPathComponent("Test App.app")
        let macOS = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: macOS.appendingPathComponent("Test App").path)
        var plist: [String: Any] = [
            "CFBundleIdentifier": identifier,
            "CFBundleShortVersionString": version,
            "CFBundleExecutable": "Test App",
            "CFBundlePackageType": "APPL",
            "AuralinkUpdateVersion": version,
            "AuralinkUpdatePublicKey": signingKey.publicKey.rawRepresentation.base64EncodedString(),
        ]
        plist.merge(extra) { _, new in new }
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        try shell("/usr/bin/codesign", "--force", "--sign", "-", app.path)
        return app
    }

    /// Zips `app` like the release script does and signs the zip. Returns an offer with file URLs.
    private func makeOffer(for app: URL, version: String, signWith key: Curve25519.Signing.PrivateKey? = nil) throws -> UpdateOffer {
        let release = root.appendingPathComponent("release-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: release, withIntermediateDirectories: true)
        let zip = release.appendingPathComponent("Auralink-EQ-\(version).zip")
        try shell("/usr/bin/ditto", "-c", "-k", "--keepParent", app.path, zip.path)
        let signature = try UpdateSignature.sign(Data(contentsOf: zip), privateKey: (key ?? signingKey).rawRepresentation.base64EncodedString())
        let sig = release.appendingPathComponent(zip.lastPathComponent + ".sig")
        try Data(signature.utf8).write(to: sig)
        return UpdateOffer(version: AppVersion(version)!, title: "Test \(version)", notes: "", pageURL: URL(string: "https://example.com")!,
                           archiveURL: zip, archiveSize: 0, signatureURL: sig)
    }

    private func preparer(current: String, identifier: String = "com.example.auralink-test") -> UpdatePreparer {
        UpdatePreparer(publicKey: signingKey.publicKey.rawRepresentation.base64EncodedString(), bundleIdentifier: identifier,
                       currentVersion: AppVersion(current)!, workFolder: root.appendingPathComponent("work-\(UUID().uuidString)"), allowingLocalFiles: true)
    }

    func testPrepareSwapAndCleanUp() async throws {
        let installedFolder = root.appendingPathComponent("Applications")
        try FileManager.default.createDirectory(at: installedFolder, withIntermediateDirectories: true)
        let installed = try makeApp(in: installedFolder, version: "1.0.0")
        let newBuild = try makeApp(in: root.appendingPathComponent("build"), version: "1.0.1")
        let offer = try makeOffer(for: newBuild, version: "1.0.1")

        try UpdateInstaller.checkReplaceable(installed)
        let progress = ProgressLog()
        let unpacked = try await preparer(current: "1.0.0").prepare(offer) { done, total in progress.add(done, total) }
        XCTAssertEqual(try UpdateInstaller.bundleInfo(of: unpacked).version, AppVersion("1.0.1"))
        XCTAssertGreaterThan(progress.last, 0)

        let oldCopyFolder = try UpdateInstaller.swap(installedApp: installed, with: unpacked)
        XCTAssertEqual(try UpdateInstaller.bundleInfo(of: installed).version, AppVersion("1.0.1"))
        let oldCopy = oldCopyFolder.appendingPathComponent(installed.lastPathComponent)
        XCTAssertEqual(try UpdateInstaller.bundleInfo(of: oldCopy).version, AppVersion("1.0.0"))
        XCTAssertNoThrow(try UpdateInstaller.verifyCodeSignature(of: installed))
        XCTAssertTrue(UpdateInstaller.isTemporaryFolder(oldCopyFolder))

        // The helper waits for a process that already ended, then deletes the old copy.
        let finished = Process()
        finished.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try finished.run()
        finished.waitUntilExit()
        try UpdateInstaller.relaunchAfterExit(app: installed, cleanup: oldCopyFolder, processID: finished.processIdentifier, openApp: false)
        for _ in 0..<50 where FileManager.default.fileExists(atPath: oldCopyFolder.path) {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldCopyFolder.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: installed.path))
    }

    func testRelaunchOpensTheAppAfterTheProcessEnds() async throws {
        // A bundle whose executable is a shell script that leaves a marker file.
        let marker = root.appendingPathComponent("launched")
        let app = root.appendingPathComponent("Launch Probe.app")
        let macOS = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let executable = macOS.appendingPathComponent("probe")
        try "#!/bin/sh\ntouch \"\(marker.path)\"\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let plist: [String: Any] = [
            "CFBundleIdentifier": "com.example.auralink-launch-probe",
            "CFBundleExecutable": "probe",
            "CFBundlePackageType": "APPL",
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))

        let finished = Process()
        finished.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try finished.run()
        finished.waitUntilExit()
        try UpdateInstaller.relaunchAfterExit(app: app, cleanup: nil, processID: finished.processIdentifier)
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: marker.path) {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path), "the helper did not open the app")
    }

    func testPrepareRefusesBadUpdates() async throws {
        let newBuild = try makeApp(in: root.appendingPathComponent("build"), version: "1.0.1")

        let forged = try makeOffer(for: newBuild, version: "1.0.1", signWith: Curve25519.Signing.PrivateKey())
        await assertThrows(.badSignature) { _ = try await self.preparer(current: "1.0.0").prepare(forged) { _, _ in } }

        let good = try makeOffer(for: newBuild, version: "1.0.1")
        await assertThrows(.wrongApp) { _ = try await self.preparer(current: "1.0.0", identifier: "com.example.other").prepare(good) { _, _ in } }
        await assertThrows(.notNewer) { _ = try await self.preparer(current: "1.0.1").prepare(good) { _, _ in } }

        let unsigned = UpdateOffer(version: good.version, title: "", notes: "", pageURL: good.pageURL,
                                   archiveURL: good.archiveURL, archiveSize: 0, signatureURL: nil)
        await assertThrows(.unsigned) { _ = try await self.preparer(current: "1.0.0").prepare(unsigned) { _, _ in } }

        // The tag says 1.0.2 but the app inside is 1.0.1.
        let mislabeled = UpdateOffer(version: AppVersion("1.0.2")!, title: "", notes: "", pageURL: good.pageURL,
                                     archiveURL: good.archiveURL, archiveSize: 0, signatureURL: good.signatureURL)
        await assertThrows(.wrongApp) { _ = try await self.preparer(current: "1.0.0").prepare(mislabeled) { _, _ in } }
    }

    func testPrepareAllowsAlphaUpgradeAndRefusesDowngrade() async throws {
        let app = try makeApp(in: root.appendingPathComponent("alpha"), version: "0.1.0-alpha.2")
        let offer = try makeOffer(for: app, version: "0.1.0-alpha.2")
        let prepared = try await preparer(current: "0.1.0-alpha.1").prepare(offer) { _, _ in }
        XCTAssertEqual(try UpdateInstaller.bundleInfo(of: prepared).version, AppVersion("0.1.0-alpha.2"))
        await assertThrows(.notNewer) { _ = try await self.preparer(current: "0.1.0").prepare(offer) { _, _ in } }
    }

    func testPrepareRefusesDamagedCodeUnsupportedOSAndChangedKey() async throws {
        let damaged = try makeApp(in: root.appendingPathComponent("damaged"), version: "1.0.1")
        try Data("tampered".utf8).write(to: damaged.appendingPathComponent("Contents/MacOS/Test App"))
        let damagedOffer = try makeOffer(for: damaged, version: "1.0.1")
        await assertThrows(.codeSignature) { _ = try await self.preparer(current: "1.0.0").prepare(damagedOffer) { _, _ in } }
        let future = try makeApp(in: root.appendingPathComponent("future"), version: "1.0.1", extra: ["LSMinimumSystemVersion": "99.0"])
        let futureOffer = try makeOffer(for: future, version: "1.0.1")
        await assertThrows(.unsupportedSystem) { _ = try await self.preparer(current: "1.0.0").prepare(futureOffer) { _, _ in } }
        let changedKey = try makeApp(in: root.appendingPathComponent("key"), version: "1.0.1", extra: ["AuralinkUpdatePublicKey": ""])
        let keyOffer = try makeOffer(for: changedKey, version: "1.0.1")
        await assertThrows(.wrongApp) { _ = try await self.preparer(current: "1.0.0").prepare(keyOffer) { _, _ in } }
    }

    func testAudioRestorationFailurePreventsReplacement() throws {
        let installed = try makeApp(in: root.appendingPathComponent("installed"), version: "1.0.0")
        let newApp = try makeApp(in: root.appendingPathComponent("new"), version: "1.0.1")
        var relaunchScheduled = false
        XCTAssertThrowsError(try UpdateInstaller.commit(installedApp: installed, with: newApp, beforeReplacement: {
            throw UpdateError.install("output restoration failed")
        }, scheduleRelaunch: { _, _ in relaunchScheduled = true }))
        XCTAssertFalse(relaunchScheduled)
        XCTAssertEqual(try UpdateInstaller.bundleInfo(of: installed).version, AppVersion("1.0.0"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: newApp.path))
    }

    func testCommitRestoresAudioBeforeSwapAndRollsBackHelperFailure() throws {
        let installed = try makeApp(in: root.appendingPathComponent("installed"), version: "1.0.0")
        let newApp = try makeApp(in: root.appendingPathComponent("new"), version: "1.0.1")
        var restored = false
        XCTAssertThrowsError(try UpdateInstaller.commit(installedApp: installed, with: newApp, beforeReplacement: {
            XCTAssertEqual(try UpdateInstaller.bundleInfo(of: installed).version, AppVersion("1.0.0"))
            restored = true
        }, scheduleRelaunch: { app, _ in
            XCTAssertTrue(restored)
            XCTAssertEqual(try UpdateInstaller.bundleInfo(of: app).version, AppVersion("1.0.1"))
            throw UpdateError.install("helper could not start")
        }))
        XCTAssertEqual(try UpdateInstaller.bundleInfo(of: installed).version, AppVersion("1.0.0"))
        XCTAssertNoThrow(try UpdateInstaller.verifyCodeSignature(of: installed))
    }

    func testReplaceableChecks() throws {
        XCTAssertThrowsError(try UpdateInstaller.checkReplaceable(URL(fileURLWithPath: "/private/var/folders/x/AppTranslocation/ABC/d/Auralink EQ.app"))) {
            XCTAssertEqual($0 as? UpdateError, .translocated)
        }
        XCTAssertThrowsError(try UpdateInstaller.checkReplaceable(URL(fileURLWithPath: "/System/Applications/Calculator.app"))) {
            guard case .notWritable = $0 as? UpdateError else { return XCTFail("\($0)") }
        }
        XCTAssertFalse(UpdateInstaller.isTemporaryFolder(URL(fileURLWithPath: "/Applications")))
    }

    // MARK: Helpers

    private func assertThrows(_ expected: UpdateError, file: StaticString = #filePath, line: UInt = #line, _ body: () async throws -> Void) async {
        do {
            try await body()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? UpdateError, expected, file: file, line: line)
        }
    }

    private func shell(_ tool: String, _ arguments: String...) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "\(tool) \(arguments)")
    }
}

private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var last: Int64 = 0

    func add(_ done: Int64, _ total: Int64) {
        lock.lock()
        last = done
        lock.unlock()
    }
}

private final class ReleaseResponseStub: URLProtocol {
    static var status = 200
    static var body = Data()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
