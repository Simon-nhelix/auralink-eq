import XCTest
@testable import AuralinkCore

/// Unit tests for the DSP engine: biquad coefficients, the offline frequency
/// response, and the realtime processor. The contract (BUILD_SPEC §DSP) is:
/// flat → ~0 dB everywhere, a +6 dB bell peaks ≈+6 dB at its center, response
/// is stable across sample rates, notches attenuate, and silence stays silence.
final class DSPTests: XCTestCase {

    private let sampleRate = 48_000.0

    // MARK: - Helpers

    /// A preset with exactly one active band (the rest flat/disabled).
    private func presetWithBand(_ band: EQBand, preampDb: Double = 0) -> EQPreset {
        var bands = EQBand.defaultBands()
        let idx = band.index
        if (1...EQBand.bandCount).contains(idx) {
            bands[idx - 1] = band
        }
        return EQPreset(id: "test", name: "Test", preampDb: preampDb, bands: bands)
    }

    // MARK: - Flat preset

    func testFlatPresetIsZeroDbEverywhere() {
        let flat = EQPreset.flat()
        let freqs = FrequencyResponse.logFrequencies(count: 128)
        let curve = FrequencyResponse.curve(for: flat, at: freqs, sampleRate: sampleRate)
        XCTAssertEqual(curve.count, freqs.count)
        for point in curve {
            XCTAssertEqual(point.magnitudeDb, 0.0, accuracy: 1e-6,
                           "Flat preset must be 0 dB at \(point.frequencyHz) Hz")
        }
    }

    // MARK: - Bell peak

    func testPositiveBellPeaksAtCenter() {
        let center = 1_000.0
        let band = EQBand(index: 10, type: .bell, frequencyHz: center, gainDb: 6, q: 1.0)
        let preset = presetWithBand(band)

        // The peaking filter's maximum is exactly its boost (+6 dB) at the center.
        let atCenter = FrequencyResponse.magnitudeDb(of: preset, atHz: center, sampleRate: sampleRate)
        XCTAssertEqual(atCenter, 6.0, accuracy: 0.5,
                       "A +6 dB bell should peak ≈+6 dB at its center frequency")

        // Far from center the response should be back near 0 dB.
        let farLow = FrequencyResponse.magnitudeDb(of: preset, atHz: 60, sampleRate: sampleRate)
        let farHigh = FrequencyResponse.magnitudeDb(of: preset, atHz: 16_000, sampleRate: sampleRate)
        XCTAssertEqual(farLow, 0.0, accuracy: 1.0)
        XCTAssertEqual(farHigh, 0.0, accuracy: 1.0)

        // The center is the maximum across a sampled grid.
        let freqs = FrequencyResponse.logFrequencies(count: 512)
        let curve = FrequencyResponse.curve(for: preset, at: freqs, sampleRate: sampleRate)
        XCTAssertEqual(curve.peakDb, 6.0, accuracy: 0.5)
    }

    func testNegativeBellDipsAtCenter() {
        let center = 2_000.0
        let band = EQBand(index: 12, type: .bell, frequencyHz: center, gainDb: -6, q: 1.0)
        let preset = presetWithBand(band)
        let atCenter = FrequencyResponse.magnitudeDb(of: preset, atHz: center, sampleRate: sampleRate)
        XCTAssertEqual(atCenter, -6.0, accuracy: 0.5,
                       "A -6 dB bell should dip ≈-6 dB at its center frequency")
    }

    // MARK: - Sample-rate stability

