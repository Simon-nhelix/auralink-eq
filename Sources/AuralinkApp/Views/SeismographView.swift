import SwiftUI

/// Live "seismograph" for the audio path.
///
/// The trace idles as a calm line (the ring's real breathing — fill error in
/// frames, gently scaled) and *jumps* when a path event lands: each event
/// injects a tall decaying spike at its moment on the timeline, colored by
/// kind. Glance value: silence + flat line = the engine saw nothing; if you
/// heard a pop anyway, it happened outside the app.
///
/// Reads only `model.audioState` and `model.recentAudioEvents`. Driven by a
/// `TimelineView(.periodic(0.1))` so the canvas updates independent of the
/// outer view's redraw cycle.
struct SeismographView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    /// Seconds of history shown in the trace.
    var windowSeconds: Double = 120

    var body: some View {
        // Only the *active* branch holds a TimelineView, so when the app is
        // backgrounded (a menu-bar app's normal state) the 100 ms tick — and the
        // full redraw it drove of this view tree — stops entirely. SwiftUI keeps
        // a periodic TimelineView ticking as long as it stays in the hierarchy
        // (and on macOS a window can stay in-hierarchy while backgrounded), so
        // the only way to actually stop it is to drop the view out of the tree.
        // Millions of background redraws over a long session were landing on the
        // exact path this app was crashing on.
        Group {
            if scenePhase == .active {
                TimelineView(.periodic(from: .now, by: 0.1)) { timeline in
                    canvas(now: timeline.date)
                }
            } else {
                canvas(now: .now)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: Theme.Metrics.radius)
                .fill(Theme.Palette.bg)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Metrics.radius)
                .stroke(Theme.Palette.line, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.radius))
    }

    /// The trace canvas, factored out so the active and idle branches draw the
    /// same thing (idle just freezes it at the last render instead of ticking).
    @ViewBuilder
    private func canvas(now: Date) -> some View {
        Canvas { ctx, size in
            let plot = CGRect(origin: .zero, size: size)
            drawGrid(ctx, plot: plot, now: now)
            drawTrace(ctx, plot: plot, now: now)
            drawEventMarks(ctx, plot: plot, now: now)
        }
    }

    private func xPosition(for date: Date, now: Date, plot: CGRect) -> CGFloat {
        let age = now.timeIntervalSince(date)
        return plot.maxX - CGFloat(age / windowSeconds) * plot.width
    }

    private func drawGrid(_ ctx: GraphicsContext, plot: CGRect, now: Date) {
        // Center baseline.
        var base = Path()
        base.move(to: CGPoint(x: plot.minX, y: plot.midY))
        base.addLine(to: CGPoint(x: plot.maxX, y: plot.midY))
        ctx.stroke(base, with: .color(Theme.Palette.lineSoft), lineWidth: 1)

        // Time ticks every 30 s, anchored to the wall clock so they scroll.
        let tickInterval: Double = 30
        let firstAge = now.timeIntervalSince1970.truncatingRemainder(dividingBy: tickInterval)
        var age = firstAge
        while age <= windowSeconds {
            let x = plot.maxX - CGFloat(age / windowSeconds) * plot.width
            var tick = Path()
            tick.move(to: CGPoint(x: x, y: plot.minY))
            tick.addLine(to: CGPoint(x: x, y: plot.maxY))
            ctx.stroke(tick, with: .color(Theme.Palette.lineSoft), lineWidth: 1)
            age += tickInterval
        }
    }

    /// Trace value in [-1, 1]: gentle ring breathing + decaying event spikes.
    private func traceValue(at date: Date, fillError: Double, bufferFrames: Int) -> Double {
        // Breathing: one I/O chunk of error ≈ 6% of half-height. Calm by design.
        let chunk = Double(max(256, bufferFrames))
        var value = max(-0.25, min(0.25, fillError / chunk * 0.06))

        // Spikes: each event adds a tall pulse that decays over ~1.5 s.
        for event in model.recentAudioEvents {
            let dt = date.timeIntervalSince(event.at)
            guard dt >= 0, dt < 4 else { continue }
            value += Self.spikeAmplitude(for: event.kind) * exp(-dt / 0.5)
        }
        return max(-1, min(1, value))
    }

    private func drawTrace(_ ctx: GraphicsContext, plot: CGRect, now: Date) {
        let samples = model.diagSamples
        guard samples.count > 1 else {
            // No telemetry yet: a flat resting line.
            var flat = Path()
            flat.move(to: CGPoint(x: plot.minX, y: plot.midY))
            flat.addLine(to: CGPoint(x: plot.maxX, y: plot.midY))
            ctx.stroke(flat, with: .color(Theme.Palette.textTertiary.opacity(0.4)), lineWidth: 1.5)
            return
        }

        let halfHeight = plot.height * 0.46
        var line = Path()
        var started = false
        for sample in samples {
            let x = xPosition(for: sample.at, now: now, plot: plot)
            guard x >= plot.minX - 4 else { continue }
            let value = sample.running
                ? traceValue(at: sample.at, fillError: sample.fillError, bufferFrames: model.audioState.bufferFrames)
                : 0
            let y = plot.midY - CGFloat(value) * halfHeight
            if started {
                line.addLine(to: CGPoint(x: x, y: y))
            } else {
                line.move(to: CGPoint(x: x, y: y))
                started = true
            }
        }
        ctx.stroke(line, with: .color(Theme.Palette.accent), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))

        // Live "now" dot at the head of the trace.
        if let last = samples.last {
            let x = min(plot.maxX - 3, xPosition(for: last.at, now: now, plot: plot))
            let value = last.running
                ? traceValue(at: last.at, fillError: last.fillError, bufferFrames: model.audioState.bufferFrames)
                : 0
            let y = plot.midY - CGFloat(value) * halfHeight
            let dot = CGRect(x: x - 3, y: y - 3, width: 6, height: 6)
            ctx.fill(Path(ellipseIn: dot), with: .color(Theme.Palette.accent))
        }
    }

    private func drawEventMarks(_ ctx: GraphicsContext, plot: CGRect, now: Date) {
        for event in model.recentAudioEvents {
            let x = xPosition(for: event.at, now: now, plot: plot)
            guard x >= plot.minX, x <= plot.maxX else { continue }
            let color = Self.color(for: event.kind)
            let amplitude = Self.spikeAmplitude(for: event.kind)
            let apexY = plot.midY - CGFloat(min(1, amplitude)) * plot.height * 0.46

            let dot = CGRect(x: x - 3.5, y: apexY - 3.5, width: 7, height: 7)
            ctx.fill(Path(ellipseIn: dot), with: .color(color))

            // Label recent spikes so the jump is self-explaining for a while.
            if now.timeIntervalSince(event.at) < 30 {
                ctx.draw(
                    Text(event.kind).font(Theme.Typo.caption).foregroundStyle(color),
                    at: CGPoint(x: min(max(x, plot.minX + 28), plot.maxX - 28), y: max(plot.minY + 8, apexY - 12))
                )
            }
        }
    }

    /// Spike amplitude for an event kind. Keep in sync with kinds emitted by
    /// `AppModel.noteAudioEvent(kind:detail:)` and the engine's onPathIncident.
    static func spikeAmplitude(for kind: String) -> Double {
        switch kind {
        case "underrun":      return 1.0
        case "feedback-stop": return 1.0
        case "clip":          return 0.9
        case "overload":      return 0.9
        case "resync":        return 0.85
        case "capture-gap":   return 0.75
        case "recovery":      return 0.7
        case "repin":         return 0.5
        default:              return 0.6
        }
    }

    /// Color for an event kind. Keep in sync with `spikeAmplitude` so the
    /// trace and the incident row badge always match.
    static func color(for kind: String) -> Color {
        switch kind {
        case "underrun", "clip", "feedback-stop": return Theme.Palette.danger
        case "resync", "capture-gap":     return Theme.Palette.warning
        case "overload":                  return Theme.Palette.auraViolet
        case "recovery", "repin":         return Theme.Palette.auraBlue
        default:                          return Theme.Palette.textSecondary
        }
    }
}
