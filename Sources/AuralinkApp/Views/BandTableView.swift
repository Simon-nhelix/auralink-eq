import SwiftUI
import AuralinkCore

/// The 20-row parametric-band table beneath the graph.
///
/// Each row mirrors one `EQBand` and edits it live through `model.updateBand`
/// (toggling enabled state goes through `model.setBandEnabled`). Numeric
/// columns use monospaced steppers + inline text entry so values stay precise.
/// The final shape column displays Q for bell/pass/notch filters and Slope for
/// shelves, while the stored preset field remains `q`.
struct BandTableView: View {

    @EnvironmentObject var model: AppModel

    var body: some View {
        AuraCard(padding: 0) {
            VStack(spacing: 0) {
                header
                Divider().overlay(Theme.Palette.line)
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(spacing: 0) {
                        ForEach(model.currentPreset.bands) { band in
                            BandRow(band: band)
                                .background(rowBackground(for: band))
                                .contentShape(Rectangle())
                                .onTapGesture { model.selectedBandIndex = band.index }
                            Divider().overlay(Theme.Palette.lineSoft)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 0) {
            cell("ON", width: Columns.enabled)
            Spacer(minLength: 4)
            cell("#", width: Columns.index, align: .center)
            Spacer(minLength: 4)
            cell("TYPE", width: Columns.type)
            Spacer(minLength: 4)
            cell("FREQ", width: Columns.freq, align: .trailing)
            Spacer(minLength: 4)
            cell("GAIN", width: Columns.gain, align: .trailing)
            Spacer(minLength: 4)
            cell("Q", width: Columns.q, align: .trailing)
            Spacer(minLength: 4)
            cell("CH", width: Columns.channel)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.Metrics.pad)
        .padding(.vertical, 8)
        .background(Theme.Palette.surface)
    }

    private func cell(_ text: String, width: CGFloat, align: Alignment = .leading) -> some View {
        Text(text)
            .font(Theme.Typo.caption)
            .tracking(0.6)
            .foregroundStyle(Theme.Palette.textTertiary)
            .frame(width: width, alignment: align)
    }

    private func rowBackground(for band: EQBand) -> some View {
        let selected = model.selectedBandIndex == band.index
        return Rectangle()
            .fill(selected ? Theme.Palette.accent.opacity(0.10) : Color.clear)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(selected ? Theme.Palette.accent : Color.clear)
                    .frame(width: 2)
            }
    }

    /// Shared column widths so header + rows line up exactly.
    enum Columns {
        static let enabled: CGFloat = 36
        static let index: CGFloat   = 28
        static let type: CGFloat    = 100
        static let freq: CGFloat    = 96
        static let gain: CGFloat    = 92
        static let q: CGFloat       = 78
        static let channel: CGFloat = 84
    }
}

// MARK: - Row

/// A single editable band row. Reads its values from the band passed in and
/// commits every change through `AppModel`, so the graph and the engine update
/// in lockstep.
private struct BandRow: View {
    @EnvironmentObject var model: AppModel
    let band: EQBand

    var body: some View {
        HStack(spacing: 0) {
            // Enabled toggle.
            Toggle("", isOn: Binding(
                get: { band.enabled },
                set: { model.setBandEnabled(band.index, $0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .tint(Theme.Palette.accent)
            .frame(width: BandTableView.Columns.enabled, alignment: .leading)

            Spacer(minLength: 4)

            // Index.
            Text("\(band.index)")
                .font(Theme.Typo.mono)
                .foregroundStyle(Theme.Palette.textSecondary)
                .frame(width: BandTableView.Columns.index, alignment: .center)

            Spacer(minLength: 4)

            // Type menu.
            Menu {
                ForEach(BandType.allCases, id: \.self) { t in
                    Button(t.displayName) { commit { $0.type = t } }
                }
            } label: {
                HStack(spacing: 3) {
                    Text(band.type.displayName)
                        .font(Theme.Typo.label)
                        .foregroundStyle(textColor)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: BandTableView.Columns.type, alignment: .leading)

            Spacer(minLength: 4)

            // Frequency.
            NumericField(
                value: band.frequencyHz,
                range: EQBand.frequencyRange,
                step: stepFor(hz: band.frequencyHz),
                format: { Fmt.hz($0) },
                width: BandTableView.Columns.freq,
                enabled: band.enabled
            ) { newValue in
                commit { $0.frequencyHz = newValue }
            }

            Spacer(minLength: 4)

            // Gain (hidden/dimmed for filter shapes that don't use gain).
            NumericField(
                value: band.gainDb,
                range: EQBand.gainRange,
                step: 0.5,
                format: { Fmt.db($0) },
                width: BandTableView.Columns.gain,
                enabled: band.enabled && band.type.usesGain
            ) { newValue in
                commit { $0.gainDb = newValue }
            }

            Spacer(minLength: 4)

            // Q / shelf slope.
            NumericField(
                value: band.q,
                range: EQBand.qRange,
                step: 0.1,
                format: { shapeFormat($0, for: band.type) },
                width: BandTableView.Columns.q,
                enabled: band.enabled
            ) { newValue in
                commit { $0.q = newValue }
            }

            Spacer(minLength: 4)

            // Channel menu.
            Menu {
                ForEach(BandChannel.allCases, id: \.self) { ch in
                    Button(ch.displayName) { commit { $0.channel = ch } }
                }
            } label: {
                HStack(spacing: 4) {
                    Circle()
                        .fill(tint(for: band.channel))
                        .frame(width: 7, height: 7)
                    Text(band.channel.displayName)
                        .font(Theme.Typo.label)
                        .foregroundStyle(textColor)
                        .lineLimit(1)
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: BandTableView.Columns.channel, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.Metrics.pad)
        .padding(.vertical, 5)
        .opacity(band.enabled ? 1.0 : 0.55)
    }

    private var textColor: Color {
        band.enabled ? Theme.Palette.textPrimary : Theme.Palette.textTertiary
    }

    /// Mutate a copy of this band and push it through the model.
    private func commit(_ mutate: (inout EQBand) -> Void) {
        var b = band
        mutate(&b)
        model.updateBand(b.clamped())
        model.selectedBandIndex = band.index
    }

    /// Frequency steps grow with magnitude so low bands move in fine Hz and high
    /// bands move in coarse kHz-ish increments.
    private func stepFor(hz: Double) -> Double {
        switch hz {
        case ..<100:    return 1
        case ..<1_000:  return 10
        case ..<10_000: return 100
        default:        return 500
        }
    }

    private func shapeFormat(_ value: Double, for type: BandType) -> String {
        "\(type.qShortName) \(Fmt.q(value))"
    }

    private func tint(for channel: BandChannel) -> Color {
        switch channel {
        case .stereo: return Theme.Palette.nodeStereo
        case .left:   return Theme.Palette.nodeLeft
        case .right:  return Theme.Palette.nodeRight
        }
    }
}
