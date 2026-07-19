import SwiftUI
import AuralinkCore

/// The full parametric editor shell.
///
/// Layout (per spec): a left/center column holding the top bar, the big EQ
/// response graph, and the 20-band parameter table; and a fixed-width right
/// rail that swaps between the Preset Library, the Headphone panel, and the AI
/// Tuning panel via a segmented control bound to `model.rightPanel`.
///
/// When the AI proposes a tuning (`model.pendingProposal != nil`) the whole
/// window is dimmed and the proposal review (`AIResultView`) floats on top, so
/// no write reaches live audio without the user seeing it first.
struct EditorWindow: View {
    @EnvironmentObject var model: AppModel

    private let rightRailWidth: CGFloat = 360

    var body: some View {
        ZStack {
            Theme.Palette.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                TopBarView()

                HStack(spacing: 0) {
                    mainColumn
                    Divider().overlay(Theme.Palette.line)
                    rightRail
                        .frame(width: rightRailWidth)
                }
            }

            if model.pendingProposal != nil {
                proposalOverlay
            }
        }
        .frame(
            minWidth: Theme.Metrics.editorMinWidth,
            minHeight: Theme.Metrics.editorMinHeight
        )
        .background(Theme.Palette.bg)
    }

    // MARK: Left / center column

    private var mainColumn: some View {
        VStack(spacing: 0) {
            TuneCommandBarView()

            Divider().overlay(Theme.Palette.line)

            VStack(spacing: Theme.Metrics.gap) {
                EQGraphView()
                    .frame(minHeight: 240, maxHeight: .infinity)

                BandTableView()
                    .frame(minHeight: 180, maxHeight: 320)
            }
            .padding(Theme.Metrics.pad)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Right rail (panel switcher)

    private var rightRail: some View {
        VStack(spacing: 0) {
            panelPicker
                .padding(.horizontal, Theme.Metrics.padSm)
                .padding(.vertical, 10)

            Divider().overlay(Theme.Palette.line)

            // The selected panel fills the remaining height.
            Group {
                switch model.rightPanel {
                case .presets:     PresetLibraryView()
                case .headphone:   HeadphonePanelView()
                case .aiTuning:    AITuningPanelView()
                case .diagnostics: DiagnosticsPanelView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .background(Theme.Palette.surface)
    }

    private var panelPicker: some View {
        HStack(spacing: 2) {
            ForEach(RightPanel.allCases) { panel in
                Button {
                    model.rightPanel = panel
                } label: {
                    VStack(spacing: 5) {
                        Image(systemName: icon(for: panel))
                            .font(.system(size: 13, weight: .medium))
                        Text(panel.title)
                            .font(Theme.Typo.caption)
                    }
                    .foregroundStyle(model.rightPanel == panel ? Theme.Palette.accent : Theme.Palette.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .overlay(alignment: .bottom) {
                        Rectangle()
                            .fill(model.rightPanel == panel ? Theme.Palette.accent : Color.clear)
                            .frame(height: 2)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func icon(for panel: RightPanel) -> String {
        switch panel {
        case .presets: return "folder"
        case .headphone: return "headphones"
        case .aiTuning: return "sparkles"
        case .diagnostics: return "waveform.path.ecg"
        }
    }

    // MARK: AI proposal overlay

    private var proposalOverlay: some View {
        ZStack {
            // Dimmed backdrop that swallows clicks behind the proposal.
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { /* modal: ignore taps outside */ }

            AIResultView()
                .frame(maxWidth: 460)
                .shadow(color: .black.opacity(0.5), radius: 30, y: 12)
        }
        .transition(.opacity)
    }
}

private struct TuneCommandBarView: View {
    @EnvironmentObject var model: AppModel
    @State private var command: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 0) {
                Image(systemName: "sparkles")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.Gradients.aura)
                    .frame(width: 38)

                TextField("Make vocals clearer with a little more kick", text: $command)
                    .textFieldStyle(.plain)
                    .font(Theme.Typo.body)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .onSubmit { tune() }
                    .padding(.vertical, 9)

                Button {
                    tune()
                } label: {
                    Label("Tune", systemImage: "sparkles")
                }
                .buttonStyle(AuraButtonStyle(role: .ai))
                .disabled(command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(5)
            .background(
                RoundedRectangle(cornerRadius: Theme.Metrics.radiusSm, style: .continuous)
                    .fill(Theme.Palette.surfaceHi)
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Metrics.radiusSm, style: .continuous)
                            .strokeBorder(Theme.Palette.line, lineWidth: 1)
                    )
            )

            HStack(spacing: 8) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.Palette.textTertiary)
                StatusDot(
                    color: model.systemOutputRoutedToAuralink ? Theme.Palette.success : Theme.Palette.warning,
                    label: model.systemOutputRoutedToAuralink
                        ? "Mac sound is going through Auralink"
                        : "Mac sound is direct"
                )
                Spacer(minLength: 0)
                Text("\(model.currentPreset.activeBands.count) active bands")
                    .font(Theme.Typo.caption)
                    .foregroundStyle(model.currentPreset.activeBands.isEmpty ? Theme.Palette.textTertiary : Theme.Palette.accent)
            }
        }
        .padding(.horizontal, Theme.Metrics.pad)
        .padding(.vertical, 10)
        .background(Theme.Palette.bg)
    }

    private func tune() {
        let text = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        model.tuneAndApply(command: text)
        command = ""
    }
}