    func testBellResponseStableAcrossSampleRates() {
        let center = 1_000.0
        let band = EQBand(index: 10, type: .bell, frequencyHz: center, gainDb: 6, q: 1.0)
        let preset = presetWithBand(band)

        // Same audible-band response at 44.1k / 48k / 96k (filters are designed
        // per sample rate, so the resulting magnitude should match closely).
        for sr in [44_100.0, 48_000.0, 96_000.0] {
            let atCenter = FrequencyResponse.magnitudeDb(of: preset, atHz: center, sampleRate: sr)
            XCTAssertEqual(atCenter, 6.0, accuracy: 0.5,
                           "Bell peak should be ≈+6 dB at \(sr) Hz, got \(atCenter)")
        }

        // Cross-rate agreement on a sampled audible grid (away from Nyquist).
        let freqs = FrequencyResponse.logFrequencies(count: 64, from: 20, to: 18_000)
        let c44 = FrequencyResponse.curve(for: preset, at: freqs, sampleRate: 44_100)
        let c96 = FrequencyResponse.curve(for: preset, at: freqs, sampleRate: 96_000)
        for (a, b) in zip(c44, c96) {
            XCTAssertEqual(a.magnitudeDb, b.magnitudeDb, accuracy: 0.5,
                           "Response at \(a.frequencyHz) Hz should agree across sample rates")
        }
    }

    // MARK: - Shelves and passes

    func testHighShelfBoostsTreble() {
        let band = EQBand(index: 18, type: .highShelf, frequencyHz: 8_000, gainDb: 6, q: 0.707)
        let preset = presetWithBand(band)
        // Well above the corner the shelf approaches its full +6 dB.
        let high = FrequencyResponse.magnitudeDb(of: preset, atHz: 18_000, sampleRate: sampleRate)
        XCTAssertEqual(high, 6.0, accuracy: 1.0)
        // Well below the corner it's near 0 dB.
        let low = FrequencyResponse.magnitudeDb(of: preset, atHz: 100, sampleRate: sampleRate)
        XCTAssertEqual(low, 0.0, accuracy: 1.0)
    }

    func testLowShelfBoostsBass() {
        let band = EQBand(index: 2, type: .lowShelf, frequencyHz: 100, gainDb: 6, q: 0.707)
        let preset = presetWithBand(band)
        let low = FrequencyResponse.magnitudeDb(of: preset, atHz: 25, sampleRate: sampleRate)
        XCTAssertEqual(low, 6.0, accuracy: 1.0)
        let high = FrequencyResponse.magnitudeDb(of: preset, atHz: 10_000, sampleRate: sampleRate)
        XCTAssertEqual(high, 0.0, accuracy: 1.0)
    }

    func testHighPassAttenuatesBelowCutoff() {
        let band = EQBand(index: 1, type: .highPass, frequencyHz: 200, gainDb: 0, q: 0.707)
        let preset = presetWithBand(band)
        // Deep below cutoff is heavily attenuated; well above is ~0 dB.
        let below = FrequencyResponse.magnitudeDb(of: preset, atHz: 30, sampleRate: sampleRate)
        let above = FrequencyResponse.magnitudeDb(of: preset, atHz: 5_000, sampleRate: sampleRate)
        XCTAssertLessThan(below, -10.0)
        XCTAssertEqual(above, 0.0, accuracy: 0.5)
    }

    // MARK: - Notch

    func testNotchAttenuatesAtCenter() {
        let center = 1_000.0
        let band = EQBand(index: 10, type: .notch, frequencyHz: center, gainDb: 0, q: 4.0)
        let preset = presetWithBand(band)
        // A notch drives the center toward -∞; require a deep cut there.
        let atCenter = FrequencyResponse.magnitudeDb(of: preset, atHz: center, sampleRate: sampleRate)
        XCTAssertLessThan(atCenter, -20.0, "Notch should deeply attenuate at its center")
        // Away from the notch the response returns to ~0 dB.
        let away = FrequencyResponse.magnitudeDb(of: preset, atHz: 200, sampleRate: sampleRate)
        XCTAssertEqual(away, 0.0, accuracy: 1.0)
    }

    // MARK: - Preamp offset

    func testPreampShiftsCurveFlatly() {
        let band = EQBand(index: 10, type: .bell, frequencyHz: 1_000, gainDb: 6, q: 1.0)
        let preset = presetWithBand(band, preampDb: -6)
        let freqs = FrequencyResponse.logFrequencies(count: 64)
        let curve = FrequencyResponse.curve(for: preset, at: freqs, sampleRate: sampleRate)
        // Every point is shifted by exactly the preamp (-6 dB) vs. the no-preamp magnitude.
        for point in curve {
            let raw = FrequencyResponse.magnitudeDb(of: preset, atHz: point.frequencyHz, sampleRate: sampleRate)
            XCTAssertEqual(point.magnitudeDb, raw - 6.0, accuracy: 1e-6)
        }
    }

