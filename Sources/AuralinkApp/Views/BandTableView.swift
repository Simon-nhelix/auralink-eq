import AuralinkLocalization
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
                Rectangle().fill(Theme.Palette.lineSoft).frame(height: 1)
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(spacing: 0) {
                        ForEach(model.currentPreset.bands) { band in
                            BandRow(band: band, selected: model.selectedBandIndex == band.index)
                                .background(rowBackground(for: band))
                                .contentShape(Rectangle())
                                .onTapGesture { model.selectedBandIndex = band.index }
                            Rectangle().fill(Theme.Palette.lineSoft).frame(height: 1)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 0) {
            cell(L10n.text("ON"), width: Columns.enabled)
            Spacer(minLength: 4)
            cell("#", width: Columns.index, align: .center)
            Spacer(minLength: 4)
            cell(L10n.text("TYPE"), width: Columns.type)
            Spacer(minLength: 4)
            cell(L10n.text("FREQ"), width: Columns.freq, align: .trailing)
            Spacer(minLength: 4)
            cell(L10n.text("GAIN"), width: Columns.gain, align: .trailing)
            Spacer(minLength: 4)
            cell(L10n.text("Q"), width: Columns.q, align: .trailing)
            Spacer(minLength: 4)
            cell(L10n.text("CH"), width: Columns.channel)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.Metrics.pad)
        .frame(height: 32)
    }

    private func cell(_ text: String, width: CGFloat, align: Alignment = .leading) -> some View {
        Text(text)
            .font(Theme.Typo.section)
            .tracking(0.5)
            .foregroundStyle(Theme.Palette.textTertiary)
            .frame(width: width, alignment: align)
    }

    private func rowBackground(for band: EQBand) -> some View {
        Rectangle()
            .fill(model.selectedBandIndex == band.index ? Theme.Palette.accentSoft : Color.clear)
    }

    /// Shared column widths so header + rows line up exactly.
    typealias Columns = Theme.Layout.BandTable
}

// MARK: - Row

/// A single editable band row. Reads its values from the band passed in and
/// commits every change through `AppModel`, so the graph and the engine update
/// in lockstep.
private struct BandRow: View {
    @EnvironmentObject var model: AppModel
    let band: EQBand
    /// The selected row shows its numeric fields as wells; other rows stay text.
    let selected: Bool

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
                .foregroundStyle(Theme.Palette.textTertiary)
                .frame(width: BandTableView.Columns.index, alignment: .center)

            Spacer(minLength: 4)

            // Type menu.
            Menu {
                ForEach(BandType.allCases, id: \.self) { t in
                    Button(L10n.text(t.displayName)) { commit { $0.type = t } }
                }
            } label: {
                HStack(spacing: 3) {
                    Text(L10n.text(band.type.displayName))
                        .font(Theme.Typo.body)
                        .foregroundStyle(textColor)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
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
                emphasized: selected,
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
                emphasized: selected,
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
                emphasized: selected,
                enabled: band.enabled
            ) { newValue in
                commit { $0.q = newValue }
            }

            Spacer(minLength: 4)

            // Channel menu. The dot sits outside the menu: a borderless menu
            // label renders only one image and one text.
            HStack(spacing: 7) {
                Circle()
                    .fill(tint(for: band.channel))
                    .frame(width: 7, height: 7)
                Menu {
                    ForEach(BandChannel.allCases, id: \.self) { ch in
                        Button(L10n.text(ch.displayName)) { commit { $0.channel = ch } }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(L10n.text(band.channel.displayName))
                            .font(Theme.Typo.body)
                            .foregroundStyle(textColor)
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(Theme.Palette.textTertiary)
                    }
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
            }
            .frame(width: BandTableView.Columns.channel, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.Metrics.pad)
        .frame(height: 34)
        .opacity(band.enabled ? 1.0 : 0.5)
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
        "\(L10n.text(type.qShortName)) \(Fmt.q(value))"
    }

    private func tint(for channel: BandChannel) -> Color {
        switch channel {
        case .stereo: return Theme.Palette.channelStereo
        case .left:   return Theme.Palette.channelLeft
        case .right:  return Theme.Palette.channelRight
        }
    }
}
