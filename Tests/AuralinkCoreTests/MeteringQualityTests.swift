import XCTest
@testable import AuralinkCore

final class MeteringQualityTests: XCTestCase {
    private let sampleRate = 48_000.0

    // MARK: - Stateful true-peak quality

    func testTruePeakIsInvariantToBufferSplits() {
        let samples = (0..<257).map { index -> Float in
            let t = Double(index)
            return Float(0.72 * sin(0.173 * t + 0.31) + 0.19 * sin(0.619 * t - 0.2))
        }

        let contiguous = estimateMono(samples, chunks: [samples.count])
        let split = estimateMono(samples, chunks: [1, 2, 31, 3, 64, 7, 5, 89, 55])

        XCTAssertEqual(split.samplePeak, contiguous.samplePeak, accuracy: 1e-7)
        XCTAssertEqual(split.estimatedTruePeak, contiguous.estimatedTruePeak, accuracy: 1e-6)
    }

    func testStereoKeepsIndependentChannelHistoryAcrossBoundary() {
        // The left plateau's oversampled FIR peak is completed using history
        // carried into buffer 2. Right has a different history and peak.
        let left: [Float] = [0, 0.9, 0.9, 0, -0.2, 0.1, 0, 0]
        let right: [Float] = [-0.72, 0.1, 0.4, -0.3, 0.2, 0.65, -0.1, 0]
        let chunks = [3, 1, 4]

        let stereo = estimateStereo(left: left, right: right, chunks: chunks)
        let leftOnly = estimateMono(left, chunks: chunks)
        let rightOnly = estimateMono(right, chunks: chunks)

        XCTAssertEqual(stereo.samplePeak, max(leftOnly.samplePeak, rightOnly.samplePeak), accuracy: 1e-7)
        XCTAssertEqual(
            stereo.estimatedTruePeak,
            max(leftOnly.estimatedTruePeak, rightOnly.estimatedTruePeak),
            accuracy: 1e-6
        )
        XCTAssertGreaterThan(stereo.estimatedTruePeak, 1.0)
    }

    func testScalarAndBufferTruePeakAPIsAgree() {
        let left = (0..<96).map { Float(0.8 * sin(Double($0) * 0.41 + 0.2)) }
        let right = (0..<96).map { Float(0.7 * cos(Double($0) * 0.27 - 0.4)) }
        let buffered = estimateStereo(left: left, right: right, chunks: [13, 1, 48, 34])

        var estimator = TruePeakEstimator()
        var scalar = TruePeakEstimator.Estimate(samplePeak: 0, estimatedTruePeak: 0)
        for index in left.indices {
            let estimate = estimator.processStereoSample(left: left[index], right: right[index])
            scalar.samplePeak = max(scalar.samplePeak, estimate.samplePeak)
            scalar.estimatedTruePeak = max(scalar.estimatedTruePeak, estimate.estimatedTruePeak)
        }

        XCTAssertEqual(scalar.samplePeak, buffered.samplePeak, accuracy: 1e-7)
        XCTAssertEqual(scalar.estimatedTruePeak, buffered.estimatedTruePeak, accuracy: 1e-6)
    }

    func testTruePeakUnderreadStaysWithinPointTwoDbOfDenseReference() {
        let cases: [(frequency: Double, phase: Double)] = [
            (997, 0.31),
            (8_000, 0.123),
            (12_000, 0.37),
            (20_000, 0.123)
        ]
        let amplitude = 0.95
        let frameCount = 4_096
        let chunks = [1, 17, 64, 511, 1_024, 2_048, 431]

        for testCase in cases {
            let samples = (0..<frameCount).map { index in
                Float(amplitude * sin(
                    2 * Double.pi * testCase.frequency * Double(index) / sampleRate
                        + testCase.phase
                ))
            }
            let estimate = estimateMono(samples, chunks: chunks)
            let reference = denseSinePeak(
                frequencyHz: testCase.frequency,
                phase: testCase.phase,
                amplitude: amplitude,
                frames: frameCount,
                oversampling: 128
            )
            let errorDb = 20 * log10(Double(estimate.estimatedTruePeak) / reference)

            XCTAssertGreaterThanOrEqual(
                errorDb,
                -0.2,
                "true-peak underread at \(testCase.frequency) Hz was \(errorDb) dB"
            )
            XCTAssertGreaterThanOrEqual(estimate.estimatedTruePeak, estimate.samplePeak)
        }
    }

