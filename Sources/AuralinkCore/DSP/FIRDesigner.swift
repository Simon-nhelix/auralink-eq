import Foundation

/// Render path used by `EQProcessor`.
///
/// `.standardIIR` remains the product default. `.hqFIR` is the opt-in measured
/// minimum-phase renderer; `EQProcessor` enables it only after eligibility,
/// response-fidelity, and PEQ-improvement gates pass.
public enum EQRenderMode: String, Codable, Sendable {
    case standardIIR = "standard_iir"
    case hqFIR = "hq_fir"

    public var displayName: String {
        switch self {
        case .standardIIR: return "Standard IIR"
        case .hqFIR:       return "Measured FIR"
    }
}
}

public enum FIRDesignChannel: String, Codable, Sendable {
    case left
    case right
}

public struct FIRDesign: Equatable, Sendable {
    public var taps: [Float]
    public var sampleRate: Double
    public var channel: FIRDesignChannel
    public var estimatedGroupDelayMs: Double

    public init(
        taps: [Float],
        sampleRate: Double,
        channel: FIRDesignChannel,
        estimatedGroupDelayMs: Double
    ) {
        self.taps = taps
        self.sampleRate = sampleRate
        self.channel = channel
        self.estimatedGroupDelayMs = estimatedGroupDelayMs
    }
}

public struct StereoFIRDesign: Equatable, Sendable {
    public var left: FIRDesign
    public var right: FIRDesign

    public init(left: FIRDesign, right: FIRDesign) {
        self.left = left
        self.right = right
    }

    public var maxEstimatedGroupDelayMs: Double {
        max(left.estimatedGroupDelayMs, right.estimatedGroupDelayMs)
    }
}

/// Magnitude-response limits used to compare the realtime FIR approximation
/// with the IIR cascade from which it was derived.
public struct FIRQualityGate: Equatable, Sendable {
    public var maxMagnitudeErrorDb: Double
    public var rmsMagnitudeErrorDb: Double

    public init(maxMagnitudeErrorDb: Double, rmsMagnitudeErrorDb: Double) {
        self.maxMagnitudeErrorDb = max(0, maxMagnitudeErrorDb)
        self.rmsMagnitudeErrorDb = max(0, rmsMagnitudeErrorDb)
    }

    /// Reference-fidelity target for ordinary, broad headphone correction.
    public static let generalCorrection = FIRQualityGate(
        maxMagnitudeErrorDb: 0.5,
        rmsMagnitudeErrorDb: 0.15
    )
}

/// Known ways a fixed, short impulse can run out of temporal support.
public enum FIRQualityLimitation: String, Codable, CaseIterable, Sendable {
    case fixedTapBudgetAtHighSampleRate = "fixed_tap_budget_at_high_sample_rate"
    case lowFrequencyTemporalSupport = "low_frequency_temporal_support"
    case highQDecayTruncation = "high_q_decay_truncation"
    case denseCascadeTailTruncation = "dense_cascade_tail_truncation"
}

public enum FIRQualityClassification: String, Codable, Sendable {
    /// The approximation satisfies the requested IIR-reference gate.
    case meetsReferenceGate = "meets_reference_gate"
    /// The gate is missed in a configuration known to exceed the 512-tap
    /// prototype's temporal budget. This remains a measured failure, not a pass.
    case expectedPrototypeLimitation = "expected_prototype_limitation"
    /// The gate is missed without one of the prototype limitations below.
    case unexpectedReferenceMismatch = "unexpected_reference_mismatch"
}

/// Dense-grid comparison of one FIR design with its source IIR cascade.
public struct FIRQualityEvaluation: Equatable, Sendable {
    public var sampleRate: Double
    public var tapCount: Int
    public var frequencyCount: Int
    public var maxMagnitudeErrorDb: Double
    public var rmsMagnitudeErrorDb: Double
    public var maxErrorFrequencyHz: Double
    public var estimatedGroupDelayMs: Double
    public var impulseSpanMs: Double
    public var gate: FIRQualityGate
    public var classification: FIRQualityClassification
    public var limitations: [FIRQualityLimitation]

