import SwiftUI
import AuralinkCore

/// The centerpiece of the full editor: a live, log-frequency EQ response graph
/// with 20 draggable band nodes drawn over the filled "aura" response curve.
///
/// Coordinate model
/// ----------------
/// * X axis: logarithmic frequency, 20 Hz … 20 kHz.
/// * Y axis: linear gain, +18 dB (top) … −18 dB (bottom).
///
/// All hit-testing and drawing go through `EQGraphGeometry.xFor(hz:)` / `EQGraphGeometry.yFor(db:)` (and their
/// inverses) so the curve, the gridlines, and the nodes stay perfectly aligned.
/// Editing is committed back through `model.updateBand`, which re-derives
/// `model.responseCurve`, so the curve always reflects the true DSP magnitude.
struct EQGraphView: View {

    @EnvironmentObject var model: AppModel

    /// Drag-state for the band currently being manipulated. Captured on the
    /// first change of a gesture so deltas are measured from a stable origin.
    @State private var dragOrigin: EQBand? = nil
    @State private var hoverBandIndex: Int? = nil

    var body: some View {
        AuraCard(padding: 0) {
            GeometryReader { geo in
                let plot = EQGraphGeometry.plotRect(in: geo.size)
                ZStack {
                    // Background plate gradient for depth.
                    RoundedRectangle(cornerRadius: Theme.Metrics.radius, style: .continuous)
                        .fill(Theme.Palette.surface)

                    // The static grid + axis labels.
                    Canvas { ctx, _ in
                        drawGrid(ctx, plot: plot)
                    }

                    // The "before" comparison curve, drawn faintly behind.
                    if model.comparingBefore, let before = model.beforeSnapshot {
                        Canvas { ctx, _ in
                            drawBeforeCurve(ctx, preset: before, plot: plot)
                        }
                    }

                    // Baseline vs preference contribution, when the current preset
                    // was layered over a known baseline correction.
                    if let baseline = model.currentBaselinePreset {
                        Canvas { ctx, _ in
                            drawContributionCurves(ctx, baseline: baseline, plot: plot)
                        }
                    }

                    // The live aura response curve (fill + glow stroke).
                    Canvas { ctx, _ in
                        drawResponseCurve(ctx, plot: plot)
                    }

                    // Scroll-wheel catcher: adjusts the selected band's Q/slope.
                    ScrollQAdjuster { deltaY in
                        adjustSelectedQ(byScroll: deltaY)
                    }
                    .allowsHitTesting(true)

                    // Interactive node layer (drag / select / Q/slope via modifier-drag).
                    nodeLayer(plot: plot)
                }
                .contentShape(Rectangle())
                .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.radius, style: .continuous))
            }
        }
        .overlay(alignment: .topLeading) { headerOverlay }
        .frame(minHeight: 240)
    }

    // MARK: - Header chrome

    private var headerOverlay: some View {
        HStack(spacing: 8) {
            SectionLabel("Frequency Response")
            AuraTag(model.currentPreset.name, tint: Theme.Palette.auraBlue)
            AuraTag("\(model.currentPreset.activeBands.count) bands", tint: model.currentPreset.activeBands.isEmpty ? Theme.Palette.textTertiary : Theme.Palette.accent)
            if let role = model.currentCorrectionRoleText {
                AuraTag(role, tint: Theme.Palette.auraViolet)
            }
            Spacer()
            if model.comparingBefore {
                AuraTag("Comparing: Before", tint: Theme.Palette.warning)
            }
            if let i = model.selectedBandIndex,
               let band = band(at: i) {
                AuraTag("Band \(band.index) · \(Fmt.hz(band.frequencyHz)) · \(band.type.qShortName) \(Fmt.q(band.q))",
                        tint: tint(for: band.channel))
            }
        }
        .padding(.horizontal, Theme.Metrics.pad)
        .padding(.top, Theme.Metrics.padSm)
        .allowsHitTesting(false)
    }

    // MARK: - Grid

    private func drawGrid(_ ctx: GraphicsContext, plot: CGRect) {
        // Vertical frequency lines.
        for hz in EQGraphGeometry.freqGrid {
            let x = EQGraphGeometry.xFor(hz: hz, in: plot)
            var line = Path()
            line.move(to: CGPoint(x: x, y: plot.minY))
            line.addLine(to: CGPoint(x: x, y: plot.maxY))
            let isLabeled = EQGraphGeometry.freqLabels[hz] != nil
            ctx.stroke(
                line,
                with: .color(isLabeled ? Theme.Palette.line : Theme.Palette.lineSoft),
                lineWidth: 1
            )
            if let label = EQGraphGeometry.freqLabels[hz] {
                let text = Text(label)
                    .font(Theme.Typo.caption)
                    .foregroundStyle(Theme.Palette.textTertiary)
                ctx.draw(text, at: CGPoint(x: x, y: plot.maxY + 9), anchor: .center)
            }
        }

        // Horizontal dB lines.
        for db in EQGraphGeometry.dbGrid {
            let y = EQGraphGeometry.yFor(db: db, in: plot)
            var line = Path()
            line.move(to: CGPoint(x: plot.minX, y: y))
            line.addLine(to: CGPoint(x: plot.maxX, y: y))
            let isZero = db == 0
            ctx.stroke(
                line,
                with: .color(isZero ? Theme.Palette.line : Theme.Palette.lineSoft),
                lineWidth: isZero ? 1.4 : 1
            )
            let text = Text(db == 0 ? "0" : String(format: "%+d", Int(db)))
                .font(Theme.Typo.caption)
                .foregroundStyle(Theme.Palette.textTertiary)
            ctx.draw(text, at: CGPoint(x: plot.minX - 6, y: y), anchor: .trailing)
        }
    }

    // MARK: - Curves

    /// Builds a smooth path through the response points (using the supplied
    /// curve), returning both the open stroke path and a closed fill path down
    /// to the 0 dB baseline.
    private func curvePaths(from points: [ResponsePoint], plot: CGRect) -> (stroke: Path, fill: Path) {
        var stroke = Path()
        guard !points.isEmpty else { return (stroke, Path()) }

        let pts: [CGPoint] = points.map { p in
            CGPoint(x: EQGraphGeometry.xFor(hz: p.frequencyHz, in: plot),
                    y: EQGraphGeometry.yFor(db: p.magnitudeDb, in: plot))
        }

        stroke.move(to: pts[0])
        if pts.count == 1 {
            stroke.addLine(to: pts[0])
        } else {
            // Catmull-Rom → cubic Bézier for a smooth, anti-aliased curve.
            for i in 0..<(pts.count - 1) {
                let p0 = i == 0 ? pts[i] : pts[i - 1]
                let p1 = pts[i]
                let p2 = pts[i + 1]
                let p3 = (i + 2 < pts.count) ? pts[i + 2] : p2
                let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6.0,
                                 y: p1.y + (p2.y - p0.y) / 6.0)
                let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6.0,
                                 y: p2.y - (p3.y - p1.y) / 6.0)
                stroke.addCurve(to: p2, control1: c1, control2: c2)
            }
        }

        var fill = stroke
        let baseY = EQGraphGeometry.yFor(db: 0, in: plot)
        if let last = pts.last, let first = pts.first {
            fill.addLine(to: CGPoint(x: last.x, y: baseY))
            fill.addLine(to: CGPoint(x: first.x, y: baseY))
            fill.closeSubpath()
        }
        return (stroke, fill)
    }

    private func drawResponseCurve(_ ctx: GraphicsContext, plot: CGRect) {
        let (stroke, fill) = curvePaths(from: model.responseCurve, plot: plot)

        // Filled area under the curve.
        ctx.fill(fill, with: .linearGradient(
            Gradient(colors: [
                Theme.Palette.auraCyan.opacity(0.28),
                Theme.Palette.auraViolet.opacity(0.02)
            ]),
            startPoint: CGPoint(x: plot.midX, y: plot.minY),
            endPoint: CGPoint(x: plot.midX, y: plot.maxY)
        ))

        // Glow pass: a wide, soft, low-opacity stroke behind the crisp line.
        var glow = ctx
        glow.addFilter(.blur(radius: 6))
        glow.stroke(stroke, with: .linearGradient(
            Gradient(colors: [Theme.Palette.auraCyan, Theme.Palette.auraBlue, Theme.Palette.auraViolet]),
            startPoint: CGPoint(x: plot.minX, y: plot.midY),
            endPoint: CGPoint(x: plot.maxX, y: plot.midY)
        ), lineWidth: 6)

        // Crisp aura stroke.
        ctx.stroke(stroke, with: .linearGradient(
            Gradient(colors: [Theme.Palette.auraCyan, Theme.Palette.auraBlue, Theme.Palette.auraViolet]),
            startPoint: CGPoint(x: plot.minX, y: plot.midY),
            endPoint: CGPoint(x: plot.maxX, y: plot.midY)
        ), lineWidth: 2.2)
    }

    private func drawBeforeCurve(_ ctx: GraphicsContext, preset: EQPreset, plot: CGRect) {
        let frequencies = model.responseCurve.map(\.frequencyHz)
        let axis = frequencies.isEmpty ? FrequencyResponse.logFrequencies(count: 240) : frequencies
        let pts = FrequencyResponse.curve(
            for: preset,
            at: axis,
            sampleRate: model.audioState.sampleRate,
            renderMode: model.audioState.hqCorrectionMode ? .hqFIR : .standardIIR
        )
        let (stroke, _) = curvePaths(from: pts, plot: plot)
        ctx.stroke(
            stroke,
            with: .color(Theme.Palette.textSecondary.opacity(0.35)),
            style: StrokeStyle(lineWidth: 1.4, dash: [4, 4])
        )
    }

    private func drawContributionCurves(_ ctx: GraphicsContext, baseline: EQPreset, plot: CGRect) {
        let freqs = model.responseCurve.map(\.frequencyHz)
        let axis = freqs.isEmpty ? FrequencyResponse.logFrequencies(count: 240) : freqs
        let renderMode: EQRenderMode = model.audioState.hqCorrectionMode ? .hqFIR : .standardIIR
        let baselineCurve = FrequencyResponse.curve(
            for: baseline,
            at: axis,
            sampleRate: model.audioState.sampleRate,
            renderMode: renderMode
        )
        let currentCurve = model.responseCurve.isEmpty
            ? FrequencyResponse.curve(
                for: model.currentPreset,
                at: axis,
                sampleRate: model.audioState.sampleRate,
                renderMode: renderMode
            )
            : model.responseCurve

        let (baselineStroke, _) = curvePaths(from: baselineCurve, plot: plot)
        ctx.stroke(
            baselineStroke,
            with: .color(Theme.Palette.textSecondary.opacity(0.32)),
            style: StrokeStyle(lineWidth: 1.2, dash: [3, 5])
        )

        let count = min(axis.count, currentCurve.count, baselineCurve.count)
        guard count > 0 else { return }
        let deltaCurve = (0..<count).map { i in
            ResponsePoint(
                frequencyHz: axis[i],
                magnitudeDb: currentCurve[i].magnitudeDb - baselineCurve[i].magnitudeDb
            )
        }
        let (deltaStroke, _) = curvePaths(from: deltaCurve, plot: plot)
        ctx.stroke(
            deltaStroke,
            with: .color(Theme.Palette.warning.opacity(0.72)),
            style: StrokeStyle(lineWidth: 1.1, dash: [8, 4])
        )
    }

    // MARK: - Node layer

    private func nodeLayer(plot: CGRect) -> some View {
        ZStack {
            ForEach(model.currentPreset.bands) { band in
                nodeView(for: band, plot: plot)
            }
        }
    }

    @ViewBuilder
    private func nodeView(for band: EQBand, plot: CGRect) -> some View {
        let gainForY = band.type.usesGain ? band.gainDb : 0
        let pos = CGPoint(x: EQGraphGeometry.xFor(hz: band.frequencyHz, in: plot),
                          y: EQGraphGeometry.yFor(db: gainForY, in: plot))
        let isSelected = model.selectedBandIndex == band.index
        let isHover = hoverBandIndex == band.index
        let baseTint = tint(for: band.channel)
        let tintColor = band.enabled ? baseTint : Theme.Palette.textTertiary

        ZStack {
            // Outer selection / hover ring.
            Circle()
                .stroke(tintColor.opacity(isSelected ? 0.9 : (isHover ? 0.5 : 0.0)),
                        lineWidth: 2)
                .frame(width: 24, height: 24)

            // The node disc.
            Circle()
                .fill(tintColor.opacity(band.enabled ? 0.9 : 0.4))
                .frame(width: isSelected ? 15 : 12, height: isSelected ? 15 : 12)
                .overlay(
                    Circle().stroke(Color.black.opacity(0.35), lineWidth: 1)
                )
                .shadow(color: band.enabled ? tintColor.opacity(0.7) : .clear,
                        radius: isSelected ? 7 : 4)

            // Index label inside the node.
            Text("\(band.index)")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(Color.black.opacity(0.7))
        }
        .opacity(band.enabled ? 1.0 : 0.5)
        .position(pos)
        .contentShape(Circle().size(width: 28, height: 28).offset(x: pos.x - 14, y: pos.y - 14))
        .onHover { inside in
            hoverBandIndex = inside ? band.index : (hoverBandIndex == band.index ? nil : hoverBandIndex)
        }
        .gesture(dragGesture(for: band, plot: plot))
        .onTapGesture { model.selectedBandIndex = band.index }
    }

    /// Dragging a node: plain drag maps X→frequency and Y→gain. Holding Option
    /// turns vertical motion into a Q/slope adjustment instead (so users can
    /// shape bandwidth or shelf steepness right on the graph).
    private func dragGesture(for band: EQBand, plot: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if dragOrigin?.index != band.index {
                    dragOrigin = band
                    model.selectedBandIndex = band.index
                }
                guard let origin = dragOrigin else { return }
                var updated = origin

                if NSEvent.modifierFlags.contains(.option) {
                    // Modifier-drag → Q/slope. Up = sharper/steeper.
                    let dy = value.startLocation.y - value.location.y
                    let qRange = EQBand.qRange.upperBound - EQBand.qRange.lowerBound
                    let deltaQ = Double(dy / plot.height) * qRange
                    updated.q = origin.q + deltaQ
                } else {
                    // Free drag → frequency + gain.
                    updated.frequencyHz = EQGraphGeometry.hzFor(x: value.location.x, in: plot)
                    if updated.type.usesGain {
                        updated.gainDb = EQGraphGeometry.dbFor(y: value.location.y, in: plot)
                    }
                }
                model.updateBand(updated.clamped())
            }
            .onEnded { _ in
                dragOrigin = nil
            }
    }

    // MARK: - Scroll-to-Q/Slope

    /// Scrolling over the graph nudges the currently-selected band's Q/slope.
    /// Scroll up = sharper/steeper, scroll down = wider/gentler.
    private func adjustSelectedQ(byScroll deltaY: CGFloat) {
        guard let i = model.selectedBandIndex, var b = band(at: i) else { return }
        let step = Double(deltaY) * 0.02
        b.q += step
        model.updateBand(b.clamped())
    }

    private func tint(for channel: BandChannel) -> Color {
        switch channel {
        case .stereo: return Theme.Palette.nodeStereo
        case .left:   return Theme.Palette.nodeLeft
        case .right:  return Theme.Palette.nodeRight
        }
    }

    private func band(at index: Int) -> EQBand? {
        model.currentPreset.bands.first { $0.index == index }
    }
}
