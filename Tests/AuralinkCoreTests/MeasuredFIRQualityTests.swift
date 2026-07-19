import Foundation
import XCTest
@testable import AuralinkCore

final class MeasuredFIRQualityTests: XCTestCase {
    func testHD600MeasuredCurveBeatsParametricFallbackAtEverySupportedRate() throws {
        let preset = try makeHD600Preset()
        for sampleRate in [44_100.0, 48_000, 96_000, 192_000] {
            let result = try XCTUnwrap(MeasuredFIRDesigner.design(for: preset, sampleRate: sampleRate))
            XCTAssertTrue(result.quality.eligible)
            XCTAssertLessThanOrEqual(result.quality.maxErrorDb, MeasuredFIRDesigner.maximumImplementationErrorDb)
            XCTAssertLessThanOrEqual(result.quality.rmsErrorDb, MeasuredFIRDesigner.maximumRMSErrorDb)
            XCTAssertGreaterThanOrEqual(
                result.quality.absoluteRmsImprovementDb,
                MeasuredFIRDesigner.minimumAbsoluteImprovementDb
            )
            XCTAssertGreaterThanOrEqual(
                result.quality.relativeRmsImprovement,
                MeasuredFIRDesigner.minimumRelativeImprovement
            )
            XCTAssertEqual(
                result.design.left.taps.count % MeasuredFIRDesigner.partitionSize(for: sampleRate),
                0
            )
            XCTAssertEqual(result.design.left.taps, result.design.right.taps)
            XCTAssertLessThanOrEqual(result.quality.supportMs, 86)
            XCTAssertTrue(result.design.left.taps.allSatisfy(\.isFinite))
        }
    }

    func testFFTQualityEvidenceMatchesDirectTapEvaluationThroughRegularization() throws {
        let preset = try makeHD600Preset()
        let result = try XCTUnwrap(MeasuredFIRDesigner.design(for: preset, sampleRate: 48_000))
        let payload = try XCTUnwrap(preset.correction?.measuredCorrection)
        var frequencies = FrequencyResponse.logFrequencies(count: 512, from: 40, to: 16_000)
        frequencies.append(contentsOf: [10_000, sqrt(10_000 * 16_000), 16_000])
        let errors = frequencies.map { frequency in
            abs(
                FIRDesigner.magnitudeDb(
                    of: result.design.left.taps,
                    atHz: frequency,
                    sampleRate: 48_000
                ) - MeasuredFIRDesigner.targetMagnitudeDb(
                    of: payload,
                    atHz: frequency,
                    sampleRate: 48_000,
                    strength: 1
                )
            )
        }
        let maxError = errors.max() ?? .infinity
        let rmsError = sqrt(errors.reduce(0) { $0 + $1 * $1 } / Double(errors.count))
        XCTAssertEqual(result.quality.maxErrorDb, maxError, accuracy: 0.01)
        XCTAssertEqual(result.quality.rmsErrorDb, rmsError, accuracy: 0.01)
    }

    func testMeasuredPayloadHashMatchesTypeScriptGoldenFixture() throws {
        let preset = try makeHD600Preset()
        XCTAssertEqual(
            preset.correction?.measuredCorrection?.contentHash,
            "3aefca2da9f0720dd64d53e46ff880a76a36c6cfa5af4a3a7b717af925f06c23"
        )
    }

    func testMeasuredFIRDoesNotCountPreampTwice() throws {
        let preset = try makeHD600Preset()
        let payload = try XCTUnwrap(preset.correction?.measuredCorrection)
        let result = try XCTUnwrap(MeasuredFIRDesigner.design(for: preset, sampleRate: 48_000))

        let firAt100 = FIRDesigner.magnitudeDb(
            of: result.design.left.taps,
            atHz: 100,
            sampleRate: 48_000
        )
        let targetAt100 = MeasuredFIRDesigner.targetMagnitudeDb(
            of: payload,
            atHz: 100,
            sampleRate: 48_000,
            strength: 1
        )
        XCTAssertEqual(firAt100, targetAt100, accuracy: 0.3)
        XCTAssertGreaterThan(firAt100, 0.5, "the taps contain correction, not the -6.3 dB global preamp")
    }

