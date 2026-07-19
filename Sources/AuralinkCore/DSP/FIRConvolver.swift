import Foundation
import Accelerate

/// Preallocated direct-form FIR used by the production convolver's immediate
/// head and by legacy short-FIR quality fixtures.
///
/// Long measured impulses use `PartitionedFIRConvolver`, which keeps this direct
/// head for causal zero-block-delay output and computes the remaining tail with
/// partitioned FFT convolution.
public struct FIRConvolver: Sendable {
    public private(set) var taps: [Float]
    private var reversedTaps: [Float]
    private var delay: [Float]
    private var history: [Float]
    private var work: [Float]
    private var writeIndex: Int = 0
    private var maxFrames: Int

    public init(taps: [Float] = [1], maxFrames: Int = 8_192) {
        let sanitized = Self.sanitized(taps)
        self.taps = sanitized
        self.reversedTaps = sanitized.reversed()
        self.delay = [Float](repeating: 0, count: sanitized.count)
        self.history = [Float](repeating: 0, count: max(0, sanitized.count - 1))
        self.maxFrames = max(1, maxFrames)
        self.work = [Float](repeating: 0, count: self.maxFrames + max(0, sanitized.count - 1))
    }

    public var length: Int { taps.count }

    public var isIdentity: Bool {
        taps.count == 1 && abs(taps[0] - 1) < 1e-7
    }

    public mutating func update(taps newTaps: [Float]) {
        let sanitized = Self.sanitized(newTaps)
        taps = sanitized
        reversedTaps = sanitized.reversed()
        delay = [Float](repeating: 0, count: sanitized.count)
        history = [Float](repeating: 0, count: max(0, sanitized.count - 1))
        work = [Float](repeating: 0, count: maxFrames + max(0, sanitized.count - 1))
        writeIndex = 0
    }

    public mutating func reset() {
        delay.withUnsafeMutableBufferPointer { buffer in
            buffer.initialize(repeating: 0)
        }
        history.withUnsafeMutableBufferPointer { buffer in
            buffer.initialize(repeating: 0)
        }
        writeIndex = 0
    }

    @inline(__always)
    public mutating func process(_ x: Float) -> Float {
        delay[writeIndex] = x
        var acc: Float = 0
        var index = writeIndex
        for tap in taps {
            acc += tap * delay[index]
            index -= 1
            if index < 0 { index = delay.count - 1 }
        }
        writeIndex += 1
        if writeIndex == delay.count { writeIndex = 0 }
        return acc.isFinite ? acc : 0
    }

    public mutating func processInPlace(_ buffer: UnsafeMutablePointer<Float>, frames: Int) {
        guard frames > 0 else { return }
        guard taps.count > 1 else {
            let gain = taps[0]
            if gain != 1 {
                var g = gain
                vDSP_vsmul(buffer, 1, &g, buffer, 1, vDSP_Length(frames))
            }
            return
        }
        guard frames <= maxFrames, work.count >= frames + history.count else {
            for n in 0..<frames {
                buffer[n] = process(buffer[n])
            }
            return
        }

        let historyCount = history.count
        var updatedHistory = false
        work.withUnsafeMutableBufferPointer { workPtr in
            guard let workBase = workPtr.baseAddress else { return }
            if historyCount > 0 {
                history.withUnsafeBufferPointer { historyPtr in
                    guard let historyBase = historyPtr.baseAddress else { return }
                    workBase.update(from: historyBase, count: historyCount)
                }
            }
            workBase.advanced(by: historyCount).update(from: buffer, count: frames)

            reversedTaps.withUnsafeBufferPointer { tapsPtr in
                guard let tapsBase = tapsPtr.baseAddress else { return }
                vDSP_conv(
                    workBase,
                    1,
                    tapsBase,
                    1,
                    buffer,
                    1,
                    vDSP_Length(frames),
                    vDSP_Length(taps.count)
                )
            }

            if historyCount > 0 {
                let tail = workBase.advanced(by: frames)
                history.withUnsafeMutableBufferPointer { historyPtr in
                    guard let historyBase = historyPtr.baseAddress else { return }
                    historyBase.update(from: tail, count: historyCount)
                }
                updatedHistory = true
            }
        }
        if updatedHistory {
            syncSampleDelayFromHistory()
        }
        for n in 0..<frames where !buffer[n].isFinite {
            buffer[n] = 0
        }
    }

    private mutating func syncSampleDelayFromHistory() {
        delay.withUnsafeMutableBufferPointer { buffer in
            buffer.initialize(repeating: 0)
        }
        writeIndex = 0
        guard !history.isEmpty, delay.count == taps.count else { return }
        let start = delay.count - history.count
        for i in history.indices {
            delay[start + i] = history[i]
        }
    }

    private static func sanitized(_ taps: [Float]) -> [Float] {
        let finite = taps.map { $0.isFinite ? $0 : 0 }
        if finite.isEmpty { return [1] }
        if finite.allSatisfy({ abs($0) < 1e-12 }) { return [0] }
        return finite
    }
}
