import SwiftUI
import CoreGraphics

/// Coordinate model for the EQ response graph.
///
/// X axis: logarithmic frequency, 20 Hz … 20 kHz.
/// Y axis: linear gain, +18 dB (top) … −18 dB (bottom).
///
/// All hit-testing and drawing go through `xFor(hz:)` / `yFor(db:)` (and their
/// inverses `hzFor(x:)` / `dbFor(y:)`) so the curve, the gridlines, and the
/// nodes stay perfectly aligned. Trivially unit-testable — no SwiftUI
/// dependencies.
enum EQGraphGeometry {
    // MARK: Axis constants

    static let minHz: Double = 20
    static let maxHz: Double = 20_000
    static let minDb: Double = -18
    static let maxDb: Double = 18

    /// Frequency gridlines (decade marks + a few helpers) and which get labels.
    static let freqGrid: [Double] = [20, 30, 50, 100, 200, 300, 500,
                                    1_000, 2_000, 3_000, 5_000,
                                    10_000, 20_000]
    static let freqLabels: [Double: String] = [
        100: "100", 1_000: "1k", 10_000: "10k", 20_000: "20k"
    ]
    static let dbGrid: [Double] = [-18, -12, -6, 0, 6, 12, 18]

    /// Inner plotting inset so axis labels have room and nodes never clip.
    static let inset = EdgeInsets(top: 42, leading: 34, bottom: 20, trailing: 14)

    // MARK: Plot rect

    /// Inner plotting rectangle: the area inside the axis insets.
    static func plotRect(in size: CGSize) -> CGRect {
        CGRect(
            x: inset.leading,
            y: inset.top,
            width: max(1, size.width - inset.leading - inset.trailing),
            height: max(1, size.height - inset.top - inset.bottom)
        )
    }

    // MARK: Forward maps (data → pixel)

    /// Frequency → x using a log10 mapping across the plot width.
    static func xFor(hz: Double, in plot: CGRect) -> CGFloat {
        let clamped = min(max(hz, minHz), maxHz)
        let t = (log10(clamped) - log10(minHz)) / (log10(maxHz) - log10(minHz))
        return plot.minX + CGFloat(t) * plot.width
    }

    /// dB → y (top = +18).
    static func yFor(db: Double, in plot: CGRect) -> CGFloat {
        let clamped = min(max(db, minDb), maxDb)
        let t = (clamped - minDb) / (maxDb - minDb)   // 0 at bottom, 1 at top
        return plot.maxY - CGFloat(t) * plot.height
    }

    // MARK: Inverse maps (pixel → data)

    /// x → frequency (inverse log map). Used while dragging a node horizontally.
    static func hzFor(x: CGFloat, in plot: CGRect) -> Double {
        let t = Double((x - plot.minX) / plot.width)
        let clampedT = min(max(t, 0), 1)
        let logHz = log10(minHz) + clampedT * (log10(maxHz) - log10(minHz))
        return pow(10, logHz)
    }

    /// y → dB (inverse). Used while dragging a node vertically.
    static func dbFor(y: CGFloat, in plot: CGRect) -> Double {
        let t = Double((plot.maxY - y) / plot.height)
        let clampedT = min(max(t, 0), 1)
        return minDb + clampedT * (maxDb - minDb)
    }
}