    // MARK: - Disabled / identity bands

    func testDisabledBandIsIdentity() {
        var band = EQBand(index: 10, type: .bell, frequencyHz: 1_000, gainDb: 12, q: 1.0)
        band.enabled = false
        let preset = presetWithBand(band)
        let atCenter = FrequencyResponse.magnitudeDb(of: preset, atHz: 1_000, sampleRate: sampleRate)
        XCTAssertEqual(atCenter, 0.0, accuracy: 1e-6, "Disabled band must not affect the response")
    }

    func testZeroGainBellIsIdentity() {
        let band = EQBand(index: 10, type: .bell, frequencyHz: 1_000, gainDb: 0, q: 1.0)
        let preset = presetWithBand(band)
        let atCenter = FrequencyResponse.magnitudeDb(of: preset, atHz: 1_000, sampleRate: sampleRate)
        XCTAssertEqual(atCenter, 0.0, accuracy: 1e-9, "A 0 dB gain band must be identity")
    }

    // MARK: - logFrequencies

    func testLogFrequenciesSpanAndOrder() {
        let freqs = FrequencyResponse.logFrequencies(count: 100)
        XCTAssertEqual(freqs.count, 100)
        XCTAssertEqual(freqs.first ?? 0, 20, accuracy: 1e-6)
        XCTAssertEqual(freqs.last ?? 0, 20_000, accuracy: 1e-3)
        // Strictly increasing.
        for i in 1..<freqs.count {
            XCTAssertGreaterThan(freqs[i], freqs[i - 1])
        }
        // Clamped to at least 2 points even if asked for fewer.
        XCTAssertEqual(FrequencyResponse.logFrequencies(count: 0).count, 2)
    }

    // MARK: - Realtime processor

    func testProcessSilenceStaysSilence() {
        let band = EQBand(index: 10, type: .bell, frequencyHz: 1_000, gainDb: 12, q: 1.0)
        let preset = presetWithBand(band)
        let processor = EQProcessor(sampleRate: sampleRate)
        processor.update(preset: preset)

        let frames = 1024
        var left = [Float](repeating: 0, count: frames)
        var right = [Float](repeating: 0, count: frames)
        left.withUnsafeMutableBufferPointer { lp in
            right.withUnsafeMutableBufferPointer { rp in
                guard let lb = lp.baseAddress, let rb = rp.baseAddress else { return }
                processor.processInPlace(left: lb, right: rb, frames: frames)
            }
        }
        for v in left { XCTAssertEqual(v, 0.0, accuracy: 1e-7) }
        for v in right { XCTAssertEqual(v, 0.0, accuracy: 1e-7) }
    }

    func testBypassedProcessorPassesAudioUntouched() {
        let band = EQBand(index: 10, type: .bell, frequencyHz: 1_000, gainDb: 12, q: 1.0)
        let preset = presetWithBand(band, preampDb: -6)
        let processor = EQProcessor(sampleRate: sampleRate)
        processor.update(preset: preset)
        processor.setEnabled(false)

        let frames = 256
        var input = (0..<frames).map { Float(sin(2 * Double.pi * 440 * Double($0) / sampleRate)) }
        let original = input
        input.withUnsafeMutableBufferPointer { p in
            guard let b = p.baseAddress else { return }
            processor.processInPlace(left: b, right: nil, frames: frames)
        }
        // Bypass means no preamp and no filtering — bit-for-bit identical.
        for (a, b) in zip(input, original) {
            XCTAssertEqual(a, b, accuracy: 1e-7)
        }
    }

    func testFlatProcessorPreservesSineWithoutPreamp() {
        // An all-flat preset (no gain bands, 0 preamp) is unity — the processor
        // must reproduce the input within float rounding.
        let preset = EQPreset.flat()
        let processor = EQProcessor(sampleRate: sampleRate)
        processor.update(preset: preset)

        let frames = 512
        var input = (0..<frames).map { Float(0.5 * sin(2 * Double.pi * 440 * Double($0) / sampleRate)) }
        let original = input
        input.withUnsafeMutableBufferPointer { p in
            guard let b = p.baseAddress else { return }
            processor.processInPlace(left: b, right: nil, frames: frames)
        }
        for (a, b) in zip(input, original) {
            XCTAssertEqual(a, b, accuracy: 1e-5)
        }
    }

