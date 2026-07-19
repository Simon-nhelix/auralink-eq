import Accelerate
import Foundation

/// Objective fit evidence for one sample-rate-specific measured FIR design.
public struct MeasuredFIRQualitySummary: Equatable, Sendable {
    public var sampleRate: Double
    public var tapCount: Int
    public var supportMs: Double
    public var maxErrorDb: Double
    public var rmsErrorDb: Double
    public var peqRmsErrorDb: Double
    public var absoluteRmsImprovementDb: Double
    public var relativeRmsImprovement: Double
    public var eligible: Bool
    public var rejectionReason: String?

    public init(
        sampleRate: Double,
        tapCount: Int,
        supportMs: Double,
        maxErrorDb: Double,
        rmsErrorDb: Double,
        peqRmsErrorDb: Double,
        absoluteRmsImprovementDb: Double,
        relativeRmsImprovement: Double,
        eligible: Bool,
        rejectionReason: String?
    ) {
        self.sampleRate = sampleRate
        self.tapCount = tapCount
        self.supportMs = supportMs
        self.maxErrorDb = maxErrorDb
        self.rmsErrorDb = rmsErrorDb
        self.peqRmsErrorDb = peqRmsErrorDb
        self.absoluteRmsImprovementDb = absoluteRmsImprovementDb
        self.relativeRmsImprovement = relativeRmsImprovement
        self.eligible = eligible
        self.rejectionReason = rejectionReason
    }
}

public struct MeasuredStereoFIRResult: Equatable, Sendable {
    public var design: StereoFIRDesign
    public var quality: MeasuredFIRQualitySummary

    public init(design: StereoFIRDesign, quality: MeasuredFIRQualitySummary) {
        self.design = design
        self.quality = quality
    }
}

/// Minimum-phase FIR synthesis from a persisted measured correction curve.
///
/// This path is deliberately independent from the preset's PEQ approximation:
/// its product value is lower residual error to the measured curve, not an
/// unsupported claim that FIR is inherently better than IIR.
public enum MeasuredFIRDesigner {
    public static let policyVersion = 1
    public static let primaryFrequencyRange = 40.0...10_000.0
    public static let maximumImplementationErrorDb = 0.30
    public static let maximumRMSErrorDb = 0.08
    public static let minimumAbsoluteImprovementDb = 0.25
    public static let minimumRelativeImprovement = 0.20
    public static let evaluationPointCount = 512

    /// Candidate temporal supports. The shortest design meeting every absolute
    /// and PEQ-superiority gate wins; taps are rounded to whole FFT partitions.
    private static let candidateSupportMs = [21.333, 42.667, 85.333]

    public static func partitionSize(for sampleRate: Double) -> Int {
        let sr = sampleRate > 0 ? sampleRate : 48_000
        if sr >= 176_400 { return 512 }
        if sr >= 88_200 { return 256 }
        return 128
    }

    /// The regularized measured baseline response, excluding global preamp.
    /// AutoEq's magnitude above 10 kHz is placement-sensitive, so version 1
    /// corrects through `usableHighHz` and returns smoothly to unity by 1.6×.
    public static func targetMagnitudeDb(
        of payload: MeasuredCorrectionPayload,
        atHz frequencyHz: Double,
        sampleRate: Double,
        strength: Double
    ) -> Double {
        let normalized = payload.normalized()
        guard normalized.isFIREligible else { return 0 }
        return targetMagnitudeDbUnchecked(
            of: normalized,
            atHz: frequencyHz,
            sampleRate: sampleRate,
            strength: strength
        )
    }