    public var meetsReferenceGate: Bool {
        classification == .meetsReferenceGate
    }
}

/// Shipping verdict deliberately separates reference accuracy from evidence of
/// an audible/product benefit. A truncated copy of the IIR impulse can match its
/// source without establishing that it improves on that source.
public enum FIRProductionVerdict: String, Codable, Sendable {
    case ready = "ready"
    case keepExperimentalReferenceAccuracy = "keep_experimental_reference_accuracy"
    case keepExperimentalNoIndependentBenefit = "keep_experimental_no_independent_benefit"
}

public struct FIRProductionAssessment: Equatable, Sendable {
    public var verdict: FIRProductionVerdict
    public var requiredEvaluationCount: Int
    public var failedEvaluationCount: Int
    public var independentBenefitDemonstrated: Bool

    public var productionReady: Bool { verdict == .ready }
}

/// Legacy IIR-impulse approximation utilities retained as quality fixtures.
///
/// This deliberately truncated the existing biquad cascade and established why
/// a fixed 512-tap copy was not a shippable renderer. Production `.hqFIR` uses
/// `MeasuredFIRDesigner` with independent dense measurement data instead.
public enum FIRDesigner {
    public static let defaultLength = 512
    public static let realtimePreviewLength = 512
    public static let lengthRange = 32...4096

    /// Historical fixed-tap test budget. It intentionally demonstrates the
    /// high-rate/low-frequency failure of the retired IIR-copy prototype and is
    /// not consulted by the production measured renderer.
    public static func realtimePreviewLength(for sampleRate: Double) -> Int {
        realtimePreviewLength
    }

    public static func stereoMinimumPhaseApproximation(
        for preset: EQPreset,
        sampleRate: Double,
        length requestedLength: Int = defaultLength
    ) -> StereoFIRDesign {
        StereoFIRDesign(
            left: minimumPhaseApproximation(
                for: preset,
                sampleRate: sampleRate,
                length: requestedLength,
                channel: .left
            ),
            right: minimumPhaseApproximation(
                for: preset,
                sampleRate: sampleRate,
                length: requestedLength,
                channel: .right
            )
        )
    }

    public static func minimumPhaseApproximation(
        for preset: EQPreset,
        sampleRate: Double,
        length requestedLength: Int = defaultLength,
        channel: FIRDesignChannel = .left
    ) -> FIRDesign {
        let sr = sampleRate > 0 ? sampleRate : 48_000
        let length = min(max(requestedLength, lengthRange.lowerBound), lengthRange.upperBound)
        let sections = biquads(for: preset.normalized(), sampleRate: sr, channel: channel)
        guard !sections.isEmpty else {
            return FIRDesign(
                taps: [1],
                sampleRate: sr,
                channel: channel,
                estimatedGroupDelayMs: 0
            )
        }

        var filters = sections
        var taps = [Float](repeating: 0, count: length)
        for n in 0..<length {
            var sample: Float = n == 0 ? 1 : 0
            for i in filters.indices {
                sample = filters[i].process(sample)
            }
            taps[n] = sample.isFinite ? sample : 0
        }
        taperTail(&taps)
        trimTrailingNearZero(&taps)
        constrainExcessPeak(&taps, referenceSections: sections, sampleRate: sr)

        return FIRDesign(
            taps: taps,
            sampleRate: sr,
            channel: channel,
            estimatedGroupDelayMs: energyCentroidMs(taps: taps, sampleRate: sr)
        )
    }

