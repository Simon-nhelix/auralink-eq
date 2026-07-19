import Foundation

/// Stateful 4x inter-sample peak estimator for live telemetry.
///
/// Each channel owns a fixed 12-sample delay line and evaluates the four
/// polyphase outputs from the order-48 interpolation FIR published in ITU-R
/// BS.1770. Channel history survives render-buffer boundaries, so splitting a
/// stream into different callback sizes cannot hide a peak. Processing performs
/// no allocation, locking, or filter design on the realtime thread.
public struct TruePeakEstimator: Sendable {
    public struct Estimate: Equatable, Sendable {
        public var samplePeak: Float
        public var estimatedTruePeak: Float

        public init(samplePeak: Float, estimatedTruePeak: Float) {
            self.samplePeak = samplePeak
            self.estimatedTruePeak = estimatedTruePeak
        }
    }

    private var leftState = ChannelState()
    private var rightState = ChannelState()

    public init() {}

    /// Clears channel history after a stream restart or discontinuity.
    public mutating func reset() {
        leftState = ChannelState()
        rightState = ChannelState()
    }

    /// Allocation-free scalar API for DSP loops that need to meter samples
    /// before they are written to a scratch buffer.
    public mutating func processStereoSample(left: Float, right: Float) -> Estimate {
        var samplePeak: Float = 0
        var truePeak: Float = 0
        leftState.accumulate(left, samplePeak: &samplePeak, truePeak: &truePeak)
        rightState.accumulate(right, samplePeak: &samplePeak, truePeak: &truePeak)
        return Estimate(samplePeak: samplePeak, estimatedTruePeak: truePeak)
    }

    /// Allocation-free scalar API using the left/mono history lane.
    public mutating func processMonoSample(_ sample: Float) -> Estimate {
        var samplePeak: Float = 0
        var truePeak: Float = 0
        leftState.accumulate(sample, samplePeak: &samplePeak, truePeak: &truePeak)
        return Estimate(samplePeak: samplePeak, estimatedTruePeak: truePeak)
    }

    /// Processes one stereo buffer while preserving independent L/R history.
    ///
    /// The FIR has a short group delay. Its delayed peak is reported by a later
    /// call when necessary, while the undelayed sample peak is always included
    /// immediately as a lower bound.
    public mutating func processStereo(
        left: UnsafePointer<Float>,
        right: UnsafePointer<Float>,
        frames: Int
    ) -> Estimate {
        guard frames > 0 else {
            return Estimate(samplePeak: 0, estimatedTruePeak: 0)
        }

        var samplePeak: Float = 0
        var truePeak: Float = 0
        leftState.accumulate(left, frames: frames, samplePeak: &samplePeak, truePeak: &truePeak)
        rightState.accumulate(right, frames: frames, samplePeak: &samplePeak, truePeak: &truePeak)
        return Estimate(samplePeak: samplePeak, estimatedTruePeak: truePeak)
    }

    /// Processes one mono buffer using the left/mono history lane.
    public mutating func processMono(samples: UnsafePointer<Float>, frames: Int) -> Estimate {
        guard frames > 0 else {
            return Estimate(samplePeak: 0, estimatedTruePeak: 0)
        }

        var samplePeak: Float = 0
        var truePeak: Float = 0
        leftState.accumulate(samples, frames: frames, samplePeak: &samplePeak, truePeak: &truePeak)
        return Estimate(samplePeak: samplePeak, estimatedTruePeak: truePeak)
    }

    // MARK: Stateless compatibility helpers

    /// One-shot compatibility API. It zero-pads the FIR tail so a peak delayed
    /// past the final input sample is still included. Stateful render paths
    /// should keep an estimator and call `processStereo` for every buffer.
    public static func estimateStereo(
        left: UnsafePointer<Float>,
        right: UnsafePointer<Float>,
        frames: Int
    ) -> Estimate {
        var estimator = TruePeakEstimator()
        var estimate = estimator.processStereo(left: left, right: right, frames: frames)
        estimator.leftState.flush(truePeak: &estimate.estimatedTruePeak)
        estimator.rightState.flush(truePeak: &estimate.estimatedTruePeak)
        return estimate
    }

