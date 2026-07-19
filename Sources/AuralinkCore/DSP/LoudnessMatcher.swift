import Foundation

/// Deterministic spectral-loudness proxy for fair A/B auditioning.
///
/// This helper still compares EQ responses rather than measuring a live audio
/// programme, so it must not be presented as an LUFS meter. Unlike a plain
/// arithmetic average of response dB, however, it follows the useful parts of
/// the BS.1770 model: the spectrum is K-weighted, converted to linear power,
/// averaged, and only then converted back to dB. Log-spaced bins model equal
/// source energy per octave and keep the result deterministic and inexpensive.
public enum LoudnessMatcher {
    public struct Match: Equatable, Sendable {
        public var preset: EQPreset
        public var adjustmentDb: Double
        /// Legacy field name; contains the candidate's response-weighted dB.
        public var candidateAverageDb: Double
        /// Legacy field name; contains the reference's response-weighted dB.
        public var referenceAverageDb: Double

        public init(
            preset: EQPreset,
            adjustmentDb: Double,
            candidateAverageDb: Double,
            referenceAverageDb: Double
        ) {
            self.preset = preset
            self.adjustmentDb = adjustmentDb
            self.candidateAverageDb = candidateAverageDb
            self.referenceAverageDb = referenceAverageDb
        }
    }

    /// K-weighted, linear-power average of an EQ response, in dB relative to a
    /// flat preset at the same sample rate.
    public static func responseWeightedDb(
        of preset: EQPreset,
        sampleRate: Double = 48_000,
        from lowHz: Double = 20,
        to highHz: Double = 20_000,
        count: Int = 192,
        renderMode: EQRenderMode = .standardIIR
    ) -> Double {
        let sr = sampleRate > 0 ? sampleRate : 48_000
        let upperLimit = max(1, sr * 0.5 * 0.98)
        let requestedLow = min(lowHz, highHz)
        let requestedHigh = max(lowHz, highHz)
        let lower = min(max(1, requestedLow), upperLimit)
        let upper = min(max(lower, requestedHigh), upperLimit)

        let frequencies = FrequencyResponse.logFrequencies(
            count: max(2, count),
            from: lower,
            to: max(lower + 1e-6, upper)
        )
        let leftCurve = FrequencyResponse.curve(
            for: preset,
            at: frequencies,
            sampleRate: sr,
            channel: .left,
            renderMode: renderMode
        )
        let rightCurve = FrequencyResponse.curve(
            for: preset,
            at: frequencies,
            sampleRate: sr,
            channel: .right,
            renderMode: renderMode
        )
        guard leftCurve.count == rightCurve.count, !leftCurve.isEmpty else {
            return preset.normalized().preampDb
        }

        let weightingFilters = makeKWeightingFilters(sampleRate: sr)
        var weightedPower = 0.0
        var weightSum = 0.0
        for index in leftCurve.indices {
            let left = leftCurve[index]
            let right = rightCurve[index]
            let weight = weightingFilters.shelf.magnitudeSquared(
                atHz: left.frequencyHz,
                sampleRate: sr
            ) * weightingFilters.highPass.magnitudeSquared(
                atHz: left.frequencyHz,
                sampleRate: sr
            )
            // BS.1770 combines channels in mean-square (linear-power) space;
            // averaging here preserves 0 dB for a flat stereo response.
            let responsePower = 0.5 * (
                pow(10.0, left.magnitudeDb / 10.0)
                + pow(10.0, right.magnitudeDb / 10.0)
            )
            weightedPower += weight * responsePower
            weightSum += weight
        }

        guard weightSum > 0, weightedPower > 0 else {
            return preset.normalized().preampDb
        }
        return 10.0 * log10(max(weightedPower / weightSum, 1e-30))
    }

    /// Source-compatible alias for callers of the original dB-average API.
    /// Its implementation now uses K-weighted linear power rather than an
    /// arithmetic mean in the logarithmic domain.
    public static func averageResponseDb(
        of preset: EQPreset,
        sampleRate: Double = 48_000,
        from lowHz: Double = 100,
        to highHz: Double = 8_000,
        count: Int = 96
    ) -> Double {
        responseWeightedDb(
            of: preset,
            sampleRate: sampleRate,
            from: lowHz,
            to: highHz,
            count: count
        )
    }

