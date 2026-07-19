import Foundation

/// Tonal-balance knowledge for a specific headphone model.
///
/// The AI reads these (via the `get_headphone_profile` MCP tool / the
/// `eq://headphones/{id}` resource) so its tuning starts from the headphone's
/// actual character instead of a generic guess. Everything here is advisory
/// metadata — never raw, unsafe EQ values.
public struct HeadphoneProfile: Codable, Identifiable, Equatable, Sendable {
    /// Stable slug, e.g. "sennheiser-hd600".
    public var id: String
    public var brand: String
    public var model: String
    public var type: HeadphoneType
    /// One-line tonal signature, e.g. "Neutral-bright, light bass, intimate mids".
    public var signature: String
    /// Human/AI-readable correction notes: what tends to need fixing and why.
    public var correctionNotes: [String]
    /// Frequency regions that commonly read as harsh/fatiguing (Hz). Used as
    /// hints by the "reduce harshness" flow.
    public var harshRegionsHz: [FrequencyRange]
    /// Optional default target curve id (see TargetCurve) appropriate for this can.
    public var suggestedTargetCurveId: String?
    /// Where the characterization comes from + how much to trust it.
    public var source: String
    public var credibility: Credibility

    public init(
        id: String,
        brand: String,
        model: String,
        type: HeadphoneType,
        signature: String,
        correctionNotes: [String] = [],
        harshRegionsHz: [FrequencyRange] = [],
        suggestedTargetCurveId: String? = nil,
        source: String = "",
        credibility: Credibility = .community
    ) {
        self.id = id
        self.brand = brand
        self.model = model
        self.type = type
        self.signature = signature
        self.correctionNotes = correctionNotes
        self.harshRegionsHz = harshRegionsHz
        self.suggestedTargetCurveId = suggestedTargetCurveId
        self.source = source
        self.credibility = credibility
    }

    public var displayName: String { "\(brand) \(model)" }
}

public enum HeadphoneType: String, Codable, Sendable {
    case openBack   = "open_back"
    case closedBack = "closed_back"
    case iem
    case earbud
    case onEar      = "on_ear"
    case trueWireless = "true_wireless"
}

/// How much to trust a profile's characterization. Surfaced in the UI so the
/// user knows whether the AI is reasoning from measurement or from hearsay.
public enum Credibility: String, Codable, Sendable {
    case measured       // derived from published measurement data
    case manufacturer   // vendor spec
    case community       // aggregated subjective consensus
    case estimated      // best-effort guess

    public var displayName: String {
        switch self {
        case .measured:     return "Measured"
        case .manufacturer: return "Manufacturer"
        case .community:    return "Community"
        case .estimated:    return "Estimated"
        }
    }
}

/// An inclusive frequency window in Hz.
public struct FrequencyRange: Codable, Equatable, Sendable {
    public var lowHz: Double
    public var highHz: Double
    public init(lowHz: Double, highHz: Double) {
        self.lowHz = lowHz
        self.highHz = highHz
    }
    public var centerHz: Double { sqrt(lowHz * highHz) }
}