    func testRequestedMeasuredFIRIsNotActiveUntilRenderBoundary() throws {
        let preset = try makeHD600Preset()
        let processor = EQProcessor(sampleRate: 48_000)
        processor.update(preset: preset)
        let frameCount = 64
        var left = [Float](repeating: 0, count: frameCount)
        var right = left
        left[0] = 1
        right[0] = 1
        left.withUnsafeMutableBufferPointer { leftPointer in
            right.withUnsafeMutableBufferPointer { rightPointer in
                _ = processor.processInPlace(
                    left: leftPointer.baseAddress!,
                    right: rightPointer.baseAddress!,
                    frames: frameCount
                )
            }
        }
        XCTAssertEqual(processor.activeRenderModeOnRenderThread, .standardIIR)
        XCTAssertTrue(processor.setRenderMode(.hqFIR))
        XCTAssertEqual(processor.activeRenderModeOnRenderThread, .standardIIR)

        left.withUnsafeMutableBufferPointer { leftPointer in
            right.withUnsafeMutableBufferPointer { rightPointer in
                _ = processor.processInPlace(
                    left: leftPointer.baseAddress!,
                    right: rightPointer.baseAddress!,
                    frames: frameCount
                )
            }
        }
        XCTAssertEqual(processor.activeRenderModeOnRenderThread, .hqFIR)
    }

    func testProcessorRendersMeasuredBaselineAndPreferenceExactlyOnce() throws {
        var preset = try makeHD600Preset()
        preset.bands[10] = EQBand(
            index: 11,
            type: .bell,
            frequencyHz: 1_000,
            gainDb: 1.5,
            q: 1
        )
        preset.correction?.role = .combined
        preset.correction?.preferenceBandIndexes = [11]

        let processor = EQProcessor(sampleRate: 48_000)
        processor.update(preset: preset)
        XCTAssertTrue(processor.setRenderMode(.hqFIR))
        XCTAssertNotNil(processor.measuredFIRQuality())

        let impulse: Float = 0.05
        var output = [Float](repeating: 0, count: 16_384)
        output[0] = impulse
        let outputCount = output.count
        output.withUnsafeMutableBufferPointer { pointer in
            guard let base = pointer.baseAddress else { return }
            processor.processInPlace(left: base, right: nil, frames: outputCount)
        }
        let normalizedImpulse = output.map { $0 / impulse }
        let actualAt1k = FIRDesigner.magnitudeDb(
            of: normalizedImpulse,
            atHz: 1_000,
            sampleRate: 48_000
        )
        let expectedAt1k = FrequencyResponse.curve(
            for: preset,
            at: [1_000],
            sampleRate: 48_000,
            channel: .left,
            renderMode: .hqFIR
        )[0].magnitudeDb
        XCTAssertEqual(actualAt1k, expectedAt1k, accuracy: 0.3)

        var withoutPreference = preset
        withoutPreference.bands[10].enabled = false
        let baselineAt1k = FrequencyResponse.curve(
            for: withoutPreference,
            at: [1_000],
            sampleRate: 48_000,
            channel: .left,
            renderMode: .hqFIR
        )[0].magnitudeDb
        XCTAssertEqual(expectedAt1k - baselineAt1k, 1.5, accuracy: 0.05)
    }

    func testMeasuredModeTransitionRemainsFiniteAndSmooth() throws {
        let preset = try makeHD600Preset()
        let processor = EQProcessor(sampleRate: 48_000)
        processor.update(preset: preset)

        func processConstant(frames: Int) -> [Float] {
            var buffer = [Float](repeating: 0.1, count: frames)
            let count = buffer.count
            buffer.withUnsafeMutableBufferPointer { pointer in
                guard let base = pointer.baseAddress else { return }
                processor.processInPlace(left: base, right: nil, frames: count)
            }
            return buffer
        }

        _ = processConstant(frames: 8_192)
        XCTAssertTrue(processor.setRenderMode(.hqFIR))
        let transition = processConstant(frames: 8_192)
        XCTAssertTrue(transition.allSatisfy(\.isFinite))
        for index in 1..<transition.count {
            XCTAssertLessThan(abs(transition[index] - transition[index - 1]), 0.025)
        }
    }

    func testMeasuredFIRCacheUsesExactStrengthIdentity() throws {
        var lower = try makeHD600Preset()
        lower.correction?.correctionStrength = 0.5001
        var higher = lower
        higher.correction?.correctionStrength = 0.5004
        let cache = MeasuredFIRDesignCache(maxEntries: 2)
        let lowerResult = try XCTUnwrap(cache.design(for: lower, sampleRate: 48_000))
        let higherResult = try XCTUnwrap(cache.design(for: higher, sampleRate: 48_000))
        XCTAssertNotEqual(lowerResult.design.left.taps, higherResult.design.left.taps)
    }

    func testMeasuredFIRCacheDoesNotBypassSourceConfidence() throws {
        let measured = try makeHD600Preset()
        let cache = MeasuredFIRDesignCache(maxEntries: 2)
        XCTAssertNotNil(cache.design(for: measured, sampleRate: 48_000))

        var downgraded = measured
        downgraded.correction?.sourceConfidence = .estimated
        XCTAssertNil(cache.design(for: downgraded, sampleRate: 48_000))
    }