    public static func magnitudeDb(of taps: [Float], atHz frequencyHz: Double, sampleRate: Double) -> Double {
        let sr = sampleRate > 0 ? sampleRate : 48_000
        guard !taps.isEmpty else { return 0 }
        let clampedFrequency = min(max(frequencyHz, 0), sr * 0.5)
        let omega = 2.0 * Double.pi * clampedFrequency / sr
        var real = 0.0
        var imag = 0.0
        for (n, tap) in taps.enumerated() {
            let phase = omega * Double(n)
            real += Double(tap) * cos(phase)
            imag -= Double(tap) * sin(phase)
        }
        let magnitude = sqrt(real * real + imag * imag)
        return 20.0 * log10(max(magnitude, 1e-9))
    }

    public static func responseCurve(of taps: [Float], at frequencies: [Double], sampleRate: Double) -> [ResponsePoint] {
        frequencies.map {
            ResponsePoint(
                frequencyHz: $0,
                magnitudeDb: magnitudeDb(of: taps, atHz: $0, sampleRate: sampleRate)
            )
        }
    }

    /// Compares a design against the channel-specific IIR magnitude response on
    /// a dense logarithmic grid. Preamp is intentionally excluded from both
    /// paths because it is applied outside the FIR/IIR filter implementation.
    public static func evaluateQuality(
        of design: FIRDesign,
        against preset: EQPreset,
        frequencyCount: Int = 2048,
        gate: FIRQualityGate = .generalCorrection
    ) -> FIRQualityEvaluation {
        let sr = design.sampleRate > 0 ? design.sampleRate : 48_000
        let upperFrequency = min(20_000, sr * 0.45)
        let frequencies = FrequencyResponse.logFrequencies(
            count: max(2, frequencyCount),
            from: 20,
            to: upperFrequency
        )
        let responseChannel: BandChannel = design.channel == .left ? .left : .right
        var squaredError = 0.0
        var maximumError = -Double.infinity
        var maximumErrorFrequency = frequencies[0]

        for frequency in frequencies {
            let referenceDb = FrequencyResponse.magnitudeDb(
                of: preset,
                atHz: frequency,
                sampleRate: sr,
                channel: responseChannel
            )
            let firDb = magnitudeDb(of: design.taps, atHz: frequency, sampleRate: sr)
            let error = abs(firDb - referenceDb)
            squaredError += error * error
            if error > maximumError {
                maximumError = error
                maximumErrorFrequency = frequency
            }
        }

        let rmsError = sqrt(squaredError / Double(frequencies.count))
        let meetsGate = maximumError <= gate.maxMagnitudeErrorDb
            && rmsError <= gate.rmsMagnitudeErrorDb
        let limitations = qualityLimitations(
            for: preset,
            design: design,
            sampleRate: sr
        )
        let classification: FIRQualityClassification
        if meetsGate {
            classification = .meetsReferenceGate
        } else if !limitations.isEmpty {
            classification = .expectedPrototypeLimitation
        } else {
            classification = .unexpectedReferenceMismatch
        }

        return FIRQualityEvaluation(
            sampleRate: sr,
            tapCount: design.taps.count,
            frequencyCount: frequencies.count,
            maxMagnitudeErrorDb: maximumError,
            rmsMagnitudeErrorDb: rmsError,
            maxErrorFrequencyHz: maximumErrorFrequency,
            estimatedGroupDelayMs: design.estimatedGroupDelayMs,
            impulseSpanMs: Double(design.taps.count) / sr * 1_000,
            gate: gate,
            classification: classification,
            limitations: limitations
        )
    }

    /// Aggregates required quality cases into a ship/no-ship decision. The
    /// caller must separately supply evidence that FIR improves a user-visible
    /// outcome (controlled listening, target accuracy, latency/CPU, and so on).
    public static func productionAssessment(
        required evaluations: [FIRQualityEvaluation],
        independentBenefitDemonstrated: Bool = false
    ) -> FIRProductionAssessment {
        let failureCount = evaluations.filter { !$0.meetsReferenceGate }.count
        let verdict: FIRProductionVerdict
        if failureCount > 0 || evaluations.isEmpty {
            verdict = .keepExperimentalReferenceAccuracy
        } else if !independentBenefitDemonstrated {
            verdict = .keepExperimentalNoIndependentBenefit
        } else {
            verdict = .ready
        }
        return FIRProductionAssessment(
            verdict: verdict,
            requiredEvaluationCount: evaluations.count,
            failedEvaluationCount: failureCount,
            independentBenefitDemonstrated: independentBenefitDemonstrated
        )
    }