    /// Caller has already verified the immutable payload once. Synthesis calls
    /// this for every FFT bin, so repeating canonical SHA-256 here would turn a
    /// millisecond design into minutes of redundant hashing.
    private static func targetMagnitudeDbUnchecked(
        of payload: MeasuredCorrectionPayload,
        atHz frequencyHz: Double,
        sampleRate: Double,
        strength: Double
    ) -> Double {
        let amount = min(max(strength, 0), 1)
        let frequency = max(frequencyHz, 1e-6)
        let upper = min(payload.usableHighHz, min(20_000, sampleRate * 0.45))
        let transitionEnd = min(min(20_000, sampleRate * 0.48), max(upper + 2_000, upper * 1.6))
        let measured = payload.magnitudeDb(atHz: min(frequency, upper)) * amount
        guard frequency > upper else { return measured }
        guard transitionEnd > upper, frequency < transitionEnd else { return 0 }
        let denominator = log(transitionEnd) - log(upper)
        guard denominator > 1e-12 else { return 0 }
        let t = min(max((log(frequency) - log(upper)) / denominator, 0), 1)
        let cosineBlend = 0.5 * (1 + cos(Double.pi * t))
        return measured * cosineBlend
    }

    public static func design(
        for preset: EQPreset,
        sampleRate: Double
    ) -> MeasuredStereoFIRResult? {
        let normalized = preset.normalized()
        guard let correction = normalized.correction,
              correction.sourceConfidence == .measured,
              let payload = correction.measuredCorrection?.normalized(),
              payload.isFIREligible else { return nil }

        let sr = sampleRate > 0 ? sampleRate : 48_000
        let strength = correction.correctionStrength
        let partition = partitionSize(for: sr)
        let primaryLow = max(primaryFrequencyRange.lowerBound, payload.usableLowHz)
        let primaryHigh = min(primaryFrequencyRange.upperBound, payload.usableHighHz)
        let primaryFrequencies = FrequencyResponse.logFrequencies(
            count: evaluationPointCount,
            from: primaryLow,
            to: primaryHigh
        )
        let transitionEnd = regularizationEndHz(payload: payload, sampleRate: sr)
        var implementationFrequencies = FrequencyResponse.logFrequencies(
            count: evaluationPointCount,
            from: primaryLow,
            to: max(primaryHigh, transitionEnd)
        )
        if transitionEnd > primaryHigh {
            let midpoint = exp((log(primaryHigh) + log(transitionEnd)) * 0.5)
            implementationFrequencies.append(contentsOf: [primaryHigh, midpoint, transitionEnd])
            implementationFrequencies = Array(Set(implementationFrequencies)).sorted()
        }
        let peqRms = baselinePEQRMSError(
            preset: normalized,
            payload: payload,
            strength: strength,
            frequencies: primaryFrequencies,
            sampleRate: sr
        )

        var lastFailure: MeasuredFIRQualitySummary?
        for supportMs in candidateSupportMs {
            let rawCount = max(partition, Int(ceil(sr * supportMs / 1_000)))
            let tapCount = ((rawCount + partition - 1) / partition) * partition
            guard let taps = synthesizeMinimumPhase(
                payload: payload,
                strength: strength,
                sampleRate: sr,
                tapCount: tapCount
            ) else { continue }

            let implementationResponse = fftMagnitudeDb(
                of: taps,
                at: implementationFrequencies,
                sampleRate: sr
            )
            let primaryResponse = fftMagnitudeDb(
                of: taps,
                at: primaryFrequencies,
                sampleRate: sr
            )
            guard implementationResponse.count == implementationFrequencies.count,
                  primaryResponse.count == primaryFrequencies.count else { continue }
            let implementationErrors = zip(implementationFrequencies, implementationResponse).map {
                frequency, realized in
                abs(
                    realized
                        - targetMagnitudeDbUnchecked(
                            of: payload,
                            atHz: frequency,
                            sampleRate: sr,
                            strength: strength
                        )
                )
            }
            let primaryErrors = zip(primaryFrequencies, primaryResponse).map {
                frequency, realized in
                abs(
                    realized
                        - targetMagnitudeDbUnchecked(
                            of: payload,
                            atHz: frequency,
                            sampleRate: sr,
                            strength: strength
                        )
                )
            }
            let maxError = implementationErrors.max() ?? .infinity
            let rmsError = sqrt(
                implementationErrors.reduce(0) { $0 + $1 * $1 }
                    / Double(max(1, implementationErrors.count))
            )
            let primaryFIRRms = sqrt(
                primaryErrors.reduce(0) { $0 + $1 * $1 }
                    / Double(max(1, primaryErrors.count))
            )
            let absoluteImprovement = peqRms - primaryFIRRms
            let relativeImprovement = peqRms > 1e-9 ? absoluteImprovement / peqRms : 0
            let reason = rejectionReason(
                maxErrorDb: maxError,
                rmsErrorDb: rmsError,
                absoluteImprovementDb: absoluteImprovement,
                relativeImprovement: relativeImprovement
            )
            let quality = MeasuredFIRQualitySummary(
                sampleRate: sr,
                tapCount: taps.count,
                supportMs: Double(taps.count) / sr * 1_000,
                maxErrorDb: maxError,
                rmsErrorDb: rmsError,
                peqRmsErrorDb: peqRms,
                absoluteRmsImprovementDb: absoluteImprovement,
                relativeRmsImprovement: relativeImprovement,
                eligible: reason == nil,
                rejectionReason: reason
            )
            if reason == nil {
                let design = FIRDesign(
                    taps: taps,
                    sampleRate: sr,
                    channel: .left,
                    estimatedGroupDelayMs: energyCentroidMs(taps: taps, sampleRate: sr)
                )
                let right = FIRDesign(
                    taps: taps,
                    sampleRate: sr,
                    channel: .right,
                    estimatedGroupDelayMs: design.estimatedGroupDelayMs
                )
                return MeasuredStereoFIRResult(
                    design: StereoFIRDesign(left: design, right: right),
                    quality: quality
                )
            }
            lastFailure = quality
        }
        _ = lastFailure
        return nil
    }

