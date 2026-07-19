import XCTest
@testable import AuralinkCore

/// Regression coverage for output-channel routing in the offline response and
/// headroom validator. The shared fixture is also consumed by the MCP tests.
final class ChannelResponseTests: XCTestCase {
    private struct Fixture: Decodable {
        struct Expected: Decodable {
            var leftDb: Double
            var rightDb: Double
            var legacyFoldedDb: Double
            var validatorPeakDb: Double
            var suggestedPreampDb: Double
        }

        var sampleRate: Double
        var centerHz: Double
        var toleranceDb: Double
        var preset: EQPreset
        var expected: Expected
    }

    private func loadFixture() throws -> Fixture {
        let testFile = URL(fileURLWithPath: #filePath)
        let fixtureURL = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/channel-response-parity.json")
        let data = try Data(contentsOf: fixtureURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Fixture.self, from: data)
    }

    func testOpposedLeftAndRightBandsRemainIndependent() throws {
        let fixture = try loadFixture()
        let left = FrequencyResponse.magnitudeDb(
            of: fixture.preset,
            atHz: fixture.centerHz,
            sampleRate: fixture.sampleRate,
            channel: .left
        )
        let right = FrequencyResponse.magnitudeDb(
            of: fixture.preset,
            atHz: fixture.centerHz,
            sampleRate: fixture.sampleRate,
            channel: .right
        )

        XCTAssertEqual(left, fixture.expected.leftDb, accuracy: fixture.toleranceDb)
        XCTAssertEqual(right, fixture.expected.rightDb, accuracy: fixture.toleranceDb)

        // The original API remains the legacy folded curve for compatibility.
        let folded = FrequencyResponse.magnitudeDb(
            of: fixture.preset,
            atHz: fixture.centerHz,
            sampleRate: fixture.sampleRate
        )
        XCTAssertEqual(folded, fixture.expected.legacyFoldedDb, accuracy: fixture.toleranceDb)
    }

    func testChannelCurveIncludesPreampAndOnlyRoutedBands() throws {
        var fixture = try loadFixture()
        fixture.preset.preampDb = -3

        let left = FrequencyResponse.curve(
            for: fixture.preset,
            at: [fixture.centerHz],
            sampleRate: fixture.sampleRate,
            channel: .left
        )
        let right = FrequencyResponse.curve(
            for: fixture.preset,
            at: [fixture.centerHz],
            sampleRate: fixture.sampleRate,
            channel: .right
        )

        XCTAssertEqual(left[0].magnitudeDb, fixture.expected.leftDb - 3, accuracy: fixture.toleranceDb)
        XCTAssertEqual(right[0].magnitudeDb, fixture.expected.rightDb - 3, accuracy: fixture.toleranceDb)
    }

    func testStereoBandContributesToBothOutputChannels() throws {
        let fixture = try loadFixture()
        var bands = EQBand.defaultBands()
        bands[9] = EQBand(
            index: 10,
            type: .bell,
            frequencyHz: fixture.centerHz,
            gainDb: 6,
            q: 1,
            channel: .stereo
        )
        let preset = EQPreset(id: "stereo", name: "Stereo", bands: bands)

        let left = FrequencyResponse.magnitudeDb(
            of: preset,
            atHz: fixture.centerHz,
            sampleRate: fixture.sampleRate,
            channel: .left
        )
        let right = FrequencyResponse.magnitudeDb(
            of: preset,
            atHz: fixture.centerHz,
            sampleRate: fixture.sampleRate,
            channel: .right
        )

        XCTAssertEqual(left, 6, accuracy: fixture.toleranceDb)
        XCTAssertEqual(right, 6, accuracy: fixture.toleranceDb)
    }

    func testValidatorUsesMaximumOfActualChannelPeaks() throws {
        let fixture = try loadFixture()
        let result = PresetValidator(rules: .default).validate(fixture.preset)

        XCTAssertEqual(result.estimatedPeakGainDb, fixture.expected.validatorPeakDb, accuracy: 0.1)
        XCTAssertEqual(result.suggestedPreampDb, fixture.expected.suggestedPreampDb, accuracy: 1e-9)
        XCTAssertEqual(result.clippingRisk, .high)
        XCTAssertTrue(result.warnings.contains {
            $0.bandIndex == nil && $0.message.contains("Combined boost peaks")
        })
    }
}
