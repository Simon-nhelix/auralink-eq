import XCTest
@testable import AuralinkCore

final class RealtimeHandoffTests: XCTestCase {
    private let sampleRate = 48_000.0

    private func processConstant(
        _ processor: EQProcessor,
        value: Float,
        frames: Int
    ) -> [Float] {
        var buffer = [Float](repeating: value, count: frames)
        buffer.withUnsafeMutableBufferPointer { pointer in
            guard let base = pointer.baseAddress else { return }
            processor.processInPlace(left: base, right: nil, frames: frames)
        }
        return buffer
    }

    func testConcurrentControlUpdatesNeverExposeDryBuffer() {
        var preset = EQPreset.flat()
        preset.preampDb = -12
        let processor = EQProcessor(sampleRate: sampleRate)
        processor.update(preset: preset)
        _ = processConstant(processor, value: 0.5, frames: 8_192)

        let finished = DispatchSemaphore(value: 0)
        let updater = Thread {
            for index in 0..<20_000 {
                processor.setPreamp(index.isMultiple(of: 2) ? -12 : -11.75)
            }
            finished.signal()
        }
        updater.start()

        var largest: Float = 0
        for _ in 0..<2_000 {
            let output = processConstant(processor, value: 0.5, frames: 64)
            largest = max(largest, output.map(abs).max() ?? 0)
        }
        XCTAssertEqual(finished.wait(timeout: .now() + 5), .success)

        // The intended range is roughly 0.126...0.129. A failed publication
        // must retain the previous wet state; the old implementation returned
        // raw 0.5 samples for an entire buffer when try-lock failed.
        XCTAssertLessThan(largest, 0.2)
    }

    func testRapidPresetEditsRemainFiniteAndBounded() {
        var bands = EQBand.defaultBands()
        bands[4] = EQBand(index: 5, type: .bell, frequencyHz: 800, gainDb: 4, q: 1.2)
        let processor = EQProcessor(sampleRate: sampleRate)
        processor.update(preset: EQPreset(id: "rapid", name: "Rapid", preampDb: -6, bands: bands))
        _ = processConstant(processor, value: 0.1, frames: 8_192)

        var maximum: Float = 0
        for edit in 0..<80 {
            bands[4].frequencyHz = 700 + Double(edit % 20) * 35
            bands[4].gainDb = 2 + Double(edit % 7) * 0.5
            processor.update(preset: EQPreset(id: "rapid", name: "Rapid", preampDb: -6, bands: bands))

            for _ in 0..<12 { // 768 frames, approximately one 16 ms edit interval.
                let output = processConstant(processor, value: 0.1, frames: 64)
                XCTAssertTrue(output.allSatisfy(\.isFinite))
                maximum = max(maximum, output.map(abs).max() ?? 0)
            }
        }

        XCTAssertLessThan(maximum, 0.35, "coalesced edits must not create a transient spike")
    }

    func testSameModePresetGenerationCommitsOnlyAtRenderBoundary() {
        var first = EQPreset.flat()
        first.id = "first"
        let processor = EQProcessor(sampleRate: sampleRate)
        let firstGeneration = processor.update(preset: first)
        XCTAssertEqual(processor.activeRenderStateGenerationOnRenderThread, 0)
        _ = processConstant(processor, value: 0.1, frames: 64)
        XCTAssertEqual(processor.activeRenderStateGenerationOnRenderThread, firstGeneration)

        var second = first
        second.id = "second"
        second.bands[5] = EQBand(
            index: 6,
            type: .bell,
            frequencyHz: 1_000,
            gainDb: 3,
            q: 1
        )
        let secondGeneration = processor.update(preset: second)
        XCTAssertGreaterThan(secondGeneration, firstGeneration)
        XCTAssertEqual(processor.activeRenderStateGenerationOnRenderThread, firstGeneration)
        _ = processConstant(processor, value: 0.1, frames: 64)
        XCTAssertEqual(processor.activeRenderStateGenerationOnRenderThread, secondGeneration)
    }

    func testNewPendingStateRetiresSupersededDeferredStateOffRenderThread() {
        func preset(id: String, gainDb: Double) -> EQPreset {
            var bands = EQBand.defaultBands()
            bands[5] = EQBand(
                index: 6,
                type: .bell,
                frequencyHz: 1_000,
                gainDb: gainDb,
                q: 1
            )
            return EQPreset(id: id, name: id, bands: bands)
        }

        let processor = EQProcessor(sampleRate: sampleRate)
        processor.update(preset: .flat())
        _ = processConstant(processor, value: 0.1, frames: 64)

        processor.update(preset: preset(id: "a", gainDb: 2))
        _ = processConstant(processor, value: 0.1, frames: 64) // starts A fade
        processor.update(preset: preset(id: "b", gainDb: 3))
        _ = processConstant(processor, value: 0.1, frames: 8_192) // defers B, completes A fade

        let beforeSupersede = processor.retiredRenderStateEnqueueCount
        processor.update(preset: preset(id: "c", gainDb: 4))
        _ = processConstant(processor, value: 0.1, frames: 64)

        XCTAssertEqual(
            processor.retiredRenderStateEnqueueCount,
            beforeSupersede + 1,
            "superseded deferred state must enter the RT retirement queue"
        )
    }

    func testSampleRateChangeRebuildsCurrentPreset() {
        var bands = EQBand.defaultBands()
        bands[7] = EQBand(index: 8, type: .bell, frequencyHz: 1_500, gainDb: 6, q: 2)
        let preset = EQPreset(id: "rate", name: "Rate", preampDb: -6, bands: bands)
        let processor = EQProcessor(sampleRate: 48_000)
        processor.update(preset: preset)
        _ = processConstant(processor, value: 0.1, frames: 2_048)

        processor.setSampleRate(96_000)
        let output = processConstant(processor, value: 0.1, frames: 2_048)

        XCTAssertTrue(output.allSatisfy(\.isFinite))
        XCTAssertLessThan(output.map(abs).max() ?? 0, 0.3)
    }
}
