import AuralinkRT
import Foundation

public struct EQProcessMetrics: Equatable, Sendable {
    public var preProtectionSamplePeak: Float
    public var preProtectionTruePeak: Float

    public init(preProtectionSamplePeak: Float, preProtectionTruePeak: Float) {
        self.preProtectionSamplePeak = preProtectionSamplePeak
        self.preProtectionTruePeak = preProtectionTruePeak
    }
}

/// The real-time EQ engine: a cascade of up to 20 biquad sections per channel
/// plus a global preamp gain, driven by an `EQPreset`.
///
/// Threading model:
/// - Coefficients/FIR taps are built on the **control thread** and published as
///   a prepared pending state.
/// - The realtime thread only uses a non-blocking try-lock to *take* pending
///   control changes at a buffer boundary. When publication is contended it
///   keeps rendering the last committed DSP state; it never exposes a dry
///   buffer or waits for the control thread.
/// - **All public control methods must be called from one serialized thread**
///   (in the app that is the MainActor via AppModel/AudioRoutingEngine).
///   Preparation intentionally runs *outside* `controlLock` so an expensive
///   FIR design can never block the render thread's try-lock; that design
///   relies on serialized callers — two concurrent control callers could
///   publish generations out of order and race the measured-FIR cache
///   dictionary. The same serialization is expected for `deinit`: destroy the
///   processor on the control thread so render-state teardown never lands on
///   a realtime or unknown thread.
///
/// Smoothing (anti-click):
/// - **Preset updates carry compatible filter state over** by stable band index
///   instead of resetting it, so live band edits don't click on every change
///   while preset-scale jumps start the new cascade from clean state.
/// - **Large chain changes crossfade old→new cascades** over the same short
///   ramp, so removing/adding/retyping bands does not expose a one-buffer jump.
/// - **Preamp changes ramp** with a ~5 ms one-pole smoother instead of stepping
///   (no zipper noise while dragging the preamp slider).
/// - **Bypass/enable crossfades** dry↔wet over the same ~5 ms, so toggling the
///   EQ never pops. Fully bypassed audio is passed through bit-perfect.
/// - An explicit **clip-protection guard** (knee at 0.99, asymptote at 1.0)
///   caps the processed path only when Safe Mode enables it. Standard IIR mode
///   remains linear and preserves full-scale flat audio.
///
/// Control changes made *before* any audio has flowed snap immediately (no
/// ramp) — initial configuration must take effect on the very first buffer.
///
/// Each band may target stereo, left or right, so we keep an independent biquad
/// chain per physical channel and only populate the sections that apply to it.
public final class EQProcessor {
    /// One physical output channel's filter chain.
    private struct Chain {
        struct Section {
            private static let maxAdoptFrequencyRatio = 1.5
            private static let maxAdoptQRatio = 4.0
            private static let maxAdoptGainDeltaDb = 9.0

            var bandIndex: Int
            var type: BandType
            var frequencyHz: Double
            var gainDb: Double
            var q: Double
            var biquad: Biquad

            init(band: EQBand, biquad: Biquad) {
                self.bandIndex = band.index
                self.type = band.type
                self.frequencyHz = band.frequencyHz
                self.gainDb = band.gainDb
                self.q = band.q
                self.biquad = biquad
            }

            func canAdoptState(from previous: Section) -> Bool {
                guard bandIndex == previous.bandIndex, type == previous.type else { return false }
                guard Self.ratio(frequencyHz, previous.frequencyHz) <= Self.maxAdoptFrequencyRatio else { return false }
                guard Self.ratio(q, previous.q) <= Self.maxAdoptQRatio else { return false }
                if type.usesGain {
                    guard abs(gainDb - previous.gainDb) <= Self.maxAdoptGainDeltaDb else { return false }
                }
                return true
            }

            private static func ratio(_ a: Double, _ b: Double) -> Double {
                let lo = Swift.max(1e-9, Swift.min(abs(a), abs(b)))
                let hi = Swift.max(abs(a), abs(b))
                return hi / lo
            }
        }

        /// Active biquad sections, in cascade order. Count ≤ `EQBand.bandCount`.
        var sections: [Section] = []

        mutating func reset() {
            for i in sections.indices { sections[i].biquad.reset() }
        }

        /// Copies delay-line state only from compatible band identities.
        /// Cascade slots can shift when an earlier band is disabled or becomes
        /// a no-op; adopting by slot would move one filter's memory into
        /// another filter and create exactly the transient this handoff is
        /// meant to avoid. Adopting across filter type or large parameter
        /// jumps is also avoided because the old delay state no longer matches
        /// the new transfer function.
        mutating func adoptState(from other: Chain) {
            for i in sections.indices {
                guard let previous = other.sections.first(where: { sections[i].canAdoptState(from: $0) }) else {
                    continue
                }
                sections[i].biquad.adoptState(from: previous.biquad)
            }
        }

        @inline(__always)
        mutating func process(_ x: Float) -> Float {
            var s = x
            for i in sections.indices {
                s = sections[i].biquad.process(s)
            }
            return s
        }
    }