    private static func biquads(for preset: EQPreset, sampleRate: Double, channel: FIRDesignChannel) -> [Biquad] {
        var sections: [Biquad] = []
        for band in preset.bands where band.enabled && includes(band.channel, in: channel) {
            if band.type.usesGain && abs(band.gainDb) < 1e-4 { continue }
            var biquad = Biquad()
            biquad.configure(
                type: band.type,
                frequencyHz: band.frequencyHz,
                gainDb: band.gainDb,
                q: band.q,
                sampleRate: sampleRate
            )
            sections.append(biquad)
        }
        return sections
    }

    private static func includes(_ bandChannel: BandChannel, in designChannel: FIRDesignChannel) -> Bool {
        switch (bandChannel, designChannel) {
        case (.stereo, _), (.left, .left), (.right, .right):
            return true
        case (.left, .right), (.right, .left):
            return false
        }
    }

    private static func qualityLimitations(
        for preset: EQPreset,
        design: FIRDesign,
        sampleRate: Double
    ) -> [FIRQualityLimitation] {
        guard design.taps.count <= realtimePreviewLength else { return [] }
        let responseChannel: BandChannel = design.channel == .left ? .left : .right
        let active = preset.normalized().bands.filter {
            $0.enabled
                && includes($0.channel, in: responseChannel)
                && (!$0.type.usesGain || abs($0.gainDb) >= 1e-4)
        }
        var limitations: [FIRQualityLimitation] = []

        if sampleRate >= 96_000 {
            limitations.append(.fixedTapBudgetAtHighSampleRate)
        }
        let approximateResolutionHz = sampleRate / Double(max(1, design.taps.count))
        if active.contains(where: { $0.frequencyHz < approximateResolutionHz * 2 }) {
            limitations.append(.lowFrequencyTemporalSupport)
        }
        if active.contains(where: { $0.q >= 4 }) {
            limitations.append(.highQDecayTruncation)
        }
        if active.count >= 12 {
            limitations.append(.denseCascadeTailTruncation)
        }
        return limitations
    }

    private static func includes(_ bandChannel: BandChannel, in responseChannel: BandChannel) -> Bool {
        switch responseChannel {
        case .left:
            return bandChannel == .stereo || bandChannel == .left
        case .right:
            return bandChannel == .stereo || bandChannel == .right
        case .stereo:
            return true
        }
    }

    private static func taperTail(_ taps: inout [Float]) {
        guard taps.count > 8 else { return }
        let start = max(1, Int(Double(taps.count) * 0.75))
        let count = taps.count - start
        guard count > 1 else { return }
        for i in start..<taps.count {
            let t = Double(i - start) / Double(count - 1)
            let fade = 0.5 * (1.0 + cos(Double.pi * t))
            taps[i] *= Float(fade)
        }
    }

    private static func trimTrailingNearZero(_ taps: inout [Float]) {
        while taps.count > 1, abs(taps.last ?? 0) < 1e-8 {
            taps.removeLast()
        }
    }

    private static func energyCentroidMs(taps: [Float], sampleRate: Double) -> Double {
        let energy = taps.map { Double($0 * $0) }
        let total = energy.reduce(0, +)
        guard total > 0 else { return 0 }
        let centroidSamples = energy.enumerated().reduce(0.0) { sum, item in
            sum + Double(item.offset) * item.element
        } / total
        return centroidSamples / sampleRate * 1_000.0
    }

