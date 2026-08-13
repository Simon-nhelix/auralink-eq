import XCTest
@testable import AuralinkCore

/// Tests for the knowledge layer and the deterministic tuning engine.
///
/// These guard two contracts that the rest of the product (and the MCP server)
/// rely on: (1) profile / curve / rules JSON decodes cleanly into the `Models`
/// types, and (2) `TuningEngine` is genuinely deterministic and stays inside
/// safety limits.
///
/// Headphone profiles come from inline fixtures written to a temporary collection
/// directory, not from the app bundle. Auralink ships no headphone database, so
/// asserting against shipped profiles would be asserting against nothing.
final class TuningTests: XCTestCase {

    // MARK: Fixtures

    /// Stand-ins for the kinds of profile the engine has to handle: a neutral
    /// reference can, a treble-peaky one, and a few plain entries the tuning tests
    /// name by display name.
    private static let fixtureProfiles: [HeadphoneProfile] = [
        HeadphoneProfile(
            id: "sennheiser-hd600",
            brand: "Sennheiser",
            model: "HD600",
            type: .openBack,
            signature: "Reference-neutral, slightly mid-forward, polite treble; bass rolls off in the sub region.",
            correctionNotes: [
                "Sub-bass below ~40 Hz rolls off; a gentle low shelf restores weight without bloat.",
                "Mild presence bump around 3 kHz can sound forward on bright tracks.",
            ],
            harshRegionsHz: [FrequencyRange(lowHz: 2800, highHz: 3600)],
            suggestedTargetCurveId: "harman-neutral",
            source: "Test fixture",
            credibility: .measured
        ),
        HeadphoneProfile(
            id: "beyerdynamic-dt990",
            brand: "Beyerdynamic",
            model: "DT990 Pro",
            type: .openBack,
            signature: "Aggressive V-shape with a prominent treble peak near 8 kHz.",
            correctionNotes: ["Strong 8 kHz peak is the defining flaw; cut it firmly."],
            harshRegionsHz: [
                FrequencyRange(lowHz: 7000, highHz: 9000),
                FrequencyRange(lowHz: 5500, highHz: 6500),
            ],
            suggestedTargetCurveId: "late-night",
            source: "Test fixture",
            credibility: .measured
        ),
        HeadphoneProfile(
            id: "apple-airpods-pro-2",
            brand: "Apple",
            model: "AirPods Pro 2",
            type: .trueWireless,
            signature: "Consumer-warm with lifted bass and a smoothed treble.",
            source: "Test fixture",
            credibility: .community
        ),
        HeadphoneProfile(
            id: "sony-wh-1000xm5",
            brand: "Sony",
            model: "WH-1000XM5",
            type: .closedBack,
            signature: "Bass-forward tuning with a recessed upper midrange.",
            source: "Test fixture",
            credibility: .community
        ),
        HeadphoneProfile(
            id: "hifiman-sundara",
            brand: "HIFIMAN",
            model: "Sundara",
            type: .openBack,
            signature: "Clean planar presentation, mildly bright.",
            source: "Test fixture",
            credibility: .measured
        ),
    ]

    private var collectionRoot: URL!

    override func setUpWithError() throws {
        collectionRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("auralink-tuning-fixtures-\(UUID().uuidString)", isDirectory: true)
        try writeProfiles(Self.fixtureProfiles, to: fixtureHeadphonesDirectory)
    }

    override func tearDownWithError() throws {
        if let collectionRoot {
            try? FileManager.default.removeItem(at: collectionRoot)
        }
        collectionRoot = nil
    }

    // MARK: Helpers

    private var fixtureHeadphonesDirectory: URL {
        collectionRoot.appendingPathComponent("headphones", isDirectory: true)
    }

    private func writeProfiles(_ profiles: [HeadphoneProfile], to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        for profile in profiles {
            try encoder.encode(profile)
                .write(to: directory.appendingPathComponent("\(profile.id).json"), options: .atomic)
        }
    }

