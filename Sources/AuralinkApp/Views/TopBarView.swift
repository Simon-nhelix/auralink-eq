import SwiftUI
import AuralinkCore

/// Studio-style command strip shared by the full editor.
///
/// The full-width layout keeps the current tuning and audio path readable while
/// preserving one obvious route action. A two-row fallback keeps the same
/// controls usable at the editor's minimum width.
struct TopBarView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ViewThatFits(in: .horizontal) {
            fullToolbar
            compactToolbar
        }
        // ViewThatFits only compares horizontal fit here. Without an explicit
        // vertical ideal size it can absorb spare height from EditorWindow's
        // VStack, leaving the controls centered in an oversized top bar.
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, Theme.Metrics.pad)
        .padding(.vertical, 10)
        .background(
            Theme.Palette.surface
                .overlay(alignment: .bottom) {
                    Rectangle().fill(Theme.Palette.line).frame(height: 1)
                }
        )
    }

    private var fullToolbar: some View {
        HStack(spacing: 12) {
            brandAndPreset
                .frame(minWidth: 300, alignment: .leading)
            Spacer(minLength: 4)
            audioPathCluster
            routingButton
            controlStrip
        }
        .frame(maxWidth: .infinity)
        .frame(height: 48)
    }

    private var compactToolbar: some View {
        VStack(spacing: 9) {
            HStack(spacing: 12) {
                brandAndPreset
                Spacer(minLength: 8)
                routingButton
            }
            HStack(spacing: 12) {
                audioPathCluster
                Spacer(minLength: 8)
                controlStrip
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var brandAndPreset: some View {
        HStack(spacing: 12) {
            AuraWaveformMark()
                .frame(width: 28, height: 20)
            Text("Auralink EQ")
                .font(Theme.Typo.title)
                .foregroundStyle(Theme.Palette.textPrimary)
                .fixedSize()
            Rectangle()
                .fill(Theme.Palette.line)
                .frame(width: 1, height: 30)
            Button {
                model.rightPanel = .presets
            } label: {
                HStack(spacing: 6) {
                    Text(model.currentPreset.name)
                        .font(Theme.Typo.label)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open the preset library")
        }
    }

    private var audioPathCluster: some View {
        HStack(spacing: 12) {
            outputMenu
            Rectangle()
                .fill(Theme.Palette.lineSoft)
                .frame(width: 1, height: 32)
            readout("Rate", String(format: "%.1f kHz", model.audioState.sampleRate / 1000))
            readout("Buffer", "\(model.audioState.bufferFrames)")
            readout("Latency", String(format: "%.1f ms", model.audioState.latencyMs))
            Rectangle()
                .fill(Theme.Palette.lineSoft)
                .frame(width: 1, height: 32)
            peakReadout
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: Theme.Metrics.radiusSm, style: .continuous)
                .fill(Theme.Palette.surfaceHi.opacity(0.72))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Metrics.radiusSm, style: .continuous)
                        .strokeBorder(Theme.Palette.line, lineWidth: 1)
                )
        )
        .frame(height: 44)
    }

    private var outputMenu: some View {
        Menu {
            ForEach(model.outputPickerSnapshot.options) { option in
                Button {
                    model.selectOutputDevice(uid: option.uid)
                } label: {
                    Label(option.name, systemImage: option.isSelected ? "checkmark" : "hifispeaker")
                }
            }
            if model.outputPickerSnapshot.options.isEmpty {
                Text("No devices")
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.Palette.textSecondary)
                Text(model.outputPickerSnapshot.selectedName)
                    .font(Theme.Typo.label)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 150, alignment: .leading)
    }

    private func readout(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .medium))
                .tracking(0.5)
                .foregroundStyle(Theme.Palette.textTertiary)
            Text(value)
                .font(Theme.Typo.mono)
                .foregroundStyle(Theme.Palette.textSecondary)
        }
        .fixedSize()
    }

    private var peakReadout: some View {
        let clipping = model.audioState.clippingDetected
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Text(peakLabel)
                    .font(Theme.Typo.mono)
                    .foregroundStyle(clipping ? Theme.Palette.danger : Theme.Palette.textSecondary)
                Circle()
                    .fill(clipping ? Theme.Palette.danger : Theme.Palette.success)
                    .frame(width: 6, height: 6)
                Text(clipping ? "Clipping" : "Clean")
                    .font(Theme.Typo.caption)
                    .foregroundStyle(clipping ? Theme.Palette.danger : Theme.Palette.textSecondary)
            }
            PeakMeter(peakDb: model.audioState.estimatedTruePeakDb, clipping: clipping)
                .frame(width: 100, height: 4)
        }
    }

    private var peakLabel: String {
        let value = model.audioState.estimatedTruePeakDb
        return value <= -120 ? "−∞ dBTP" : String(format: "%.1f dBTP", value)
    }

    private var routingButton: some View {
        Button {
            model.systemEQActive ? model.stopSystemEQ() : model.startSystemEQ()
        } label: {
            Label(
                model.systemEQActive ? "Stop System EQ" : "Start System EQ",
                systemImage: model.systemEQActive ? "stop.fill" : "play.fill"
            )
            .frame(minWidth: 112)
        }
        .buttonStyle(AuraButtonStyle(prominent: !model.systemEQActive, role: .route))
        .help("Start or stop system-wide EQ routing")
    }

    private var controlStrip: some View {
        HStack(spacing: 4) {
            eqToggle
            safeModeToggle
            abButton
            preampControl
            resetButton
            hqToggle
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: Theme.Metrics.radiusSm, style: .continuous)
                .fill(Theme.Palette.surfaceHi.opacity(0.55))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Metrics.radiusSm, style: .continuous)
                        .strokeBorder(Theme.Palette.lineSoft, lineWidth: 1)
                )
        )
    }

    private var eqToggle: some View {
        Toggle(isOn: Binding(
            get: { model.audioState.eqEnabled },
            set: { model.setEQEnabled($0) }
        )) {
            Label("EQ", systemImage: "slider.horizontal.3")
                .font(Theme.Typo.label)
        }
        .toggleStyle(StudioToggleStyle(onColor: Theme.Palette.accent))
        .help("Enable or bypass the equalizer")
    }

    private var safeModeToggle: some View {
        Toggle(isOn: Binding(
            get: { model.audioState.safeMode },
            set: { model.setSafeMode($0) }
        )) {
            Label("Safe", systemImage: "shield")
                .font(Theme.Typo.label)
        }
        .toggleStyle(StudioToggleStyle(onColor: Theme.Palette.success))
        .help(model.safeModeStatusText)
    }

    private var abButton: some View {
        Button {
            model.toggleAB()
        } label: {
            VStack(spacing: 2) {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 12, weight: .medium))
                Text(model.comparingBefore ? "Before" : "A/B")
                    .font(Theme.Typo.caption)
            }
            .frame(minWidth: 36)
        }
        .buttonStyle(StudioChromeButtonStyle(selected: model.comparingBefore))
        .disabled(model.beforeSnapshot == nil)
        .opacity(model.beforeSnapshot == nil ? 0.4 : 1)
    }

    private var preampControl: some View {
        VStack(spacing: 2) {
            Text("Preamp")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(Theme.Palette.textTertiary)
            Text(preampReadout)
                .font(Theme.Typo.mono)
                .foregroundStyle(Theme.Palette.textSecondary)
            Slider(
                value: Binding(
                    get: { model.currentPreset.preampDb },
                    set: { model.setPreamp($0) }
                ),
                in: EQPreset.preampRange.lowerBound...EQPreset.preampRange.upperBound
            )
            .controlSize(.mini)
            .tint(Theme.Palette.accent)
            .frame(width: 72)
        }
        .padding(.horizontal, 6)
        .help(model.preampStatusText)
    }

    private var preampReadout: String {
        if model.audioState.safeMode && model.safeModeGuardReductionDb < -0.05 {
            return Fmt.db(model.effectivePreampDb)
        }
        return Fmt.db(model.currentPreset.preampDb)
    }

    private var resetButton: some View {
        Button {
            model.resetAll()
        } label: {
            VStack(spacing: 2) {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 12, weight: .medium))
                Text("Reset")
                    .font(Theme.Typo.caption)
            }
            .frame(minWidth: 36)
        }
        .buttonStyle(StudioChromeButtonStyle())
    }

    private var hqToggle: some View {
        Toggle(isOn: Binding(
            get: { model.measuredFIRRequested },
            set: { model.setHQCorrectionMode($0) }
        )) {
            VStack(spacing: 2) {
                Image(systemName: "flask")
                    .font(.system(size: 12, weight: .medium))
                Text("FIR")
                    .font(Theme.Typo.caption)
            }
            .frame(minWidth: 40)
        }
        .toggleStyle(StudioToggleStyle(onColor: Theme.Palette.auraViolet))
        .disabled(!model.measuredFIRRequestAllowed)
        .opacity(model.measuredFIRRequestAllowed ? 1 : 0.5)
        .help(model.measuredFIRHelpText)
    }
}

private struct PeakMeter: View {
    let peakDb: Double
    let clipping: Bool

    var body: some View {
        GeometryReader { geometry in
            let level = max(0, min(1, (peakDb + 60) / 60))
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.Palette.line)
                Capsule()
                    .fill(clipping
                          ? AnyShapeStyle(Theme.Palette.danger)
                          : AnyShapeStyle(Theme.Gradients.aura))
                    .frame(width: geometry.size.width * CGFloat(level))
            }
        }
    }
}

private struct StudioToggleStyle: ToggleStyle {
    let onColor: Color

    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            configuration.label
                .foregroundStyle(configuration.isOn ? onColor : Theme.Palette.textSecondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(configuration.isOn ? onColor.opacity(0.12) : Color.clear)
                )
        }
        .buttonStyle(.plain)
    }
}

private struct StudioChromeButtonStyle: ButtonStyle {
    var selected = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(selected ? Theme.Palette.accent : Theme.Palette.textSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(selected ? Theme.Palette.accent.opacity(0.12) : Color.clear)
            )
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
