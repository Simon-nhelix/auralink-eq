import AuralinkLocalization
import SwiftUI
import AuralinkCore

// The full editor's chrome: toolbar items, the graph control strip, and the
// bottom status bar. The toolbar keeps only identity and routing; controls that
// change the curve sit on the graph; technical readouts sit in the status bar.

/// Leading toolbar item: brand mark and the current preset, which opens the
/// preset library.
struct EditorBrandAndPreset: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                AuraWaveformMark()
                    .frame(width: 16, height: 15)
                Text(L10n.text("Auralink EQ"))
                    .font(Theme.Typo.headline)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .fixedSize()
            }
            Rectangle()
                .fill(Theme.Palette.line)
                .frame(width: 1, height: 18)
            Button {
                model.rightPanel = .presets
            } label: {
                HStack(spacing: 7) {
                    Text(model.currentPreset.name)
                        .font(Theme.Typo.body.weight(.medium))
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
                .frame(maxWidth: 420, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L10n.text("Open the preset library"))
        }
        .padding(.horizontal, 4)
    }
}

/// Trailing toolbar item: output device and the one routing action.
struct EditorRouteControls: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            outputMenu
            Button {
                model.systemEQActive ? model.stopSystemEQ() : model.startSystemEQ()
            } label: {
                Label(
                    model.systemEQActive ? L10n.text("Stop System EQ") : L10n.text("Start System EQ"),
                    systemImage: model.systemEQActive ? "stop.fill" : "play.fill"
                )
                .labelStyle(.titleAndIcon)
                .fixedSize()
            }
            .buttonStyle(AuraButtonStyle(prominent: !model.systemEQActive))
            .help(L10n.text("Start or stop system-wide EQ routing"))
        }
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
                Text(L10n.text("No devices"))
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "speaker.wave.2")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.Palette.textSecondary)
                Text(model.outputPickerSnapshot.selectedName)
                    .font(Theme.Typo.body)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .frame(maxWidth: 220)
            .background(
                RoundedRectangle(cornerRadius: Theme.Metrics.radiusSm, style: .continuous)
                    .fill(Theme.Palette.inset)
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Metrics.radiusSm, style: .continuous)
                            .strokeBorder(Theme.Palette.lineSoft, lineWidth: 1)
                    )
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L10n.text("Output device"))
    }
}

/// EQ, Safe, A/B, Preamp, Reset, and Measured FIR: everything that changes
/// what the graph shows, placed in the graph header. `compact` drops the
/// preamp slider and button captions for the editor's minimum width.
struct GraphControlStrip: View {
    @EnvironmentObject private var model: AppModel
    var compact = false