    /// Bundled target curves and safety rules, plus the fixture profiles standing in
    /// for a user's collection.
    private func makeKnowledge() -> KnowledgeBase {
        KnowledgeBase(dataDirectory: nil, collectionHeadphonesDirectory: fixtureHeadphonesDirectory)
    }

    private func makeEngine(_ kb: KnowledgeBase) -> TuningEngine {
        TuningEngine(knowledge: kb, validator: PresetValidator(rules: kb.safetyRules))
    }

    /// A knowledge base whose collection holds exactly `profiles`.
    private func makeKnowledge(profiles: [HeadphoneProfile]) throws -> (KnowledgeBase, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("auralink-tuning-tests-\(UUID().uuidString)", isDirectory: true)
        let headphones = root.appendingPathComponent("headphones", isDirectory: true)
        try writeProfiles(profiles, to: headphones)
        return (KnowledgeBase(dataDirectory: nil, collectionHeadphonesDirectory: headphones), root)
    }

    /// Sum of absolute gain in enabled gain-using bands within [low, high] Hz —
    /// a cheap proxy for energy in a region, independent of the DSP module.
    private func regionEnergy(_ preset: EQPreset, low: Double, high: Double) -> Double {
        preset.bands
            .filter { $0.enabled && $0.type.usesGain && $0.frequencyHz >= low && $0.frequencyHz <= high }
            .reduce(0) { $0 + $1.gainDb }
    }

    // MARK: Knowledge loading

    func testKnowledgeBaseLoadsBundledCurvesAndRules() {
        let kb = makeKnowledge()
        // Target curves and safety rules are app machinery and stay bundled — the
        // count guards the JSON schema against the Codable types. A schema mismatch
        // would yield 0 here.
        XCTAssertGreaterThanOrEqual(kb.targetCurves.count, 7,
                                    "Expected at least 7 target curves to decode.")
        XCTAssertEqual(kb.safetyRules.maxBoostDb, 6, accuracy: 0.001)
        XCTAssertEqual(kb.safetyRules.maxAggregateBoostDb, 9, accuracy: 0.001)
    }

    /// The state a fresh install is in: curves and rules present, zero profiles.
    func testKnowledgeBaseShipsNoHeadphoneProfiles() {
        let bundleOnly = KnowledgeBase(dataDirectory: nil, collectionHeadphonesDirectory: nil)
        XCTAssertTrue(bundleOnly.headphoneProfiles.isEmpty,
                      "Auralink must ship no headphone profiles; the collection is the user's.")
        XCTAssertFalse(bundleOnly.targetCurves.isEmpty,
                       "Target curves are app machinery and must still be bundled.")
        XCTAssertEqual(bundleOnly.safetyRules.maxBoostDb, 6, accuracy: 0.001)
        // Lookups on an empty collection answer cleanly rather than trapping.
        XCTAssertNil(bundleOnly.profile(id: "sennheiser-hd600"))
        XCTAssertNil(bundleOnly.profileMatching("HD600"))
    }

    func testKnowledgeBaseLoadsProfilesFromCollection() {
        let kb = makeKnowledge()
        XCTAssertEqual(kb.headphoneProfiles.count, Self.fixtureProfiles.count)
    }

    /// An empty collection directory is a normal state, not an error.
    func testKnowledgeBaseToleratesMissingCollectionDirectory() {
        let missing = collectionRoot.appendingPathComponent("does-not-exist", isDirectory: true)
        let kb = KnowledgeBase(dataDirectory: nil, collectionHeadphonesDirectory: missing)
        XCTAssertTrue(kb.headphoneProfiles.isEmpty)
        XCTAssertFalse(kb.targetCurves.isEmpty)
    }