    private static func baselinePEQRMSError(
        preset: EQPreset,
        payload: MeasuredCorrectionPayload,
        strength: Double,
        frequencies: [Double],
        sampleRate: Double
    ) -> Double {
        let preferenceIndexes = Set(preset.correction?.preferenceBandIndexes ?? [])
        var baseline = preset
        baseline.preampDb = 0
        baseline.bands = baseline.bands.map { band in
            guard preferenceIndexes.contains(band.index) else { return band }
            var disabled = band
            disabled.enabled = false
            return disabled
        }
        func rms(for channel: FIRDesignChannel) -> Double {
            let responseChannel: BandChannel = channel == .left ? .left : .right
            let squared = frequencies.reduce(0.0) { sum, frequency in
                let peqDb = FrequencyResponse.magnitudeDb(
                    of: baseline,
                    atHz: frequency,
                    sampleRate: sampleRate,
                    channel: responseChannel
                )
                let targetDb = targetMagnitudeDbUnchecked(
                    of: payload,
                    atHz: frequency,
                    sampleRate: sampleRate,
                    strength: strength
                )
                let error = peqDb - targetDb
                return sum + error * error
            }
            return sqrt(squared / Double(max(1, frequencies.count)))
        }
        return max(rms(for: .left), rms(for: .right))
    }

    private static func regularizationEndHz(
        payload: MeasuredCorrectionPayload,
        sampleRate: Double
    ) -> Double {
        let upper = min(payload.usableHighHz, min(20_000, sampleRate * 0.45))
        return min(min(20_000, sampleRate * 0.48), max(upper + 2_000, upper * 1.6))
    }

    private static func rejectionReason(
        maxErrorDb: Double,
        rmsErrorDb: Double,
        absoluteImprovementDb: Double,
        relativeImprovement: Double
    ) -> String? {
        guard maxErrorDb <= maximumImplementationErrorDb else {
            return String(format: "FIR maximum error %.2f dB exceeds %.2f dB.", maxErrorDb, maximumImplementationErrorDb)
        }
        guard rmsErrorDb <= maximumRMSErrorDb else {
            return String(format: "FIR RMS error %.2f dB exceeds %.2f dB.", rmsErrorDb, maximumRMSErrorDb)
        }
        guard absoluteImprovementDb >= minimumAbsoluteImprovementDb else {
            return String(format: "FIR improves PEQ RMS by only %.2f dB.", absoluteImprovementDb)
        }
        guard relativeImprovement >= minimumRelativeImprovement else {
            return String(format: "FIR improves PEQ RMS by only %.0f%%.", relativeImprovement * 100)
        }
        return nil
    }

