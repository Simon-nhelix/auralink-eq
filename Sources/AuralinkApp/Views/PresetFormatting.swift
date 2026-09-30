import AuralinkLocalization
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
        case .generic:    return L10n.text("Generic")
        case .baseline:   return L10n.text("Baseline")
        case .preference: return L10n.text("Preference")
        case .combined:   return L10n.text("Combined")
        }
    }

    /// Inline tag-pill form (lowercase) for the HeadphonePanelView preset row.
    static func roleTag(_ role: CorrectionRole) -> String {
        switch role {
        case .generic:    return L10n.text("generic")
        case .baseline:   return L10n.text("baseline")
        case .preference: return L10n.text("preference")
        case .combined:   return L10n.text("combined")
        }
    }

    // MARK: Headphone type labels

    static func typeLabel(_ type: HeadphoneType) -> String {
        switch type {
        case .openBack:     return L10n.text("Open-back")
        case .closedBack:   return L10n.text("Closed-back")
        case .iem:          return L10n.text("IEM")
        case .earbud:       return L10n.text("Earbud")
        case .onEar:        return L10n.text("On-ear")
        case .trueWireless: return L10n.text("True wireless")
        }
    }

    // MARK: Credibility tints

    static func credibilityTint(_ c: Credibility) -> Color {
        switch c {
        case .measured:     return Theme.Palette.success
        case .manufacturer: return Theme.Palette.info
        case .community:    return Theme.Palette.ai
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