    func testStandardModePreservesFullScaleFlatAudio() {
        let processor = EQProcessor(sampleRate: sampleRate)
        processor.update(preset: .flat())
        var input: [Float] = [-1, -0.999, 0, 0.999, 1]
        let original = input
        let frameCount = input.count

        input.withUnsafeMutableBufferPointer { p in
            guard let base = p.baseAddress else { return }
            processor.processInPlace(left: base, right: nil, frames: frameCount)
        }

        XCTAssertEqual(input, original, "standard path must not waveshape valid full-scale PCM")
    }

    func testPreampScalesAmplitude() {
        // A -6 dB preamp on a flat preset halves the amplitude (≈0.501).
        let preset = EQPreset(id: "p", name: "p", preampDb: -6, bands: EQBand.defaultBands())
        let processor = EQProcessor(sampleRate: sampleRate)
        processor.update(preset: preset)

        let frames = 64
        var input = [Float](repeating: 1.0, count: frames)
        input.withUnsafeMutableBufferPointer { p in
            guard let b = p.baseAddress else { return }
            processor.processInPlace(left: b, right: nil, frames: frames)
        }
        let expected = Float(pow(10.0, -6.0 / 20.0)) // ≈ 0.5012
        for v in input {
            XCTAssertEqual(v, expected, accuracy: 1e-4)
        }
    }

    // MARK: - HQ FIR prototype

    func testFIRConvolverReplaysImpulseTaps() {
        var convolver = FIRConvolver(taps: [0.5, 0.25, -0.125])
        let input: [Float] = [1, 0, 0, 0]
        let output = input.map { convolver.process($0) }

        XCTAssertEqual(output[0], 0.5, accuracy: 1e-7)
        XCTAssertEqual(output[1], 0.25, accuracy: 1e-7)
        XCTAssertEqual(output[2], -0.125, accuracy: 1e-7)
        XCTAssertEqual(output[3], 0, accuracy: 1e-7)
    }

    func testFIRConvolverBlockPathReplaysImpulseTaps() {
        var convolver = FIRConvolver(taps: [0.5, 0.25, -0.125])
        var buffer: [Float] = [1, 0, 0, 0]
        let frames = buffer.count
        buffer.withUnsafeMutableBufferPointer { p in
            guard let base = p.baseAddress else { return }
            convolver.processInPlace(base, frames: frames)
        }

        XCTAssertEqual(buffer[0], 0.5, accuracy: 1e-7)
        XCTAssertEqual(buffer[1], 0.25, accuracy: 1e-7)
        XCTAssertEqual(buffer[2], -0.125, accuracy: 1e-7)
        XCTAssertEqual(buffer[3], 0, accuracy: 1e-7)
    }

    func testMinimumPhaseFIRApproximationTracksIIRMagnitude() {
        var bands = EQBand.defaultBands()
        bands[1] = EQBand(index: 2, type: .lowShelf, frequencyHz: 120, gainDb: 2.5, q: 0.707)
        bands[8] = EQBand(index: 9, type: .bell, frequencyHz: 1_100, gainDb: -2, q: 1.1)
        bands[14] = EQBand(index: 15, type: .bell, frequencyHz: 4_800, gainDb: 1.5, q: 1.4)
        bands[17] = EQBand(index: 18, type: .highShelf, frequencyHz: 9_500, gainDb: 1.25, q: 0.707)
        let preset = EQPreset(id: "fir", name: "FIR", preampDb: -2, bands: bands)
        let design = FIRDesigner.minimumPhaseApproximation(
            for: preset,
            sampleRate: sampleRate,
            length: 2048,
            channel: .left
        )

        XCTAssertGreaterThan(design.taps.count, 1)
        XCTAssertLessThan(design.estimatedGroupDelayMs, 2.0)

        for hz in [50.0, 120.0, 500.0, 1_100.0, 4_800.0, 10_000.0, 16_000.0] {
            let expected = FrequencyResponse.magnitudeDb(of: preset, atHz: hz, sampleRate: sampleRate)
            let actual = FIRDesigner.magnitudeDb(of: design.taps, atHz: hz, sampleRate: sampleRate)
            XCTAssertEqual(actual, expected, accuracy: 0.8, "FIR approximation drift at \(hz) Hz")
        }
    }

