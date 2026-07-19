import Foundation

/// The guardrails every AI-generated (and user-generated) preset is checked
/// against. Exposed to the AI as the `eq://safety-rules` resource so it tunes
/// *within* the rules instead of being rejected after the fact.
public struct SafetyRules: Codable, Equatable, Sendable {
    public var gainMinDb: Double
    public var gainMaxDb: Double
    public var qMin: Double
    public var qMax: Double
    /// Largest single-band boost the AI should propose without explicit user opt-in.
    public var maxBoostDb: Double
    /// Largest *summed* boost across overlapping bands before it's flagged.
    public var maxAggregateBoostDb: Double
    /// Estimated true-peak headroom (dB) we want to keep below 0 dBFS.
    public var targetHeadroomDb: Double
    /// When true, the validator proposes a preamp that offsets the peak boost.
    public var autoPreampEnabled: Bool

    public init(
        gainMinDb: Double = -18,
        gainMaxDb: Double = 18,
        qMin: Double = 0.1,
        qMax: Double = 10,
        maxBoostDb: Double = 6,
        maxAggregateBoostDb: Double = 9,
        targetHeadroomDb: Double = 1.0,
        autoPreampEnabled: Bool = true
    ) {
        self.gainMinDb = gainMinDb
        self.gainMaxDb = gainMaxDb
        self.qMin = qMin
        self.qMax = qMax
        self.maxBoostDb = maxBoostDb
        self.maxAggregateBoostDb = maxAggregateBoostDb
        self.targetHeadroomDb = targetHeadroomDb
        self.autoPreampEnabled = autoPreampEnabled
    }

    /// The shipped defaults. Loaded from `safety-rules.json` at runtime but this
    /// is the authoritative fallback.
    public static let `default` = SafetyRules()
}
