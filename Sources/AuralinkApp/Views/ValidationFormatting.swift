import SwiftUI
import AuralinkCore

/// Shared color/icon formatters for the validator enums (`ClippingRisk`,
/// `ValidationSeverity`). Centralized so the AI proposal card and the
/// permission dialog show identical visuals for the same severity.
enum ValidationFormatting {

    // MARK: Clipping risk tints

    static func riskTint(_ risk: ClippingRisk) -> Color {
        switch risk {
        case .low:    return Theme.Palette.success
        case .medium: return Theme.Palette.warning
        case .high:   return Theme.Palette.danger
        }
    }

    // MARK: Issue severity (icon + tint)

    static func issueIcon(_ severity: ValidationSeverity) -> String {
        switch severity {
        case .info:    return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error:   return "xmark.octagon.fill"
        }
    }

    static func issueTint(_ severity: ValidationSeverity) -> Color {
        switch severity {
        case .info:    return Theme.Palette.textSecondary
        case .warning: return Theme.Palette.warning
        case .error:   return Theme.Palette.danger
        }
    }
}