    /// Fully prepared render configuration. Construction may allocate and is
    /// therefore control-thread-only; the audio thread merely installs it at a
    /// buffer boundary and owns all subsequent mutable filter state.
    private final class PreparedRenderState {
        var leftChain: Chain
        var rightChain: Chain
        let leftFIR: PartitionedFIRConvolver
        let rightFIR: PartitionedFIRConvolver
        let renderMode: EQRenderMode
        let measuredQuality: MeasuredFIRQualitySummary?
        let generation: UInt64

        init(
            leftChain: Chain,
            rightChain: Chain,
            leftFIR: PartitionedFIRConvolver,
            rightFIR: PartitionedFIRConvolver,
            renderMode: EQRenderMode,
            measuredQuality: MeasuredFIRQualitySummary?,
            generation: UInt64
        ) {
            self.leftChain = leftChain
            self.rightChain = rightChain
            self.leftFIR = leftFIR
            self.rightFIR = rightFIR
            self.renderMode = renderMode
            self.measuredQuality = measuredQuality
            self.generation = generation
        }
    }

    /// Coalesced controls waiting for the next render boundary. Replacing a
    /// pending render state happens on the control thread, so rapid UI edits
    /// discard stale prepared states without burdening the audio callback.
    private struct PendingChanges {
        var sampleRate: Double?
        var renderState: PreparedRenderState?
        var enabled: Bool?
        var preampDb: Double?
        var preampLinear: Float?
        var clipProtectionEnabled: Bool?

        var isEmpty: Bool {
            sampleRate == nil
                && renderState == nil
                && enabled == nil
                && preampLinear == nil
                && clipProtectionEnabled == nil
        }
    }

    /// Guards only control snapshots and the pending mailbox. The render thread
    /// never needs this lock to process the current buffer.
    private let controlLock = NSLock()
    private var pendingChanges = PendingChanges()

    // Control-thread source of truth used to prepare complete render states.
    private var controlSampleRate: Double
    private var controlPreset: EQPreset = .flat()
    private var controlRenderMode: EQRenderMode = .standardIIR
    private var controlEnabled = true
    private var controlPreampDb: Double = 0
    private var controlClipProtectionEnabled = false
    private var controlMeasuredQuality: MeasuredFIRQualitySummary?
    private var controlRenderGeneration: UInt64 = 0

    // Realtime-thread-owned state below this point.
    private var sampleRate: Double
    private let channelCount: Int

    /// Dry/wet mix for the bypass crossfade: 1 = full EQ, 0 = bypass.
    private var mixTarget: Float = 1.0
    private var mixCurrent: Float = 1.0

    private var preampDb: Double = 0
    private var preampTargetLinear: Float = 1.0
    private var preampCurrentLinear: Float = 1.0

    /// One-pole smoothing coefficient for the ~5 ms gain/mix ramps.
    private var rampCoeff: Float

    /// True once audio has flowed; before that, control changes snap (initial
    /// configuration must be exact on the very first buffer).
    private var hasProcessedAudio = false
    /// Tracks whether the chains were reset after reaching full bypass, so the
    /// stale filter state is dropped exactly once.
    private var chainsResetAfterBypass = true

    private var activeRenderState: PreparedRenderState
    private var fadingRenderState: PreparedRenderState?
    private let measuredFIRCache = MeasuredFIRDesignCache(maxEntries: 6)
    private var deferredRenderState: PreparedRenderState?
    /// Retained render states leave the RT thread through this SPSC queue and
    /// are destroyed only when a control call drains it.
    private let retiredStateQueue: OpaquePointer
    /// Diagnostic counter used by ownership regression tests; render-thread-owned.
    private(set) var retiredRenderStateEnqueueCount: UInt64 = 0
    private var clipProtectionEnabled = false
    private var preProtectionTruePeakEstimator = TruePeakEstimator()
    /// Wet-path transition mix: 0 = old path, 1 = current path.
    private var chainFadeCurrent: Float = 1.0
    private static let transitionScratchFrames = 8_192
    private let transitionNewLeft = UnsafeMutablePointer<Float>.allocate(capacity: transitionScratchFrames)
    private let transitionNewRight = UnsafeMutablePointer<Float>.allocate(capacity: transitionScratchFrames)
    private let transitionOldLeft = UnsafeMutablePointer<Float>.allocate(capacity: transitionScratchFrames)
    private let transitionOldRight = UnsafeMutablePointer<Float>.allocate(capacity: transitionScratchFrames)

    public init(sampleRate: Double, channelCount: Int = 2) {
        let sr = sampleRate > 0 ? sampleRate : 48_000
        guard let retirementQueue = alk_ptr_queue_create(256) else {
            fatalError("Unable to allocate the realtime render-state retirement queue.")
        }
        self.controlSampleRate = sr
        self.sampleRate = sr
        self.channelCount = Swift.max(1, channelCount)
        self.rampCoeff = Self.rampCoefficient(sampleRate: sr)
        self.retiredStateQueue = retirementQueue
        self.activeRenderState = PreparedRenderState(
            leftChain: Chain(),
            rightChain: Chain(),
            leftFIR: PartitionedFIRConvolver(),
            rightFIR: PartitionedFIRConvolver(),
            renderMode: .standardIIR,
            measuredQuality: nil,
            generation: 0
        )
    }

