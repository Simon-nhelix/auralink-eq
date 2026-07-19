import XCTest
@testable import AuralinkCore

final class FIRQualityGateTests: XCTestCase {
    private let sampleRates: [Double] = [44_100, 48_000, 96_000, 192_000]

    private struct Scenario {
        var name: String
        var preset: EQPreset
    }

    func testRealtime512TapQualityMatrixAndProductionVerdict() throws {
        let scenarios = [
            Scenario(name: "broad", preset: broadCorrectionPreset()),
            Scenario(name: "low-frequency", preset: lowFrequencyStressPreset()),
            Scenario(name: "high-q", preset: highQStressPreset()),
            Scenario(name: "20-band", preset: denseTwentyBandPreset()),
        ]
        var matrix: [String: [Double: FIRQualityEvaluation]] = [:]

        for scenario in scenarios {
            for sampleRate in sampleRates {
                let design = FIRDesigner.minimumPhaseApproximation(
                    for: scenario.preset,
                    sampleRate: sampleRate,
                    length: FIRDesigner.realtimePreviewLength(for: sampleRate),
                    channel: .left
                )
                let evaluation = FIRDesigner.evaluateQuality(
                    of: design,
                    against: scenario.preset,
                    frequencyCount: 2048
                )
                matrix[scenario.name, default: [:]][sampleRate] = evaluation

                XCTAssertEqual(evaluation.sampleRate, sampleRate)
                XCTAssertEqual(evaluation.frequencyCount, 2048)
                XCTAssertLessThanOrEqual(evaluation.tapCount, FIRDesigner.realtimePreviewLength)
                XCTAssertTrue(evaluation.maxMagnitudeErrorDb.isFinite)
                XCTAssertTrue(evaluation.rmsMagnitudeErrorDb.isFinite)
                XCTAssertTrue(evaluation.maxErrorFrequencyHz.isFinite)
                XCTAssertGreaterThanOrEqual(evaluation.estimatedGroupDelayMs, 0)
                XCTAssertGreaterThanOrEqual(evaluation.impulseSpanMs, evaluation.estimatedGroupDelayMs)

                print(
                    String(
                        format: "FIR QUALITY %-13@ %6.1f kHz  max=%7.3f dB  rms=%7.3f dB  peak@%7.1f Hz  delay=%6.3f ms  span=%6.3f ms  %@  %@",
                        scenario.name as NSString,
                        sampleRate / 1_000,
                        evaluation.maxMagnitudeErrorDb,
                        evaluation.rmsMagnitudeErrorDb,
                        evaluation.maxErrorFrequencyHz,
                        evaluation.estimatedGroupDelayMs,
                        evaluation.impulseSpanMs,
                        evaluation.classification.rawValue as NSString,
                        evaluation.limitations.map(\.rawValue).joined(separator: ",") as NSString
                    )
                )
            }
        }

        XCTAssertEqual(matrix.count, scenarios.count)
        XCTAssertTrue(matrix.values.allSatisfy { $0.count == sampleRates.count })

        // Ordinary broad correction must meet the explicit production-fidelity
        // gate at the two sample rates used by the normal audio path.
        let standardBroad = [44_100.0, 48_000.0].compactMap { matrix["broad"]?[$0] }
        XCTAssertEqual(standardBroad.count, 2)
        for evaluation in standardBroad {
            XCTAssertLessThanOrEqual(evaluation.maxMagnitudeErrorDb, 0.5)
            XCTAssertLessThanOrEqual(evaluation.rmsMagnitudeErrorDb, 0.15)
            XCTAssertEqual(evaluation.classification, .meetsReferenceGate)
        }

        let highRateBroad = try XCTUnwrap(matrix["broad"]?[192_000])
        XCTAssertEqual(highRateBroad.classification, .expectedPrototypeLimitation)
        XCTAssertGreaterThan(highRateBroad.maxMagnitudeErrorDb, 0.5)
        XCTAssertGreaterThan(highRateBroad.rmsMagnitudeErrorDb, 0.15)
        XCTAssertTrue(highRateBroad.limitations.contains(.fixedTapBudgetAtHighSampleRate))

        // Every measured miss must stay visible as a miss. Known 512-tap stress
        // failures are classified, rather than weakened into passing thresholds.
        let stressEvaluations = ["low-frequency", "high-q", "20-band"].flatMap {
            matrix[$0]?.values.map { $0 } ?? []
        }
        let measuredStressFailures = stressEvaluations.filter { !$0.meetsReferenceGate }
        XCTAssertFalse(measuredStressFailures.isEmpty)
        XCTAssertTrue(measuredStressFailures.allSatisfy {
            $0.classification == .expectedPrototypeLimitation && !$0.limitations.isEmpty
        })

        for scenarioName in ["low-frequency", "high-q", "20-band"] {
            let evaluation = try XCTUnwrap(matrix[scenarioName]?[192_000])
            XCTAssertEqual(evaluation.classification, .expectedPrototypeLimitation)
            XCTAssertTrue(evaluation.limitations.contains(.fixedTapBudgetAtHighSampleRate))
        }

        let allEvaluations = scenarios.flatMap { scenario in
            sampleRates.compactMap { matrix[scenario.name]?[$0] }
        }
        let accuracyAssessment = FIRDesigner.productionAssessment(
            required: allEvaluations,
            independentBenefitDemonstrated: false
        )
        XCTAssertFalse(accuracyAssessment.productionReady)
        XCTAssertEqual(accuracyAssessment.verdict, .keepExperimentalReferenceAccuracy)
        XCTAssertGreaterThan(accuracyAssessment.failedEvaluationCount, 0)

        // Even the subset that matches its source IIR is not a shipping claim:
        // a truncated IIR impulse has no independent quality benefit by itself.
        let noBenefitAssessment = FIRDesigner.productionAssessment(
            required: standardBroad,
            independentBenefitDemonstrated: false
        )
        XCTAssertFalse(noBenefitAssessment.productionReady)
        XCTAssertEqual(noBenefitAssessment.verdict, .keepExperimentalNoIndependentBenefit)
        XCTAssertEqual(noBenefitAssessment.failedEvaluationCount, 0)
    }

