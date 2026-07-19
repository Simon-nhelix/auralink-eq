import XCTest
@testable import AuralinkCore

/// Tests for the preset persistence layer (`PresetStore`) and the safety
/// validator (`PresetValidator`). Every store test runs against a fresh temp
/// directory created in `setUp` and removed in `tearDown`, so nothing touches
/// the user's real Application Support folder.
final class PresetTests: XCTestCase {

    private var root: URL!
    private var presetsDir: URL!
    private var revisionsDir: URL!
    private var store: PresetStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AuralinkPresetTests-\(UUID().uuidString)", isDirectory: true)
        presetsDir = root.appendingPathComponent("presets", isDirectory: true)
        revisionsDir = root.appendingPathComponent("revisions", isDirectory: true)
        try FileManager.default.createDirectory(at: presetsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: revisionsDir, withIntermediateDirectories: true)
        store = PresetStore(directory: presetsDir, revisionsDirectory: revisionsDir)
    }

    override func tearDownWithError() throws {
        if let root, FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
        root = nil
        presetsDir = nil
        revisionsDir = nil
        store = nil
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    /// A simple preset with one enabled boosting band.
    private func makePreset(id: String = "preset_test", name: String = "Test", gainDb: Double = 4) -> EQPreset {
        var bands = EQBand.defaultBands()
        bands[5] = EQBand(index: 6, type: .bell, frequencyHz: 1000, gainDb: gainDb, q: 1.0, enabled: true)
        return EQPreset(id: id, name: name, bands: bands)
    }

    // MARK: - Roundtrip

    func testSaveLoadRoundtrip() throws {
        let original = makePreset()
        let saved = try store.save(original)

        let all = try store.loadAll()
        XCTAssertEqual(all.count, 1)

        let loaded = try XCTUnwrap(all.first)
        XCTAssertEqual(loaded.id, saved.id)
        XCTAssertEqual(loaded.name, saved.name)
        // Normalized presets always carry exactly 20 bands.
        XCTAssertEqual(loaded.bands.count, EQBand.bandCount)
        // The enabled band's gain survived the roundtrip.
        let band = try XCTUnwrap(loaded.bands.first { $0.index == 6 })
        XCTAssertEqual(band.gainDb, 4, accuracy: 0.0001)
        XCTAssertTrue(band.enabled)
    }

    func testMeasuredCorrectionRoundtripAndNormalization() throws {
        let points = (0..<20).map { index in
            MeasuredCorrectionPoint(
                frequencyHz: 20 * pow(1_000, Double(index) / 19),
                gainDb: Double(index % 5) - 2
            )
        }
        let payload = MeasuredCorrectionPayload(
            measurementId: "autoeq-test",
            source: "oratory1990",
            provenanceURL: "https://example.invalid/GraphicEQ.txt",
            sourcePreampDb: -6,
            contentHash: MeasuredCorrectionPayload.contentHash(points: points),
            points: points
        )
        var preset = makePreset(id: "measured", name: "Measured")
        preset.correction = CorrectionMetadata(
            role: .combined,
            source: "AutoEq/oratory1990",
            sourceConfidence: .measured,
            preferenceBandIndexes: [6, 6, 99],
            measuredCorrection: payload
        )
        _ = try store.save(preset)
        let loaded = try XCTUnwrap(try store.get(id: "measured"))
        let measured = try XCTUnwrap(loaded.correction?.measuredCorrection)

        XCTAssertTrue(measured.isFIREligible)
        XCTAssertEqual(measured.points.count, 20)
        XCTAssertTrue(zip(measured.points, measured.points.dropFirst()).allSatisfy { pair in
            pair.0.frequencyHz < pair.1.frequencyHz
        })
        XCTAssertEqual(loaded.correction?.preferenceBandIndexes, [6])
        XCTAssertEqual(measured.sourcePreampDb, -6)
        XCTAssertEqual(measured.contentHash, MeasuredCorrectionPayload.contentHash(points: points))
    }

    func testMeasuredCorrectionDoesNotRepairOrRehashMalformedPoints() {
        let ascending = (0..<20).map { index in
            MeasuredCorrectionPoint(
                frequencyHz: 20 * pow(1_000, Double(index) / 19),
                gainDb: Double(index % 5) - 2
            )
        }
        let descending = ascending.reversed()
        let payload = MeasuredCorrectionPayload(
            measurementId: "malformed",
            source: "test",
            provenanceURL: "https://example.invalid/malformed",
            sourcePreampDb: 0,
            contentHash: MeasuredCorrectionPayload.contentHash(points: ascending),
            points: Array(descending)
        )

        let normalized = payload.normalized()
        XCTAssertFalse(normalized.isFIREligible)
        XCTAssertEqual(normalized.points, Array(descending))
        XCTAssertEqual(normalized.contentHash, payload.contentHash)
    }

    // MARK: - Version bump + revision snapshot

    func testReSaveBumpsVersionAndSnapshotsRevision() throws {
        let first = try store.save(makePreset(name: "V1"))
        XCTAssertEqual(first.version, 1)
        XCTAssertTrue(try store.revisions(of: first.id).isEmpty)

        // Re-save with a change.
        var edited = first
        edited.name = "V2"
        let second = try store.save(edited)
        XCTAssertEqual(second.version, 2)
        XCTAssertEqual(second.name, "V2")

        // The prior on-disk version (v1) was snapshotted.
        let revs = try store.revisions(of: first.id)
        XCTAssertEqual(revs.count, 1)
        XCTAssertEqual(revs.first?.version, 1)
        XCTAssertEqual(revs.first?.name, "V1")

        // updatedAt advanced (or stayed equal); createdAt is preserved.
        // The compare tolerance absorbs ISO-8601's sub-second truncation: the
        // on-disk createdAt loses fractional seconds, so we assert "same second"
        // rather than bit-exact equality.
        XCTAssertGreaterThanOrEqual(second.updatedAt, first.updatedAt)
        XCTAssertEqual(second.createdAt.timeIntervalSince1970,
                       first.createdAt.timeIntervalSince1970,
                       accuracy: 1.0)
    }

    func testPreviousRevisionReturnsPrior() throws {
        let v1 = try store.save(makePreset(name: "Original"))

        var e = v1
        e.name = "Edited"
        _ = try store.save(e)

        let prior = try XCTUnwrap(try store.previousRevision(of: v1.id))
        XCTAssertEqual(prior.version, 1)
        XCTAssertEqual(prior.name, "Original")

        // No revisions for an id that's only ever been saved once.
        let fresh = try store.save(makePreset(id: "preset_solo", name: "Solo"))
        XCTAssertNil(try store.previousRevision(of: fresh.id))
    }

    // MARK: - Duplicate

    func testDuplicateGetsNewIdAndVersionOne() throws {
        let original = try store.save(makePreset(id: "preset_src", name: "Source"))
        // Bump it so the source is at a higher version.
        var e = original
        e.name = "Source v2"
        let bumped = try store.save(e)
        XCTAssertEqual(bumped.version, 2)

        let copy = try store.duplicate(id: bumped.id, newName: "Copy")
        XCTAssertNotEqual(copy.id, bumped.id)
        XCTAssertEqual(copy.name, "Copy")
        XCTAssertEqual(copy.version, 1)

        // Both exist on disk and the copy has no revision history.
        let all = try store.loadAll()
        XCTAssertEqual(all.count, 2)
        XCTAssertTrue(try store.revisions(of: copy.id).isEmpty)

        // Band content matches the source.
        let srcBand = try XCTUnwrap(bumped.bands.first { $0.index == 6 })
        let copyBand = try XCTUnwrap(copy.bands.first { $0.index == 6 })
        XCTAssertEqual(srcBand.gainDb, copyBand.gainDb, accuracy: 0.0001)
    }

    func testDuplicateUnknownIdThrows() throws {
        XCTAssertThrowsError(try store.duplicate(id: "does_not_exist", newName: "X")) { error in
            XCTAssertEqual(error as? PresetStoreError, .notFound("does_not_exist"))
        }
    }

    // MARK: - Delete

    func testDeleteRemovesPresetAndRevisions() throws {
        let v1 = try store.save(makePreset())
        var e = v1
        e.name = "Edited"
        _ = try store.save(e)
        XCTAssertFalse(try store.revisions(of: v1.id).isEmpty)

        try store.delete(id: v1.id)
        XCTAssertNil(try store.get(id: v1.id))
        XCTAssertTrue(try store.revisions(of: v1.id).isEmpty)
    }

    // MARK: - Import / Export

    func testExportThenImportAssignsFreshIdOnCollision() throws {
        let original = try store.save(makePreset(id: "preset_export", name: "Exportable"))
        let fileURL = root.appendingPathComponent("exported.json")
        try store.export(original, to: fileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

        // Importing while the original still exists must yield a fresh id.
        let imported = try store.importPreset(from: fileURL)
        XCTAssertNotEqual(imported.id, original.id)
        XCTAssertEqual(imported.name, original.name)
    }

    // MARK: - Factory seed

    func testLoadAllSeedsThreeFactoryPresetsWhenEmpty() throws {
        let seeded = try store.loadAll()
        XCTAssertEqual(seeded.count, 3)
        let names = Set(seeded.map(\.name))
        XCTAssertEqual(names, ["Flat", "Warm & Smooth", "Vocal Clarity"])

        // They are now persisted: a second load returns the same three.
        let reloaded = try store.loadAll()
        XCTAssertEqual(reloaded.count, 3)
        XCTAssertEqual(Set(reloaded.map(\.name)), names)
    }

    // MARK: - Validator

    func testValidatorFlagsOutOfRangeBand() {
        let validator = PresetValidator(rules: .default)
        // Build a preset with an illegal Q by bypassing the model clamp:
        // construct bands directly, then DON'T normalize before validating —
        // the validator normalizes internally, which clamps Q back into range,
        // so to truly exercise an out-of-range error we tighten the rules.
        let strictRules = SafetyRules(qMin: 0.5, qMax: 2.0)
        let strictValidator = PresetValidator(rules: strictRules)

        var bands = EQBand.defaultBands()
        bands[0] = EQBand(index: 1, type: .bell, frequencyHz: 1000, gainDb: 3, q: 8.0, enabled: true)
        let preset = EQPreset(id: "p_oor", name: "OOR", bands: bands)

        let result = strictValidator.validate(preset)
        XCTAssertFalse(result.ok)
        XCTAssertTrue(result.errors.contains { $0.bandIndex == 1 })

        // And a gain-out-of-range error against tightened gain rules.
        let gainRules = SafetyRules(gainMinDb: -6, gainMaxDb: 6)
        let gainValidator = PresetValidator(rules: gainRules)
        var gbands = EQBand.defaultBands()
        gbands[0] = EQBand(index: 1, type: .bell, frequencyHz: 1000, gainDb: 12, q: 1.0, enabled: true)
        let gpreset = EQPreset(id: "p_gain", name: "Gain", bands: gbands)
        let gresult = gainValidator.validate(gpreset)
        XCTAssertFalse(gresult.ok)
        XCTAssertTrue(gresult.errors.contains { $0.bandIndex == 1 })

        // A clean preset against default rules passes with no errors.
        var clean = EQBand.defaultBands()
        clean[0] = EQBand(index: 1, type: .bell, frequencyHz: 1000, gainDb: 3, q: 1.0, enabled: true)
        let cleanPreset = EQPreset(id: "p_clean", name: "Clean", bands: clean)
        let cleanResult = validator.validate(cleanPreset)
        XCTAssertTrue(cleanResult.ok)
    }

    func testValidatorFlagsOverBoostedPreset() {
        let validator = PresetValidator(rules: .default) // maxBoostDb = 6
        var bands = EQBand.defaultBands()
        // Single band well over the 6 dB single-band limit (but within ±18 legal range).
        bands[0] = EQBand(index: 1, type: .bell, frequencyHz: 1000, gainDb: 12, q: 1.0, enabled: true)
        let preset = EQPreset(id: "p_boost", name: "Boost", bands: bands)

        let result = validator.validate(preset)
        // Over single-band limit but not out of legal range → warning, still ok.
        XCTAssertTrue(result.ok)
        XCTAssertTrue(result.warnings.contains { $0.bandIndex == 1 })

        // Aggregate-boost warning: several overlapping boosts pushing the peak
        // past maxAggregateBoostDb (9 dB).
        var aggBands = EQBand.defaultBands()
        aggBands[0] = EQBand(index: 1, type: .bell, frequencyHz: 900,  gainDb: 6, q: 0.7, enabled: true)
        aggBands[1] = EQBand(index: 2, type: .bell, frequencyHz: 1000, gainDb: 6, q: 0.7, enabled: true)
        aggBands[2] = EQBand(index: 3, type: .bell, frequencyHz: 1100, gainDb: 6, q: 0.7, enabled: true)
        let aggPreset = EQPreset(id: "p_agg", name: "Agg", bands: aggBands)
        let aggResult = validator.validate(aggPreset)
        XCTAssertGreaterThan(aggResult.estimatedPeakGainDb, 9)
        XCTAssertTrue(aggResult.warnings.contains { $0.bandIndex == nil })
    }

    func testValidatorFlagsHeadroomAndSharpTrebleRisks() {
        let validator = PresetValidator(rules: .default)
        var bands = EQBand.defaultBands()
        bands[0] = EQBand(index: 1, type: .lowShelf, frequencyHz: 50, gainDb: 4.5, q: 0.7, enabled: true)
        bands[1] = EQBand(index: 2, type: .bell, frequencyHz: 7_000, gainDb: 3.0, q: 5.0, enabled: true)
        let preset = EQPreset(id: "p_risky_shape", name: "Risky Shape", preampDb: 0, bands: bands)

        let result = validator.validate(preset)

        XCTAssertTrue(result.ok)
        XCTAssertTrue(result.warnings.contains { $0.bandIndex == 1 && $0.message.contains("below 80 Hz") })
        XCTAssertTrue(result.warnings.contains { $0.bandIndex == 2 && $0.message.contains("narrow boosted treble") })
        XCTAssertTrue(result.warnings.contains { $0.bandIndex == nil && $0.message.contains("Estimated peak") })
    }

    func testAutoPreampIsNonPositiveAndReducesClippingRisk() {
        let validator = PresetValidator(rules: .default)
        var bands = EQBand.defaultBands()
        bands[0] = EQBand(index: 1, type: .bell, frequencyHz: 1000, gainDb: 12, q: 1.0, enabled: true)

        // Without preamp the post-peak is high.
        let noPreamp = EQPreset(id: "p_np", name: "NP", preampDb: 0, bands: bands)
        let beforeRisk = validator.validate(noPreamp).clippingRisk
        XCTAssertEqual(beforeRisk, .high)

        // autoPreamp must be ≤ 0 and a multiple of 0.5.
        let preamp = validator.autoPreamp(for: noPreamp)
        XCTAssertLessThanOrEqual(preamp, 0)
        XCTAssertEqual((preamp * 2).rounded(), preamp * 2, accuracy: 0.0001)

        // Applying it lowers the clipping risk.
        var withPreamp = noPreamp
        withPreamp.preampDb = preamp
        let afterRisk = validator.validate(withPreamp).clippingRisk
        XCTAssertEqual(afterRisk, .low)
        XCTAssertNotEqual(afterRisk, beforeRisk)
    }

    func testAutoPreampZeroWhenAlreadyWithinHeadroom() {
        let validator = PresetValidator(rules: .default)
        // Flat preset (all bands disabled) → peak ≈ 0, already within headroom.
        let flat = EQPreset.flat()
        let preamp = validator.autoPreamp(for: flat)
        XCTAssertEqual(preamp, 0, accuracy: 0.0001)
    }

    func testFactoryPresetsValidate() {
        let validator = PresetValidator(rules: .default)
        for preset in PresetStore.factoryPresets() {
            let result = validator.validate(preset)
            XCTAssertTrue(result.ok, "Factory preset \(preset.name) should validate without errors")
        }
    }
}
