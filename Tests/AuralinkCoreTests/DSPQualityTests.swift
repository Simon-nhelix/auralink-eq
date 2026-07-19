import XCTest
@testable import AuralinkCore

/// Measurement-first DSP tests. These complement the coefficient-level tests in
/// `DSPTests` by checking null behavior, impulse-response parity, and the shared
/// Swift/TypeScript response fixture used by the MCP validator.
final class DSPQualityTests: XCTestCase {
    private let sampleRate = 48_000.0

    private struct TransitionMetrics {
        var boundaryExcessStep: Float
        var maxExcessStepNearBoundary: Float
        var rmsExcessStepNearBoundary: Double
        var outputPeak: Float
    }

    private struct ResponseParityFixture: Decodable {
        var sampleRate: Double
        var toleranceDb: Double
        var preset: EQPreset
        var frequenciesHz: [Double]
        var expectedDb: [Double]
    }

    private func loadResponseParityFixture() throws -> ResponseParityFixture {
        let testFile = URL(fileURLWithPath: #filePath)
        let fixtureURL = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/response-parity.json")
        let data = try Data(contentsOf: fixtureURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ResponseParityFixture.self, from: data)
    }

    private func qualityPreset(includeNotch: Bool = false) -> EQPreset {
        var bands = EQBand.defaultBands()
        bands[1] = EQBand(index: 2, type: .lowShelf, frequencyHz: 120, gainDb: 2.5, q: 0.707)
        bands[7] = EQBand(index: 8, type: .bell, frequencyHz: 750, gainDb: -2.25, q: 1.2)
        bands[11] = EQBand(index: 12, type: .bell, frequencyHz: 2_400, gainDb: 3, q: 1.1)
        if includeNotch {
            bands[15] = EQBand(index: 16, type: .notch, frequencyHz: 6_200, gainDb: 0, q: 5)
        }
        bands[17] = EQBand(index: 18, type: .highShelf, frequencyHz: 9_500, gainDb: 1.75, q: 0.707)
        return EQPreset(
            id: "quality",
            name: "Quality",
            preampDb: -2,
            bands: bands,
            createdBy: .ai,
            tags: ["quality-test"]
        )
    }

    private func processedImpulseResponse(
        preset: EQPreset,
        frames: Int = 65_536,
        impulseAmplitude: Float = 0.125
    ) -> [Double] {
        let processor = EQProcessor(sampleRate: sampleRate)
        processor.update(preset: preset)
        var buffer = [Float](repeating: 0, count: frames)
        buffer[0] = impulseAmplitude
        buffer.withUnsafeMutableBufferPointer { p in
            guard let base = p.baseAddress else { return }
            processor.processInPlace(left: base, right: nil, frames: frames)
        }
        let scale = Double(impulseAmplitude)
        return buffer.map { Double($0) / scale }
    }

    private func magnitudeDb(ofImpulse impulse: [Double], atHz frequency: Double) -> Double {
        var re = 0.0
        var im = 0.0
        for (n, sample) in impulse.enumerated() where sample != 0 {
            let angle = -2.0 * Double.pi * frequency * Double(n) / sampleRate
            re += sample * cos(angle)
            im += sample * sin(angle)
        }
        let mag = sqrt(re * re + im * im)
        return 20.0 * log10(max(mag, 1e-9))
    }

    private func maxAbsDifference(_ a: [Float], _ b: [Float]) -> Float {
        zip(a, b).map { abs($0 - $1) }.max() ?? 0
    }

    private func rmsDifference(_ a: [Float], _ b: [Float]) -> Double {
        guard !a.isEmpty, a.count == b.count else { return .infinity }
        let sum = zip(a, b).reduce(0.0) { acc, pair in
            let d = Double(pair.0 - pair.1)
            return acc + d * d
        }
        return sqrt(sum / Double(a.count))
    }

    private func transitionProbeSample(at index: Int) -> Float {
        let t = Double(index) / sampleRate
        return Float(
            0.23 * sin(2 * Double.pi * 147 * t) +
            0.17 * sin(2 * Double.pi * 733 * t + 0.3) +
            0.11 * sin(2 * Double.pi * 2_911 * t + 0.9) +
            0.05 * sin(2 * Double.pi * 7_123 * t + 1.4)
        )
    }

    private func renderProbeSegment(startIndex: Int, frames: Int) -> [Float] {
        (0..<frames).map { transitionProbeSample(at: startIndex + $0) }
    }

    private func process(_ buffer: inout [Float], with processor: EQProcessor) {
        let frames = buffer.count
        buffer.withUnsafeMutableBufferPointer { p in
            guard let base = p.baseAddress else { return }
            processor.processInPlace(left: base, right: nil, frames: frames)
        }
    }

    private func transitionMetrics(
        from beforePreset: EQPreset,
        to afterPreset: EQPreset,
        warmupFrames: Int = 8_192,
        beforeFrames: Int = 512,
        afterFrames: Int = 2_048,
        nearBoundaryFrames: Int = 512
    ) -> TransitionMetrics {
        let processor = EQProcessor(sampleRate: sampleRate)
        processor.update(preset: beforePreset)

        var warmup = renderProbeSegment(startIndex: 0, frames: warmupFrames)
        process(&warmup, with: processor)

        let beforeStart = warmupFrames
        let beforeInput = renderProbeSegment(startIndex: beforeStart, frames: beforeFrames)
        var beforeOutput = beforeInput
        process(&beforeOutput, with: processor)

        processor.update(preset: afterPreset)

        let afterStart = beforeStart + beforeFrames
        let afterInput = renderProbeSegment(startIndex: afterStart, frames: afterFrames)
        var afterOutput = afterInput
        process(&afterOutput, with: processor)

        let input = beforeInput + afterInput
        let output = beforeOutput + afterOutput
        let boundary = beforeFrames

        let boundaryInputStep = abs(input[boundary] - input[boundary - 1])
        let boundaryOutputStep = abs(output[boundary] - output[boundary - 1])
        let boundaryExcess = max(0, boundaryOutputStep - boundaryInputStep)

        let end = min(output.count - 1, boundary + nearBoundaryFrames)
        var maxExcess: Float = 0
        var sumSquares = 0.0
        var count = 0
        for i in boundary...end {
            let inputStep = abs(input[i] - input[i - 1])
            let outputStep = abs(output[i] - output[i - 1])
            let excess = max(0, outputStep - inputStep)
            maxExcess = max(maxExcess, excess)
            sumSquares += Double(excess * excess)
            count += 1
        }

        return TransitionMetrics(
            boundaryExcessStep: boundaryExcess,
            maxExcessStepNearBoundary: maxExcess,
            rmsExcessStepNearBoundary: count > 0 ? sqrt(sumSquares / Double(count)) : 0,
            outputPeak: output.map { abs($0) }.max() ?? 0
        )
    }

    private func liveDragPreset(centerHz: Double, gainDb: Double, q: Double = 0.9) -> EQPreset {
        var bands = EQBand.defaultBands()
        bands[5] = EQBand(index: 6, type: .bell, frequencyHz: centerHz, gainDb: gainDb, q: q)
        bands[11] = EQBand(index: 12, type: .bell, frequencyHz: 2_400, gainDb: 1.5, q: 1.1)
        return EQPreset(id: "drag", name: "Drag", preampDb: -3, bands: bands)
    }

    private func presetSwitchVariant(bassGain: Double, presenceGain: Double, trebleGain: Double) -> EQPreset {
        var bands = EQBand.defaultBands()
        bands[1] = EQBand(index: 2, type: .lowShelf, frequencyHz: 110, gainDb: bassGain, q: 0.707)
        bands[8] = EQBand(index: 9, type: .bell, frequencyHz: 1_100, gainDb: -1.5, q: 0.9)
        bands[12] = EQBand(index: 13, type: .bell, frequencyHz: 3_200, gainDb: presenceGain, q: 1.2)
        bands[17] = EQBand(index: 18, type: .highShelf, frequencyHz: 9_000, gainDb: trebleGain, q: 0.707)
        return EQPreset(id: "switch", name: "Switch", preampDb: -5, bands: bands)
    }

    func testSharedResponseFixtureMatchesSwiftFrequencyResponse() throws {
        let fixture = try loadResponseParityFixture()
        XCTAssertEqual(fixture.frequenciesHz.count, fixture.expectedDb.count)

        let curve = FrequencyResponse.curve(
            for: fixture.preset,
            at: fixture.frequenciesHz,
            sampleRate: fixture.sampleRate
        )

        for (point, expected) in zip(curve, fixture.expectedDb) {
            XCTAssertEqual(
                point.magnitudeDb,
                expected,
                accuracy: fixture.toleranceDb,
                "Shared parity fixture drifted at \(point.frequencyHz) Hz"
            )
        }
    }

    func testFlatImpulseResponseIsSingleSampleUnity() {
        let amplitude: Float = 0.5
        var buffer = [Float](repeating: 0, count: 2_048)
        buffer[0] = amplitude

        let processor = EQProcessor(sampleRate: sampleRate)
        processor.update(preset: .flat())
        let frameCount = buffer.count
        buffer.withUnsafeMutableBufferPointer { p in
            guard let base = p.baseAddress else { return }
            processor.processInPlace(left: base, right: nil, frames: frameCount)
        }

        XCTAssertEqual(buffer[0], amplitude, accuracy: 0)
        for sample in buffer.dropFirst() {
            XCTAssertEqual(sample, 0, accuracy: 0)
        }
    }

    func testFlatProgramNullsAgainstInput() {
        let frames = 4_096
        var program = (0..<frames).map { n -> Float in
            let t = Double(n) / sampleRate
            return Float(
                0.32 * sin(2 * Double.pi * 110 * t) +
                0.21 * sin(2 * Double.pi * 997 * t) +
                0.11 * sin(2 * Double.pi * 5_300 * t)
            )
        }
        let original = program

        let processor = EQProcessor(sampleRate: sampleRate)
        processor.update(preset: .flat())
        program.withUnsafeMutableBufferPointer { p in
            guard let base = p.baseAddress else { return }
            processor.processInPlace(left: base, right: nil, frames: frames)
        }

        XCTAssertEqual(maxAbsDifference(program, original), 0, accuracy: 0)
        XCTAssertEqual(rmsDifference(program, original), 0, accuracy: 0)
    }

    func testSettledBypassNullsAgainstInput() {
        let processor = EQProcessor(sampleRate: sampleRate)
        processor.update(preset: qualityPreset(includeNotch: true))

        var warmup = [Float](repeating: 0.2, count: 512)
        let warmupFrames = warmup.count
        warmup.withUnsafeMutableBufferPointer { p in
            guard let base = p.baseAddress else { return }
            processor.processInPlace(left: base, right: nil, frames: warmupFrames)
        }

        processor.setEnabled(false)
        var fadeOut = [Float](repeating: 0.2, count: 4_096)
        let fadeOutFrames = fadeOut.count
        fadeOut.withUnsafeMutableBufferPointer { p in
            guard let base = p.baseAddress else { return }
            processor.processInPlace(left: base, right: nil, frames: fadeOutFrames)
        }

        let frames = 2_048
        var program = (0..<frames).map { n -> Float in
            let t = Double(n) / sampleRate
            return Float(0.37 * sin(2 * Double.pi * 223 * t) + 0.19 * sin(2 * Double.pi * 3_101 * t))
        }
        let original = program
        program.withUnsafeMutableBufferPointer { p in
            guard let base = p.baseAddress else { return }
            processor.processInPlace(left: base, right: nil, frames: frames)
        }

        XCTAssertEqual(maxAbsDifference(program, original), 0, accuracy: 0)
        XCTAssertEqual(rmsDifference(program, original), 0, accuracy: 0)
    }

    func testRealtimeImpulseResponseMatchesOfflineMagnitude() {
        let preset = qualityPreset()
        let impulse = processedImpulseResponse(preset: preset)
        let frequencies = [40.0, 80, 160, 315, 630, 1_250, 2_500, 5_000, 10_000, 16_000]

        for frequency in frequencies {
            let measured = magnitudeDb(ofImpulse: impulse, atHz: frequency)
            let expected = FrequencyResponse.curve(
                for: preset,
                at: [frequency],
                sampleRate: sampleRate
            )[0].magnitudeDb
            XCTAssertEqual(
                measured,
                expected,
                accuracy: 0.15,
                "Realtime impulse response drifted from offline response at \(frequency) Hz"
            )
        }
    }

    func testLiveBandDragTransitionHasBoundedClickMetric() {
        let metrics = transitionMetrics(
            from: liveDragPreset(centerHz: 900, gainDb: 2.0),
            to: liveDragPreset(centerHz: 980, gainDb: 2.75)
        )

        XCTAssertLessThan(metrics.boundaryExcessStep, 0.02)
        XCTAssertLessThan(metrics.maxExcessStepNearBoundary, 0.04)
        XCTAssertLessThan(metrics.rmsExcessStepNearBoundary, 0.006)
        XCTAssertLessThan(metrics.outputPeak, 0.75)
    }

    func testPresetSwitchTransitionHasBoundedClickMetric() {
        let metrics = transitionMetrics(
            from: presetSwitchVariant(bassGain: 1.5, presenceGain: 1.0, trebleGain: -0.5),
            to: presetSwitchVariant(bassGain: 3.0, presenceGain: -1.0, trebleGain: 1.5)
        )

        XCTAssertLessThan(metrics.boundaryExcessStep, 0.05)
        XCTAssertLessThan(metrics.maxExcessStepNearBoundary, 0.09)
        XCTAssertLessThan(metrics.rmsExcessStepNearBoundary, 0.015)
        XCTAssertLessThan(metrics.outputPeak, 0.75)
    }
}
