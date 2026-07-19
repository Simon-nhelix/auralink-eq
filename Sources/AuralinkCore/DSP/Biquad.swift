import Foundation

/// A single second-order IIR (biquad) section, configured from the
/// **RBJ Audio EQ Cookbook** (Robert Bristow-Johnson). One biquad realizes one
/// EQ band; the `EQProcessor` cascades up to 20 of them per channel.
///
/// The transfer function is the canonical
/// `H(z) = (b0 + b1·z⁻¹ + b2·z⁻²) / (a0 + a1·z⁻¹ + a2·z⁻²)`.
/// Coefficients are stored pre-normalized by `a0` (so the realized `a0 == 1`)
/// and the section runs as a **Direct Form II Transposed** filter, which is the
/// numerically well-behaved choice for float audio.
///
/// `process` is real-time safe: it touches only the two state words `z1`/`z2`
/// and the cached coefficients — no allocation, no locking. It also flushes
/// numerically irrelevant tiny tails to zero so silence never leaves denormal
/// state values behind on the audio thread.
public struct Biquad {
    /// Far below any audible or meter-visible level (~-600 dBFS), but well
    /// above Float's subnormal range. Used only to zero filter tails/state.
    private static let denormalCutoff = 1e-30

    // Feed-forward / feed-back coefficients, already normalized so a0 == 1.
    private var b0: Double = 1
    private var b1: Double = 0
    private var b2: Double = 0
    private var a1: Double = 0
    private var a2: Double = 0

    // Direct Form II Transposed state (two delay elements).
    private var z1: Double = 0
    private var z2: Double = 0

    /// Builds an identity (passthrough) section.
    public init() {}

    /// Configures this section for one EQ band at a given sample rate.
    ///
    /// Becomes an exact passthrough (identity) when the band is a no-op:
    /// a gain-type filter (bell/shelf) whose gain is ≈0 dB contributes nothing
    /// to the response and is short-circuited so it adds no rounding noise.
    /// The caller is responsible for skipping disabled bands entirely; this
    /// method only guards the gain≈0 case. Frequency, gain and Q are clamped to
    /// the legal `EQBand` ranges so out-of-range AI/user input can never produce
    /// unstable coefficients.
    public mutating func configure(type: BandType, frequencyHz: Double, gainDb: Double, q: Double, sampleRate: Double) {
        // Clamp inputs into the model's legal ranges (no force-unwraps, no NaNs).
        let sr = sampleRate > 0 ? sampleRate : 48_000
        let f = clamp(frequencyHz, EQBand.frequencyRange)
        let gain = clamp(gainDb, EQBand.gainRange)
        let qv = clamp(q, EQBand.qRange)

        // Gain filters at ≈0 dB are perceptually and mathematically transparent.
        if type.usesGain && abs(gain) < 1e-4 {
            setIdentity()
            return
        }

        // Nyquist guard: a cutoff at/above Nyquist would wrap; pin just below.
        let nyquist = sr * 0.5
        let f0 = Swift.min(f, nyquist * 0.999)

        // Cookbook intermediate variables.
        let w0 = 2.0 * Double.pi * f0 / sr
        let cosW0 = cos(w0)
        let sinW0 = sin(w0)
        let alpha = sinW0 / (2.0 * qv)
        // A = sqrt(linear gain). Cookbook expresses shelf/peak gain as A = 10^(dB/40).
        let A = pow(10.0, gain / 40.0)

        // Raw, un-normalized coefficients per filter shape.
        var rb0 = 1.0, rb1 = 0.0, rb2 = 0.0
        var ra0 = 1.0, ra1 = 0.0, ra2 = 0.0

        switch type {
        case .bell:
            // Peaking EQ.
            rb0 = 1 + alpha * A
            rb1 = -2 * cosW0
            rb2 = 1 - alpha * A
            ra0 = 1 + alpha / A
            ra1 = -2 * cosW0
            ra2 = 1 - alpha / A

        case .lowShelf:
            let twoSqrtAalpha = 2 * sqrt(A) * alpha
            rb0 =      A * ((A + 1) - (A - 1) * cosW0 + twoSqrtAalpha)
            rb1 =  2 * A * ((A - 1) - (A + 1) * cosW0)
            rb2 =      A * ((A + 1) - (A - 1) * cosW0 - twoSqrtAalpha)
            ra0 =          (A + 1) + (A - 1) * cosW0 + twoSqrtAalpha
            ra1 =     -2 * ((A - 1) + (A + 1) * cosW0)
            ra2 =          (A + 1) + (A - 1) * cosW0 - twoSqrtAalpha

        case .highShelf:
            let twoSqrtAalpha = 2 * sqrt(A) * alpha
            rb0 =      A * ((A + 1) + (A - 1) * cosW0 + twoSqrtAalpha)
            rb1 = -2 * A * ((A - 1) + (A + 1) * cosW0)
            rb2 =      A * ((A + 1) + (A - 1) * cosW0 - twoSqrtAalpha)
            ra0 =          (A + 1) - (A - 1) * cosW0 + twoSqrtAalpha
            ra1 =      2 * ((A - 1) - (A + 1) * cosW0)
            ra2 =          (A + 1) - (A - 1) * cosW0 - twoSqrtAalpha

        case .lowPass:
            rb0 = (1 - cosW0) / 2
            rb1 =  1 - cosW0
            rb2 = (1 - cosW0) / 2
            ra0 =  1 + alpha
            ra1 = -2 * cosW0
            ra2 =  1 - alpha

        case .highPass:
            rb0 =  (1 + cosW0) / 2
            rb1 = -(1 + cosW0)
            rb2 =  (1 + cosW0) / 2
            ra0 =   1 + alpha
            ra1 =  -2 * cosW0
            ra2 =   1 - alpha

        case .notch:
            rb0 =  1
            rb1 = -2 * cosW0
            rb2 =  1
            ra0 =  1 + alpha
            ra1 = -2 * cosW0
            ra2 =  1 - alpha
        }

        // Normalize by a0 so the realized denominator leads with 1.0.
        guard ra0 != 0, ra0.isFinite else {
            setIdentity()
            return
        }
        b0 = rb0 / ra0
        b1 = rb1 / ra0
        b2 = rb2 / ra0
        a1 = ra1 / ra0
        a2 = ra2 / ra0

        // Defend against any non-finite result from extreme inputs.
        if !(b0.isFinite && b1.isFinite && b2.isFinite && a1.isFinite && a2.isFinite) {
            setIdentity()
        }
    }