    private static func constrainExcessPeak(
        _ taps: inout [Float],
        referenceSections: [Biquad],
        sampleRate: Double
    ) {
        guard !taps.isEmpty, !referenceSections.isEmpty else { return }
        let frequencies = logFrequencies(count: 96, from: 20, to: min(20_000, sampleRate * 0.45))
        let firPeak = frequencies
            .map { magnitudeDb(of: taps, atHz: $0, sampleRate: sampleRate) }
            .max() ?? 0
        let referencePeak = frequencies
            .map { referenceMagnitudeDb(of: referenceSections, atHz: $0, sampleRate: sampleRate) }
            .max() ?? 0
        let allowedPeak = max(referencePeak + 3.0, 12.0)
        guard firPeak > allowedPeak else { return }

        let gain = Float(pow(10.0, (allowedPeak - firPeak) / 20.0))
        for i in taps.indices {
            taps[i] *= gain
        }
    }

    private static func referenceMagnitudeDb(of sections: [Biquad], atHz frequency: Double, sampleRate: Double) -> Double {
        sections.reduce(0.0) { total, biquad in
            total + 20.0 * log10(max(biquad.magnitude(atHz: frequency, sampleRate: sampleRate), 1e-9))
        }
    }

    private static func logFrequencies(count: Int, from: Double, to: Double) -> [Double] {
        let n = max(2, count)
        let lo = max(1e-6, min(from, to))
        let hi = max(lo + 1e-6, max(from, to))
        let logLo = log10(lo)
        let logHi = log10(hi)
        let step = (logHi - logLo) / Double(n - 1)
        return (0..<n).map { i in pow(10.0, logLo + step * Double(i)) }
    }
}

/// Cache retained for legacy IIR-approximation quality fixtures only.
///
/// The key intentionally fingerprints the normalized band topology, not the
/// preset id, so transient AI proposals and saved copies can share an impulse
/// when their audible filter parameters are identical.
public final class FIRDesignCache {
    private struct Key: Hashable {
        var sampleRateHz: Int
        var length: Int
        var fingerprint: String
    }

    private let maxEntries: Int
    private var storage: [Key: StereoFIRDesign] = [:]
    private var order: [Key] = []

    public init(maxEntries: Int = 8) {
        self.maxEntries = max(1, maxEntries)
    }

    public func design(
        for preset: EQPreset,
        sampleRate: Double,
        length: Int = FIRDesigner.realtimePreviewLength
    ) -> StereoFIRDesign {
        let normalized = preset.normalized()
        let key = Key(
            sampleRateHz: Int((sampleRate > 0 ? sampleRate : 48_000).rounded()),
            length: min(max(length, FIRDesigner.lengthRange.lowerBound), FIRDesigner.lengthRange.upperBound),
            fingerprint: Self.fingerprint(normalized)
        )
        if let cached = storage[key] {
            touch(key)
            return cached
        }
        let design = FIRDesigner.stereoMinimumPhaseApproximation(
            for: normalized,
            sampleRate: sampleRate,
            length: key.length
        )
        storage[key] = design
        order.append(key)
        evictIfNeeded()
        return design
    }

    public func removeAll() {
        storage.removeAll()
        order.removeAll()
    }

    private func touch(_ key: Key) {
        order.removeAll { $0 == key }
        order.append(key)
    }

    private func evictIfNeeded() {
        while storage.count > maxEntries, let oldest = order.first {
            order.removeFirst()
            storage.removeValue(forKey: oldest)
        }
    }

    private static func fingerprint(_ preset: EQPreset) -> String {
        preset.bands
            .filter { $0.enabled }
            .map {
                [
                    "\($0.index)",
                    $0.type.rawValue,
                    String(format: "%.3f", $0.frequencyHz),
                    String(format: "%.3f", $0.gainDb),
                    String(format: "%.3f", $0.q),
                    $0.channel.rawValue,
                ].joined(separator: ":")
            }
            .joined(separator: "|")
    }
}
