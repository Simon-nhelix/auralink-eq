import AppKit
import SwiftUI

/// Auralink's visual language — "quiet neutral".
///
/// Warm graphite and stone surfaces, one muted accent that stands in for the
/// audio signal, and tabular numeric readouts. Every color resolves per
/// appearance, so the app follows `AppearancePreference` (System, Light, Dark)
/// without views reading the color scheme themselves. Every view should pull
/// colors, type, and metrics from here so the menu bar and the full editor
/// feel like one product. Change shared styling here, screen dimensions in
/// `Layout`, and composition in the individual views.
public enum Theme {

    // MARK: Palette
    public enum Palette {
        // Surfaces, back to front.
        /// Window canvas.
        public static let bg            = dynamic(light: 0xF2F1ED, dark: 0x141413)
        /// Primary surface: bars, the right rail, cards on the canvas.
        public static let surface       = dynamic(light: 0xFAF9F6, dark: 0x1B1A18)
        /// Raised controls and cards drawn on top of a surface.
        public static let raised        = dynamic(light: 0xFFFFFF, dark: 0x242320)
        /// Recessed wells: fields, segmented-control tracks, icon plates.
        public static let inset         = dynamic(light: 0xEDEBE6, dark: 0x10100F)
        /// Hairline separators and control borders.
        public static let line          = dynamic(light: 0xE0DDD6, dark: 0x2F2D2A)
        /// Softer hairlines: card edges, minor grid lines, row dividers.
        public static let lineSoft      = dynamic(light: 0x1C1B19, dark: 0xFFFFFF, lightAlpha: 0.07, darkAlpha: 0.06)

        public static let textPrimary   = Color(nsColor: AppKitColors.textPrimary)
        public static let textSecondary = dynamic(light: 0x57544F, dark: 0xABA79F)
        public static let textTertiary  = Color(nsColor: AppKitColors.textTertiary)

        /// The one signal accent: the response curve, primary actions, selection.
        public static let accent        = dynamic(light: 0x396B83, dark: 0x8DB2C3)
        /// Tinted fill behind selected rows, active chips, and the curve area.
        public static let accentSoft    = dynamic(light: 0x396B83, dark: 0x8DB2C3, lightAlpha: 0.13, darkAlpha: 0.13)
        /// Foreground on accent-filled buttons.
        public static let textOnAccent  = dynamic(light: 0xFFFFFF, dark: 0x0E1416)

        public static let success       = dynamic(light: 0x3A7A50, dark: 0x85B894)
        public static let warning       = dynamic(light: 0x8E610F, dark: 0xD3A45A)
        public static let danger        = dynamic(light: 0xA9443A, dark: 0xDA7B71)
        /// Categorical tag tints (manufacturer data, headphone names, AI authorship).
        public static let info          = dynamic(light: 0x3462A3, dark: 0x7FA3D8)
        public static let ai            = dynamic(light: 0x5E5A9E, dark: 0xADA8D9)

        /// Per-channel band tints. Left and right differ in lightness as well as
        /// hue so they stay distinguishable without color vision.
        public static let channelStereo = accent
        public static let channelLeft   = info
        public static let channelRight  = dynamic(light: 0xB0612B, dark: 0xE0A877)

        public static let modalScrim    = dynamic(light: 0x000000, dark: 0x000000, lightAlpha: 0.22, darkAlpha: 0.55)
        public static let modalShadow   = dynamic(light: 0x000000, dark: 0x000000, lightAlpha: 0.16, darkAlpha: 0.5)

        private static func dynamic(
            light: UInt,
            dark: UInt,
            lightAlpha: CGFloat = 1,
            darkAlpha: CGFloat = 1
        ) -> Color {
            Color(nsColor: .auralinkDynamic(light: light, dark: dark, lightAlpha: lightAlpha, darkAlpha: darkAlpha))
        }
    }