    var body: some View {
        HStack(spacing: 12) {
            eqToggle
            safeModeToggle
            abButton
            divider
            preampControl
            divider
            resetButton
            firToggle
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(Theme.Palette.line)
            .frame(width: 1, height: 16)
    }

    private var eqToggle: some View {
        Toggle(isOn: Binding(
            get: { model.audioState.eqEnabled },
            set: { model.setEQEnabled($0) }
        )) {
            Text(L10n.text("EQ")).font(Theme.Typo.label)
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .tint(Theme.Palette.accent)
        .fixedSize()
        .help(L10n.text("Enable or bypass the equalizer"))
    }

    private var safeModeToggle: some View {
        Toggle(isOn: Binding(
            get: { model.audioState.safeMode },
            set: { model.setSafeMode($0) }
        )) {
            Text(L10n.text("Safe")).font(Theme.Typo.label)
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .tint(Theme.Palette.accent)
        .fixedSize()
        .help(model.safeModeStatusText)
    }

    private var abButton: some View {
        Button {
            model.toggleAB()
        } label: {
            HStack(spacing: 5) {
                Text(model.comparingBefore ? L10n.text("Before") : L10n.text("A/B"))
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 10, weight: .medium))
            }
        }
        .buttonStyle(QuietButtonStyle(selected: model.comparingBefore, bordered: true))
        .disabled(model.beforeSnapshot == nil)
        .opacity(model.beforeSnapshot == nil ? 0.45 : 1)
        .fixedSize()
    }

    private var preampControl: some View {
        HStack(spacing: 8) {
            Text(L10n.text("Preamp"))
                .font(Theme.Typo.label)
                .foregroundStyle(Theme.Palette.textPrimary)
            if !compact {
                Slider(
                    value: Binding(
                        get: { model.currentPreset.preampDb },
                        set: { model.setPreamp($0) }
                    ),
                    in: EQPreset.preampRange.lowerBound...EQPreset.preampRange.upperBound
                )
                .controlSize(.mini)
                .tint(Theme.Palette.accent)
                .frame(width: 88)
            }
            Text(preampReadout)
                .font(Theme.Typo.mono)
                .foregroundStyle(Theme.Palette.textPrimary)
                .frame(minWidth: 52, alignment: .trailing)
        }
        .fixedSize()
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
            HStack(spacing: 5) {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 11, weight: .medium))
                if !compact {
                    Text(L10n.text("Reset"))
                }
            }
        }
        .buttonStyle(QuietButtonStyle())
        .fixedSize()
        .help(L10n.text("Reset"))
    }

    private var firToggle: some View {
        Toggle(isOn: Binding(
            get: { model.measuredFIRRequested },
            set: { model.setHQCorrectionMode($0) }
        )) {
            Text(L10n.text("FIR")).font(Theme.Typo.label)
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .tint(Theme.Palette.accent)
        .fixedSize()
        .disabled(!model.measuredFIRRequestAllowed)
        .opacity(model.measuredFIRRequestAllowed ? 1 : 0.45)
        .help(model.measuredFIRHelpText)
    }
}

/// Quiet bottom bar: routing state and audio-path readouts on the left, band
/// count and output level on the right.
struct EditorStatusBar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 14) {
            StatusDot(
                color: model.systemOutputRoutedToAuralink ? Theme.Palette.success : Theme.Palette.warning,
                label: model.systemOutputRoutedToAuralink
                    ? L10n.text("Mac sound is going through Auralink")
                    : L10n.text("Mac sound is direct")
            )
            separator
            readout(L10n.text("Rate"), String(format: "%.1f kHz", model.audioState.sampleRate / 1000))
            readout(L10n.text("Buffer"), "\(model.audioState.bufferFrames)")
            readout(L10n.text("Latency"), String(format: "%.1f ms", model.audioState.latencyMs))

            Spacer(minLength: 8)

            Text(L10n.format("%lld active bands", model.currentPreset.activeBands.count))
                .foregroundStyle(Theme.Palette.textSecondary)
            separator
            PeakMeter(peakDb: model.audioState.estimatedTruePeakDb, clipping: clipping)
                .frame(width: 72, height: 3)
            Text(Fmt.dbtp(model.audioState.estimatedTruePeakDb))
                .monospacedDigit()
                .foregroundStyle(clipping ? Theme.Palette.danger : Theme.Palette.textSecondary)
            StatusDot(
                color: clipping ? Theme.Palette.danger : Theme.Palette.success,
                label: clipping ? L10n.text("Clipping") : L10n.text("Clean")
            )
        }
        .font(Theme.Typo.caption)
        .lineLimit(1)
        .padding(.horizontal, Theme.Metrics.padLg)
        .frame(height: Theme.Layout.Editor.statusBarHeight)
        .background(
            Theme.Palette.surface
                .overlay(alignment: .top) {
                    Rectangle().fill(Theme.Palette.lineSoft).frame(height: 1)
                }
        )
    }

    private var clipping: Bool { model.audioState.clippingDetected }

    private var separator: some View {
        Rectangle()
            .fill(Theme.Palette.line)
            .frame(width: 1, height: 12)
    }

    private func readout(_ label: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(Theme.Palette.textTertiary)
            Text(value)
                .monospacedDigit()
                .foregroundStyle(Theme.Palette.textSecondary)
        }
        .fixedSize()
    }
}
