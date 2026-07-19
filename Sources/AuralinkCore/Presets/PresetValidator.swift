import Foundation

/// Checks a preset against `SafetyRules` and estimates its clipping risk.
///
/// The validator is the gatekeeper for both the in-app editor and the MCP
/// `validate_eq_preset` / `create_eq_preset` flows. It never *mutates* a
/// preset; it reports issues and a suggested preamp so the caller can decide.
///
/// Peak gain is estimated from the actual magnitude response (so overlapping
/// boosts sum correctly) sampled **without** the preamp, and the preamp's effect
/// is then applied analytically when classifying clipping risk and computing the
/// suggested auto-preamp.
public final class PresetValidator {
    public let rules: SafetyRules

    /// Number of log-spaced points used to sample the response curve. Dense
    /// enough to catch narrow peaks without being expensive.
    private let sampleCount: Int
    /// Sample rate used purely for the magnitude estimate (filter shapes are
    /// effectively rate-independent in the audible band; 48 kHz is the common
    /// system rate).
    private let estimationSampleRate: Double

    public init(rules: SafetyRules, sampleCount: Int = 256, estimationSampleRate: Double = 48_000) {
        self.rules = rules
        self.sampleCount = max(2, sampleCount)
        self.estimationSampleRate = estimationSampleRate
    }

    // MARK: - Validation

    /// Runs every safety check and returns a structured result.
    ///
    /// Issues:
    /// - **error** — any band's gain or Q/slope falls outside the rules' legal range.
    /// - **warning** — a single boosting band exceeds `maxBoostDb`.
    /// - **warning** — the response peak (overlapping boosts) exceeds
    ///   `maxAggregateBoostDb`.
    /// - **warning** — high-Q treble boosts and low-bass boosts that are likely
    ///   to sound sharp or consume headroom.
    /// - **warning** — medium/high clipping risk after the current preamp.
    ///
    /// `ok` is true iff there are no `.error` issues.
    public func validate(_ preset: EQPreset) -> ValidationResult {
        let normalized = preset.normalized()
        var issues: [ValidationIssue] = []

        if let payload = normalized.correction?.measuredCorrection,
           normalized.correction?.sourceConfidence != .measured || !payload.isFIREligible {
            issues.append(ValidationIssue(
                severity: .error,
                message: "Measured correction metadata is invalid or its canonical content hash does not match.",
                bandIndex: nil
            ))
        }

        // 1) Per-band range + single-band boost checks (active bands only).
        for band in normalized.bands where band.enabled {
            if band.q < rules.qMin || band.q > rules.qMax {
                issues.append(ValidationIssue(
                    severity: .error,
                    message: "Band \(band.index) \(band.type.qDisplayName) \(Self.fmt(band.q)) is outside the allowed range \(Self.fmt(rules.qMin))–\(Self.fmt(rules.qMax)).",
                    bandIndex: band.index
                ))
            }

            // Gain only matters for filter shapes that actually use it.
            guard band.type.usesGain else { continue }

            if band.gainDb < rules.gainMinDb || band.gainDb > rules.gainMaxDb {
                issues.append(ValidationIssue(
                    severity: .error,
                    message: "Band \(band.index) gain \(Self.fmt(band.gainDb)) dB is outside the allowed range \(Self.fmt(rules.gainMinDb))–\(Self.fmt(rules.gainMaxDb)) dB.",
                    bandIndex: band.index
                ))
            } else if band.gainDb > rules.maxBoostDb {
                issues.append(ValidationIssue(
                    severity: .warning,
                    message: "Band \(band.index) boosts \(Self.fmt(band.gainDb)) dB, above the \(Self.fmt(rules.maxBoostDb)) dB single-band limit.",
                    bandIndex: band.index
                ))
            }

            if band.gainDb > 3, band.frequencyHz < 80 {
                issues.append(ValidationIssue(
                    severity: .warning,
                    message: "Band \(band.index) adds \(Self.fmt(band.gainDb)) dB below 80 Hz, which can spend headroom quickly on bass-heavy material.",
                    bandIndex: band.index
                ))
            }

            if band.gainDb > 2, band.frequencyHz >= 5_000, band.q >= 4 {
                issues.append(ValidationIssue(
                    severity: .warning,
                    message: "Band \(band.index) is a narrow boosted treble band (\(band.type.qDisplayName) \(Self.fmt(band.q))), which can sound sharp or highlight artifacts.",
                    bandIndex: band.index
                ))
            }
        }

        // 2) Aggregate / peak boost — measured from the louder actual output
        //    channel. Left- and right-only bands must never be summed together.
        let peakDb = estimatedPeakGainDb(of: normalized)
        if peakDb > rules.maxAggregateBoostDb {
            issues.append(ValidationIssue(
                severity: .warning,
                message: "Combined boost peaks at \(Self.fmt(peakDb)) dB, above the \(Self.fmt(rules.maxAggregateBoostDb)) dB aggregate limit. Lower overlapping bands or accept more preamp.",
                bandIndex: nil
            ))
        }

        // 3) Clipping risk uses the *applied* preamp on the preset, while the
        //    suggested preamp shows what would bring it under headroom.
        let suggestedPreamp = autoPreamp(for: normalized)
        let risk = clippingRisk(peakDb: peakDb, preampDb: normalized.preampDb)
        let postPeak = peakDb + normalized.preampDb
        switch risk {
        case .high:
            issues.append(ValidationIssue(
                severity: .warning,
                message: "Estimated peak reaches \(Self.fmt(postPeak)) dBFS after preamp and may clip. Lower preamp toward \(Self.fmt(suggestedPreamp)) dB or reduce boosts.",
                bandIndex: nil
            ))
        case .medium:
            issues.append(ValidationIssue(
                severity: .warning,
                message: "Estimated peak reaches \(Self.fmt(postPeak)) dBFS after preamp, leaving less than \(Self.fmt(rules.targetHeadroomDb)) dB headroom.",
                bandIndex: nil
            ))
        case .low:
            break
        }

        let ok = !issues.contains { $0.severity == .error }
        return ValidationResult(
            ok: ok,
            clippingRisk: risk,
            estimatedPeakGainDb: peakDb,
            suggestedPreampDb: suggestedPreamp,
            issues: issues
        )
    }