    func testProfileLookupById() {
        let kb = makeKnowledge()
        XCTAssertNotNil(kb.profile(id: "sennheiser-hd600"))
        XCTAssertNotNil(kb.profile(id: "apple-airpods-pro-2"))
        XCTAssertNil(kb.profile(id: "no-such-headphone"))
    }

    func testProfileFuzzyMatching() {
        let kb = makeKnowledge()
        let hd600 = kb.profileMatching("HD600")
        XCTAssertNotNil(hd600, "Fuzzy match for 'HD600' should find the Sennheiser HD600.")
        XCTAssertEqual(hd600?.id, "sennheiser-hd600")

        // Spacing/case insensitivity.
        XCTAssertEqual(kb.profileMatching("hd 600")?.id, "sennheiser-hd600")
        XCTAssertEqual(kb.profileMatching("Sennheiser HD600")?.id, "sennheiser-hd600")
        XCTAssertEqual(kb.profileMatching("DT990")?.id, "beyerdynamic-dt990")
        XCTAssertNil(kb.profileMatching("completely unknown can"))
    }

    func testTargetCurveLookup() {
        let kb = makeKnowledge()
        XCTAssertNotNil(kb.targetCurve(id: "rock"))
        XCTAssertNotNil(kb.targetCurve(id: "harman-neutral"))
        XCTAssertNil(kb.targetCurve(id: "no-such-curve"))
    }

    /// A collection can live anywhere on disk — a git checkout outside Application
    /// Support is the normal case — and one file per model is the only layout.
    func testKnowledgeBaseLoadsCollectionFromArbitraryDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("auralink-collection-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let headphones = root.appendingPathComponent("headphones", isDirectory: true)

        try writeProfiles([
            HeadphoneProfile(
                id: "from-collection",
                brand: "Lib",
                model: "Two",
                type: .closedBack,
                signature: "lib",
                source: "test",
                credibility: .measured
            )
        ], to: headphones)

        // A stale aggregate next door must not leak back in: per-file is the layout.
        let dataDir = root.appendingPathComponent("data", isDirectory: true)
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        try JSONEncoder().encode([
            HeadphoneProfile(
                id: "from-aggregate",
                brand: "Agg",
                model: "One",
                type: .openBack,
                signature: "agg",
                source: "test",
                credibility: .estimated
            )
        ]).write(to: dataDir.appendingPathComponent("headphone-profiles.json"))

        let kb = KnowledgeBase(dataDirectory: dataDir, collectionHeadphonesDirectory: headphones)
        XCTAssertNotNil(kb.profile(id: "from-collection"))
        XCTAssertEqual(kb.profile(id: "from-collection")?.credibility, .measured)
        XCTAssertNil(kb.profile(id: "from-aggregate"),
                     "Aggregate headphone-profiles.json is no longer a profile source.")
    }

    // MARK: Tuning generation

    func testMakeTuningHD600Rock() {
        let kb = makeKnowledge()
        let engine = makeEngine(kb)
        let request = AITuningRequest(
            headphone: "HD600",
            targetCurveId: "rock",
            avoidHarshTreble: true
        )
        let result = engine.makeTuning(request: request, basePreset: nil)

        // It is an AI preset.
        XCTAssertEqual(result.preset.createdBy, .ai)
        // Name contains the goal label "Rock".
        XCTAssertTrue(result.preset.name.contains("Rock"),
                      "Expected the preset name to contain 'Rock', got '\(result.preset.name)'.")
        // It is attributed to the HD600.
        XCTAssertEqual(result.preset.headphone, "Sennheiser HD600")
        // Validation passes. With the new level-preserving audition policy, the
        // preset may still report high clipping risk instead of auto-attenuating.
        XCTAssertTrue(result.validation.ok, "Expected a valid preset. Issues: \(result.validation.issues)")
        XCTAssertEqual(result.preset.safety.autoGainEnabled, false)
        XCTAssertEqual(result.preset.preampDb, 0, accuracy: 0.0001)
        XCTAssertEqual(result.preset.safety.clippingRisk, result.validation.clippingRisk)
        // There is at least one explained change and one intent bullet.
        XCTAssertFalse(result.changes.isEmpty)
        XCTAssertFalse(result.intent.isEmpty)
        // Always exactly 20 normalized band slots.
        XCTAssertEqual(result.preset.bands.count, EQBand.bandCount)
    }