    /// The few palette colors AppKit-bridged views need as `NSColor`.
    public enum AppKitColors {
        public static var textPrimary: NSColor { .auralinkDynamic(light: 0x1C1B19, dark: 0xECEAE4) }
        public static var textTertiary: NSColor { .auralinkDynamic(light: 0x6E6A63, dark: 0x8E8A82) }
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
        /// Card titles and primary row text.
        public static let bodyStrong = Font.system(size: 13, weight: .semibold)
        public static let label   = Font.system(size: 12, weight: .medium)
        public static let caption = Font.system(size: 11, weight: .regular)
        /// Small uppercase section and column headers.
        public static let section = Font.system(size: 11, weight: .semibold)
        /// Axis labels and other dense graph annotations.
        public static let micro   = Font.system(size: 10, weight: .regular)
        /// Tabular-digit readout for frequency / gain / Q or slope values, so
        /// numbers keep their width while they change.
        public static let mono    = Font.system(size: 12, weight: .medium).monospacedDigit()
        public static let monoLg  = Font.system(size: 13, weight: .medium).monospacedDigit()
    }

    // MARK: Metrics
    public enum Metrics {
        public static let radiusSm: CGFloat = 8
        public static let radius: CGFloat   = 12
        public static let radiusLg: CGFloat = 14
        /// Small controls inside a card: fields, chips, table cells.
        public static let radiusXs: CGFloat = 6
        public static let pad: CGFloat      = 14
        public static let padLg: CGFloat    = 16
        public static let padSm: CGFloat    = 8
        public static let gap: CGFloat      = 10
        public static let buttonPadHorizontal: CGFloat = 14
        public static let buttonPadVertical: CGFloat = 7
    }

    // MARK: Screen layout

    /// Screen dimensions are independent of general spacing and DSP limits.
    /// Keep a shared dimension here when multiple views must agree on it.
    public enum Layout {
        public enum MenuBar {
            public static let width: CGFloat = 380
            public static let responseHeight: CGFloat = 104
            public static let pickerHeight: CGFloat = 190
            public static let pickerCompactHeight: CGFloat = 138
        }

        public enum Editor {
            public static let minWidth: CGFloat = 1100
            public static let minHeight: CGFloat = 700
            public static let topBarHeight: CGFloat = 52
            public static let statusBarHeight: CGFloat = 28
            public static let graphHeaderHeight: CGFloat = 44
            public static let rightRailWidth: CGFloat = 360
            public static let graphMinHeight: CGFloat = 260
            public static let bandTableMinHeight: CGFloat = 180
            public static let bandTableMaxHeight: CGFloat = 320
        }

        /// Header and editable rows must use the same column widths.
        public enum BandTable {
            public static let enabled: CGFloat = 44
            public static let index: CGFloat = 32
            public static let type: CGFloat = 120
            public static let freq: CGFloat = 112
            public static let gain: CGFloat = 104
            public static let q: CGFloat = 96
            public static let channel: CGFloat = 104
        }

        public enum Monitor {
            public static let minWidth: CGFloat = 480
            public static let minHeight: CGFloat = 380
            public static let defaultWidth: CGFloat = 540
            public static let defaultHeight: CGFloat = 460
            public static let traceHeight: CGFloat = 140
        }

        public enum Proposal {
            public static let maxWidth: CGFloat = 540
            public static let editorMaxWidth: CGFloat = 460
            public static let permissionWidth: CGFloat = 420
            public static let contentMaxHeight: CGFloat = 320
        }
    }
}

// MARK: - Color helpers
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

public extension NSColor {
    /// A color that resolves to `light` or `dark` for the drawing appearance,
    /// including the high-contrast variants of each.
    static func auralinkDynamic(
        light: UInt,
        dark: UInt,
        lightAlpha: CGFloat = 1,
        darkAlpha: CGFloat = 1
    ) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(auralinkHex: isDark ? dark : light, alpha: isDark ? darkAlpha : lightAlpha)
        }
    }

    convenience init(auralinkHex hex: UInt, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255.0,
            green: CGFloat((hex >> 8) & 0xFF) / 255.0,
            blue: CGFloat(hex & 0xFF) / 255.0,
            alpha: alpha
        )
    }
}
