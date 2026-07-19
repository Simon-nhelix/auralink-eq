import XCTest
@testable import AuralinkCore

final class PartitionedFIRConvolverTests: XCTestCase {
    func testVariableCallbackSegmentationMatchesDirectConvolution() {
        let taps = (0..<1_000).map { index in
            Float(exp(-Double(index) / 150) * cos(Double(index) * 0.17) * 0.01)
        }
        var adjustedTaps = taps
        adjustedTaps[0] += 0.8
        let input = deterministicNoise(count: 12_000)
        let expected = directConvolution(input: input, taps: adjustedTaps)
        let convolver = PartitionedFIRConvolver(taps: adjustedTaps, partitionSize: 128)

        var actual: [Float] = []
        actual.reserveCapacity(input.count)
        let callbacks = [1, 63, 64, 65, 511, 2_048, 17, 8_192]
        var inputIndex = 0
        var callbackIndex = 0
        while inputIndex < input.count {
            let count = min(callbacks[callbackIndex % callbacks.count], input.count - inputIndex)
            var block = Array(input[inputIndex..<(inputIndex + count)])
            block.withUnsafeMutableBufferPointer { pointer in
                guard let base = pointer.baseAddress else { return }
                convolver.processInPlace(base, frames: count)
            }
            actual.append(contentsOf: block)
            inputIndex += count
            callbackIndex += 1
        }

        let errors = zip(actual, expected).map { abs($0 - $1) }
        let maxError = errors.max() ?? .infinity
        let rmsError = sqrt(errors.reduce(0) { $0 + $1 * $1 } / Float(max(1, errors.count)))
        XCTAssertLessThanOrEqual(maxError, 2e-5)
        XCTAssertLessThanOrEqual(rmsError, 2e-6)
        XCTAssertEqual(convolver.algorithmicLatencyFrames, 0)
    }

    func testImpulseHasNoPartitionSchedulingLatency() {
        var taps = [Float](repeating: 0, count: 700)
        taps[0] = 0.75
        taps[127] = 0.1
        taps[128] = -0.2
        taps[511] = 0.05
        let convolver = PartitionedFIRConvolver(taps: taps, partitionSize: 128)
        var impulse = [Float](repeating: 0, count: 1_024)
        impulse[0] = 1
        let impulseCount = impulse.count
        impulse.withUnsafeMutableBufferPointer { pointer in
            guard let base = pointer.baseAddress else { return }
            convolver.processInPlace(base, frames: impulseCount)
        }

        for index in taps.indices {
            XCTAssertEqual(impulse[index], taps[index], accuracy: 1e-6, "tap \(index)")
        }
        XCTAssertEqual(impulse[700], 0, accuracy: 1e-6)
    }

    func testResetClearsDirectAndPartitionedHistory() {
        let taps = (0..<600).map { index in Float(exp(-Double(index) / 100) * 0.02) }
        let convolver = PartitionedFIRConvolver(taps: taps, partitionSize: 128)
        var noise = deterministicNoise(count: 777)
        let noiseCount = noise.count
        noise.withUnsafeMutableBufferPointer { pointer in
            guard let base = pointer.baseAddress else { return }
            convolver.processInPlace(base, frames: noiseCount)
        }
        convolver.reset()
        var silence = [Float](repeating: 0, count: 1_024)
        let silenceCount = silence.count
        silence.withUnsafeMutableBufferPointer { pointer in
            guard let base = pointer.baseAddress else { return }
            convolver.processInPlace(base, frames: silenceCount)
        }
        XCTAssertTrue(silence.allSatisfy { $0 == 0 && $0.isFinite })
    }

    private func deterministicNoise(count: Int) -> [Float] {
        var state: UInt64 = 0x4d595df4d0f33173
        return (0..<count).map { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let unit = Double(state >> 11) / Double(UInt64.max >> 11)
            return Float(unit * 2 - 1) * 0.1
        }
    }

    private func directConvolution(input: [Float], taps: [Float]) -> [Float] {
        var output = [Float](repeating: 0, count: input.count)
        for sampleIndex in input.indices {
            var sum: Double = 0
            let maximumTap = min(sampleIndex, taps.count - 1)
            for tapIndex in 0...maximumTap {
                sum += Double(taps[tapIndex]) * Double(input[sampleIndex - tapIndex])
            }
            output[sampleIndex] = Float(sum)
        }
        return output
    }
}