    func testMakeTuningHonorsMaxBoost() {
        let kb = makeKnowledge()
        let engine = makeEngine(kb)
        // Tighten the ceiling to 3 dB and demand bass — no band should exceed it.
        let request = AITuningRequest(
            headphone: "Sony WH-1000XM5",
            targetCurveId: "bass-boost",
            maxBoostDb: 3,
            avoidHarshTreble: true
        )
        let result = engine.makeTuning(request: request, basePreset: nil)
        for band in result.preset.activeBands where band.type.usesGain {
            XCTAssertLessThanOrEqual(band.gainDb, 3.0 + 0.001,
                                     "Band at \(band.frequencyHz) Hz exceeded the requested max boost.")
        }
    }

    func testMakeTuningStoresBaselineCorrectionMetadata() {
        let kb = makeKnowledge()
        let engine = makeEngine(kb)
        let request = AITuningRequest(
            headphone: "HD600",
            targetCurveId: "rock",
            correctionStrength: 0.6,
            targetBlend: 0.4,
            avoidHarshTreble: true
        )

        let result = engine.makeTuning(request: request, basePreset: nil)
        let correction = result.preset.correction

        XCTAssertEqual(correction?.role, .baseline)
        XCTAssertNil(correction?.baselinePresetId)
        XCTAssertEqual(correction?.sourceConfidence, .measured)
        XCTAssertEqual(correction?.targetCurveId, "rock")
        XCTAssertEqual(correction?.correctionStrength ?? -1, 0.6, accuracy: 0.001)
        XCTAssertEqual(correction?.targetBlend ?? -1, 0.4, accuracy: 0.001)
        XCTAssertEqual(correction?.preferenceBandIndexes, [])
    }

    func testMakeTuningStoresPreferenceMetadataWhenLayeredOnBaseline() {
        let kb = makeKnowledge()
        let engine = makeEngine(kb)
        var bands = EQBand.defaultBands()
        bands[0] = EQBand(index: 1, type: .lowShelf, frequencyHz: 80, gainDb: 1.5, q: 0.7, enabled: true)
        let base = EQPreset(
            id: "hd600-baseline",
            name: "HD600 Baseline",
            headphone: "Sennheiser HD600",
            bands: bands,
            createdBy: .ai,
            tags: ["baseline"],
            correction: CorrectionMetadata(role: .baseline, sourceConfidence: .measured)
        ).normalized()
        let request = AITuningRequest(preference: "more vocal clarity", avoidHarshTreble: true)

        let result = engine.makeTuning(request: request, basePreset: base)
        let correction = result.preset.correction

        XCTAssertEqual(correction?.role, .preference)
        XCTAssertEqual(correction?.baselinePresetId, "hd600-baseline")
        XCTAssertFalse(correction?.preferenceBandIndexes.isEmpty ?? true)
    }

