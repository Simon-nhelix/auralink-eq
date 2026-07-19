import SwiftUI
import AuralinkCore

/// Glanceable response preview for the menu-bar surface.
/// It uses the same live response data as the full editor and remains fully
/// code-native so preset and band changes are visible immediately.
struct MiniResponseGraphView: View {
    let curve: [ResponsePoint]
    let bands: [EQBand]

    private let minimumDb = -12.0
    private let maximumDb = 12.0

    var body: some View {
        GeometryReader { geometry in
            let plot = CGRect(
                x: 8,
                y: 6,
                width: max(1, geometry.size.width - 16),
                height: max(1, geometry.size.height - 22)
            )

            ZStack {
                Canvas { context, _ in
                    drawGrid(context, plot: plot)
                    drawCurve(context, plot: plot)
                }

                ForEach(bands.filter(\.enabled)) { band in
                    node(for: band, plot: plot)
                }

                frequencyLabels
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Mini frequency response")
        .accessibilityValue("\(bands.filter(\.enabled).count) active bands")
    }

    private func drawGrid(_ context: GraphicsContext, plot: CGRect) {
        for db in [-12.0, -6.0, 0.0, 6.0, 12.0] {
            var line = Path()
            let y = y(for: db, in: plot)
            line.move(to: CGPoint(x: plot.minX, y: y))
            line.addLine(to: CGPoint(x: plot.maxX, y: y))
            context.stroke(
                line,
                with: .color(db == 0 ? Theme.Palette.line : Theme.Palette.lineSoft),
                lineWidth: db == 0 ? 1 : 0.6
            )
        }

        for frequency in [20.0, 50.0, 100.0, 200.0, 500.0, 1_000.0, 2_000.0, 5_000.0, 10_000.0, 20_000.0] {
            var line = Path()
            let x = x(for: frequency, in: plot)
            line.move(to: CGPoint(x: x, y: plot.minY))
            line.addLine(to: CGPoint(x: x, y: plot.maxY))
            context.stroke(line, with: .color(Theme.Palette.lineSoft), lineWidth: 0.6)
        }
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
        let baseline = y(for: 0, in: plot)
        if let first = points.first, let last = points.last {
            fill.addLine(to: CGPoint(x: last.x, y: baseline))
            fill.addLine(to: CGPoint(x: first.x, y: baseline))
            fill.closeSubpath()
        }

        context.fill(
            fill,
            with: .linearGradient(
                Gradient(colors: [
                    Theme.Palette.auraCyan.opacity(0.23),
                    Theme.Palette.auraViolet.opacity(0.08)
                ]),
                startPoint: CGPoint(x: plot.minX, y: plot.minY),
                endPoint: CGPoint(x: plot.maxX, y: plot.maxY)
            )
        )
        context.stroke(
            stroke,
            with: .linearGradient(
                Gradient(colors: [Theme.Palette.auraCyan, Theme.Palette.auraBlue, Theme.Palette.auraViolet]),
                startPoint: CGPoint(x: plot.minX, y: plot.midY),
                endPoint: CGPoint(x: plot.maxX, y: plot.midY)
            ),
            lineWidth: 2
        )
    }

    private func node(for band: EQBand, plot: CGRect) -> some View {
        let gain = band.type.usesGain ? band.gainDb : 0
        let tint = band.frequencyHz >= 2_000 ? Theme.Palette.auraViolet : Theme.Palette.auraCyan
        return ZStack {
            Circle()
                .fill(Theme.Palette.bg)
                .overlay(Circle().stroke(tint, lineWidth: 1.5))
                .frame(width: 19, height: 19)
            Text("\(band.index)")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(Theme.Palette.textPrimary)
        }
        .position(x: x(for: band.frequencyHz, in: plot), y: y(for: gain, in: plot))
    }

    private var frequencyLabels: some View {
        HStack {
            Text("20")
            Spacer()
            Text("200")
            Spacer()
            Text("1k")
            Spacer()
            Text("5k")
            Spacer()
            Text("20kHz")
        }
        .font(.system(size: 9, weight: .regular))
        .foregroundStyle(Theme.Palette.textTertiary)
        .padding(.horizontal, 8)
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