    /// Clears the filter's delay memory (`z1`, `z2`) without changing coefficients.
    /// Call before processing a fresh, discontinuous buffer to avoid a transient.
    public mutating func reset() {
        z1 = 0
        z2 = 0
    }

    /// Copies the delay-line state from another section while keeping this
    /// section's (new) coefficients. Lets a rebuilt cascade continue from the
    /// previous cascade's state instead of restarting from silence — the reset
    /// transient is what used to click on every live band edit.
    public mutating func adoptState(from other: Biquad) {
        z1 = other.z1
        z2 = other.z2
    }

    /// Processes one sample through the section (Direct Form II Transposed).
    @inline(__always)
    public mutating func process(_ x: Float) -> Float {
        let xin = Self.flushTiny(Double(x))
        let y = Self.flushTiny(b0 * xin + z1)
        z1 = Self.flushTiny(b1 * xin - a1 * y + z2)
        z2 = Self.flushTiny(b2 * xin - a2 * y)
        return Float(y)
    }

    /// Linear (not dB) magnitude of the section's response at frequency `f`.
    ///
    /// Evaluates `|H(e^{jw})|` directly from the coefficients via the standard
    /// closed form, which is what the editor's frequency-response curve samples.
    /// An identity section returns exactly `1.0`.
    public func magnitude(atHz f: Double, sampleRate: Double) -> Double {
        let sr = sampleRate > 0 ? sampleRate : 48_000
        // Evaluate on the unit circle at w = 2πf/sr.
        let w = 2.0 * Double.pi * (f / sr)
        let cosw = cos(w)
        let cos2w = cos(2 * w)
        let sinw = sin(w)
        let sin2w = sin(2 * w)

        // Numerator   B(e^{jw}) = b0 + b1 e^{-jw} + b2 e^{-2jw}
        let numRe = b0 + b1 * cosw + b2 * cos2w
        let numIm =    -(b1 * sinw + b2 * sin2w)
        // Denominator A(e^{jw}) = 1  + a1 e^{-jw} + a2 e^{-2jw}   (a0 == 1)
        let denRe = 1 + a1 * cosw + a2 * cos2w
        let denIm =   -(a1 * sinw + a2 * sin2w)

        let numMag = (numRe * numRe + numIm * numIm).squareRoot()
        let denMag = (denRe * denRe + denIm * denIm).squareRoot()
        guard denMag > 0 else { return 1.0 }
        return numMag / denMag
    }

    // MARK: - Helpers

    /// Resets coefficients to a unity passthrough (does not touch state).
    private mutating func setIdentity() {
        b0 = 1; b1 = 0; b2 = 0
        a1 = 0; a2 = 0
    }

    @inline(__always)
    private func clamp(_ value: Double, _ range: ClosedRange<Double>) -> Double {
        guard value.isFinite else { return range.lowerBound }
        return Swift.min(Swift.max(value, range.lowerBound), range.upperBound)
    }

    @inline(__always)
    private static func flushTiny(_ value: Double) -> Double {
        abs(value) < denormalCutoff ? 0 : value
    }
}