    deinit {
        drainRetiredStatesOnControlThread()
        alk_ptr_queue_destroy(retiredStateQueue)
        transitionNewLeft.deallocate()
        transitionNewRight.deallocate()
        transitionOldLeft.deallocate()
        transitionOldRight.deallocate()
    }

    /// ~5 ms one-pole time constant at the given rate.
    private static func rampCoefficient(sampleRate: Double) -> Float {
        Float(1.0 - exp(-1.0 / (0.005 * sampleRate)))
    }

    /// RT producer: retain without destruction and publish one opaque pointer.
    /// The queue is deliberately large relative to the maximum two live/fading
    /// states; overflow leaks one retained state rather than deallocating on RT.
    @inline(__always)
    private func retireOnRenderThread(_ state: PreparedRenderState?) {
        guard let state else { return }
        let retained = Unmanaged.passRetained(state).toOpaque()
        if alk_ptr_queue_push(retiredStateQueue, retained) {
            retiredRenderStateEnqueueCount &+= 1
        }
    }

    /// Control consumer: releasing here runs vDSP setup and nested Array
    /// destruction away from the callback.
    private func drainRetiredStatesOnControlThread() {
        while let pointer = alk_ptr_queue_pop(retiredStateQueue) {
            _ = Unmanaged<PreparedRenderState>.fromOpaque(pointer).takeRetainedValue()
        }
    }

    // MARK: - Control-thread configuration

    /// Builds a complete render state on the control thread and publishes it
    /// for the next audio-buffer boundary. FIR design is lazy: Standard IIR
    /// edits never synthesize or allocate a measured impulse.
    @discardableResult
    public func update(preset: EQPreset) -> UInt64 {
        let p = preset.normalized()
        controlLock.lock()
        drainRetiredStatesOnControlThread()
        controlPreset = p
        controlPreampDb = p.preampDb
        let sr = controlSampleRate
        let mode = controlRenderMode
        controlRenderGeneration &+= 1
        let generation = controlRenderGeneration
        controlLock.unlock()

        let prepared = prepareRenderState(
            preset: p,
            sampleRate: sr,
            mode: mode,
            generation: generation
        )
        let linear = Float(pow(10.0, p.preampDb / 20.0))
        controlLock.lock()
        controlRenderMode = prepared.renderMode
        controlMeasuredQuality = prepared.measuredQuality
        pendingChanges.renderState = prepared
        pendingChanges.preampDb = p.preampDb
        pendingChanges.preampLinear = linear
        controlLock.unlock()
        return generation
    }

    /// Changes the working sample rate and prepares the current preset for it.
    /// The audio thread resets stale delay state when it consumes this update.
    @discardableResult
    public func setSampleRate(_ sr: Double) -> UInt64 {
        let value = sr > 0 ? sr : 48_000
        controlLock.lock()
        drainRetiredStatesOnControlThread()
        controlSampleRate = value
        let preset = controlPreset
        let mode = controlRenderMode
        controlRenderGeneration &+= 1
        let generation = controlRenderGeneration
        controlLock.unlock()

        measuredFIRCache.removeAll()
        let prepared = prepareRenderState(
            preset: preset,
            sampleRate: value,
            mode: mode,
            generation: generation
        )
        controlLock.lock()
        controlRenderMode = prepared.renderMode
        controlMeasuredQuality = prepared.measuredQuality
        pendingChanges.sampleRate = value
        pendingChanges.renderState = prepared
        controlLock.unlock()
        return generation
    }

    /// Enables or bypasses the whole processor. The transition crossfades over
    /// ~5 ms; once fully bypassed, audio passes through bit-perfect (not even
    /// preamp or the clip guard touch it).
    public func setEnabled(_ on: Bool) {
        controlLock.lock()
        drainRetiredStatesOnControlThread()
        controlEnabled = on
        pendingChanges.enabled = on
        controlLock.unlock()
    }

    /// Switches between standard PEQ and measured FIR + preference PEQ.
    /// Returns false when the current preset lacks an eligible measured curve;
    /// in that case the prepared renderer remains standard IIR.
    @discardableResult
    public func setRenderMode(_ mode: EQRenderMode) -> Bool {
        controlLock.lock()
        drainRetiredStatesOnControlThread()
        let alreadyRequested = mode == controlRenderMode
        let preset = controlPreset
        let sr = controlSampleRate
        if !alreadyRequested {
            controlRenderGeneration &+= 1
        }
        let generation = controlRenderGeneration
        controlLock.unlock()
        if alreadyRequested { return mode != .hqFIR || preset.correction?.measuredCorrection?.isFIREligible == true }

        let prepared = prepareRenderState(
            preset: preset,
            sampleRate: sr,
            mode: mode,
            generation: generation
        )
        controlLock.lock()
        controlRenderMode = prepared.renderMode
        controlMeasuredQuality = prepared.measuredQuality
        pendingChanges.renderState = prepared
        controlLock.unlock()
        return prepared.renderMode == mode
    }

