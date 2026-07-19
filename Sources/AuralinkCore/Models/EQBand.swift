import Foundation

/// Filter shape of a single parametric EQ band.
///
/// Raw values are the lowercase snake_case strings used in the on-disk preset
/// JSON and in the MCP tool payloads, so the wire format stays stable and
/// human-readable (e.g. `"low_shelf"`).
public enum BandType: String, Codable, CaseIterable, Sendable {
    case bell
    case lowShelf  = "low_shelf"
    case highShelf = "high_shelf"
    case lowPass   = "low_pass"
    case highPass  = "high_pass"
    case notch

    /// Whether this filter shape uses the `gainDb` parameter. Pass filters and
    /// notches are defined purely by frequency and Q, so their gain is ignored
    /// by the DSP and hidden in the editor.
    public var usesGain: Bool {
        switch self {
        case .bell, .lowShelf, .highShelf: return true
        case .lowPass, .highPass, .notch:  return false
        }
    }

    /// Short label for the UI / AI explanations.
    public var displayName: String {
        switch self {
        case .bell:      return "Bell"
        case .lowShelf:  return "Low Shelf"
        case .highShelf: return "High Shelf"
        case .lowPass:   return "Low Pass"
        case .highPass:  return "High Pass"
        case .notch:     return "Notch"
        }
    }

    /// User-facing name for `EQBand.q`. Shelves deliberately retain Q semantics
    /// because presets, AutoEq text files, and supported hardware PEQs all use
    /// Q≈0.71 for a conventional shelf. Reinterpreting stored values as RBJ's
    /// separate S parameter would silently change existing presets.
    public var qDisplayName: String {
        "Q"
    }

    public var qShortName: String {
        "Q"
    }
}

/// Which stereo channel(s) a band applies to.
public enum BandChannel: String, Codable, CaseIterable, Sendable {
    case stereo
    case left
    case right

    public var displayName: String {
        switch self {
        case .stereo: return "Stereo"
        case .left:   return "Left"
        case .right:  return "Right"
        }
    }
}

/// One band of the 20-band parametric EQ.
///
/// This is the atomic unit the whole product is built around: the DSP turns it
/// into biquad coefficients, the editor draws it as a draggable node, and the
/// MCP server reads/writes it as JSON.
public struct EQBand: Codable, Identifiable, Equatable, Sendable {
    /// 1-based slot index (1...20). Stable identity within a preset.
    public var index: Int
    public var type: BandType
    /// Center frequency (bell/notch) or cutoff (shelf/pass), in Hz. 20…20000.
    public var frequencyHz: Double
    /// Boost/cut in dB. -18…+18. Ignored when `type.usesGain == false`.
    public var gainDb: Double
    /// Bandwidth / resonance Q for all filter types, including shelves. 0.1…10.
    public var q: Double
    public var channel: BandChannel
    public var enabled: Bool

    public var id: Int { index }

    public init(
        index: Int,
        type: BandType = .bell,
        frequencyHz: Double,
        gainDb: Double = 0,
        q: Double = 1.0,
        channel: BandChannel = .stereo,
        enabled: Bool = true
    ) {
        self.index = index
        self.type = type
        self.frequencyHz = frequencyHz
        self.gainDb = gainDb
        self.q = q
        self.channel = channel
        self.enabled = enabled
    }
}

// MARK: - Parameter ranges (single source of truth for clamping & UI bounds)

public extension EQBand {
    static let frequencyRange: ClosedRange<Double> = 20...20_000
    static let gainRange: ClosedRange<Double> = -18...18
    static let qRange: ClosedRange<Double> = 0.1...10
    static let bandCount = 20

    /// Returns a copy with every parameter clamped into its legal range.
    func clamped() -> EQBand {
        var b = self
        b.frequencyHz = Swift.min(Swift.max(frequencyHz, EQBand.frequencyRange.lowerBound), EQBand.frequencyRange.upperBound)
        b.gainDb = Swift.min(Swift.max(gainDb, EQBand.gainRange.lowerBound), EQBand.gainRange.upperBound)
        b.q = Swift.min(Swift.max(q, EQBand.qRange.lowerBound), EQBand.qRange.upperBound)
        return b
    }

    /// A flat, disabled band for an empty slot. Frequencies are spread roughly
    /// log-uniformly across the audible range so a fresh preset has sensible
    /// default node positions.
    static func emptyBand(index: Int) -> EQBand {
        let defaults: [Double] = [
            32, 48, 72, 110, 160, 240, 350, 520, 760, 1100,
            1600, 2400, 3500, 5000, 7000, 9000, 11000, 13000, 16000, 19000
        ]
        let freq = (1...bandCount).contains(index) ? defaults[index - 1] : 1000
        return EQBand(index: index, type: .bell, frequencyHz: freq, gainDb: 0, q: 1.0, enabled: false)
    }

    /// A full set of 20 flat, disabled bands — the starting point for a new preset.
    static func defaultBands() -> [EQBand] {
        (1...bandCount).map { emptyBand(index: $0) }
    }
}