    func testStereoFIRDesignHonorsLeftRightBands() {
        var bands = EQBand.defaultBands()
        bands[5] = EQBand(index: 6, type: .bell, frequencyHz: 1_000, gainDb: 6, q: 1, channel: .left)
        let preset = EQPreset(id: "lr", name: "LR", bands: bands)
        let design = FIRDesigner.stereoMinimumPhaseApproximation(for: preset, sampleRate: sampleRate, length: 512)

        let leftDb = FIRDesigner.magnitudeDb(of: design.left.taps, atHz: 1_000, sampleRate: sampleRate)
        let rightDb = FIRDesigner.magnitudeDb(of: design.right.taps, atHz: 1_000, sampleRate: sampleRate)

        XCTAssertEqual(leftDb, 6, accuracy: 0.8)
        XCTAssertEqual(rightDb, 0, accuracy: 1e-6)
    }

    func testFIRDesignCacheReusesEquivalentBandTopology() {
        let band = EQBand(index: 10, type: .bell, frequencyHz: 1_000, gainDb: 3, q: 1)
        let firstPreset = presetWithBand(band)
        let secondPreset = EQPreset(id: "copy", name: "Copy", preampDb: -6, bands: firstPreset.bands)
        let cache = FIRDesignCache(maxEntries: 2)

        let first = cache.design(for: firstPreset, sampleRate: sampleRate, length: 512)
        let second = cache.design(for: secondPreset, sampleRate: sampleRate, length: 512)

        XCTAssertEqual(first.left.taps, second.left.taps)
        XCTAssertEqual(first.right.taps, second.right.taps)
    }

    func testRealtimeFIRPreviewUsesShortTapBudget() {
        XCTAssertEqual(FIRDesigner.realtimePreviewLength, 512)
        XCTAssertEqual(FIRDesigner.realtimePreviewLength(for: 192_000), 512)

        let band = EQBand(index: 10, type: .bell, frequencyHz: 1_000, gainDb: 3, q: 1)
        let cache = FIRDesignCache(maxEntries: 1)
        let design = cache.design(for: presetWithBand(band), sampleRate: sampleRate)

        XCTAssertLessThanOrEqual(design.left.taps.count, FIRDesigner.realtimePreviewLength)
        XCTAssertLessThanOrEqual(design.right.taps.count, FIRDesigner.realtimePreviewLength)
    }

    func testLegacyPresetCannotActivateMeasuredFIRAndStaysTransparent() {
        let preset = EQPreset.flat()
        let processor = EQProcessor(sampleRate: sampleRate)
        processor.update(preset: preset)
        XCTAssertFalse(processor.setRenderMode(.hqFIR))

        let frames = 512
        var input = (0..<frames).map { Float(0.5 * sin(2 * Double.pi * 440 * Double($0) / sampleRate)) }
        let original = input
        input.withUnsafeMutableBufferPointer { p in
            guard let b = p.baseAddress else { return }
            processor.processInPlace(left: b, right: nil, frames: frames)
        }
        for (a, b) in zip(input, original) {
            XCTAssertEqual(a, b, accuracy: 1e-6)
        }
    }

    func testRejectedMeasuredFIRRequestKeepsStandardIIRImpulse() {
        let band = EQBand(index: 10, type: .bell, frequencyHz: 1_000, gainDb: 3, q: 1)
        let preset = presetWithBand(band)
        let processor = EQProcessor(sampleRate: sampleRate)
        processor.update(preset: preset)
        XCTAssertFalse(processor.setRenderMode(.hqFIR))

        let frames = 256
        let impulse: Float = 0.125
        var buffer = [Float](repeating: 0, count: frames)
        buffer[0] = impulse
        buffer.withUnsafeMutableBufferPointer { pointer in
            guard let base = pointer.baseAddress else { return }
            processor.processInPlace(left: base, right: nil, frames: frames)
        }
        let responseAt1k = FIRDesigner.magnitudeDb(
            of: buffer.map { $0 / impulse },
            atHz: 1_000,
            sampleRate: sampleRate
        )
        XCTAssertEqual(responseAt1k, 3, accuracy: 0.1)
    }