    public func requestedRenderStateGeneration() -> UInt64 {
        controlLock.lock()
        let generation = controlRenderGeneration
        controlLock.unlock()
        return generation
    }

    public func measuredFIRQuality() -> MeasuredFIRQualitySummary? {
        controlLock.lock()
        drainRetiredStatesOnControlThread()
        let quality = controlMeasuredQuality
        controlLock.unlock()
        return quality
    }

    /// Sets the global preamp in dB (clamped to the preset range). Ramped.
    public func setPreamp(_ db: Double) {
        let clamped = Swift.min(Swift.max(db, EQPreset.preampRange.lowerBound), EQPreset.preampRange.upperBound)
        let linear = Float(pow(10.0, clamped / 20.0))
        controlLock.lock()
        drainRetiredStatesOnControlThread()
        controlPreampDb = clamped
        pendingChanges.preampDb = clamped
        pendingChanges.preampLinear = linear
        controlLock.unlock()
    }

    /// Enables the nonlinear emergency guard used by Safe Mode. Off by default
    /// so a flat, enabled EQ remains a transparent linear path up to 0 dBFS.
    public func setClipProtectionEnabled(_ enabled: Bool) {
        controlLock.lock()
        drainRetiredStatesOnControlThread()
        controlClipProtectionEnabled = enabled
        pendingChanges.clipProtectionEnabled = enabled
        controlLock.unlock()
    }

    /// Allocating preparation path. This never runs from `processInPlace`.
    private func prepareRenderState(
        preset: EQPreset,
        sampleRate: Double,
        mode: EQRenderMode,
        generation: UInt64
    ) -> PreparedRenderState {
        let normalized = preset.normalized()
        let measuredResult = mode == .hqFIR
            ? measuredFIRCache.design(for: normalized, sampleRate: sampleRate)
            : nil
        let resolvedMode: EQRenderMode = measuredResult == nil ? .standardIIR : .hqFIR
        let preferenceIndexes = Set(normalized.correction?.preferenceBandIndexes ?? [])
        var left = Chain()
        var right = Chain()

        for band in normalized.bands where band.enabled {
            if resolvedMode == .hqFIR && !preferenceIndexes.contains(band.index) { continue }
            if band.type.usesGain && abs(band.gainDb) < 1e-4 { continue }

            var biquad = Biquad()
            biquad.configure(
                type: band.type,
                frequencyHz: band.frequencyHz,
                gainDb: band.gainDb,
                q: band.q,
                sampleRate: sampleRate
            )

            switch band.channel {
            case .stereo:
                left.sections.append(Chain.Section(band: band, biquad: biquad))
                right.sections.append(Chain.Section(band: band, biquad: biquad))
            case .left:
                left.sections.append(Chain.Section(band: band, biquad: biquad))
            case .right:
                right.sections.append(Chain.Section(band: band, biquad: biquad))
            }
        }

        let partition = MeasuredFIRDesigner.partitionSize(for: sampleRate)
        return PreparedRenderState(
            leftChain: left,
            rightChain: right,
            leftFIR: PartitionedFIRConvolver(
                taps: measuredResult?.design.left.taps ?? [1],
                partitionSize: partition
            ),
            rightFIR: PartitionedFIRConvolver(
                taps: measuredResult?.design.right.taps ?? [1],
                partitionSize: partition
            ),
            renderMode: resolvedMode,
            measuredQuality: measuredResult?.quality,
            generation: generation
        )
    }

    /// Takes coalesced controls without blocking. A miss simply leaves the
    /// current render state in place for this buffer.
    private func consumePendingChangesAtBufferBoundary() {
        var changes: PendingChanges?
        if controlLock.try() {
            if !pendingChanges.isEmpty {
                changes = pendingChanges
                pendingChanges = PendingChanges()
            }
            controlLock.unlock()
        }

        var installedRenderState = false
        if let changes {
            if let newRate = changes.sampleRate {
                sampleRate = newRate
                rampCoeff = Self.rampCoefficient(sampleRate: newRate)
                activeRenderState.leftChain.reset()
                activeRenderState.rightChain.reset()
                activeRenderState.leftFIR.reset()
                activeRenderState.rightFIR.reset()
                retireOnRenderThread(fadingRenderState)
                fadingRenderState = nil
                retireOnRenderThread(deferredRenderState)
                deferredRenderState = nil
                preProtectionTruePeakEstimator.reset()
                chainFadeCurrent = 1
                // Engine graph changes happen while stopped; make the first
                // buffer at the new rate an exact, non-ramped configuration.
                hasProcessedAudio = false
            }

            if let enabled = changes.enabled {
                mixTarget = enabled ? 1 : 0
                if !hasProcessedAudio { mixCurrent = mixTarget }
            }
            if let linear = changes.preampLinear {
                preampDb = changes.preampDb ?? preampDb
                preampTargetLinear = linear
                if !hasProcessedAudio { preampCurrentLinear = linear }
            }
            if let protection = changes.clipProtectionEnabled {
                if protection != clipProtectionEnabled {
                    preProtectionTruePeakEstimator.reset()
                }
                clipProtectionEnabled = protection
            }
            if let state = changes.renderState {
                if hasProcessedAudio, chainFadeCurrent < 1 {
                    // Keep only the newest edit while the current audible
                    // transition finishes. Retire the superseded prepared
                    // object off-thread instead of destroying it here.
                    retireOnRenderThread(deferredRenderState)
                    deferredRenderState = state
                } else {
                    retireOnRenderThread(deferredRenderState)
                    deferredRenderState = nil
                    installRenderState(state)
                    installedRenderState = true
                }
            }
        }

        if !installedRenderState,
           chainFadeCurrent == 1,
           let deferred = deferredRenderState {
            deferredRenderState = nil
            installRenderState(deferred)
        }
    }

