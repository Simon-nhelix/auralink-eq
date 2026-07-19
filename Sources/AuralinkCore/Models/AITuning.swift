import Foundation

/// A natural-language tuning request — the input to the (in-app heuristic or
/// external LLM) tuning flow. Mirrors the AI Tuning Panel inputs in the plan
/// (§6.3) and the `create_headphone_tuning` MCP prompt arguments.
public struct AITuningRequest: Codable, Equatable, Sendable {
    /// Headphone slug or display name, e.g. "sennheiser-hd600" / "Sennheiser HD600".
    public var headphone: String?
    /// Target curve slug, e.g. "rock", "vocal-focus". Optional if `goalText` set.
    public var targetCurveId: String?
    /// Free-text goal, e.g. "Rock — punchy kick, clear guitars, preserved vocals".
    public var goalText: String?
    /// Free-text preference, e.g. "keep vocals, brighter guitars, a bit more kick".
    public var preference: String?
    /// Hard ceiling on any single boost the tuner may propose (dB).
    public var maxBoostDb: Double?
    /// 0...1 strength for headphone/profile correction moves.
    public var correctionStrength: Double
    /// 0...1 blend/strength for target curve moves.
    public var targetBlend: Double
    /// If true, prefer cuts over boosts and avoid harsh-region energy.
    public var avoidHarshTreble: Bool

    public init(
        headphone: String? = nil,
        targetCurveId: String? = nil,
        goalText: String? = nil,
        preference: String? = nil,
        maxBoostDb: Double? = nil,
        correctionStrength: Double = 1,
        targetBlend: Double = 1,
        avoidHarshTreble: Bool = true
    ) {
        self.headphone = headphone
        self.targetCurveId = targetCurveId
        self.goalText = goalText
        self.preference = preference
        self.maxBoostDb = maxBoostDb
        self.correctionStrength = min(max(correctionStrength, 0), 1)
        self.targetBlend = min(max(targetBlend, 0), 1)
        self.avoidHarshTreble = avoidHarshTreble
    }
}

/// A single explained change between two presets, for the AI result screen
/// ("Changes: +2.5dB at 85Hz, Q 0.9" or shelf "Slope 0.7").
public struct TuningChange: Codable, Equatable, Sendable, Identifiable {
    public var id: Int { bandIndex }
    public var bandIndex: Int
    public var summary: String     // "+2.5 dB at 85 Hz, Q 0.9" / "Slope 0.7"
    public var rationale: String   // "Add punch to kick drum"
    public init(bandIndex: Int, summary: String, rationale: String) {
        self.bandIndex = bandIndex
        self.summary = summary
        self.rationale = rationale
    }
}

/// The output of a tuning flow: the proposed preset plus a human-readable
/// account of intent and changes, and the validation verdict. This is what the
/// AI result screen and the MCP `create_eq_preset` response present.
public struct TuningResult: Codable, Equatable, Sendable {
    public var preset: EQPreset
    /// Bullet intents, e.g. ["Add punch to kick drum", "Preserve vocal clarity"].
    public var intent: [String]
    public var changes: [TuningChange]
    public var validation: ValidationResult
    /// Profile/source attribution so the user can judge trust.
    public var basis: String

    public init(
        preset: EQPreset,
        intent: [String],
        changes: [TuningChange],
        validation: ValidationResult,
        basis: String = ""
    ) {
        self.preset = preset
        self.intent = intent
        self.changes = changes
        self.validation = validation
        self.basis = basis
    }
}
