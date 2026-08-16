import Foundation

/// Pure, stateless frequency-response math for a preset.
///
/// This is what the editor graph plots and what `PresetValidator` samples to
/// estimate the peak boost (and therefore clipping risk). It computes the same
/// biquad magnitudes as the realtime `EQProcessor`, but offline. Callers that
/// need an actual output-channel response use the channel-aware overloads;
/// stereo bands apply to both channels and left/right bands only to their routed
/// channel.
///
/// The original channel-less APIs remain a folded response that includes every
/// enabled band. That preserves the editor/API contract for existing callers.
/// Safety calculations should use `.left` and `.right` independently so bands
/// routed to opposite channels are never incorrectly summed together.
public enum FrequencyResponse {
    /// Log-spaced frequency axis (default 20 Hz … 20 kHz) for the graph.
    /// `count` is clamped to ≥2 so the endpoints are always present.
    public static func logFrequencies(count: Int, from: Double = 20, to: Double = 20_000) -> [Double] {
        let n = Swift.max(2, count)
        let lo = Swift.max(1e-6, Swift.min(from, to))
        let hi = Swift.max(lo + 1e-6, Swift.max(from, to))
        let logLo = log10(lo)
        let logHi = log10(hi)
        let step = (logHi - logLo) / Double(n - 1)
        return (0..<n).map { i in pow(10.0, logLo + step * Double(i)) }
    }

    /// Total EQ magnitude (in dB) at one frequency, **excluding** the preamp.
    ///
    /// Sums the dB contribution of every enabled, non-identity band. Disabled
    /// bands and gain-type bands at ≈0 dB contribute exactly 0 dB (identity).
    public static func magnitudeDb(of preset: EQPreset, atHz f: Double, sampleRate: Double) -> Double {
        magnitudeDb(of: preset, atHz: f, sampleRate: sampleRate, channel: .stereo)
    }

    /// EQ magnitude (in dB) at one frequency for an output channel, excluding
    /// the preamp.
    ///
    /// - `.left` includes stereo and left-only bands.
    /// - `.right` includes stereo and right-only bands.
    /// - `.stereo` preserves the legacy folded response and includes all bands.
    public static func magnitudeDb(
        of preset: EQPreset,
        atHz f: Double,
        sampleRate: Double,
        channel: BandChannel
    ) -> Double {
        let sr = sampleRate > 0 ? sampleRate : 48_000
        let p = preset.normalized()
        return magnitudeDb(ofNormalized: p, atHz: f, sampleRate: sr, channel: channel)
    }

    /// Render-aware response, excluding preamp. Measured FIR uses the persisted
    /// dense baseline and only the explicitly marked preference bands.
    public static func magnitudeDb(
        of preset: EQPreset,
        atHz f: Double,
        sampleRate: Double,
        channel: BandChannel,
        renderMode: EQRenderMode
    ) -> Double {
        let sr = sampleRate > 0 ? sampleRate : 48_000
        let normalized = preset.normalized()
        guard renderMode == .hqFIR,
              let correction = normalized.correction,
              correction.sourceConfidence == .measured,
              let payload = correction.measuredCorrection?.normalized(),
              payload.isFIREligible else {
            return magnitudeDb(ofNormalized: normalized, atHz: f, sampleRate: sr, channel: channel)
        }
        let measured = MeasuredFIRDesigner.targetMagnitudeDb(
            of: payload,
            atHz: f,
            sampleRate: sr,
            strength: correction.correctionStrength
        )
        let preferenceIndexes = Set(correction.preferenceBandIndexes)
        let preference = magnitudeDb(
            ofNormalized: normalized,
            atHz: f,
            sampleRate: sr,
            channel: channel,
            includedBandIndexes: preferenceIndexes
        )
        return measured + preference
    }

    private static func magnitudeDb(
        ofNormalized preset: EQPreset,
        atHz f: Double,
        sampleRate: Double,
        channel: BandChannel,
        includedBandIndexes: Set<Int>? = nil
    ) -> Double {
        var totalDb = 0.0

        for band in preset.bands where band.enabled && applies(band.channel, to: channel) {
            if let includedBandIndexes, !includedBandIndexes.contains(band.index) { continue }
            // Identity short-circuit mirrors the processor exactly.
            if band.type.usesGain && abs(band.gainDb) < 1e-4 { continue }

            var biquad = Biquad()
            biquad.configure(
                type: band.type,
                frequencyHz: band.frequencyHz,
                gainDb: band.gainDb,
                q: band.q,
                sampleRate: sampleRate
            )
            let linear = biquad.magnitude(atHz: f, sampleRate: sampleRate)
            // Guard against log of zero (an ideal notch can reach 0 at center).
            totalDb += 20.0 * log10(Swift.max(linear, 1e-9))
        }
        return totalDb
    }

    private static func applies(_ bandChannel: BandChannel, to responseChannel: BandChannel) -> Bool {
        switch responseChannel {
        case .left:
            return bandChannel == .stereo || bandChannel == .left
        case .right:
            return bandChannel == .stereo || bandChannel == .right
        case .stereo:
            return true
        }
    }

    /// Full response curve for the graph: one `ResponsePoint` per frequency,
    /// with the preset's `preampDb` added as a flat offset to every point so the
    /// drawn curve matches what the listener actually hears after the preamp.
    public static func curve(for preset: EQPreset, at frequencies: [Double], sampleRate: Double) -> [ResponsePoint] {
        curve(for: preset, at: frequencies, sampleRate: sampleRate, channel: .stereo)
    }

    /// Full response curve for one output channel. See the channel semantics on
    /// `magnitudeDb(of:atHz:sampleRate:channel:)`.
    public static func curve(
        for preset: EQPreset,
        at frequencies: [Double],
        sampleRate: Double,
        channel: BandChannel
    ) -> [ResponsePoint] {
        curve(
            for: preset,
            at: frequencies,
            sampleRate: sampleRate,
            channel: channel,
            renderMode: .standardIIR
        )
    }

    public static func curve(
        for preset: EQPreset,
        at frequencies: [Double],
        sampleRate: Double,
        channel: BandChannel = .stereo,
        renderMode: EQRenderMode
    ) -> [ResponsePoint] {
        let sr = sampleRate > 0 ? sampleRate : 48_000
        let normalized = preset.normalized()
        guard renderMode == .hqFIR,
              let correction = normalized.correction,
              correction.sourceConfidence == .measured,
              let payload = correction.measuredCorrection?.normalized(),
              payload.isFIREligible else {
            return frequencies.map { frequency in
                ResponsePoint(
                    frequencyHz: frequency,
                    magnitudeDb: magnitudeDb(
                        ofNormalized: normalized,
                        atHz: frequency,
                        sampleRate: sr,
                        channel: channel
                    ) + normalized.preampDb
                )
            }
        }
        let preferenceIndexes = Set(correction.preferenceBandIndexes)
        let strength = correction.correctionStrength
        return frequencies.map { frequency in
            let measured = MeasuredFIRDesigner.targetMagnitudeDbUnchecked(
                of: payload,
                atHz: frequency,
                sampleRate: sr,
                strength: strength
            )
            let preference = magnitudeDb(
                ofNormalized: normalized,
                atHz: frequency,
                sampleRate: sr,
                channel: channel,
                includedBandIndexes: preferenceIndexes
            )
            return ResponsePoint(frequencyHz: frequency, magnitudeDb: measured + preference + normalized.preampDb)
        }
    }
}
