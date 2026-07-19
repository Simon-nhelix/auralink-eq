import SwiftUI

/// Auralink's visual language — "an aurora over a dark studio".
///
/// Deep neutral graphite surfaces, a cyan→violet "aura" accent that stands in
/// for the audio signal, glassy elevated panels, and monospaced numeric
/// readouts for the pro-audio feel. Every view should pull colors, type, and
/// metrics from here so the menubar and the full editor feel like one product.
public enum Theme {

    // MARK: Palette
    public enum Palette {
        /// App canvas — near-black graphite with a faint blue cast.
        public static let bg            = Color(hex: 0x090C12)
        /// Primary surface (popover / panels).
        public static let surface       = Color(hex: 0x111722)
        /// Elevated surface (cards, the graph plate).
        public static let surfaceHi     = Color(hex: 0x18212D)
        /// Hairline separators / grid lines.
        public static let line          = Color(hex: 0x2A3443)
        public static let lineSoft      = Color(white: 1.0, opacity: 0.06)

        public static let textPrimary   = Color(hex: 0xEDF1F7)
        public static let textSecondary = Color(hex: 0x9AA6B8)
        public static let textTertiary  = Color(hex: 0x6A778B)

        // The "aura" — the signature signal gradient.
        public static let auraCyan      = Color(hex: 0x35C8FF)
        public static let auraBlue      = Color(hex: 0x4C8DFF)
        public static let auraViolet    = Color(hex: 0x8E62FF)

        public static let accent        = auraCyan
        public static let success       = Color(hex: 0x49E5A6)
        public static let warning       = Color(hex: 0xFFC24B)
        public static let danger        = Color(hex: 0xFF5C72)

        /// Per-channel band node tints.
        public static let nodeStereo    = auraCyan
        public static let nodeLeft      = Color(hex: 0x5B8CFF)
        public static let nodeRight     = Color(hex: 0xFF7AC6)
    }

    // MARK: Gradients
    public enum Gradients {
        /// Left→right aura used for the accent stroke / active controls.
        public static let aura = LinearGradient(
            colors: [Palette.auraCyan, Palette.auraBlue, Palette.auraViolet],
            startPoint: .leading, endPoint: .trailing
        )
        /// Vertical fill under the EQ curve.
        public static func curveFill(opacity: Double = 0.28) -> LinearGradient {
            LinearGradient(
                colors: [Palette.auraCyan.opacity(opacity), Palette.auraViolet.opacity(0.02)],
                startPoint: .top, endPoint: .bottom
            )
        }
        /// Subtle top-lit surface sheen for elevated cards.
        public static let surfaceSheen = LinearGradient(
            colors: [Color.white.opacity(0.05), Color.white.opacity(0.0)],
            startPoint: .top, endPoint: .bottom
        )
    }

    // MARK: Typography
    public enum Typo {
        // Avoid Font.Design (.rounded/.monospaced) on macOS 26: it routes through
        // the private DesignLibrary framework and can trigger the Swift 6.2/6.3
        // dynamic actor-isolation executor-check crash in SwiftUI view bodies.
        public static let titleXL = Font.system(size: 22, weight: .semibold)
        public static let title   = Font.system(size: 17, weight: .semibold)
        public static let headline = Font.system(size: 14, weight: .semibold)
        public static let body    = Font.system(size: 13, weight: .regular)
        public static let label   = Font.system(size: 12, weight: .medium)
        public static let caption = Font.system(size: 11, weight: .regular)
        /// Monospaced-digit readout for frequency / gain / Q or slope values.
        public static let mono    = Font.system(size: 12, weight: .medium)
        public static let monoLg  = Font.system(size: 15, weight: .semibold)
    }

    // MARK: Metrics
    public enum Metrics {
        public static let radiusSm: CGFloat = 8
        public static let radius: CGFloat   = 10
        public static let radiusLg: CGFloat = 14
        public static let pad: CGFloat      = 14
        public static let padSm: CGFloat    = 8
        public static let gap: CGFloat      = 10
        public static let popoverWidth: CGFloat = 380
        public static let editorMinWidth: CGFloat = 1100
        public static let editorMinHeight: CGFloat = 700
    }
}

// MARK: - Color hex helper
public extension Color {
    init(hex: UInt, opacity: Double = 1.0) {
        self.init(
            .sRGB,
            red:   Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8)  & 0xFF) / 255.0,
            blue:  Double(hex & 0xFF) / 255.0,
            opacity: opacity
        )
    }
}