    func testTruePeakResetDropsHistoryAtStreamDiscontinuity() {
        var estimator = TruePeakEstimator()
        let prefix: [Float] = [0, 0.9, 0.9]
        prefix.withUnsafeBufferPointer { buffer in
            _ = estimator.processMono(samples: buffer.baseAddress!, frames: buffer.count)
        }
        estimator.reset()

        let suffix: [Float] = [0]
        let estimate = suffix.withUnsafeBufferPointer { buffer in
            estimator.processMono(samples: buffer.baseAddress!, frames: buffer.count)
        }
        XCTAssertEqual(estimate.samplePeak, 0, accuracy: 0)
        XCTAssertEqual(estimate.estimatedTruePeak, 0, accuracy: 0)
    }

    func testProcessorReportsPreProtectionIntersampleOvershoot() {
        let processor = EQProcessor(sampleRate: sampleRate)
        processor.update(preset: .flat())
        processor.setClipProtectionEnabled(true)
        var samples = [Float](repeating: 0, count: 48)
        samples[20] = 0.9
        samples[21] = 0.9
        let frames = samples.count

        let metrics = samples.withUnsafeMutableBufferPointer { buffer in
            processor.processInPlaceWithMetrics(
                left: buffer.baseAddress!,
                right: nil,
                frames: frames
            )
        }

        XCTAssertEqual(metrics.preProtectionSamplePeak, 0.9, accuracy: 1e-6)
        XCTAssertGreaterThan(metrics.preProtectionTruePeak, 1.0)
    }

    // MARK: - Response-weighted loudness quality

    func testKWeightingMatches48kReferencePoints() {
        let points: [(frequency: Double, expectedDb: Double)] = [
            (100, -1.1334981),
            (1_000, 0.6977044),
            (10_000, 4.0418822)
        ]

        for point in points {
            let power = LoudnessMatcher.kWeightingPowerGain(
                atHz: point.frequency,
                sampleRate: sampleRate
            )
            XCTAssertEqual(
                10 * log10(power),
                point.expectedDb,
                accuracy: 1e-5,
                "K-weighting mismatch at \(point.frequency) Hz"
            )
        }
    }

    func testFlatResponseWeightedMetricTracksPreampExactly() {
        for preamp in [0.0, -2.5, -9.0, -18.0] {
            var preset = EQPreset.flat()
            preset.preampDb = preamp
            XCTAssertEqual(
                LoudnessMatcher.responseWeightedDb(of: preset, sampleRate: sampleRate),
                preamp,
                accuracy: 1e-10
            )
        }
    }

    func testResponseMetricAveragesLinearPowerNotDb() {
        let preset = presetWithBand(
            EQBand(index: 1, type: .bell, frequencyHz: 1_200, gainDb: 9, q: 1.1)
        )
        let frequencies = FrequencyResponse.logFrequencies(count: 192, from: 20, to: 20_000)
        let curve = FrequencyResponse.curve(for: preset, at: frequencies, sampleRate: sampleRate)

        var weightedDbSum = 0.0
        var weightSum = 0.0
        for point in curve {
            let weight = LoudnessMatcher.kWeightingPowerGain(
                atHz: point.frequencyHz,
                sampleRate: sampleRate
            )
            weightedDbSum += weight * point.magnitudeDb
            weightSum += weight
        }
        let logarithmicAverage = weightedDbSum / weightSum
        let powerAverage = LoudnessMatcher.responseWeightedDb(of: preset, sampleRate: sampleRate)

        XCTAssertGreaterThan(powerAverage, logarithmicAverage + 0.1)
    }

