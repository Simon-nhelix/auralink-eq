import AuralinkLocalization
import SwiftUI
import AuralinkCore

/// The full parametric editor shell.
///
/// Layout: a unified toolbar holding identity (brand, preset) and routing
/// (output, Start System EQ); a main column with the tune prompt, the EQ
/// response graph (whose header carries the controls that change the curve),
/// and the 20-band table; a fixed-width right rail that swaps between the
/// Preset Library, the Headphone panel, AI Tuning, and the Monitor; and a
/// quiet status bar with the audio-path readouts.
///
/// When the AI proposes a tuning (`model.pendingProposal != nil`) the whole
/// window is dimmed and the proposal review (`AIResultView`) floats on top, so
/// no write reaches live audio without the user seeing it first.
struct EditorWindow: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ZStack {
            Theme.Palette.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    mainColumn
                    rightRail
                        .frame(width: Theme.Layout.Editor.rightRailWidth)
                }
                EditorStatusBar()
            }

            if model.pendingProposal != nil {
                proposalOverlay
            }
        }
        .frame(
            minWidth: Theme.Layout.Editor.minWidth,
            minHeight: Theme.Layout.Editor.minHeight
        )
        .background(Theme.Palette.bg)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                EditorBrandAndPreset()
            }
            // With the window title hidden nothing separates the groups, so a
            // spacer item (a flexible space in a macOS toolbar) pushes routing
            // to the trailing edge.
            ToolbarItem(placement: .automatic) {
                Spacer()
            }
            ToolbarItem(placement: .automatic) {
                EditorRouteControls()
            }
        }
        .toolbarBackground(Theme.Palette.surface, for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
    }

    // MARK: Left / center column

    private var mainColumn: some View {
        VStack(spacing: Theme.Metrics.pad) {
            UpdateAvailableButton()
            TuneCommandBarView()

            EQGraphView()
                .frame(minHeight: Theme.Layout.Editor.graphMinHeight, maxHeight: .infinity)

            BandTableView()
                .frame(minHeight: Theme.Layout.Editor.bandTableMinHeight,
                       maxHeight: Theme.Layout.Editor.bandTableMaxHeight)
        }
        .padding(Theme.Metrics.padLg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Right rail (panel switcher)

    private var rightRail: some View {
        VStack(spacing: 0) {
            QuietSegmentedControl(
                options: RightPanel.allCases,
                selection: $model.rightPanel,
                title: { $0.title }
            )
            .padding(.horizontal, Theme.Metrics.padLg)
            .padding(.vertical, Theme.Metrics.pad)

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
        .background(
            Theme.Palette.surface
                .overlay(alignment: .leading) {
                    Rectangle().fill(Theme.Palette.lineSoft).frame(width: 1)
                }
        )
    }

    // MARK: AI proposal overlay

    private var proposalOverlay: some View {
        ZStack {
            // Dimmed backdrop that swallows clicks behind the proposal.
            Theme.Palette.modalScrim
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { /* modal: ignore taps outside */ }

            AIResultView(onEditManually: {
                guard let proposal = model.pendingProposal else { return }
                model.auditionTransientPreset(
                    proposal.preset,
                    message: L10n.format("Editing \"%@\" in the band table.", String(proposal.preset.name))
                )
                model.pendingProposal = nil
            })
                .frame(maxWidth: Theme.Layout.Proposal.editorMaxWidth)
                .shadow(color: Theme.Palette.modalShadow, radius: 30, y: 12)
        }
        .transition(.opacity)
    }
}

/// One-line natural-language tuning prompt above the graph.
private struct TuneCommandBarView: View {
    @EnvironmentObject var model: AppModel
    @State private var command: String = ""

    var body: some View {
        let canSubmit = !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.Palette.accent)

            TextField(L10n.text("Make vocals clearer with a little more kick"), text: $command)
                .textFieldStyle(.plain)
                .font(Theme.Typo.body)
                .foregroundStyle(Theme.Palette.textPrimary)
                .onSubmit { tune() }

            Button(L10n.text("Tune")) { tune() }
                .buttonStyle(FieldActionButtonStyle(enabled: canSubmit))
                .fixedSize()
                .disabled(!canSubmit)
        }
        .padding(.leading, 13)
        .padding(.trailing, 5)
        .frame(height: 40)
        .background(PromptFieldBackground())
    }

    private func tune() {
        let text = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        model.tuneAndApply(command: text)
        command = ""
    }
}