    /// One-shot compatibility API. It zero-pads the FIR tail so a peak delayed
    /// past the final input sample is still included.
    public static func estimateMono(samples: UnsafePointer<Float>, frames: Int) -> Estimate {
        var estimator = TruePeakEstimator()
        var estimate = estimator.processMono(samples: samples, frames: frames)
        estimator.leftState.flush(truePeak: &estimate.estimatedTruePeak)
        return estimate
    }

    /// Fixed value state avoids copy-on-write storage and keeps the render path
    /// allocation-free even if an estimator value was copied before use.
    private struct ChannelState: Sendable {
        private var h0: Float = 0
        private var h1: Float = 0
        private var h2: Float = 0
        private var h3: Float = 0
        private var h4: Float = 0
        private var h5: Float = 0
        private var h6: Float = 0
        private var h7: Float = 0
        private var h8: Float = 0
        private var h9: Float = 0
        private var h10: Float = 0
        private var h11: Float = 0

        mutating func accumulate(
            _ samples: UnsafePointer<Float>,
            frames: Int,
            samplePeak: inout Float,
            truePeak: inout Float
        ) {
            for index in 0..<frames {
                accumulate(samples[index], samplePeak: &samplePeak, truePeak: &truePeak)
            }
        }

        mutating func accumulate(
            _ sample: Float,
            samplePeak: inout Float,
            truePeak: inout Float
        ) {
            Self.updatePeak(sample, peak: &samplePeak)
            Self.updatePeak(sample, peak: &truePeak)
            push(sample, truePeak: &truePeak)
        }

        /// Completes the delayed response for one-shot/offline callers only.
        mutating func flush(truePeak: inout Float) {
            for _ in 0..<11 {
                push(0, truePeak: &truePeak)
            }
        }

        private mutating func push(_ sample: Float, truePeak: inout Float) {
            h11 = h10
            h10 = h9
            h9 = h8
            h8 = h7
            h7 = h6
            h6 = h5
            h5 = h4
            h4 = h3
            h3 = h2
            h2 = h1
            h1 = h0
            h0 = sample

            // ITU-R BS.1770 Annex 2: order-48, four-phase FIR interpolator.
            let phase0 =
                0.001708984375 * h0
                + 0.010986328125 * h1
                - 0.0196533203125 * h2
                + 0.033203125 * h3
                - 0.0594482421875 * h4
                + 0.1373291015625 * h5
                + 0.97216796875 * h6
                - 0.102294921875 * h7
                + 0.047607421875 * h8
                - 0.026611328125 * h9
                + 0.014892578125 * h10
                - 0.00830078125 * h11
            let phase1 =
                -0.0291748046875 * h0
                + 0.029296875 * h1
                - 0.0517578125 * h2
                + 0.089111328125 * h3
                - 0.16650390625 * h4
                + 0.465087890625 * h5
                + 0.77978515625 * h6
                - 0.2003173828125 * h7
                + 0.1015625 * h8
                - 0.0582275390625 * h9
                + 0.0330810546875 * h10
                - 0.0189208984375 * h11
            let phase2 =
                -0.0189208984375 * h0
                + 0.0330810546875 * h1
                - 0.0582275390625 * h2
                + 0.1015625 * h3
                - 0.2003173828125 * h4
                + 0.77978515625 * h5
                + 0.465087890625 * h6
                - 0.16650390625 * h7
                + 0.089111328125 * h8
                - 0.0517578125 * h9
                + 0.029296875 * h10
                - 0.0291748046875 * h11
            let phase3 =
                -0.00830078125 * h0
                + 0.014892578125 * h1
                - 0.026611328125 * h2
                + 0.047607421875 * h3
                - 0.102294921875 * h4
                + 0.97216796875 * h5
                + 0.1373291015625 * h6
                - 0.0594482421875 * h7
                + 0.033203125 * h8
                - 0.0196533203125 * h9
                + 0.010986328125 * h10
                + 0.001708984375 * h11

            Self.updatePeak(phase0, peak: &truePeak)
            Self.updatePeak(phase1, peak: &truePeak)
            Self.updatePeak(phase2, peak: &truePeak)
            Self.updatePeak(phase3, peak: &truePeak)
        }

        private static func updatePeak(_ value: Float, peak: inout Float) {
            let magnitude = abs(value)
            if magnitude > peak { peak = magnitude }
        }
    }
}