    /// Homomorphic minimum-phase synthesis from a Hermitian log-magnitude
    /// spectrum. Every allocation/setup occurs on the control thread.
    private static func synthesizeMinimumPhase(
        payload: MeasuredCorrectionPayload,
        strength: Double,
        sampleRate: Double,
        tapCount: Int
    ) -> [Float]? {
        let fftSize = nextPowerOfTwo(max(64, tapCount * 2))
        let log2FFT = vDSP_Length(Int(log2(Double(fftSize))))
        guard let setup = vDSP_create_fftsetup(log2FFT, FFTRadix(kFFTRadix2)) else { return nil }
        defer { vDSP_destroy_fftsetup(setup) }

        var real = [Float](repeating: 0, count: fftSize)
        var imaginary = [Float](repeating: 0, count: fftSize)
        for bin in 0...fftSize / 2 {
            let frequency = Double(bin) * sampleRate / Double(fftSize)
            let db = targetMagnitudeDbUnchecked(
                of: payload,
                atHz: max(frequency, 1e-6),
                sampleRate: sampleRate,
                strength: strength
            )
            let logMagnitude = Float(db * log(10) / 20)
            real[bin] = logMagnitude
            if bin > 0 && bin < fftSize / 2 { real[fftSize - bin] = logMagnitude }
        }

        transform(setup: setup, log2FFT: log2FFT, real: &real, imaginary: &imaginary, direction: FFTDirection(FFT_INVERSE))
        let inverseScale = Float(1.0 / Double(fftSize))
        for index in 0..<fftSize {
            real[index] *= inverseScale
            imaginary[index] *= inverseScale
        }

        if fftSize / 2 > 1 {
            for index in 1..<fftSize / 2 { real[index] *= 2 }
        }
        if fftSize / 2 + 1 < fftSize {
            for index in (fftSize / 2 + 1)..<fftSize { real[index] = 0 }
        }
        imaginary.withUnsafeMutableBufferPointer { $0.initialize(repeating: 0) }

        transform(setup: setup, log2FFT: log2FFT, real: &real, imaginary: &imaginary, direction: FFTDirection(FFT_FORWARD))
        for index in 0..<fftSize {
            let magnitude = exp(Double(real[index]))
            let phase = Double(imaginary[index])
            real[index] = Float(magnitude * cos(phase))
            imaginary[index] = Float(magnitude * sin(phase))
        }
        transform(setup: setup, log2FFT: log2FFT, real: &real, imaginary: &imaginary, direction: FFTDirection(FFT_INVERSE))

        var taps = Array(real.prefix(tapCount))
        for index in taps.indices { taps[index] *= inverseScale }
        taperTail(&taps)
        guard taps.allSatisfy(\.isFinite), !taps.isEmpty else { return nil }
        return taps
    }