    // MARK: - Smoothing / anti-click contract

    /// Drives `frames` samples of DC `value` through the processor and returns
    /// the buffer (mono path).
    private func processDC(_ processor: EQProcessor, value: Float, frames: Int) -> [Float] {
        var buf = [Float](repeating: value, count: frames)
        buf.withUnsafeMutableBufferPointer { p in
            guard let b = p.baseAddress else { return }
            processor.processInPlace(left: b, right: nil, frames: frames)
        }
        return buf
    }

    func testPreampChangeRampsInsteadOfStepping() {
        let processor = EQProcessor(sampleRate: sampleRate)
        processor.update(preset: EQPreset.flat())
        _ = processDC(processor, value: 1.0, frames: 512)   // audio is flowing

        processor.setPreamp(-12)
        let out = processDC(processor, value: 1.0, frames: 4096)

        // No step at the change point…
        XCTAssertGreaterThan(out[0], 0.9, "preamp must ramp, not jump")
        // …no audible per-sample jumps anywhere in the ramp…
        for i in 1..<out.count {
            XCTAssertLessThan(abs(out[i] - out[i - 1]), 0.02)
        }
        // …and the ramp converges to the target (~5 ms time constant).
        let target = Float(pow(10.0, -12.0 / 20.0))
        XCTAssertEqual(out.last!, target, accuracy: 0.01)
    }

    func testBypassToggleCrossfadesAndSettlesBitPerfect() {
        // Flat bands with a -12 dB preamp: wet ≈ 0.25, dry = 1.0.
        let preset = EQPreset(id: "p", name: "p", preampDb: -12, bands: EQBand.defaultBands())
        let processor = EQProcessor(sampleRate: sampleRate)
        processor.update(preset: preset)
        let settled = processDC(processor, value: 1.0, frames: 512)
        XCTAssertEqual(settled.last!, Float(pow(10.0, -12.0 / 20.0)), accuracy: 0.01)

        // Toggle bypass mid-stream: output glides wet → dry without a step.
        processor.setEnabled(false)
        let fade = processDC(processor, value: 1.0, frames: 4096)
        XCTAssertLessThan(fade[0], 0.3, "fade must start from the wet level")
        for i in 1..<fade.count {
            XCTAssertLessThan(abs(fade[i] - fade[i - 1]), 0.02)
        }
        // Converges to dry; full-scale DC grazes the 0.99 clip-guard knee, so
        // allow its ≤0.25 % shaping.
        XCTAssertEqual(fade.last!, 1.0, accuracy: 5e-3)

        // Once fully bypassed, the pass-through is bit-perfect.
        let bypassed = processDC(processor, value: 0.7, frames: 256)
        for v in bypassed { XCTAssertEqual(v, 0.7, accuracy: 0) }
    }

    func testPresetUpdateCarriesFilterStateWithoutClick() {
        // DC 0.2 through a +12 dB low shelf settles near 0.2 × 3.98 ≈ 0.8.
        let bandA = EQBand(index: 1, type: .lowShelf, frequencyHz: 100, gainDb: 12, q: 0.707)
        let bandB = EQBand(index: 1, type: .lowShelf, frequencyHz: 120, gainDb: 12, q: 0.707)
        let processor = EQProcessor(sampleRate: sampleRate)
        processor.update(preset: presetWithBand(bandA))
        let before = processDC(processor, value: 0.2, frames: 4096)
        let settled = before.last!
        XCTAssertEqual(settled, 0.2 * 3.98, accuracy: 0.05)

        // Rebuilding the cascade for a similar band must continue from the old
        // filter state — a state reset would step the output back toward 0.2.
        processor.update(preset: presetWithBand(bandB))
        let after = processDC(processor, value: 0.2, frames: 1024)
        XCTAssertEqual(after[0], settled, accuracy: 0.1,
                       "preset update must not restart the filters (click)")
        for i in 1..<after.count {
            XCTAssertLessThan(abs(after[i] - after[i - 1]), 0.02)
        }
    }

