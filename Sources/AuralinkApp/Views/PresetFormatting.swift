import SwiftUI
import AuralinkCore

/// Shared label/color/percent formatters for the preset / headphone / role
/// enums. Centralized so the views don't drift apart — the source of truth
/// for "what does a role look like in a tag pill" lives here, not in each
/// view.
enum PresetFormatting {

    // MARK: Role labels

    /// Display form for tags and meta rows (Title Case).
    static func roleLabel(_ role: CorrectionRole) -> String {
        switch role {
        case .generic:    return "Generic"
        case .baseline:   return "Baseline"
        case .preference: return "Preference"
        case .combined:   return "Combined"
        }
    }

    /// Inline tag-pill form (lowercase) for the HeadphonePanelView preset row.
    static func roleTag(_ role: CorrectionRole) -> String {
        switch role {
        case .generic:    return "generic"
        case .baseline:   return "baseline"
        case .preference: return "preference"
        case .combined:   return "combined"
        }
    }

    // MARK: Headphone type labels

    static func typeLabel(_ type: HeadphoneType) -> String {
        switch type {
        case .openBack:     return "Open-back"
        case .closedBack:   return "Closed-back"
        case .iem:          return "IEM"
        case .earbud:       return "Earbud"
        case .onEar:        return "On-ear"
        case .trueWireless: return "True wireless"
        }
    }

    // MARK: Credibility tints

    static func credibilityTint(_ c: Credibility) -> Color {
        switch c {
        case .measured:     return Theme.Palette.success
        case .manufacturer: return Theme.Palette.auraBlue
        case .community:    return Theme.Palette.auraViolet
        case .estimated:    return Theme.Palette.warning
        }
    }

    // MARK: Harsh-region label

    static func harshLabel(_ r: FrequencyRange) -> String {
        "\(Fmt.hz(r.lowHz))–\(Fmt.hz(r.highHz))"
    }

    // MARK: Percent

    /// `0.42` → `"42%"`. Used for correction-strength / target-blend sliders.
    static func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    // MARK: Preset menu icon

    /// SF Symbol name for a preset in the menubar command-palette picker.
    /// AI-created presets get a sparkle; user presets get a slider.
    static func presetMenuIcon(_ preset: EQPreset) -> String {
        preset.createdBy == .ai ? "sparkles" : "slider.horizontal.3"
    }
}
