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

    // MARK: Migration detection

    /// Builds a scratch legacy/collection layout and runs the pure migration check.
    private func withMigrationFixture(
        legacyHeadphones: [String] = [],
        legacyPresets: [String] = [],
        aggregateProfiles: [HeadphoneProfile] = [],
        collectionHeadphones: [String] = [],
        collectionPresets: [String] = [],
        body: (Bool) -> Void
    ) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("auralink-migration-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let legacyHP = root.appendingPathComponent("legacy/headphones", isDirectory: true)
        let legacyPR = root.appendingPathComponent("legacy/presets", isDirectory: true)
        let aggregate = root.appendingPathComponent("legacy/headphone-profiles.json")
        let collHP = root.appendingPathComponent("collection/headphones", isDirectory: true)
        let collPR = root.appendingPathComponent("collection/presets", isDirectory: true)

        for dir in [legacyHP, legacyPR, collHP, collPR] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        for id in legacyHeadphones { try "{}".write(to: legacyHP.appendingPathComponent("\(id).json"), atomically: true, encoding: .utf8) }
        for id in legacyPresets { try "{}".write(to: legacyPR.appendingPathComponent("\(id).json"), atomically: true, encoding: .utf8) }
        for id in collectionHeadphones { try "{}".write(to: collHP.appendingPathComponent("\(id).json"), atomically: true, encoding: .utf8) }
        for id in collectionPresets { try "{}".write(to: collPR.appendingPathComponent("\(id).json"), atomically: true, encoding: .utf8) }
        if !aggregateProfiles.isEmpty {
            try JSONEncoder().encode(aggregateProfiles).write(to: aggregate)
        }

        let result = AuralinkPaths.needsCollectionMigration(
            legacyHeadphonesDirectory: legacyHP,
            legacyPresetsDirectory: legacyPR,
            legacyAggregateFile: aggregate,
            collectionHeadphonesDirectory: collHP,
            collectionPresetsDirectory: collPR
        )
        body(result)
    }

    func testMigrationNotNeededWhenLegacyIsEmpty() throws {
        try withMigrationFixture(collectionHeadphones: ["a"]) { result in
            XCTAssertFalse(result, "Empty legacy means no migration prompt")
        }
    }

    func testMigrationNeededForMirrorOnlyLegacy() throws {
        try withMigrationFixture(legacyHeadphones: ["hd600"]) { result in
            XCTAssertTrue(result, "Legacy mirror headphones with empty collection must prompt")
        }
    }

    func testMigrationNeededForAggregateOnlyLegacy() throws {
        let profile = HeadphoneProfile(id: "agg-only", brand: "B", model: "M", type: .iem, signature: "s")
        try withMigrationFixture(aggregateProfiles: [profile]) { result in
            XCTAssertTrue(result, "Aggregate-only legacy data must prompt (was missed before)")
        }
    }

    func testMigrationNeededForPresetsOnlyLegacy() throws {
        try withMigrationFixture(legacyPresets: ["preset_shared"]) { result in
            XCTAssertTrue(result, "Presets-only legacy data must prompt (was missed before)")
        }
    }

    func testMigrationNeededForPartialMigration() throws {
        let profile = HeadphoneProfile(id: "missing-one", brand: "B", model: "M", type: .iem, signature: "s")
        try withMigrationFixture(
            aggregateProfiles: [profile],
            collectionHeadphones: ["other-one"]
        ) { result in
            XCTAssertTrue(result, "Partial migration must re-prompt while legacy IDs remain unmigrated")
        }
    }

    func testMigrationNotNeededWhenAllIDsAreMigrated() throws {
        let profile = HeadphoneProfile(id: "done", brand: "B", model: "M", type: .iem, signature: "s")
        try withMigrationFixture(
            legacyHeadphones: ["done"],
            legacyPresets: ["preset_done"],
            aggregateProfiles: [profile],
            collectionHeadphones: ["done"],
            collectionPresets: ["preset_done"]
        ) { result in
            XCTAssertFalse(result, "Fully migrated collection must not prompt")
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

        switch CollectionManifest.read(from: url) {
        case .success(let manifest?):
            XCTAssertEqual(manifest.name, "Simon's Cans")
            XCTAssertEqual(manifest.schemaVersion, CollectionManifest.currentSchemaVersion)
            XCTAssertEqual(manifest.isFromNewerBuild, false)
        case .success(nil):
            XCTFail("Manifest should exist")
        case .failure(let error):
            XCTFail("Manifest read failed: \(error)")
        }
    }

    func testEnsureExistsCreatesOnceAndNeverOverwrites() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("auralink-manifest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("manifest.json")

        try CollectionManifest(name: "Mine").write(to: url)
        switch CollectionManifest.ensureExists(at: url) {
        case .success(let kept):
            XCTAssertEqual(kept.name, "Mine", "The user's own manifest metadata must survive.")
        case .failure(let error):
            XCTFail("ensureExists failed: \(error)")
        }

        let freshURL = root.appendingPathComponent("fresh/manifest.json")
        switch CollectionManifest.ensureExists(at: freshURL) {
        case .success(let created):
            XCTAssertEqual(created.schemaVersion, CollectionManifest.currentSchemaVersion)
            switch CollectionManifest.read(from: freshURL) {
            case .success(let manifest?):
                XCTAssertEqual(manifest.schemaVersion, CollectionManifest.currentSchemaVersion)
            case .success(nil):
                XCTFail("Manifest should exist")
            case .failure(let error):
                XCTFail("Manifest read failed: \(error)")
            }
        case .failure(let error):
            XCTFail("ensureExists failed: \(error)")
        }
    }

    func testManifestFromNewerBuildIsFlagged() {
        let future = CollectionManifest(schemaVersion: CollectionManifest.currentSchemaVersion + 1)
        XCTAssertTrue(future.isFromNewerBuild)
    }

    func testMissingManifestReadsAsNil() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("auralink-absent-\(UUID().uuidString)/manifest.json")
        switch CollectionManifest.read(from: url) {
        case .success(let manifest):
            XCTAssertNil(manifest)
        case .failure(let error):
            XCTFail("Missing manifest should not fail: \(error)")
        }
    }

    func testCorruptManifestReturnsErrorAndIsNotOverwritten() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("auralink-manifest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("manifest.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        // Write corrupt JSON
        let corruptData = "{ invalid json }".data(using: .utf8)!
        try corruptData.write(to: url)

        // read() should return failure
        switch CollectionManifest.read(from: url) {
        case .success:
            XCTFail("Corrupt manifest should return failure")
        case .failure(let error):
            XCTAssertTrue(error.localizedDescription.contains("corrupt"))
        }

        // ensureExists should NOT overwrite the corrupt manifest
        switch CollectionManifest.ensureExists(at: url) {
        case .success:
            XCTFail("ensureExists should not succeed with corrupt manifest")
        case .failure:
            break // expected
        }

        // Corrupt data should still be there (not overwritten)
        let stillThere = try? Data(contentsOf: url)
        XCTAssertEqual(stillThere, corruptData)
    }
}