    func testQualityEvaluationUsesTheDesignedChannelReference() {
        var bands = EQBand.defaultBands()
        bands[8] = EQBand(
            index: 9,
            type: .bell,
            frequencyHz: 1_000,
            gainDb: 6,
            q: 0.7,
            channel: .left
        )
        let preset = EQPreset(id: "quality-channel", name: "Quality channel", bands: bands)
        let stereo = FIRDesigner.stereoMinimumPhaseApproximation(
            for: preset,
            sampleRate: 48_000,
            length: FIRDesigner.realtimePreviewLength
        )

        let left = FIRDesigner.evaluateQuality(of: stereo.left, against: preset)
        let right = FIRDesigner.evaluateQuality(of: stereo.right, against: preset)

        XCTAssertEqual(left.classification, .meetsReferenceGate)
        XCTAssertEqual(right.classification, .meetsReferenceGate)
        XCTAssertEqual(right.tapCount, 1)
        XCTAssertEqual(right.maxMagnitudeErrorDb, 0, accuracy: 1e-12)
        XCTAssertEqual(right.rmsMagnitudeErrorDb, 0, accuracy: 1e-12)
        XCTAssertEqual(right.estimatedGroupDelayMs, 0, accuracy: 1e-12)
    }

    private func broadCorrectionPreset() -> EQPreset {
        var bands = EQBand.defaultBands()
        bands[3] = EQBand(index: 4, type: .lowShelf, frequencyHz: 120, gainDb: 2.5, q: 0.7)
        bands[7] = EQBand(index: 8, type: .bell, frequencyHz: 700, gainDb: -2, q: 0.55)
        bands[11] = EQBand(index: 12, type: .bell, frequencyHz: 2_400, gainDb: 2, q: 0.7)
        bands[15] = EQBand(index: 16, type: .bell, frequencyHz: 7_500, gainDb: -1.5, q: 0.8)
        bands[18] = EQBand(index: 19, type: .highShelf, frequencyHz: 12_000, gainDb: 1, q: 0.7)
        return EQPreset(id: "fir-quality-broad", name: "Broad correction", bands: bands)
    }

    private func lowFrequencyStressPreset() -> EQPreset {
        var bands = EQBand.defaultBands()
        bands[0] = EQBand(index: 1, type: .lowShelf, frequencyHz: 28, gainDb: 12, q: 0.7)
        bands[2] = EQBand(index: 3, type: .bell, frequencyHz: 55, gainDb: -9, q: 1.4)
        return EQPreset(id: "fir-quality-low", name: "Low frequency stress", bands: bands)
    }

    private func highQStressPreset() -> EQPreset {
        var bands = EQBand.defaultBands()
        bands[8] = EQBand(index: 9, type: .bell, frequencyHz: 1_000, gainDb: 12, q: 10)
        bands[13] = EQBand(index: 14, type: .bell, frequencyHz: 4_500, gainDb: -12, q: 10)
        return EQPreset(id: "fir-quality-high-q", name: "High Q stress", bands: bands)
    }

    private func denseTwentyBandPreset() -> EQPreset {
        let frequencies: [Double] = [
            32, 48, 72, 110, 160, 240, 350, 520, 760, 1_100,
            1_600, 2_400, 3_500, 5_000, 7_000, 9_000, 11_000, 13_000, 16_000, 19_000,
        ]
        let bands = frequencies.enumerated().map { offset, frequency in
            EQBand(
                index: offset + 1,
                type: .bell,
                frequencyHz: frequency,
                gainDb: offset.isMultiple(of: 2) ? 5 : -5,
                q: offset.isMultiple(of: 3) ? 3.5 : 1.8
            )
        }
        return EQPreset(id: "fir-quality-dense", name: "Dense 20-band stress", bands: bands)
    }
}
