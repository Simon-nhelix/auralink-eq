import Foundation

/// Severity of a validation finding.
public enum ValidationSeverity: String, Codable, Sendable {
    case info
    case warning
    case error
}

/// One issue found while validating a preset.
public struct ValidationIssue: Codable, Equatable, Sendable {
    public var severity: ValidationSeverity
    public var message: String
    /// Band index this issue refers to, if any.
    public var bandIndex: Int?

    public init(severity: ValidationSeverity, message: String, bandIndex: Int? = nil) {
        self.severity = severity
        self.message = message
        self.bandIndex = bandIndex
    }
}

/// Result of running a preset through the safety validator.
///
/// `apply_eq_preset` should refuse (or require explicit override) when
/// `ok == false`. `suggestedPreampDb` is the auto-preamp the app applies when
/// `PresetSafety.autoGainEnabled` is on.
public struct ValidationResult: Codable, Equatable, Sendable {
    public var ok: Bool
    public var clippingRisk: ClippingRisk
    /// Worst-case summed boost (dB) across the response — the basis for preamp.
    public var estimatedPeakGainDb: Double
    /// Preamp (≤ 0 dB) that brings the estimated peak back under headroom.
    public var suggestedPreampDb: Double
    public var issues: [ValidationIssue]

    public init(
        ok: Bool,
        clippingRisk: ClippingRisk,
        estimatedPeakGainDb: Double,
        suggestedPreampDb: Double,
        issues: [ValidationIssue]
    ) {
        self.ok = ok
        self.clippingRisk = clippingRisk
        self.estimatedPeakGainDb = estimatedPeakGainDb
        self.suggestedPreampDb = suggestedPreampDb
        self.issues = issues
    }

    public var errors: [ValidationIssue] { issues.filter { $0.severity == .error } }
    public var warnings: [ValidationIssue] { issues.filter { $0.severity == .warning } }
}