    public static func match(
        _ candidate: EQPreset,
        to reference: EQPreset,
        sampleRate: Double = 48_000,
        maxCutDb: Double = 9,
        renderMode: EQRenderMode = .standardIIR
    ) -> Match {
        let candidateAverage = responseWeightedDb(
            of: candidate,
            sampleRate: sampleRate,
            renderMode: renderMode
        )
        let referenceAverage = responseWeightedDb(
            of: reference,
            sampleRate: sampleRate,
            renderMode: renderMode
        )

        // A/B should not make either side louder than its stored preset. If the
        // candidate is quieter, leave it alone; if it is louder, cut it toward
        // the reference, bounded so a wild preset cannot vanish.
        let rawCut = min(0, referenceAverage - candidateAverage)
        let boundedCut = max(-abs(maxCutDb), rawCut)

        var matched = candidate.normalized()
        let originalPreamp = matched.preampDb
        let targetPreamp = originalPreamp + boundedCut
        let clampedPreamp = min(
            max(targetPreamp, EQPreset.preampRange.lowerBound),
            EQPreset.preampRange.upperBound
        )
        matched.preampDb = clampedPreamp

        return Match(
            preset: matched,
            adjustmentDb: clampedPreamp - originalPreamp,
            candidateAverageDb: candidateAverage,
            referenceAverageDb: referenceAverage
        )
    }

    /// Squared magnitude of the two-stage BS.1770 K-weighting response.
    /// Internal visibility keeps the standard reference points testable.
    static func kWeightingPowerGain(atHz frequencyHz: Double, sampleRate: Double) -> Double {
        let sr = sampleRate > 0 ? sampleRate : 48_000
        let frequency = min(max(0, frequencyHz), sr * 0.5)
        let filters = makeKWeightingFilters(sampleRate: sr)
        return filters.shelf.magnitudeSquared(atHz: frequency, sampleRate: sr)
            * filters.highPass.magnitudeSquared(atHz: frequency, sampleRate: sr)
    }

    /// Coefficients follow the sample-rate adaptation used by EBU R128
    /// implementations: a head-diffraction shelf followed by RLB high-pass.
    private static func makeKWeightingFilters(
        sampleRate: Double
    ) -> (shelf: WeightingBiquad, highPass: WeightingBiquad) {
        let shelfDb = 3.999843853973347
        let shelfFrequency = 1681.974450955533
        let shelfQ = 0.7071752369554196
        let shelfK = tan(.pi * shelfFrequency / sampleRate)
        let shelfK2 = shelfK * shelfK
        let highGain = pow(10.0, shelfDb / 20.0)
        let transitionGain = pow(highGain, 0.4996667741545416)
        let shelfA0 = 1.0 + shelfK / shelfQ + shelfK2
        let shelf = WeightingBiquad(
            b0: (highGain + transitionGain * shelfK / shelfQ + shelfK2) / shelfA0,
            b1: 2.0 * (shelfK2 - highGain) / shelfA0,
            b2: (highGain - transitionGain * shelfK / shelfQ + shelfK2) / shelfA0,
            a1: 2.0 * (shelfK2 - 1.0) / shelfA0,
            a2: (1.0 - shelfK / shelfQ + shelfK2) / shelfA0
        )

        let highPassFrequency = 38.13547087602444
        let highPassQ = 0.5003270373238773
        let highPassK = tan(.pi * highPassFrequency / sampleRate)
        let highPassK2 = highPassK * highPassK
        let highPassA0 = 1.0 + highPassK / highPassQ + highPassK2
        let highPass = WeightingBiquad(
            b0: 1,
            b1: -2,
            b2: 1,
            a1: 2.0 * (highPassK2 - 1.0) / highPassA0,
            a2: (1.0 - highPassK / highPassQ + highPassK2) / highPassA0
        )
        return (shelf, highPass)
    }

    private struct WeightingBiquad {
        var b0: Double
        var b1: Double
        var b2: Double
        var a1: Double
        var a2: Double

        func magnitudeSquared(atHz frequencyHz: Double, sampleRate: Double) -> Double {
            let omega = 2.0 * Double.pi * frequencyHz / sampleRate
            let numeratorReal = b0 + b1 * cos(omega) + b2 * cos(2 * omega)
            let numeratorImaginary = -b1 * sin(omega) - b2 * sin(2 * omega)
            let denominatorReal = 1.0 + a1 * cos(omega) + a2 * cos(2 * omega)
            let denominatorImaginary = -a1 * sin(omega) - a2 * sin(2 * omega)
            let numeratorPower = numeratorReal * numeratorReal
                + numeratorImaginary * numeratorImaginary
            let denominatorPower = denominatorReal * denominatorReal
                + denominatorImaginary * denominatorImaginary
            return numeratorPower / max(denominatorPower, 1e-30)
        }
    }
}
