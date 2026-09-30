import SwiftUI

// Reusable building blocks shared across every screen. Keeps the menubar and
// the full editor visually consistent. All purely presentational.

/// Rounded card with a hairline edge. Use the default `surface` fill on the
/// window canvas and `raised` for cards that sit on a surface (the right rail).
public struct AuraCard<Content: View>: View {
    var padding: CGFloat
    var fill: Color
    @ViewBuilder var content: Content
    public init(
        padding: CGFloat = Theme.Metrics.pad,
        fill: Color = Theme.Palette.surface,
        @ViewBuilder content: () -> Content
    ) {
        self.padding = padding
        self.fill = fill
        self.content = content()
    }
    public var body: some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: Theme.Metrics.radius, style: .continuous)
                    .fill(fill)
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Metrics.radius, style: .continuous)
                            .strokeBorder(Theme.Palette.lineSoft, lineWidth: 1)
                    )
            )
    }
}

/// Filled accent button for the primary action, or a raised bordered button
/// for secondary actions.
public struct AuraButtonStyle: ButtonStyle {
    var prominent: Bool

    public init(prominent: Bool = true) {
        self.prominent = prominent
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(prominent ? Theme.Typo.bodyStrong : Theme.Typo.body.weight(.medium))
            .foregroundStyle(prominent ? Theme.Palette.textOnAccent : Theme.Palette.textPrimary)
            .padding(.horizontal, Theme.Metrics.buttonPadHorizontal)
            .padding(.vertical, Theme.Metrics.buttonPadVertical)
            .background(
                RoundedRectangle(cornerRadius: Theme.Metrics.radiusSm, style: .continuous)
                    .fill(prominent ? Theme.Palette.accent : Theme.Palette.raised)
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Metrics.radiusSm, style: .continuous)
                            .strokeBorder(prominent ? Color.clear : Theme.Palette.line, lineWidth: 1)
                    )
            )
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Borderless text-and-icon button for quiet toolbar actions (Reset, A/B).
/// `selected` tints it with the accent for latched states such as "Before".
public struct QuietButtonStyle: ButtonStyle {
    var selected: Bool
    var bordered: Bool

    public init(selected: Bool = false, bordered: Bool = false) {
        self.selected = selected
        self.bordered = bordered
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Typo.label)
            .foregroundStyle(selected ? Theme.Palette.accent : Theme.Palette.textSecondary)
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(selected ? Theme.Palette.accentSoft : Color.clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(bordered && !selected ? Theme.Palette.line : Color.clear, lineWidth: 1)
                    )
            )
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// Neutral button that sits at the end of a text field (Tune).
public struct FieldActionButtonStyle: ButtonStyle {
    var enabled: Bool

    public init(enabled: Bool = true) {
        self.enabled = enabled
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Typo.label.weight(.semibold))
            .foregroundStyle(enabled ? Theme.Palette.textPrimary : Theme.Palette.textTertiary)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Theme.Palette.inset)
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(Theme.Palette.line, lineWidth: 1)
                    )
            )
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// The rounded, bordered well that holds a prompt field and its action.
struct PromptFieldBackground: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Theme.Palette.raised)
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Theme.Palette.line, lineWidth: 1)
            )
    }
}

/// A calm segmented control: a recessed track with the selected segment
/// raised. Used for the editor's right-rail panel switcher.
struct QuietSegmentedControl<Option: Hashable>: View {
    let options: [Option]
    @Binding var selection: Option
    let title: (Option) -> String

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                let isSelected = option == selection
                Button {
                    selection = option
                } label: {
                    Text(title(option))
                        .font(isSelected ? Theme.Typo.label.weight(.semibold) : Theme.Typo.label)
                        .foregroundStyle(isSelected ? Theme.Palette.textPrimary : Theme.Palette.textSecondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .frame(height: 26)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(isSelected ? Theme.Palette.raised : Color.clear)
                                .shadow(color: isSelected ? Color.black.opacity(0.10) : .clear, radius: 1, y: 1)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Theme.Palette.inset)
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Theme.Palette.lineSoft, lineWidth: 1)
                )
        )
    }
}