    private func installRenderState(_ prepared: PreparedRenderState) {
        let old = activeRenderState
        prepared.leftChain.adoptState(from: old.leftChain)
        prepared.rightChain.adoptState(from: old.rightChain)
        prepared.leftFIR.reset()
        prepared.rightFIR.reset()

        let shouldCrossfade = hasProcessedAudio
            && mixCurrent > 0
            && mixTarget > 0
            && (old.renderMode != prepared.renderMode
                || !old.leftChain.sections.isEmpty || !old.rightChain.sections.isEmpty
                || !prepared.leftChain.sections.isEmpty || !prepared.rightChain.sections.isEmpty
                || !old.leftFIR.isIdentity || !old.rightFIR.isIdentity
                || !prepared.leftFIR.isIdentity || !prepared.rightFIR.isIdentity)

        activeRenderState = prepared
        retireOnRenderThread(fadingRenderState)
        if shouldCrossfade {
            fadingRenderState = old
            chainFadeCurrent = 0
        } else {
            fadingRenderState = nil
            retireOnRenderThread(old)
            chainFadeCurrent = 1
        }
    }

    // MARK: - Realtime rendering

    /// Read only from the render callback after processing a buffer. Control
    /// code must use its requested/prepared status instead of racing this state.
    public var activeRenderModeOnRenderThread: EQRenderMode {
        activeRenderState.renderMode
    }

    public var activeRenderStateGenerationOnRenderThread: UInt64 {
        activeRenderState.generation
    }

    /// Filters planar (de-interleaved) buffers in place. `right` may be nil for
    /// mono sources, in which case only the left chain runs.
    ///
    /// Returns the **pre-clip-guard peak** of the processed path (0 when fully
    /// bypassed or skipped), which is the honest clipping signal: the guard
    /// caps the output below 1.0, so the post-output peak alone can no longer
    /// reveal that the EQ pushed past full scale.
    ///
    /// Realtime-safe: no allocation, deallocation, or blocking. Prepared state
    /// ownership is transferred at the boundary; retired states go through a
    /// C11 SPSC queue for control-thread destruction. A mailbox collision
    /// defers the update rather than changing the audio rendered for this buffer.
    @discardableResult
    public func processInPlace(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>?, frames: Int) -> Float {
        processInPlaceWithMetrics(left: left, right: right, frames: frames).preProtectionSamplePeak
    }

