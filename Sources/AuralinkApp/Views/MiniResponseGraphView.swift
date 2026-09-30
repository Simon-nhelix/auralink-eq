import AuralinkLocalization
import SwiftUI
import AuralinkCore

/// Glanceable response preview for the menu-bar surface.
/// It uses the same live response data as the full editor and remains fully
/// code-native so preset and band changes are visible immediately. Like the
/// editor graph, the curve includes the preamp, so a dotted line marks it.
struct MiniResponseGraphView: View {
    let curve: [ResponsePoint]
    let bands: [EQBand]
    let preampDb: Double

    private let minimumDb = -12.0
    private let maximumDb = 12.0
    private let labelHeight: CGFloat = 16
    private let frequencyLabels: [(hz: Double, text: String)] = [
        (20, "20"), (100, "100"), (1_000, "1k"), (10_000, "10k"), (20_000, "20k")
    ]

    var body: some View {
        GeometryReader { geometry in
            let plot = CGRect(
                x: 0,
                y: 0,
                width: max(1, geometry.size.width),
                height: max(1, geometry.size.height - labelHeight)
            )

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: Theme.Metrics.radiusSm, style: .continuous)
                    .fill(Theme.Palette.inset)
                    .frame(width: plot.width, height: plot.height)

                Canvas { context, _ in
                    var plate = context
                    plate.clip(to: Path(roundedRect: plot, cornerRadius: Theme.Metrics.radiusSm))
                    drawGrid(plate, plot: plot)
                    drawPreampLine(plate, plot: plot)
                    drawCurve(plate, plot: plot)
                    drawLabels(context, plot: plot)
                }

                ForEach(bands.filter(\.enabled)) { band in
                    node(for: band, plot: plot)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.text("Mini frequency response"))
        .accessibilityValue(L10n.format("%lld active bands", bands.filter(\.enabled).count))
    }

    private func drawGrid(_ context: GraphicsContext, plot: CGRect) {
        for db in [-6.0, 0.0, 6.0] {
            var line = Path()
            let y = y(for: db, in: plot)
            line.move(to: CGPoint(x: plot.minX, y: y))
            line.addLine(to: CGPoint(x: plot.maxX, y: y))
            context.stroke(
                line,
                with: .color(db == 0 ? Theme.Palette.line : Theme.Palette.lineSoft),
                lineWidth: db == 0 ? 1.25 : 1
            )
        }

        for frequency in [50.0, 100.0, 200.0, 500.0, 1_000.0, 2_000.0, 5_000.0, 10_000.0] {
            var line = Path()
            let x = x(for: frequency, in: plot)
            line.move(to: CGPoint(x: x, y: plot.minY))
            line.addLine(to: CGPoint(x: x, y: plot.maxY))
            let isDecade = [100.0, 1_000.0, 10_000.0].contains(frequency)
            context.stroke(
                line,
                with: .color(isDecade ? Theme.Palette.line : Theme.Palette.lineSoft),
                lineWidth: 1
            )
        }
    }

    private func drawPreampLine(_ context: GraphicsContext, plot: CGRect) {
        guard abs(preampDb) >= 0.05 else { return }
        var line = Path()
        let y = y(for: preampDb, in: plot)
        line.move(to: CGPoint(x: plot.minX, y: y))
        line.addLine(to: CGPoint(x: plot.maxX, y: y))
        context.stroke(
            line,
            with: .color(Theme.Palette.textTertiary.opacity(0.8)),
            style: StrokeStyle(lineWidth: 1, dash: [2, 3])
        )
    }

    private func drawCurve(_ context: GraphicsContext, plot: CGRect) {
        guard !curve.isEmpty else { return }
        let points = curve.map {
            CGPoint(x: x(for: $0.frequencyHz, in: plot), y: y(for: $0.magnitudeDb, in: plot))
        }

        var stroke = Path()
        stroke.move(to: points[0])
        for point in points.dropFirst() {
            stroke.addLine(to: point)
        }

        var fill = stroke
        let baseline = y(for: preampDb, in: plot)
        if let first = points.first, let last = points.last {
            fill.addLine(to: CGPoint(x: last.x, y: baseline))
            fill.addLine(to: CGPoint(x: first.x, y: baseline))
            fill.closeSubpath()
        }

        context.fill(fill, with: .color(Theme.Palette.accent.opacity(0.08)))
        context.stroke(
            stroke,
            with: .color(Theme.Palette.accent),
            style: StrokeStyle(lineWidth: 1.75, lineCap: .round, lineJoin: .round)
        )
    }

    /// Frequency labels at their true log positions, end labels aligned inward.
    private func drawLabels(_ context: GraphicsContext, plot: CGRect) {
        for (offset, label) in frequencyLabels.enumerated() {
            let anchor: UnitPoint = offset == 0 ? .topLeading
                : offset == frequencyLabels.count - 1 ? .topTrailing
                : .top
            let text = Text(label.text)
                .font(Theme.Typo.micro)
                .foregroundStyle(Theme.Palette.textTertiary)
            context.draw(text, at: CGPoint(x: x(for: label.hz, in: plot), y: plot.maxY + 4), anchor: anchor)
        }
    }

    private func node(for band: EQBand, plot: CGRect) -> some View {
        let gain = band.type.usesGain ? band.gainDb : 0
        let tint = tint(for: band.channel)
        return ZStack {
            Circle()
                .fill(Theme.Palette.surface)
                .overlay(Circle().strokeBorder(tint, lineWidth: 1.5))
                .frame(width: 16, height: 16)
            Text("\(band.index)")
                .font(.system(size: 9, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(tint)
        }
        .position(
            x: min(max(x(for: band.frequencyHz, in: plot), plot.minX + 8), plot.maxX - 8),
            y: min(max(y(for: gain, in: plot), plot.minY + 8), plot.maxY - 8)
        )
    }

    private func tint(for channel: BandChannel) -> Color {
        switch channel {
        case .stereo: return Theme.Palette.channelStereo
        case .left:   return Theme.Palette.channelLeft
        case .right:  return Theme.Palette.channelRight
        }
    }

    private func x(for frequency: Double, in plot: CGRect) -> CGFloat {
        let clamped = min(max(frequency, 20), 20_000)
        let normalized = (log10(clamped) - log10(20)) / (log10(20_000) - log10(20))
        return plot.minX + plot.width * CGFloat(normalized)
    }

    private func y(for gain: Double, in plot: CGRect) -> CGFloat {
        let clamped = min(max(gain, minimumDb), maximumDb)
        let normalized = (maximumDb - clamped) / (maximumDb - minimumDb)
        return plot.minY + plot.height * CGFloat(normalized)
    }
}
