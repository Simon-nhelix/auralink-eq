import SwiftUI

// Reusable building blocks shared across every screen. Keeps the menubar and
// the full editor visually consistent. All purely presentational.

/// Elevated rounded card with a faint top sheen and hairline border.
public struct AuraCard<Content: View>: View {
    var padding: CGFloat
    @ViewBuilder var content: Content
    public init(padding: CGFloat = Theme.Metrics.pad, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }
    public var body: some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: Theme.Metrics.radius, style: .continuous)
                    .fill(Theme.Palette.surfaceHi)
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Metrics.radius, style: .continuous)
                            .fill(Theme.Gradients.surfaceSheen)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Metrics.radius, style: .continuous)
                            .strokeBorder(Theme.Palette.lineSoft, lineWidth: 1)
                    )
            )
    }
}

/// Primary action button filled with the aura gradient.
public enum AuraButtonRole {
    case route
    case ai

    fileprivate var fill: AnyShapeStyle {
        switch self {
        case .route:
            return AnyShapeStyle(LinearGradient(
                colors: [Theme.Palette.auraCyan, Theme.Palette.auraBlue],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ))
        case .ai:
            return AnyShapeStyle(LinearGradient(
                colors: [Theme.Palette.auraViolet, Color(hex: 0x6C3ED7)],
                startPoint: .leading,
                endPoint: .trailing
            ))
        }
    }
}

public struct AuraButtonStyle: ButtonStyle {
    var prominent: Bool
    var role: AuraButtonRole

    public init(prominent: Bool = true, role: AuraButtonRole = .route) {
        self.prominent = prominent
        self.role = role
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Typo.label)
            .foregroundStyle(prominent ? Color.black.opacity(0.9) : Theme.Palette.textPrimary)
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(
                Group {
                    if prominent {
                        RoundedRectangle(cornerRadius: Theme.Metrics.radiusSm, style: .continuous)
                            .fill(role.fill)
                    } else {
                        RoundedRectangle(cornerRadius: Theme.Metrics.radiusSm, style: .continuous)
                            .fill(Theme.Palette.surfaceHi)
                            .overlay(RoundedRectangle(cornerRadius: Theme.Metrics.radiusSm, style: .continuous)
                                .strokeBorder(Theme.Palette.line, lineWidth: 1))
                    }
                }
            )
            .opacity(configuration.isPressed ? 0.75 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Small status dot + label (connection / clipping / routing indicators).
public struct StatusDot: View {
    var color: Color
    var label: String
    var glow: Bool
    public init(color: Color, label: String, glow: Bool = false) {
        self.color = color; self.label = label; self.glow = glow
    }
    public var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
                .shadow(color: glow ? color.opacity(0.8) : .clear, radius: glow ? 4 : 0)
            Text(label)
                .font(Theme.Typo.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
        }
    }
}

/// Section header used inside panels.
public struct SectionLabel: View {
    var text: String
    public init(_ text: String) { self.text = text }
    public var body: some View {
        Text(text.uppercased())
            .font(Theme.Typo.caption)
            .tracking(0.8)
            .foregroundStyle(Theme.Palette.textTertiary)
    }
}

/// A pill/tag (headphone, genre, channel).
public struct AuraTag: View {
    var text: String
    var tint: Color
    public init(_ text: String, tint: Color = Theme.Palette.accent) {
        self.text = text; self.tint = tint
    }
    public var body: some View {
        Text(text)
            .font(Theme.Typo.caption)
            .foregroundStyle(tint)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(
                Capsule().fill(tint.opacity(0.14))
                    .overlay(Capsule().strokeBorder(tint.opacity(0.30), lineWidth: 1))
            )
    }
}

/// Format helpers for numeric readouts.
public enum Fmt {
    public static func hz(_ v: Double) -> String {
        v >= 1000 ? String(format: "%.2f kHz", v / 1000) : String(format: "%.0f Hz", v)
    }
    public static func db(_ v: Double) -> String {
        String(format: "%+.1f dB", v)
    }
    public static func q(_ v: Double) -> String {
        String(format: "%.2f", v)
    }
}