    /// Variant used by the routing engine when Safe Mode needs the true peak
    /// before its nonlinear guard. Standard-mode callers can keep using the
    /// source-compatible `processInPlace` API above.
    @discardableResult
    public func processInPlaceWithMetrics(
        left: UnsafeMutablePointer<Float>,
        right: UnsafeMutablePointer<Float>?,
        frames: Int
    ) -> EQProcessMetrics {
        guard frames > 0 else {
            return EQProcessMetrics(preProtectionSamplePeak: 0, preProtectionTruePeak: 0)
        }

        consumePendingChangesAtBufferBoundary()
        hasProcessedAudio = true

        let mixT = mixTarget
        var mix = mixCurrent
        let gainT = preampTargetLinear
        var gain = preampCurrentLinear
        let coeff = rampCoeff
        var chainFade = chainFadeCurrent
        let protectionEnabled = clipProtectionEnabled

        // Fast path: fully bypassed and not fading back in — bit-perfect pass.
        if mixT == 0 && mix == 0 {
            if !chainsResetAfterBypass {
                // Drop stale filter state exactly once so a later re-enable
                // starts from silence instead of an old transient.
                activeRenderState.leftChain.reset()
                activeRenderState.rightChain.reset()
                activeRenderState.leftFIR.reset()
                activeRenderState.rightFIR.reset()
                preProtectionTruePeakEstimator.reset()
                chainsResetAfterBypass = true
            }
            retireOnRenderThread(fadingRenderState)
            fadingRenderState = nil
            chainFadeCurrent = 1
            return EQProcessMetrics(preProtectionSamplePeak: 0, preProtectionTruePeak: 0)
        }
        chainsResetAfterBypass = false

        var preClipPeak: Float = 0
        var preProtectionTruePeak: Float = 0

        if mix == 1, mixT == 1, gain == gainT, chainFade == 1,
           activeRenderState.renderMode == .hqFIR {
            for n in 0..<frames {
                left[n] *= gain
            }
            activeRenderState.leftFIR.processInPlace(left, frames: frames)
            if !activeRenderState.leftChain.sections.isEmpty {
                for n in 0..<frames { left[n] = activeRenderState.leftChain.process(left[n]) }
            }

            if let right {
                for n in 0..<frames {
                    right[n] *= gain
                }
                activeRenderState.rightFIR.processInPlace(right, frames: frames)
                if !activeRenderState.rightChain.sections.isEmpty {
                    for n in 0..<frames { right[n] = activeRenderState.rightChain.process(right[n]) }
                }
                for n in 0..<frames {
                    let a = Swift.max(abs(left[n]), abs(right[n]))
                    if a > preClipPeak { preClipPeak = a }
                    if protectionEnabled {
                        let estimate = preProtectionTruePeakEstimator.processStereoSample(
                            left: left[n],
                            right: right[n]
                        )
                        preProtectionTruePeak = max(preProtectionTruePeak, estimate.estimatedTruePeak)
                    }
                    left[n] = Self.applyClipProtection(left[n], enabled: protectionEnabled)
                    right[n] = Self.applyClipProtection(right[n], enabled: protectionEnabled)
                }
            } else {
                for n in 0..<frames {
                    let a = abs(left[n])
                    if a > preClipPeak { preClipPeak = a }
                    if protectionEnabled {
                        let estimate = preProtectionTruePeakEstimator.processMonoSample(left[n])
                        preProtectionTruePeak = max(preProtectionTruePeak, estimate.estimatedTruePeak)
                    }
                    left[n] = Self.applyClipProtection(left[n], enabled: protectionEnabled)
                }
            }
        } else if mix == 1, mixT == 1, gain == gainT, chainFade == 1 {
            // Settled fast path: full wet, constant gain.
            if let right {
                for n in 0..<frames {
                    let wetL = processCurrentWetLeft(left[n], gain: gain)
                    let wetR = processCurrentWetRight(right[n], gain: gain)
                    let a = Swift.max(abs(wetL), abs(wetR))
                    if a > preClipPeak { preClipPeak = a }
                    if protectionEnabled {
                        let estimate = preProtectionTruePeakEstimator.processStereoSample(left: wetL, right: wetR)
                        preProtectionTruePeak = max(preProtectionTruePeak, estimate.estimatedTruePeak)
                    }
                    left[n] = Self.applyClipProtection(wetL, enabled: protectionEnabled)
                    right[n] = Self.applyClipProtection(wetR, enabled: protectionEnabled)
                }
            } else {
                for n in 0..<frames {
                    let wet = processCurrentWetLeft(left[n], gain: gain)
                    let a = abs(wet)
                    if a > preClipPeak { preClipPeak = a }
                    if protectionEnabled {
                        let estimate = preProtectionTruePeakEstimator.processMonoSample(wet)
                        preProtectionTruePeak = max(preProtectionTruePeak, estimate.estimatedTruePeak)
                    }
                    left[n] = Self.applyClipProtection(wet, enabled: protectionEnabled)
                }
            }
        } else if frames <= Self.transitionScratchFrames {
            // Any gain, bypass, preset, or renderer transition uses preallocated
            // block buffers. Variable preamp is applied while copying, then the
            // FIR head stays on vDSP instead of reverting to scalar 512-tap work.
            var blockGain = gain
            if let right {
                for n in 0..<frames {
                    blockGain += (gainT - blockGain) * coeff
                    transitionNewLeft[n] = left[n] * blockGain
                    transitionNewRight[n] = right[n] * blockGain
                    transitionOldLeft[n] = transitionNewLeft[n]
                    transitionOldRight[n] = transitionNewRight[n]
                }
            } else {
                for n in 0..<frames {
                    blockGain += (gainT - blockGain) * coeff
                    transitionNewLeft[n] = left[n] * blockGain
                    transitionOldLeft[n] = transitionNewLeft[n]
                }
            }
            gain = blockGain

            processCurrentWetLeftBuffer(transitionNewLeft, frames: frames, gain: 1)
            if chainFade < 1,
               !processFadingWetLeftBuffer(transitionOldLeft, frames: frames, gain: 1) {
                transitionOldLeft.update(from: transitionNewLeft, count: frames)
            }
            if chainFade == 1 {
                transitionOldLeft.update(from: transitionNewLeft, count: frames)
            }

            if let right {
                processCurrentWetRightBuffer(transitionNewRight, frames: frames, gain: 1)
                if chainFade < 1,
                   !processFadingWetRightBuffer(transitionOldRight, frames: frames, gain: 1) {
                    transitionOldRight.update(from: transitionNewRight, count: frames)
                }
                if chainFade == 1 {
                    transitionOldRight.update(from: transitionNewRight, count: frames)
                }
                for n in 0..<frames {
                    mix += (mixT - mix) * coeff
                    let fade = chainFade
                    let wetLeft = transitionOldLeft[n]
                        + (transitionNewLeft[n] - transitionOldLeft[n]) * fade
                    let wetRight = transitionOldRight[n]
                        + (transitionNewRight[n] - transitionOldRight[n]) * fade
                    let outputLeft = left[n] + (wetLeft - left[n]) * mix
                    let outputRight = right[n] + (wetRight - right[n]) * mix
                    let peak = Swift.max(abs(outputLeft), abs(outputRight))
                    if peak > preClipPeak { preClipPeak = peak }
                    if protectionEnabled {
                        let estimate = preProtectionTruePeakEstimator.processStereoSample(
                            left: outputLeft,
                            right: outputRight
                        )
                        preProtectionTruePeak = max(preProtectionTruePeak, estimate.estimatedTruePeak)
                    }
                    left[n] = Self.applyClipProtection(outputLeft, enabled: protectionEnabled)
                    right[n] = Self.applyClipProtection(outputRight, enabled: protectionEnabled)
                    if chainFade < 1 { chainFade += (1 - chainFade) * coeff }
                }
            } else {
                for n in 0..<frames {
                    mix += (mixT - mix) * coeff
                    let fade = chainFade
                    let wet = transitionOldLeft[n]
                        + (transitionNewLeft[n] - transitionOldLeft[n]) * fade
                    let output = left[n] + (wet - left[n]) * mix
                    let peak = abs(output)
                    if peak > preClipPeak { preClipPeak = peak }
                    if protectionEnabled {
                        let estimate = preProtectionTruePeakEstimator.processMonoSample(output)
                        preProtectionTruePeak = max(preProtectionTruePeak, estimate.estimatedTruePeak)
                    }
                    left[n] = Self.applyClipProtection(output, enabled: protectionEnabled)
                    if chainFade < 1 { chainFade += (1 - chainFade) * coeff }
                }
            }
            if abs(gain - gainT) < 1e-5 { gain = gainT }
            if abs(mix - mixT) < 1e-4 { mix = mixT }
            if abs(1 - chainFade) < 1e-4 { chainFade = 1 }
        } else {
            // Gain/bypass ramp or oversized fallback: smooth per sample with one
            // shared trajectory for both channels so the image never wanders.
            if let right {
                for n in 0..<frames {
                    gain += (gainT - gain) * coeff
                    mix += (mixT - mix) * coeff
                    let fade = chainFade
                    let dryL = left[n]
                    let dryR = right[n]
                    let newWetL = processCurrentWetLeft(dryL, gain: gain)
                    let newWetR = processCurrentWetRight(dryR, gain: gain)
                    let oldWetL = fade < 1 ? processFadingWetLeft(dryL, gain: gain, fallback: newWetL) : newWetL
                    let oldWetR = fade < 1 ? processFadingWetRight(dryR, gain: gain, fallback: newWetR) : newWetR
                    let wetL = oldWetL + (newWetL - oldWetL) * fade
                    let wetR = oldWetR + (newWetR - oldWetR) * fade
                    let outL = dryL + (wetL - dryL) * mix
                    let outR = dryR + (wetR - dryR) * mix
                    let a = Swift.max(abs(outL), abs(outR))
                    if a > preClipPeak { preClipPeak = a }
                    if protectionEnabled {
                        let estimate = preProtectionTruePeakEstimator.processStereoSample(left: outL, right: outR)
                        preProtectionTruePeak = max(preProtectionTruePeak, estimate.estimatedTruePeak)
                    }
                    left[n] = Self.applyClipProtection(outL, enabled: protectionEnabled)
                    right[n] = Self.applyClipProtection(outR, enabled: protectionEnabled)
                    if chainFade < 1 { chainFade += (1 - chainFade) * coeff }
                }
            } else {
                for n in 0..<frames {
                    gain += (gainT - gain) * coeff
                    mix += (mixT - mix) * coeff
                    let fade = chainFade
                    let dry = left[n]
                    let newWet = processCurrentWetLeft(dry, gain: gain)
                    let oldWet = fade < 1 ? processFadingWetLeft(dry, gain: gain, fallback: newWet) : newWet
                    let wet = oldWet + (newWet - oldWet) * fade
                    let out = dry + (wet - dry) * mix
                    let a = abs(out)
                    if a > preClipPeak { preClipPeak = a }
                    if protectionEnabled {
                        let estimate = preProtectionTruePeakEstimator.processMonoSample(out)
                        preProtectionTruePeak = max(preProtectionTruePeak, estimate.estimatedTruePeak)
                    }
                    left[n] = Self.applyClipProtection(out, enabled: protectionEnabled)
                    if chainFade < 1 { chainFade += (1 - chainFade) * coeff }
                }
            }
            // Snap once the ramps converge so we re-enter the fast paths.
            if abs(gain - gainT) < 1e-5 { gain = gainT }
            if abs(mix - mixT) < 1e-4 { mix = mixT }
            if abs(1 - chainFade) < 1e-4 { chainFade = 1 }
        }

        preampCurrentLinear = gain
        mixCurrent = mix
        chainFadeCurrent = chainFade
        if chainFade == 1, fadingRenderState != nil {
            retireOnRenderThread(fadingRenderState)
            fadingRenderState = nil
        }
        return EQProcessMetrics(
            preProtectionSamplePeak: preClipPeak,
            preProtectionTruePeak: protectionEnabled
                ? max(preClipPeak, preProtectionTruePeak)
                : preClipPeak
        )
    }

