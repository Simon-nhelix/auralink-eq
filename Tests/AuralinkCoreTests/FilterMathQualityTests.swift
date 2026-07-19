import XCTest
@testable import AuralinkCore

final class FilterMathQualityTests: XCTestCase {
    func testShelfParameterContractRemainsQCompatible() {
        XCTAssertEqual(BandType.lowShelf.qDisplayName, "Q")
        XCTAssertEqual(BandType.highShelf.qShortName, "Q")
    }

    func testLowShelfMatchesIndependentQParameterizedRBJOracle() {
        let sampleRate = 48_000.0
        let frequency = 120.0
        let gainDb = 6.0
        let q = 0.707
        var biquad = Biquad()
        biquad.configure(
            type: .lowShelf,
            frequencyHz: frequency,
            gainDb: gainDb,
            q: q,
            sampleRate: sampleRate
        )

        for probe in [30.0, 120, 500, 5_000] {
            let expected = independentLowShelfMagnitude(
                atHz: probe,
                centerHz: frequency,
                gainDb: gainDb,
                q: q,
                sampleRate: sampleRate
            )
            XCTAssertEqual(biquad.magnitude(atHz: probe, sampleRate: sampleRate), expected, accuracy: 1e-10)
        }
    }

    private func independentLowShelfMagnitude(
        atHz probe: Double,
        centerHz: Double,
        gainDb: Double,
        q: Double,
        sampleRate: Double
    ) -> Double {
        let omega0 = 2 * Double.pi * centerHz / sampleRate
        let cosine = cos(omega0)
        let alpha = sin(omega0) / (2 * q)
        let amplitude = pow(10, gainDb / 40)
        let term = 2 * sqrt(amplitude) * alpha

        let rawB0 = amplitude * ((amplitude + 1) - (amplitude - 1) * cosine + term)
        let rawB1 = 2 * amplitude * ((amplitude - 1) - (amplitude + 1) * cosine)
        let rawB2 = amplitude * ((amplitude + 1) - (amplitude - 1) * cosine - term)
        let rawA0 = (amplitude + 1) + (amplitude - 1) * cosine + term
        let rawA1 = -2 * ((amplitude - 1) + (amplitude + 1) * cosine)
        let rawA2 = (amplitude + 1) + (amplitude - 1) * cosine - term

        let b0 = rawB0 / rawA0
        let b1 = rawB1 / rawA0
        let b2 = rawB2 / rawA0
        let a1 = rawA1 / rawA0
        let a2 = rawA2 / rawA0
        let omega = 2 * Double.pi * probe / sampleRate
        let numerator = ComplexPair(
            real: b0 + b1 * cos(omega) + b2 * cos(2 * omega),
            imaginary: -(b1 * sin(omega) + b2 * sin(2 * omega))
        )
        let denominator = ComplexPair(
            real: 1 + a1 * cos(omega) + a2 * cos(2 * omega),
            imaginary: -(a1 * sin(omega) + a2 * sin(2 * omega))
        )
        return numerator.magnitude / denominator.magnitude
    }

    private struct ComplexPair {
        var real: Double
        var imaginary: Double
        var magnitude: Double { hypot(real, imaginary) }
    }
}