    func testPEQBenefitGateUsesWorseOutputChannel() throws {
        let stereo = try makeHD600Preset()
        let stereoResult = try XCTUnwrap(MeasuredFIRDesigner.design(for: stereo, sampleRate: 48_000))
        var leftOnly = stereo
        leftOnly.bands = leftOnly.bands.map { band in
            var copy = band
            if copy.enabled { copy.channel = .left }
            return copy
        }
        let asymmetricResult = try XCTUnwrap(MeasuredFIRDesigner.design(for: leftOnly, sampleRate: 48_000))
        XCTAssertGreaterThan(
            asymmetricResult.quality.peqRmsErrorDb,
            stereoResult.quality.peqRmsErrorDb + 0.5
        )
    }

    func testProcessorRejectsHQForLegacyPresetWithoutMeasuredData() {
        let processor = EQProcessor(sampleRate: 48_000)
        processor.update(preset: EQPreset.flat())
        XCTAssertFalse(processor.setRenderMode(.hqFIR))
        XCTAssertNil(processor.measuredFIRQuality())
    }

    func testFlatMeasuredCurveIsNotPromotedWithoutIndependentBenefit() {
        let points = (0..<32).map { index in
            MeasuredCorrectionPoint(
                frequencyHz: 20 * pow(1_000, Double(index) / 31),
                gainDb: 0
            )
        }
        let payload = MeasuredCorrectionPayload(
            measurementId: "flat",
            source: "test",
            provenanceURL: "https://example.invalid/flat",
            sourcePreampDb: 0,
            contentHash: MeasuredCorrectionPayload.contentHash(points: points),
            points: points
        )
        let correction = CorrectionMetadata(
            role: .baseline,
            source: "test",
            sourceConfidence: .measured,
            measuredCorrection: payload
        )
        let preset = EQPreset(
            id: "flat-measured",
            name: "Flat measured",
            bands: EQBand.defaultBands(),
            correction: correction
        )
        XCTAssertNil(MeasuredFIRDesigner.design(for: preset, sampleRate: 48_000))
    }

    private func makeHD600Preset() throws -> EQPreset {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("mcp-server/test/fixtures/sennheiser-hd600-graphic-eq.txt")
        let text = try String(contentsOf: sourceURL, encoding: .utf8)
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "GraphicEQ:", with: "")
        let points = try body.split(separator: ";").map { pair -> MeasuredCorrectionPoint in
            let fields = pair.split(whereSeparator: \.isWhitespace)
            guard fields.count == 2,
                  let frequency = Double(fields[0]),
                  let sourceGain = Double(fields[1]) else {
                throw NSError(domain: "MeasuredFIRQualityTests", code: 1)
            }
            return MeasuredCorrectionPoint(
                frequencyHz: frequency,
                gainDb: sourceGain - (-6.3)
            )
        }
        let payload = MeasuredCorrectionPayload(
            measurementId: "autoeq-hd600-oratory1990",
            source: "oratory1990",
            provenanceURL: "https://raw.githubusercontent.com/jaakkopasanen/AutoEq/master/results/oratory1990/over-ear/Sennheiser%20HD%20600/Sennheiser%20HD%20600%20GraphicEQ.txt",
            sourcePreampDb: -6.3,
            contentHash: MeasuredCorrectionPayload.contentHash(points: points),
            usableLowHz: 40,
            usableHighHz: 10_000,
            points: points
        )

        let specs: [(BandType, Double, Double, Double)] = [
            (.lowShelf, 105, 6.5, 0.7),
            (.bell, 125, -2.7, 0.55),
            (.bell, 522, 0.7, 1.02),
            (.bell, 1_298, -1.2, 2.14),
            (.bell, 2_166, 0.9, 3.32),
            (.bell, 3_158, -1.8, 3.67),
            (.bell, 5_433, -1.2, 5.7),
            (.bell, 6_639, 2.2, 5.82),
            (.bell, 8_445, 3.3, 1.61),
            (.highShelf, 10_000, -3.1, 0.7),
        ]
        var bands = EQBand.defaultBands()
        for (offset, spec) in specs.enumerated() {
            bands[offset] = EQBand(
                index: offset + 1,
                type: spec.0,
                frequencyHz: spec.1,
                gainDb: spec.2,
                q: spec.3
            )
        }
        return EQPreset(
            id: "hd600-measured",
            name: "HD600 Measured",
            headphone: "Sennheiser HD600",
            preampDb: -6.3,
            bands: bands,
            correction: CorrectionMetadata(
                role: .baseline,
                source: "AutoEq/oratory1990",
                sourceConfidence: .measured,
                preferenceBandIndexes: [],
                measuredCorrection: payload
            )
        )
    }
}