    private func processCurrentWetLeftBuffer(
        _ buffer: UnsafeMutablePointer<Float>,
        frames: Int,
        gain: Float
    ) {
        switch activeRenderState.renderMode {
        case .standardIIR:
            for index in 0..<frames {
                buffer[index] = activeRenderState.leftChain.process(buffer[index] * gain)
            }
        case .hqFIR:
            for index in 0..<frames { buffer[index] *= gain }
            activeRenderState.leftFIR.processInPlace(buffer, frames: frames)
            if !activeRenderState.leftChain.sections.isEmpty {
                for index in 0..<frames {
                    buffer[index] = activeRenderState.leftChain.process(buffer[index])
                }
            }
        }
    }

    private func processCurrentWetRightBuffer(
        _ buffer: UnsafeMutablePointer<Float>,
        frames: Int,
        gain: Float
    ) {
        switch activeRenderState.renderMode {
        case .standardIIR:
            for index in 0..<frames {
                buffer[index] = activeRenderState.rightChain.process(buffer[index] * gain)
            }
        case .hqFIR:
            for index in 0..<frames { buffer[index] *= gain }
            activeRenderState.rightFIR.processInPlace(buffer, frames: frames)
            if !activeRenderState.rightChain.sections.isEmpty {
                for index in 0..<frames {
                    buffer[index] = activeRenderState.rightChain.process(buffer[index])
                }
            }
        }
    }

