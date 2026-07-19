import Foundation

/// A genre/purpose tuning template the AI uses as a starting target.
///
/// A target curve is intentionally *advisory*: it describes the direction of a
/// tuning ("more sub-bass, slightly recessed upper-mids") as a set of band
/// hints, not a locked-in preset. The AI combines a TargetCurve with a
/// HeadphoneProfile and the user's stated preference to synthesize the final
/// `EQPreset`, then runs it through validation.
public struct TargetCurve: Codable, Identifiable, Equatable, Sendable {
    /// Stable slug, e.g. "rock", "vocal-focus", "fps-footstep", "late-night".
    public var id: String
    public var name: String
    public var category: TargetCategory
    public var description: String
    /// Suggested band moves, relative to flat. These are starting points the
    /// AI scales to the headphone and to safety limits.
    public var hints: [BandHint]

    public init(
        id: String,
        name: String,
        category: TargetCategory,
        description: String,
        hints: [BandHint]
    ) {
        self.id = id
        self.name = name
        self.category = category
        self.description = description
        self.hints = hints
    }
}

public enum TargetCategory: String, Codable, CaseIterable, Sendable {
    case genre
    case purpose
    case reference   // e.g. Harman-style neutral targets

    public var displayName: String {
        switch self {
        case .genre:     return "Genre"
        case .purpose:   return "Purpose"
        case .reference: return "Reference"
        }
    }
}

/// A single suggested move within a target curve.
public struct BandHint: Codable, Equatable, Sendable {
    public var type: BandType
    public var frequencyHz: Double
    public var gainDb: Double
    public var q: Double
    /// Why this move exists, in plain language (shown in AI explanations).
    public var rationale: String

    public init(type: BandType, frequencyHz: Double, gainDb: Double, q: Double, rationale: String = "") {
        self.type = type
        self.frequencyHz = frequencyHz
        self.gainDb = gainDb
        self.q = q
        self.rationale = rationale
    }

    /// Materialize this hint into a concrete band at the given slot.
    public func band(index: Int) -> EQBand {
        EQBand(index: index, type: type, frequencyHz: frequencyHz, gainDb: gainDb, q: q).clamped()
    }
}