    func testPresetUpdateDoesNotMoveStateAcrossBandIndices() {
        // The old chain has one settled low shelf in slot/index 1.
        let oldBand = EQBand(index: 1, type: .lowShelf, frequencyHz: 100, gainDb: 12, q: 0.707)
        // The new chain is a different stable band identity. It must start
        // fresh rather than inheriting index 1's low-shelf memory.
        let newBand = EQBand(index: 2, type: .highPass, frequencyHz: 100, gainDb: 0, q: 0.707)
        let processor = EQProcessor(sampleRate: sampleRate)
        processor.update(preset: presetWithBand(oldBand))
        let before = processDC(processor, value: 0.2, frames: 4096)
        XCTAssertGreaterThan(before.last!, 0.7)

        processor.update(preset: presetWithBand(newBand))
        let after = processDC(processor, value: 0.2, frames: 2048)

        let reference = EQProcessor(sampleRate: sampleRate)
        reference.update(preset: presetWithBand(newBand))
        let fresh = processDC(reference, value: 0.2, frames: 2048)
        let tail = zip(after.suffix(256), fresh.suffix(256))
        let maxTailDiff = tail.map { abs($0 - $1) }.max() ?? .infinity
        XCTAssertLessThan(maxTailDiff, 0.01)
    }

    func testPresetUpdateDoesNotCarryStateAcrossFilterTypes() {
        let oldBand = EQBand(index: 1, type: .lowShelf, frequencyHz: 20, gainDb: 12, q: 0.707)
        let newBand = EQBand(index: 1, type: .highPass, frequencyHz: 20, gainDb: 0, q: 0.707)
        let processor = EQProcessor(sampleRate: sampleRate)
        processor.update(preset: presetWithBand(oldBand))
        let before = processDC(processor, value: 0.2, frames: 8_192)
        XCTAssertGreaterThan(before.last!, 0.7)

        processor.update(preset: presetWithBand(newBand))
        let after = processDC(processor, value: 0.2, frames: 8_192)

        let reference = EQProcessor(sampleRate: sampleRate)
        reference.update(preset: presetWithBand(newBand))
        let fresh = processDC(reference, value: 0.2, frames: 8_192)
        let tail = zip(after.suffix(1_024), fresh.suffix(1_024))
        let maxTailDiff = tail.map { abs($0 - $1) }.max() ?? .infinity
        XCTAssertLessThan(maxTailDiff, 0.005)
    }

    func testPresetUpdateCrossfadesRemovedBands() {
        let band = EQBand(index: 1, type: .lowShelf, frequencyHz: 100, gainDb: 12, q: 0.707)
        let processor = EQProcessor(sampleRate: sampleRate)
        processor.update(preset: presetWithBand(band))
        let before = processDC(processor, value: 0.2, frames: 4096)
        let settled = before.last!
        XCTAssertGreaterThan(settled, 0.7)

        processor.update(preset: .flat())
        let after = processDC(processor, value: 0.2, frames: 4096)

        XCTAssertEqual(after[0], settled, accuracy: 0.05)
        for i in 1..<512 {
            XCTAssertLessThan(abs(after[i] - after[i - 1]), 0.02)
        }
        XCTAssertEqual(after.last!, 0.2, accuracy: 0.02)
    }

    func testClipGuardCapsOutputAndReportsPreClipPeak() {
        // +12 dB low shelf on full-scale DC pushes the wet path to ≈ 4× — the
        // guard must cap the output below 1.0 while the *returned* peak still
        // reports the pre-guard overshoot (that is the honest clipping signal).
        let band = EQBand(index: 1, type: .lowShelf, frequencyHz: 1_000, gainDb: 12, q: 0.707)
        let processor = EQProcessor(sampleRate: sampleRate)
        processor.update(preset: presetWithBand(band))
        processor.setClipProtectionEnabled(true)

        var buf = [Float](repeating: 1.0, count: 4096)
        let preClipPeak = buf.withUnsafeMutableBufferPointer { p -> Float in
            guard let b = p.baseAddress else { return 0 }
            return processor.processInPlace(left: b, right: nil, frames: 4096)
        }
        XCTAssertGreaterThan(preClipPeak, 1.0, "pre-guard peak must report the overshoot")
        for v in buf {
            XCTAssertLessThanOrEqual(abs(v), 1.0, "clip guard must cap the output")
        }
    }