    func testMakeTuningPreservesBaselineBandsAndPreampWhileLayeringMoves() {
        let kb = makeKnowledge()
        let engine = makeEngine(kb)
        var bands = EQBand.defaultBands()
        bands[1] = EQBand(
            index: 2,
            type: .bell,
            frequencyHz: 850,
            gainDb: -3.25,
            q: 1.4,
            channel: .left,
            enabled: true
        )
        bands[6] = EQBand(
            index: 7,
            type: .highPass,
            frequencyHz: 28,
            gainDb: 0,
            q: 0.8,
            channel: .stereo,
            enabled: true
        )
        let base = EQPreset(
            id: "measured-baseline",
            name: "Measured Baseline",
            headphone: "Reference Can",
            preampDb: -4.5,
            bands: bands,
            correction: CorrectionMetadata(
                role: .baseline,
                source: "Measured fixture",
                sourceConfidence: .measured,
                correctionStrength: 1
            )
        ).normalized()

        let result = engine.makeTuning(
            request: AITuningRequest(
                targetCurveId: "rock",
                preference: "more vocal clarity",
                correctionStrength: 1,
                avoidHarshTreble: false
            ),
            basePreset: base
        )

        XCTAssertEqual(result.preset.bands.count, EQBand.bandCount)
        XCTAssertEqual(result.preset.bands[1], base.bands[1])
        XCTAssertEqual(result.preset.bands[6], base.bands[6])
        XCTAssertEqual(result.preset.preampDb, -4.5, accuracy: 0.001)
        XCTAssertEqual(result.preset.headphone, "Reference Can")
        XCTAssertGreaterThan(result.preset.activeBands.count, base.activeBands.count)
        XCTAssertFalse(result.preset.correction?.preferenceBandIndexes.isEmpty ?? true)
        XCTAssertFalse(result.preset.correction?.preferenceBandIndexes.contains(2) ?? true)
        XCTAssertFalse(result.preset.correction?.preferenceBandIndexes.contains(7) ?? true)
        XCTAssertEqual(result.preset.correction?.source, "Measured fixture")
        XCTAssertEqual(result.preset.correction?.sourceConfidence, .measured)
        XCTAssertEqual(result.preset.correction?.correctionStrength ?? -1, 1, accuracy: 0.001)
    }

    func testMakeTuningPreservesFullTwentyBandBaselineDeterministically() {
        let activeBands = (1...EQBand.bandCount).map { index in
            EQBand(
                index: index,
                type: .bell,
                frequencyHz: 40 * Double(index),
                gainDb: Double((index % 5) - 2),
                q: 0.7 + Double(index) * 0.02,
                enabled: true
            )
        }
        let base = EQPreset(
            id: "full-baseline",
            name: "Full Baseline",
            preampDb: -6,
            bands: activeBands,
            correction: CorrectionMetadata(role: .baseline, sourceConfidence: .measured)
        ).normalized()
        let engine = makeEngine(makeKnowledge())
        let request = AITuningRequest(
            targetCurveId: "rock",
            preference: "more bass and clearer vocal",
            avoidHarshTreble: false
        )

        let first = engine.makeTuning(request: request, basePreset: base)
        let second = engine.makeTuning(request: request, basePreset: base)

        XCTAssertEqual(first.preset.bands, base.bands)
        XCTAssertEqual(first.preset.preampDb, base.preampDb, accuracy: 0.001)
        XCTAssertEqual(first.preset, second.preset)
        XCTAssertEqual(first.changes, second.changes)
        XCTAssertTrue(first.changes.isEmpty)
    }