    @discardableResult
    private func processFadingWetLeftBuffer(
        _ buffer: UnsafeMutablePointer<Float>,
        frames: Int,
        gain: Float
    ) -> Bool {
        guard let fading = fadingRenderState else { return false }
        switch fading.renderMode {
        case .standardIIR:
            for index in 0..<frames {
                buffer[index] = fading.leftChain.process(buffer[index] * gain)
            }
        case .hqFIR:
            for index in 0..<frames { buffer[index] *= gain }
            fading.leftFIR.processInPlace(buffer, frames: frames)
            if !fading.leftChain.sections.isEmpty {
                for index in 0..<frames {
                    buffer[index] = fading.leftChain.process(buffer[index])
                }
            }
        }
        return true
    }

    @discardableResult
    private func processFadingWetRightBuffer(
        _ buffer: UnsafeMutablePointer<Float>,
        frames: Int,
        gain: Float
    ) -> Bool {
        guard let fading = fadingRenderState else { return false }
        switch fading.renderMode {
        case .standardIIR:
            for index in 0..<frames {
                buffer[index] = fading.rightChain.process(buffer[index] * gain)
            }
        case .hqFIR:
            for index in 0..<frames { buffer[index] *= gain }
            fading.rightFIR.processInPlace(buffer, frames: frames)
            if !fading.rightChain.sections.isEmpty {
                for index in 0..<frames {
                    buffer[index] = fading.rightChain.process(buffer[index])
                }
            }
        }
        return true
    }

    @inline(__always)
    private func processCurrentWetLeft(_ dry: Float, gain: Float) -> Float {
        switch activeRenderState.renderMode {
        case .standardIIR:
            return activeRenderState.leftChain.process(dry * gain)
        case .hqFIR:
            return activeRenderState.leftChain.process(activeRenderState.leftFIR.process(dry * gain))
        }
    }

    @inline(__always)
    private func processCurrentWetRight(_ dry: Float, gain: Float) -> Float {
        switch activeRenderState.renderMode {
        case .standardIIR:
            return activeRenderState.rightChain.process(dry * gain)
        case .hqFIR:
            return activeRenderState.rightChain.process(activeRenderState.rightFIR.process(dry * gain))
        }
    }

    @inline(__always)
    private func processFadingWetLeft(_ dry: Float, gain: Float, fallback: Float) -> Float {
        guard let fading = fadingRenderState else { return fallback }
        switch fading.renderMode {
        case .standardIIR:
            return fading.leftChain.process(dry * gain)
        case .hqFIR:
            return fading.leftChain.process(fading.leftFIR.process(dry * gain))
        }
    }

    @inline(__always)
    private func processFadingWetRight(_ dry: Float, gain: Float, fallback: Float) -> Float {
        guard let fading = fadingRenderState else { return fallback }
        switch fading.renderMode {
        case .standardIIR:
            return fading.rightChain.process(dry * gain)
        case .hqFIR:
            return fading.rightChain.process(fading.rightFIR.process(dry * gain))
        }
    }

    /// Safe Mode's emergency nonlinear guard. Standard mode never calls the
    /// waveshaper, so full-scale flat audio remains bit-transparent.
    @inline(__always)
    private static func applyClipProtection(_ x: Float, enabled: Bool) -> Float {
        guard enabled else { return x }
        let knee: Float = 0.99
        let ax = abs(x)
        guard ax > knee else { return x }
        let span: Float = 1.0 - knee
        let compressed = knee + span * tanhf((ax - knee) / span)
        return x < 0 ? -compressed : compressed
    }

}
