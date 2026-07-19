import SwiftUI
import AppKit

/// The Monitor in its own window: the same seismograph panel plus a
/// float-on-top toggle, so it can sit in a screen corner during long
/// listening sessions while other apps have focus.
struct MonitorWindowView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("auralink.monitorFloats") private var floatsOnTop = true

    var body: some View {
        DiagnosticsPanelView()
            .frame(minWidth: 480, minHeight: 380)
            .overlay(alignment: .topTrailing) {
                Toggle(isOn: $floatsOnTop) {
                    Text("Float on top").font(Theme.Typo.caption)
                }
                .toggleStyle(.checkbox)
                .foregroundStyle(Theme.Palette.textSecondary)
                .padding(.top, Theme.Metrics.pad)
                .padding(.trailing, Theme.Metrics.pad)
            }
            .background(Theme.Palette.bg)
            .background(WindowLevelAccessor(floating: floatsOnTop))
    }
}

/// Live "seismograph" for the audio path.
///
/// The trace idles as a calm line (the ring's real breathing — fill error in
/// frames, gently scaled) and *jumps* when a path event lands: each event
/// injects a tall decaying spike at its moment on the timeline, colored by
/// kind. Glance value: silence + flat line = the engine saw nothing; if you
/// heard a pop anyway, it happened outside the app.
///
/// Below the trace, dashcam-style incident reports: every event auto-captures
/// ±10 s of context into a compact text block with a Copy button, ready to
/// paste into a chat for analysis. Calm stretches are never recorded.
struct DiagnosticsPanelView: View {
    @EnvironmentObject var model: AppModel

    /// Seconds of history shown in the trace.
    private static let windowSeconds: Double = 120

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Metrics.gap) {
                SectionLabel("Path Monitor")
                SeismographView()
                    .frame(height: 140)
                legend
                statsRow

                SectionLabel("Incidents")
                incidentList
            }
            .padding(Theme.Metrics.pad)
        }
    }

    // MARK: Legend & stats

    private var legend: some View {
        HStack(spacing: 10) {
            legendDot("underrun / clip", Theme.Palette.danger)
            legendDot("resync / gap", Theme.Palette.warning)
            legendDot("recovery", Theme.Palette.auraBlue)
            Spacer()
            Text("last \(Int(Self.windowSeconds)) s")
                .font(Theme.Typo.caption)
                .foregroundStyle(Theme.Palette.textTertiary)
        }
    }

    private func legendDot(_ label: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label).font(Theme.Typo.caption).foregroundStyle(Theme.Palette.textSecondary)
        }
    }

    private var statsRow: some View {
        let state = model.audioState
        let columns = Array(repeating: GridItem(.flexible(minimum: 96), spacing: Theme.Metrics.gap), count: 3)
        return LazyVGrid(columns: columns, alignment: .leading, spacing: Theme.Metrics.gap) {
            statCell("Drift trim", String(format: "%+.0f ppm", model.diagSamples.last?.servoPpm ?? 0))
            statCell("Latency", String(format: "%.0f ms", state.latencyMs))
            statCell("Output", dbString(state.outputPeakDb))
            statCell("Output true", dbString(state.estimatedTruePeakDb))
            statCell("Pre true", dbString(state.preClipTruePeakDb ?? state.preClipPeakDb))
            statCell("Pre sample", dbString(state.preClipPeakDb))
            statCell("Clips", "\(state.clippingEventsTotal)")
            statCell("Underruns", "\(state.underrunsTotal)")
            statCell("Resyncs", "\(state.resyncsTotal)")
        }
    }

    private func dbString(_ value: Double) -> String {
        String(format: "%+.1f dB", max(value, -120))
    }

    private func statCell(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(Theme.Typo.caption)
                .foregroundStyle(Theme.Palette.textTertiary)
            Text(value)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.Palette.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Metrics.padSm)
        .background(
            RoundedRectangle(cornerRadius: Theme.Metrics.radiusSm)
                .fill(Theme.Palette.surfaceHi)
        )
    }

    // MARK: Incidents (dashcam captures)

    private var incidentList: some View {
        Group {
            if model.incidents.isEmpty {
                Text("No incidents captured. When an event fires, ±10 s of context is saved here automatically — copy it and share it for analysis.")
                    .font(Theme.Typo.caption)
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Theme.Metrics.padSm)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Metrics.radiusSm)
                            .fill(Theme.Palette.surfaceHi)
                    )
            } else {
                VStack(spacing: 6) {
                    ForEach(model.incidents.reversed()) { incident in
                        incidentRow(incident)
                    }
                }
            }
        }
    }

    private func incidentRow(_ incident: AppModel.AudioIncident) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Circle()
                    .fill(SeismographView.color(for: incident.kind.components(separatedBy: "+").first ?? incident.kind))
                    .frame(width: 6, height: 6)
                Text(incident.kind)
                    .font(Theme.Typo.label)
                    .foregroundStyle(Theme.Palette.textPrimary)
                Text(incident.at, style: .time)
                    .font(Theme.Typo.caption)
                    .foregroundStyle(Theme.Palette.textTertiary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(incident.report, forType: .string)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                        .font(Theme.Typo.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.Palette.accent)
            }
            Text(incident.report)
                .font(.system(size: 10))
                .foregroundStyle(Theme.Palette.textSecondary)
                .lineLimit(8)
                .textSelection(.enabled)
        }
        .padding(Theme.Metrics.padSm)
        .background(
            RoundedRectangle(cornerRadius: Theme.Metrics.radiusSm)
                .fill(Theme.Palette.surfaceHi)
        )
    }
}