    func testUnknownAndEstimatedCorrectionStrengthAreConservativelyCapped() throws {
        let unknown = makeEngine(makeKnowledge()).makeTuning(
            request: AITuningRequest(
                targetCurveId: "rock",
                correctionStrength: 1,
                avoidHarshTreble: false
            ),
            basePreset: nil
        )
        XCTAssertEqual(unknown.preset.correction?.sourceConfidence, .unknown)
        XCTAssertEqual(unknown.preset.correction?.correctionStrength ?? -1, 0.5, accuracy: 0.001)

        let harshRegion = FrequencyRange(lowHz: 6_000, highHz: 8_000)
        let estimatedProfile = HeadphoneProfile(
            id: "estimated-can",
            brand: "Fixture",
            model: "Estimated Can",
            type: .openBack,
            signature: "Test fixture",
            harshRegionsHz: [harshRegion],
            source: "Estimated fixture",
            credibility: .estimated
        )
        let measuredProfile = HeadphoneProfile(
            id: "measured-can",
            brand: "Fixture",
            model: "Measured Can",
            type: .openBack,
            signature: "Test fixture",
            harshRegionsHz: [harshRegion],
            source: "Measured fixture",
            credibility: .measured
        )
        let (knowledge, directory) = try makeKnowledge(profiles: [estimatedProfile, measuredProfile])
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = makeEngine(knowledge)

        let estimated = engine.makeTuning(
            request: AITuningRequest(
                headphone: "Estimated Can",
                correctionStrength: 1,
                avoidHarshTreble: true
            ),
            basePreset: nil
        )
        let measured = engine.makeTuning(
            request: AITuningRequest(
                headphone: "Measured Can",
                correctionStrength: 1,
                avoidHarshTreble: true
            ),
            basePreset: nil
        )

        XCTAssertEqual(estimated.preset.correction?.sourceConfidence, .estimated)
        XCTAssertEqual(estimated.preset.correction?.correctionStrength ?? -1, 0.5, accuracy: 0.001)
        XCTAssertEqual(estimated.preset.activeBands.count, 1)
        XCTAssertEqual(estimated.preset.activeBands[0].gainDb, -1, accuracy: 0.001)

        XCTAssertEqual(measured.preset.correction?.sourceConfidence, .measured)
        XCTAssertEqual(measured.preset.correction?.correctionStrength ?? -1, 1, accuracy: 0.001)
        XCTAssertEqual(measured.preset.activeBands.count, 1)
        XCTAssertEqual(measured.preset.activeBands[0].gainDb, -2, accuracy: 0.001)
    }

    func testTargetBlendScalesTargetCurveMoves() {
        let kb = makeKnowledge()
        let engine = makeEngine(kb)
        let full = engine.makeTuning(
            request: AITuningRequest(targetCurveId: "rock", targetBlend: 1, avoidHarshTreble: false),
            basePreset: nil
        )
        let light = engine.makeTuning(
            request: AITuningRequest(targetCurveId: "rock", targetBlend: 0.25, avoidHarshTreble: false),
            basePreset: nil
        )

        let fullEnergy = full.preset.activeBands.reduce(0) { $0 + abs($1.gainDb) }
        let lightEnergy = light.preset.activeBands.reduce(0) { $0 + abs($1.gainDb) }
        XCTAssertLessThan(lightEnergy, fullEnergy)
    }

    func testMakeTuningGoalTextKeywordInference() {
        let kb = makeKnowledge()
        let engine = makeEngine(kb)
        // No explicit curve — keyword "footsteps" should drive the FPS direction.
        let request = AITuningRequest(
            headphone: "HIFIMAN Sundara",
            goalText: "I want to hear footsteps in competitive FPS games",
            avoidHarshTreble: true
        )
        let result = engine.makeTuning(request: request, basePreset: nil)
        XCTAssertEqual(result.preset.createdBy, .ai)
        XCTAssertTrue(result.validation.ok)
        // Should have produced at least one move (footstep emphasis).
        XCTAssertFalse(result.preset.activeBands.isEmpty)
    }

    func testMakeTuningKoreanWarmRequest() {
        let kb = makeKnowledge()
        let engine = makeEngine(kb)
        let request = AITuningRequest(
            headphone: "HD600",
            goalText: "HD600 소리를 좀 더 따뜻하게 해줘",
            preference: "보컬은 너무 뒤로 가지 않게",
            avoidHarshTreble: true
        )
        let result = engine.makeTuning(request: request, basePreset: nil)

        XCTAssertEqual(result.preset.headphone, "Sennheiser HD600")
        XCTAssertTrue(result.validation.ok)
        XCTAssertTrue(
            result.preset.activeBands.contains { $0.frequencyHz <= 140 && $0.gainDb > 0 },
            "A Korean warm request should add low-end warmth."
        )
    }