    private static func transform(
        setup: FFTSetup,
        log2FFT: vDSP_Length,
        real: inout [Float],
        imaginary: inout [Float],
        direction: FFTDirection
    ) {
        real.withUnsafeMutableBufferPointer { realPointer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
                guard let realBase = realPointer.baseAddress,
                      let imaginaryBase = imaginaryPointer.baseAddress else { return }
                var split = DSPSplitComplex(realp: realBase, imagp: imaginaryBase)
                vDSP_fft_zip(setup, &split, 1, log2FFT, direction)
            }
        }
    }

    /// Dense realized response from one zero-padded FFT. This keeps preparation
    /// O(N log N) instead of summing every tap independently at every gate point.
    private static func fftMagnitudeDb(
        of taps: [Float],
        at frequencies: [Double],
        sampleRate: Double
    ) -> [Double] {
        guard !taps.isEmpty, sampleRate > 0 else { return [] }
        let fftSize = nextPowerOfTwo(max(4_096, taps.count * 4))
        let log2FFT = vDSP_Length(Int(log2(Double(fftSize))))
        guard let setup = vDSP_create_fftsetup(log2FFT, FFTRadix(kFFTRadix2)) else { return [] }
        defer { vDSP_destroy_fftsetup(setup) }
        var real = [Float](repeating: 0, count: fftSize)
        var imaginary = [Float](repeating: 0, count: fftSize)
        real.replaceSubrange(0..<taps.count, with: taps)
        transform(
            setup: setup,
            log2FFT: log2FFT,
            real: &real,
            imaginary: &imaginary,
            direction: FFTDirection(FFT_FORWARD)
        )
        let nyquistBin = fftSize / 2
        return frequencies.map { frequency in
            let position = min(
                max(frequency / sampleRate * Double(fftSize), 0),
                Double(nyquistBin)
            )
            let lower = min(Int(floor(position)), nyquistBin)
            let upper = min(lower + 1, nyquistBin)
            let fraction = position - Double(lower)
            let lowerDb = 20 * log10(max(hypot(Double(real[lower]), Double(imaginary[lower])), 1e-12))
            let upperDb = 20 * log10(max(hypot(Double(real[upper]), Double(imaginary[upper])), 1e-12))
            return lowerDb + (upperDb - lowerDb) * fraction
        }
    }

    private static func taperTail(_ taps: inout [Float]) {
        guard taps.count > 32 else { return }
        let start = max(1, Int(Double(taps.count) * 0.95))
        guard start < taps.count - 1 else { return }
        for index in start..<taps.count {
            let t = Double(index - start) / Double(taps.count - 1 - start)
            taps[index] *= Float(0.5 * (1 + cos(Double.pi * t)))
        }
    }

    private static func energyCentroidMs(taps: [Float], sampleRate: Double) -> Double {
        var total = 0.0
        var weighted = 0.0
        for (index, tap) in taps.enumerated() {
            let energy = Double(tap * tap)
            total += energy
            weighted += Double(index) * energy
        }
        guard total > 0 else { return 0 }
        return weighted / total / sampleRate * 1_000
    }

    private static func nextPowerOfTwo(_ value: Int) -> Int {
        var result = 1
        while result < value { result <<= 1 }
        return result
    }
}

/// Small immutable-kernel cache. Convolver history is never shared.
public final class MeasuredFIRDesignCache {
    private struct Key: Hashable {
        var sampleRateBits: UInt64
        var policyVersion: Int
        var contentHash: String
        var strengthBits: UInt64
        var baselineFingerprint: String
    }

    private let maxEntries: Int
    private var storage: [Key: MeasuredStereoFIRResult] = [:]
    private var order: [Key] = []

    public init(maxEntries: Int = 6) {
        self.maxEntries = max(1, maxEntries)
    }

    public func design(for preset: EQPreset, sampleRate: Double) -> MeasuredStereoFIRResult? {
        let normalized = preset.normalized()
        guard let correction = normalized.correction,
              correction.sourceConfidence == .measured,
              let payload = correction.measuredCorrection?.normalized(),
              payload.isFIREligible else { return nil }
        let preference = Set(correction.preferenceBandIndexes)
        let baselineFingerprint = normalized.bands
            .filter { $0.enabled && !preference.contains($0.index) }
            .map { "\($0.index):\($0.type.rawValue):\($0.frequencyHz):\($0.gainDb):\($0.q):\($0.channel.rawValue)" }
            .joined(separator: "|")
        let resolvedSampleRate = sampleRate > 0 ? sampleRate : 48_000
        let key = Key(
            sampleRateBits: resolvedSampleRate.bitPattern,
            policyVersion: MeasuredFIRDesigner.policyVersion,
            contentHash: "\(payload.contentHash)|\(payload.usableLowHz.bitPattern)|\(payload.usableHighHz.bitPattern)",
            strengthBits: correction.correctionStrength.bitPattern,
            baselineFingerprint: baselineFingerprint
        )
        if let cached = storage[key] {
            touch(key)
            return cached
        }
        guard let result = MeasuredFIRDesigner.design(for: normalized, sampleRate: sampleRate) else { return nil }
        storage[key] = result
        order.append(key)
        evictIfNeeded()
        return result
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
}