/// Shared brand mark for the menu bar and full editor: five accent bars.
struct AuraWaveformMark: View {
    var body: some View {
        GeometryReader { geometry in
            let heights: [CGFloat] = [0.35, 0.65, 1.0, 0.75, 0.45]
            let barWidth = max(2, geometry.size.width * 0.14)
            HStack(alignment: .center, spacing: max(1.5, geometry.size.width * 0.08)) {
                ForEach(heights.indices, id: \.self) { index in
                    Capsule()
                        .fill(Theme.Palette.accent)
                        .frame(width: barWidth, height: max(2, geometry.size.height * heights[index]))
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }
}

/// Small status dot + label (connection / clipping / routing indicators).
public struct StatusDot: View {
    var color: Color
    var label: String
    public init(color: Color, label: String) {
        self.color = color; self.label = label
    }
    public var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(label)
                .font(Theme.Typo.label.weight(.regular))
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
            .font(Theme.Typo.section)
            .tracking(0.6)
            .foregroundStyle(Theme.Palette.textTertiary)
    }
}

/// A small tinted tag (headphone, genre, role, credibility).
public struct AuraTag: View {
    var text: String
    var tint: Color
    public init(_ text: String, tint: Color = Theme.Palette.accent) {
        self.text = text; self.tint = tint
    }
    public var body: some View {
        Text(text)
            .font(Theme.Typo.caption.weight(.medium))
            .foregroundStyle(tint)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .frame(height: 20)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(tint.opacity(0.13))
            )
    }
}

// MARK: - Right-rail building blocks

/// Panel title at the top of a right-rail panel ("Presets", "Headphone").
struct RailPanelTitle: View {
    var text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(Theme.Typo.headline)
            .foregroundStyle(Theme.Palette.textPrimary)
    }
}

/// Small heading for a group of controls inside a rail panel.
struct RailSectionTitle: View {
    var text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(Theme.Typo.label.weight(.semibold))
            .foregroundStyle(Theme.Palette.textSecondary)
    }
}

/// Hairline between groups of controls in a rail panel.
struct RailDivider: View {
    var body: some View {
        Rectangle()
            .fill(Theme.Palette.lineSoft)
            .frame(height: 1)
    }
}

/// Recessed well behind rail text fields (search, preference).
struct RailFieldBackground: View {
    var body: some View {
        RoundedRectangle(cornerRadius: Theme.Metrics.radiusSm, style: .continuous)
            .fill(Theme.Palette.inset)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Metrics.radiusSm, style: .continuous)
                    .strokeBorder(Theme.Palette.lineSoft, lineWidth: 1)
            )
    }
}

/// List row in a rail panel: accent-tinted when selected, a faint highlight
/// while hovered, otherwise flat on the rail.
struct RailRowButtonStyle: ButtonStyle {
    var selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        RailRow(configuration: configuration, selected: selected)
    }

    private struct RailRow: View {
        let configuration: ButtonStyleConfiguration
        let selected: Bool
        @State private var hovering = false

        var body: some View {
            configuration.label
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Metrics.radiusSm, style: .continuous)
                        .fill(selected
                              ? Theme.Palette.accentSoft
                              : (hovering || configuration.isPressed ? Theme.Palette.lineSoft : Color.clear))
                )
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}

/// A thin level meter: dBTP mapped from −60…0 onto the track width.
struct PeakMeter: View {
    let peakDb: Double
    let clipping: Bool

    var body: some View {
        GeometryReader { geometry in
            let level = max(0, min(1, (peakDb + 60) / 60))
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.Palette.line)
                Capsule()
                    .fill(clipping ? Theme.Palette.danger : Theme.Palette.accent)
                    .frame(width: geometry.size.width * CGFloat(level))
            }
        }
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
    /// Estimated true peak, with the floor shown as −∞.
    public static func dbtp(_ v: Double) -> String {
        v <= -120 ? "−∞ dBTP" : String(format: "%.1f dBTP", v)
    }
}
