import XCTest
@testable import AuralinkCore

/// Tests for collection root resolution and the collection manifest.
///
/// These matter because the collection is user-owned and often lives outside
/// Application Support (a git checkout). A silently wrong root means the app shows
/// an empty headphone list and the user cannot tell why.
final class CollectionPathsTests: XCTestCase {

    private var savedDefault: String?

    override func setUpWithError() throws {
        try super.setUpWithError()
        savedDefault = UserDefaults.standard.string(forKey: AuralinkPaths.collectionDirectoryDefaultsKey)
        UserDefaults.standard.removeObject(forKey: AuralinkPaths.collectionDirectoryDefaultsKey)
    }

    override func tearDownWithError() throws {
        if let savedDefault {
            UserDefaults.standard.set(savedDefault, forKey: AuralinkPaths.collectionDirectoryDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: AuralinkPaths.collectionDirectoryDefaultsKey)
        }
        savedDefault = nil
        try super.tearDownWithError()
    }

    /// Whether the environment override is set; it wins over `UserDefaults`, so the
    /// defaults-based expectations below only hold when it is absent.
    private var environmentOverrideActive: Bool {
        let raw = ProcessInfo.processInfo.environment[AuralinkPaths.collectionDirectoryEnvKey]
        return (raw?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
    }

    // MARK: Root resolution

    func testDefaultCollectionRootIsOutsideApplicationSupport() throws {
        try XCTSkipIf(environmentOverrideActive, "AURALINK_COLLECTION_DIR is set in this environment.")
        let expected = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(AuralinkPaths.defaultCollectionDirectoryName, isDirectory: true)
        XCTAssertEqual(AuralinkPaths.collectionDirectory.standardizedFileURL, expected.standardizedFileURL)
        // The whole point of the split: the collection is not app-managed state.
        XCTAssertFalse(
            AuralinkPaths.collectionDirectory.path.hasPrefix(AuralinkPaths.supportDirectory.path),
            "The collection must not default inside Application Support."
        )
    }

    func testDefaultCollectionRootAvoidsTCCProtectedDocuments() throws {
        try XCTSkipIf(environmentOverrideActive, "AURALINK_COLLECTION_DIR is set in this environment.")
        // ~/Documents triggers a TCC prompt whose grant an ad-hoc signed build loses
        // on every rebuild, which would look like the collection vanishing.
        XCTAssertFalse(AuralinkPaths.collectionDirectory.path.contains("/Documents/"))
    }

    func testUserDefaultsOverrideIsHonored() throws {
        try XCTSkipIf(environmentOverrideActive, "AURALINK_COLLECTION_DIR is set in this environment.")
        let custom = FileManager.default.temporaryDirectory
            .appendingPathComponent("auralink-custom-collection", isDirectory: true)
        UserDefaults.standard.set(custom.path, forKey: AuralinkPaths.collectionDirectoryDefaultsKey)

        XCTAssertEqual(AuralinkPaths.collectionDirectory.standardizedFileURL, custom.standardizedFileURL)
        XCTAssertEqual(AuralinkPaths.collectionHeadphonesDirectory.lastPathComponent, "headphones")
        XCTAssertEqual(AuralinkPaths.collectionPresetsDirectory.lastPathComponent, "presets")
        XCTAssertEqual(AuralinkPaths.collectionManifestFile.lastPathComponent, "manifest.json")
    }

    func testTildeInOverrideIsExpanded() throws {
        try XCTSkipIf(environmentOverrideActive, "AURALINK_COLLECTION_DIR is set in this environment.")
        UserDefaults.standard.set("~/my-cans", forKey: AuralinkPaths.collectionDirectoryDefaultsKey)
        let resolved = AuralinkPaths.collectionDirectory
        XCTAssertFalse(resolved.path.contains("~"))
        XCTAssertTrue(resolved.path.hasSuffix("/my-cans"))
    }

    /// A relative path would follow the process working directory, which for a
    /// menubar app is wherever Launch Services happened to start it.
    func testRelativeAndBlankOverridesAreIgnored() throws {
        try XCTSkipIf(environmentOverrideActive, "AURALINK_COLLECTION_DIR is set in this environment.")
        let fallback = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(AuralinkPaths.defaultCollectionDirectoryName, isDirectory: true)

        for bad in ["relative/path", "   ", ""] {
            UserDefaults.standard.set(bad, forKey: AuralinkPaths.collectionDirectoryDefaultsKey)
            XCTAssertEqual(AuralinkPaths.collectionDirectory.standardizedFileURL,
                           fallback.standardizedFileURL,
                           "Override '\(bad)' should have been rejected.")
        }
    }

    // MARK: Manifest

    func testManifestRoundTrips() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("auralink-manifest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("manifest.json")

        let written = CollectionManifest(name: "Simon's Cans")
        try written.write(to: url)

        let read = CollectionManifest.read(from: url)
        XCTAssertEqual(read?.name, "Simon's Cans")
        XCTAssertEqual(read?.schemaVersion, CollectionManifest.currentSchemaVersion)
        XCTAssertEqual(read?.isFromNewerBuild, false)
    }

    func testEnsureExistsCreatesOnceAndNeverOverwrites() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("auralink-manifest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("manifest.json")

        try CollectionManifest(name: "Mine").write(to: url)
        let kept = CollectionManifest.ensureExists(at: url)
        XCTAssertEqual(kept.name, "Mine", "The user's own manifest metadata must survive.")

        let freshURL = root.appendingPathComponent("fresh/manifest.json")
        let created = CollectionManifest.ensureExists(at: freshURL)
        XCTAssertEqual(created.schemaVersion, CollectionManifest.currentSchemaVersion)
        XCTAssertNotNil(CollectionManifest.read(from: freshURL))
    }

    func testManifestFromNewerBuildIsFlagged() {
        let future = CollectionManifest(schemaVersion: CollectionManifest.currentSchemaVersion + 1)
        XCTAssertTrue(future.isFromNewerBuild)
    }

    func testMissingManifestReadsAsNil() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("auralink-absent-\(UUID().uuidString)/manifest.json")
        XCTAssertNil(CollectionManifest.read(from: url))
    }
}