    // MARK: - Auto preamp

    /// The preamp (≤ 0 dB, rounded to the nearest 0.5 dB) that offsets the peak
    /// boost so the post-preamp peak sits at `targetHeadroomDb` below 0 dBFS.
    ///
    /// A preset with no net boost (peak ≤ 0 dB, e.g. flat or all-cut) is already
    /// quieter than unity, so it needs no attenuation and the result is 0. Only
    /// when the response actually adds gain do we pull it back below headroom.
    public func autoPreamp(for preset: EQPreset) -> Double {
        // `peakDb` is the boost above unity (clamped to ≥ 0 in the estimator).
        let peakDb = estimatedPeakGainDb(of: preset)
        guard peakDb > 0 else { return 0 }

        // Bring the boosted peak down to -targetHeadroom:
        //   peakDb + preamp ≤ -targetHeadroom  →  preamp ≤ -(peakDb + targetHeadroom).
        let needed = -(peakDb + rules.targetHeadroomDb)
        // Only ever attenuate; never propose a positive (boosting) preamp.
        let clamped = min(0, needed)
        // Round *down* to the next 0.5 dB so we never under-shoot the headroom.
        let rounded = (clamped * 2).rounded(.down) / 2
        // Keep within the preset's legal preamp range.
        return max(EQPreset.preampRange.lowerBound, min(EQPreset.preampRange.upperBound, rounded))
    }

    // MARK: - Estimation internals

    /// Worst-case magnitude (dB) across both output channels and every renderer
    /// the preset can use. This keeps one saved preamp safe when the user A/Bs
    /// standard PEQ against Measured FIR.
    private func estimatedPeakGainDb(of preset: EQPreset) -> Double {
        let standard = estimatedPeakGainDb(of: preset, renderMode: .standardIIR)
        guard preset.correction?.sourceConfidence == .measured,
              preset.correction?.measuredCorrection?.isFIREligible == true else { return standard }
        return max(standard, estimatedPeakGainDb(of: preset, renderMode: .hqFIR))
    }

    private func estimatedPeakGainDb(of preset: EQPreset, renderMode: EQRenderMode) -> Double {
        var noPreamp = preset
        noPreamp.preampDb = 0
        let frequencies = FrequencyResponse.logFrequencies(count: sampleCount)
        let leftCurve = FrequencyResponse.curve(
            for: noPreamp,
            at: frequencies,
            sampleRate: estimationSampleRate,
            channel: .left,
            renderMode: renderMode
        )
        let rightCurve = FrequencyResponse.curve(
            for: noPreamp,
            at: frequencies,
            sampleRate: estimationSampleRate,
            channel: .right,
            renderMode: renderMode
        )
        return max(0, leftCurve.peakDb, rightCurve.peakDb)
    }

    /// Classifies risk from the post-preamp peak per the build spec thresholds:
    /// `peak + preamp ≤ -targetHeadroom` → low; `≤ +1` → medium; else high.
    private func clippingRisk(peakDb: Double, preampDb: Double) -> ClippingRisk {
        let postPeak = peakDb + preampDb
        if postPeak <= -rules.targetHeadroomDb {
            return .low
        } else if postPeak <= 1.0 {
            return .medium
        } else {
            return .high
        }
    }

    /// Compact number formatting for issue messages (trims trailing zeros).
    private static func fmt(_ value: Double) -> String {
        if value == value.rounded() {
            return String(Int(value))
        }
        return String(format: "%.1f", value)
    }
}