    func testMakeTuningKoreanHarshnessRequest() {
        let kb = makeKnowledge()
        let engine = makeEngine(kb)
        let request = AITuningRequest(
            headphone: "HD600",
            goalText: "쏘는 고음 줄이고 좀 더 부드럽게",
            preference: "치찰음 줄여줘",
            avoidHarshTreble: true
        )
        let result = engine.makeTuning(request: request, basePreset: nil)

        XCTAssertTrue(result.validation.ok)
        XCTAssertTrue(
            result.preset.activeBands.contains { $0.frequencyHz >= 5000 && $0.frequencyHz <= 9000 && $0.gainDb < 0 },
            "A Korean harshness request should create a treble cut."
        )
    }

    // MARK: Quick actions

    func testReduceHarshnessLowersEnergyIn5to9kHz() {
        let kb = makeKnowledge()
        let engine = makeEngine(kb)

        // Build a base preset with deliberate energy in the 5–9 kHz region.
        var bands = EQBand.defaultBands()
        bands[0] = EQBand(index: 1, type: .bell, frequencyHz: 6000, gainDb: 5.0, q: 2.0, enabled: true)
        bands[1] = EQBand(index: 2, type: .bell, frequencyHz: 8000, gainDb: 4.0, q: 2.0, enabled: true)
        let base = EQPreset(id: "base_harsh", name: "Harsh", bands: bands).normalized()

        let before = regionEnergy(base, low: 5000, high: 9000)
        XCTAssertGreaterThan(before, 0, "Test fixture should have positive 5–9 kHz energy.")

        let result = engine.reduceHarshness(in: base, amountDb: 4.0)
        let after = regionEnergy(result.preset, low: 5000, high: 9000)

        XCTAssertLessThan(after, before,
                          "reduceHarshness should lower 5–9 kHz energy (before \(before), after \(after)).")
        XCTAssertEqual(result.preset.createdBy, .ai)
    }

    func testWarmerAddsLowEnd() {
        let kb = makeKnowledge()
        let engine = makeEngine(kb)
        let base = EQPreset.flat()
        let before = regionEnergy(base, low: 20, high: 350)

        let result = engine.warmer(base)
        let after = regionEnergy(result.preset, low: 20, high: 350)

        XCTAssertGreaterThan(after, before, "warmer should add low/low-mid energy.")
        XCTAssertTrue(result.validation.ok)
        XCTAssertEqual(result.preset.createdBy, .ai)
    }

    // MARK: Determinism

    func testMakeTuningIsDeterministic() {
        let kb = makeKnowledge()
        let engine = makeEngine(kb)
        let request = AITuningRequest(
            headphone: "HD600",
            targetCurveId: "rock",
            preference: "a bit more kick, keep vocals clear",
            avoidHarshTreble: true
        )
        let a = engine.makeTuning(request: request, basePreset: nil)
        let b = engine.makeTuning(request: request, basePreset: nil)

        // Byte-identical via Codable round-trip (the strongest equality check).
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let da = try? encoder.encode(a)
        let db = try? encoder.encode(b)
        XCTAssertNotNil(da)
        XCTAssertEqual(da, db, "Identical requests must produce identical tuning results.")

        // And the in-memory values match too.
        XCTAssertEqual(a.preset, b.preset)
        XCTAssertEqual(a.changes, b.changes)
        XCTAssertEqual(a.intent, b.intent)
    }

    func testReduceHarshnessIsDeterministic() {
        let kb = makeKnowledge()
        let engine = makeEngine(kb)
        var bands = EQBand.defaultBands()
        bands[0] = EQBand(index: 1, type: .bell, frequencyHz: 7000, gainDb: 4.0, q: 2.0, enabled: true)
        let base = EQPreset(id: "base", name: "Base", bands: bands).normalized()

        let a = engine.reduceHarshness(in: base, amountDb: 3.0)
        let b = engine.reduceHarshness(in: base, amountDb: 3.0)
        XCTAssertEqual(a.preset, b.preset)
        XCTAssertEqual(a.changes, b.changes)
    }
}