    // MARK: - True peak telemetry

    func testTruePeakEstimatorPreservesSamplePeak() {
        let samples: [Float] = [0, 0.25, -0.5, 0.125]
        let estimate = samples.withUnsafeBufferPointer { p in
            TruePeakEstimator.estimateMono(samples: p.baseAddress!, frames: samples.count)
        }

        XCTAssertEqual(estimate.samplePeak, 0.5, accuracy: 1e-6)
        XCTAssertGreaterThanOrEqual(estimate.estimatedTruePeak, estimate.samplePeak)
    }

    func testTruePeakEstimatorDetectsIntersampleOvershoot() {
        // A plateau surrounded by lower samples can reconstruct above the
        // largest sample value; a sample-peak-only meter would report 0.9.
        let samples: [Float] = [0, 0.9, 0.9, 0]
        let estimate = samples.withUnsafeBufferPointer { p in
            TruePeakEstimator.estimateMono(samples: p.baseAddress!, frames: samples.count)
        }

        XCTAssertEqual(estimate.samplePeak, 0.9, accuracy: 1e-6)
        XCTAssertGreaterThan(estimate.estimatedTruePeak, 1.0)
    }

    // MARK: - Loudness-matched A/B

    func testLoudnessMatcherCutsLouderCandidateToReference() {
        var candidate = EQPreset.flat()
        candidate.preampDb = 0
        var reference = EQPreset.flat()
        reference.preampDb = -4

        let match = LoudnessMatcher.match(candidate, to: reference, sampleRate: sampleRate)

        XCTAssertEqual(match.adjustmentDb, -4, accuracy: 0.1)
        XCTAssertEqual(match.preset.preampDb, -4, accuracy: 0.1)
    }

    func testLoudnessMatcherDoesNotBoostQuieterCandidate() {
        var candidate = EQPreset.flat()
        candidate.preampDb = -8
        var reference = EQPreset.flat()
        reference.preampDb = -2

        let match = LoudnessMatcher.match(candidate, to: reference, sampleRate: sampleRate)

        XCTAssertEqual(match.adjustmentDb, 0, accuracy: 0.1)
        XCTAssertEqual(match.preset.preampDb, -8, accuracy: 0.1)
    }

    // MARK: - Biquad magnitude sanity

    func testBiquadIdentityMagnitudeIsOne() {
        let biquad = Biquad() // unconfigured = passthrough
        XCTAssertEqual(biquad.magnitude(atHz: 1_000, sampleRate: sampleRate), 1.0, accuracy: 1e-9)
    }

    func testBiquadClampsOutOfRangeInputs() {
        // Frequencies above Nyquist and absurd Q/gain must not produce NaN/inf.
        var biquad = Biquad()
        biquad.configure(type: .bell, frequencyHz: 100_000, gainDb: 999, q: 999, sampleRate: sampleRate)
        let m = biquad.magnitude(atHz: 1_000, sampleRate: sampleRate)
        XCTAssertTrue(m.isFinite, "Magnitude must stay finite for clamped extreme inputs")
        // And the per-sample path stays finite too.
        let y = biquad.process(0.5)
        XCTAssertTrue(y.isFinite)
    }

    func testBiquadFlushesDenormalSizedSamplesToZero() {
        var biquad = Biquad()
        let subnormal = Float.leastNormalMagnitude / 2
        XCTAssertEqual(biquad.process(subnormal), 0, accuracy: 0)
        XCTAssertEqual(biquad.process(0), 0, accuracy: 0)
    }

    func testBiquadPreservesQuietNormalSamplesAboveDenormalClamp() {
        var biquad = Biquad()
        let quiet = Float(1e-20)
        XCTAssertEqual(biquad.process(quiet), quiet, accuracy: 0)
    }
}