    func testResponseMetricCombinesLeftAndRightInPowerSpace() {
        var bands = EQBand.defaultBands()
        bands[0] = EQBand(
            index: 1,
            type: .highShelf,
            frequencyHz: 20,
            gainDb: 6,
            q: 0.707,
            channel: .left
        )
        bands[1] = EQBand(
            index: 2,
            type: .highShelf,
            frequencyHz: 20,
            gainDb: -6,
            q: 0.707,
            channel: .right
        )
        let preset = EQPreset(id: "stereo-power", name: "Stereo power", preampDb: 0, bands: bands)

        // A folded dB sum nearly cancels, but channel powers cannot: the +6 dB
        // side contributes about 4x power while the -6 dB side contributes 1/4.
        XCTAssertGreaterThan(
            LoudnessMatcher.responseWeightedDb(of: preset, sampleRate: sampleRate),
            2.5
        )
    }

    func testLoudnessMatchUsesWeightedMetricAndNeverBoosts() {
        let candidate = presetWithBand(
            EQBand(index: 1, type: .highShelf, frequencyHz: 2_500, gainDb: 6, q: 0.707)
        )
        let reference = EQPreset.flat()
        let candidateMetric = LoudnessMatcher.responseWeightedDb(of: candidate, sampleRate: sampleRate)
        let match = LoudnessMatcher.match(candidate, to: reference, sampleRate: sampleRate)

        XCTAssertGreaterThan(candidateMetric, 0)
        XCTAssertEqual(match.adjustmentDb, -candidateMetric, accuracy: 1e-10)
        XCTAssertLessThanOrEqual(match.adjustmentDb, 0)
        XCTAssertEqual(match.preset.preampDb, match.adjustmentDb, accuracy: 1e-10)
    }

    // MARK: - Helpers

    private func presetWithBand(_ band: EQBand, preampDb: Double = 0) -> EQPreset {
        var bands = EQBand.defaultBands()
        bands[band.index - 1] = band
        return EQPreset(id: "metering-test", name: "Metering test", preampDb: preampDb, bands: bands)
    }

    private func estimateMono(
        _ samples: [Float],
        chunks: [Int]
    ) -> TruePeakEstimator.Estimate {
        precondition(chunks.reduce(0, +) == samples.count)
        var estimator = TruePeakEstimator()
        var aggregate = TruePeakEstimator.Estimate(samplePeak: 0, estimatedTruePeak: 0)
        samples.withUnsafeBufferPointer { buffer in
            var offset = 0
            for count in chunks {
                let estimate = estimator.processMono(
                    samples: buffer.baseAddress!.advanced(by: offset),
                    frames: count
                )
                aggregate.samplePeak = max(aggregate.samplePeak, estimate.samplePeak)
                aggregate.estimatedTruePeak = max(
                    aggregate.estimatedTruePeak,
                    estimate.estimatedTruePeak
                )
                offset += count
            }
        }
        return aggregate
    }

    private func estimateStereo(
        left: [Float],
        right: [Float],
        chunks: [Int]
    ) -> TruePeakEstimator.Estimate {
        precondition(left.count == right.count)
        precondition(chunks.reduce(0, +) == left.count)
        var estimator = TruePeakEstimator()
        var aggregate = TruePeakEstimator.Estimate(samplePeak: 0, estimatedTruePeak: 0)
        left.withUnsafeBufferPointer { leftBuffer in
            right.withUnsafeBufferPointer { rightBuffer in
                var offset = 0
                for count in chunks {
                    let estimate = estimator.processStereo(
                        left: leftBuffer.baseAddress!.advanced(by: offset),
                        right: rightBuffer.baseAddress!.advanced(by: offset),
                        frames: count
                    )
                    aggregate.samplePeak = max(aggregate.samplePeak, estimate.samplePeak)
                    aggregate.estimatedTruePeak = max(
                        aggregate.estimatedTruePeak,
                        estimate.estimatedTruePeak
                    )
                    offset += count
                }
            }
        }
        return aggregate
    }

    private func denseSinePeak(
        frequencyHz: Double,
        phase: Double,
        amplitude: Double,
        frames: Int,
        oversampling: Int
    ) -> Double {
        var peak = 0.0
        let sampleCount = max(1, (frames - 1) * oversampling + 1)
        for index in 0..<sampleCount {
            let samplePosition = Double(index) / Double(oversampling)
            let value = amplitude * sin(
                2 * Double.pi * frequencyHz * samplePosition / sampleRate + phase
            )
            peak = max(peak, abs(value))
        }
        return peak
    }
}
