import AuralinkLocalization
import SwiftUI
import AppKit
import AuralinkCore

/// Auralink's primary, glanceable menu-bar workspace.
///
/// The default state keeps routing, the current tuning, safety, and quick AI
/// actions visible without scrolling. Selecting the tuning summary temporarily
/// replaces secondary content with a searchable headphone/preset chooser.
struct MenuBarView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var updates: UpdateModel
    @Environment(\.openWindow) private var openWindow

    @State private var tuningPickerExpanded = false
    @State private var browseAllHeadphones = false
    @State private var tuningQuery = ""
    @State private var tuneCommand = ""
    @State private var appearNonce = 0
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.gap) {
            header
            UpdateAvailableButton()

            if let notice = currentNotice {
                noticeView(notice)
            }

            routePanel
            tuningPanel
            compactControls

            if !tuningPickerExpanded {
                quickTune
                recentPresetsSection
            }

            footer
        }
        .padding(Theme.Metrics.pad)
        .frame(width: Theme.Layout.MenuBar.width)
        .background(Theme.Palette.bg)
        .background(
            GeometryReader { geometry in
                Color.clear.preference(
                    key: MenuBarContentHeightKey.self,
                    value: geometry.size.height
                )
            }
        )
        .onPreferenceChange(MenuBarContentHeightKey.self) { contentHeight = $0 }
        .background(MenuBarWindowAnchor(nonce: appearNonce, contentHeight: contentHeight))
        .onAppear { appearNonce &+= 1 }
        .onDisappear {
            tuningPickerExpanded = false
            browseAllHeadphones = false
            tuningQuery = ""
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            AuraWaveformMark()
                .frame(width: 18, height: 17)
            Text(L10n.text("Auralink EQ"))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.Palette.textPrimary)
            Spacer(minLength: 0)
            StatusDot(
                color: model.controlServerRunning ? Theme.Palette.success : Theme.Palette.danger,
                label: apiStatusLabel
            )
            overflowMenu
        }
        .frame(height: 28)
    }

    private var apiStatusLabel: String {
        if !model.controlServerRunning { return L10n.text("API off") }
        return model.audioState.mcpConnected ? L10n.text("AI linked") : L10n.text("API ready")
    }

    private var overflowMenu: some View {
        Menu {
            Button(L10n.text("Check for updates…"), systemImage: "arrow.down.app") {
                openWindow(id: "updates")
                updates.checkNow()
            }
            AppearancePicker()
            Divider()
            Button(L10n.text("Refresh audio setup"), systemImage: "arrow.clockwise") {
                model.refreshAudioSetup()
            }
            Button(L10n.text("Open setup guide"), systemImage: "book") {
                model.openSetupGuide()
            }
            Divider()
            Button(L10n.text("Reset EQ"), systemImage: "arrow.counterclockwise") {
                model.resetAll()
            }
            Button(
                model.measuredFIRRequested ? L10n.text("Disable Measured FIR") : L10n.text("Enable Measured FIR"),
                systemImage: "flask"
            ) {
                model.setHQCorrectionMode(!model.measuredFIRRequested)
            }
            .disabled(!model.measuredFIRRequestAllowed)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.Palette.textSecondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L10n.text("More Auralink controls"))
    }

    // MARK: Notice

    private struct MiniNotice {
        let text: String
        let isError: Bool
        let needsSetup: Bool
    }

    private var currentNotice: MiniNotice? {
        if let error = model.lastError {
            return MiniNotice(text: error, isError: true, needsSetup: false)
        }
        if model.needsVirtualDevice {
            return MiniNotice(
                text: model.loopbackDriverInstalled
                    ? L10n.text("Restart macOS to finish BlackHole setup.")
                    : L10n.text("BlackHole is required for system audio."),
                isError: false,
                needsSetup: true
            )
        }
        if let status = model.statusMessage {
            if status == AppModel.initialReadyMessage { return nil }
            return MiniNotice(text: status, isError: false, needsSetup: false)
        }
        return nil
    }

    private func noticeView(_ notice: MiniNotice) -> some View {
        let tint = notice.isError ? Theme.Palette.danger : Theme.Palette.warning
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: notice.isError ? "exclamationmark.octagon" : "info.circle")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(tint)
                .padding(.top, 1)
            Text(notice.text)
                .font(Theme.Typo.label.weight(.regular))
                .foregroundStyle(Theme.Palette.textPrimary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if notice.needsSetup {
                Button(L10n.text("Set Up")) { model.openSetupGuide() }
                    .buttonStyle(.plain)
                    .font(Theme.Typo.label.weight(.semibold))
                    .foregroundStyle(Theme.Palette.accent)
            } else {
                Button {
                    model.lastError = nil
                    model.statusMessage = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.Palette.textTertiary)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(tint.opacity(0.10))
        )
    }

    // MARK: Route

    private var routePanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                iconPlate(
                    model.systemEQActive ? "waveform" : "speaker.wave.2",
                    tint: model.systemEQActive ? Theme.Palette.success : Theme.Palette.textSecondary
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text(model.systemEQActive ? L10n.text("Mac sound processed") : L10n.text("Mac sound direct"))
                        .font(Theme.Typo.bodyStrong)
                        .foregroundStyle(Theme.Palette.textPrimary)
                    outputMenu
                }

                Spacer(minLength: 4)

                Button {
                    model.systemEQActive ? model.stopSystemEQ() : model.startSystemEQ()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: model.systemEQActive ? "stop.fill" : "play.fill")
                            .font(.system(size: 10))
                        Text(model.systemEQActive ? L10n.text("Stop System EQ") : L10n.text("Start System EQ"))
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
                .buttonStyle(AuraButtonStyle(prominent: !model.systemEQActive))
                .disabled(model.needsVirtualDevice && !model.systemEQActive)
                .opacity(model.needsVirtualDevice && !model.systemEQActive ? 0.45 : 1)
            }
            .padding(12)

            Rectangle().fill(Theme.Palette.lineSoft).frame(height: 1)

            HStack(spacing: 12) {
                PeakMeter(
                    peakDb: model.audioState.estimatedTruePeakDb,
                    clipping: model.audioState.clippingDetected
                )
                .frame(height: 3)
                Text(Fmt.dbtp(model.audioState.estimatedTruePeakDb))
                    .font(Theme.Typo.mono.weight(.regular))
                    .foregroundStyle(model.audioState.clippingDetected ? Theme.Palette.danger : Theme.Palette.textSecondary)
                StatusDot(
                    color: model.audioState.clippingDetected ? Theme.Palette.danger : Theme.Palette.success,
                    label: model.audioState.clippingDetected ? L10n.text("Clipping") : L10n.text("Clean")
                )
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .background(panelBackground)
    }

    private var outputMenu: some View {
        Menu {
            if model.outputPickerSnapshot.options.isEmpty {
                Text(L10n.text("No output devices"))
            }
            ForEach(model.outputPickerSnapshot.options) { option in
                Button {
                    model.selectOutputDevice(uid: option.uid)
                } label: {
                    Label(option.name, systemImage: option.isSelected ? "checkmark" : "hifispeaker")
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(model.outputPickerSnapshot.selectedName)
                    .font(Theme.Typo.label.weight(.regular))
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(maxWidth: 150, alignment: .leading)
    }

    /// 32-pt recessed plate holding a row's leading symbol.
    private func iconPlate(_ systemName: String, tint: Color) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: 32, height: 32)
            .background(
                RoundedRectangle(cornerRadius: Theme.Metrics.radiusSm, style: .continuous)
                    .fill(Theme.Palette.inset)
            )
    }

    // MARK: Current tuning + search

    private var tuningPanel: some View {
        VStack(spacing: 0) {
            Button {
                toggleTuningPicker()
            } label: {
                HStack(spacing: 10) {
                    iconPlate("headphones", tint: Theme.Palette.textSecondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(currentHeadphoneProfile?.displayName ?? L10n.text("Generic / Flat"))
                            .font(Theme.Typo.bodyStrong)
                            .foregroundStyle(Theme.Palette.textPrimary)
                            .lineLimit(1)
                        Text(compactPresetDetail(model.currentPreset))
                            .font(Theme.Typo.label.weight(.regular))
                            .foregroundStyle(Theme.Palette.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: tuningPickerExpanded ? "chevron.up" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(12)

            if tuningPickerExpanded {
                Rectangle().fill(Theme.Palette.lineSoft).frame(height: 1)
                tuningPicker
                    .transition(.opacity.combined(with: .move(edge: .top)))
            } else {
                Button {
                    openWindow(id: "editor")
                } label: {
                    MiniResponseGraphView(
                        curve: model.responseCurve,
                        bands: model.currentPreset.bands,
                        preampDb: model.currentPreset.preampDb
                    )
                    .frame(height: Theme.Layout.MenuBar.responseHeight + 16)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .help(L10n.text("Open the full response graph"))

                HStack {
                    StatusDot(
                        color: model.currentPreset.activeBands.isEmpty ? Theme.Palette.textTertiary : Theme.Palette.accent,
                        label: L10n.format("%lld bands", model.currentPreset.activeBands.count)
                    )
                    Spacer()
                    HStack(spacing: 4) {
                        Text(L10n.text("Preamp"))
                            .foregroundStyle(Theme.Palette.textSecondary)
                        Text(Fmt.db(model.currentPreset.preampDb))
                            .foregroundStyle(Theme.Palette.textPrimary)
                    }
                    .font(Theme.Typo.mono.weight(.regular))
                }
                .padding(.horizontal, 12)
                .padding(.top, 6)
                .padding(.bottom, 11)
            }
        }
        .background(panelBackground)
    }

    private var tuningPicker: some View {
        MiniTuningPickerView(
            query: $tuningQuery,
            browseAllHeadphones: $browseAllHeadphones,
            profiles: model.headphoneProfiles,
            presets: model.presets,
            currentProfile: currentHeadphoneProfile,
            currentPresetId: model.currentPreset.id,
            listHeight: tuningPickerListHeight,
            presetsForProfile: { model.presets(for: $0) },
            onSelectHeadphone: { profile in
                model.applyHeadphoneProfile(profile)
                closeTuningPicker()
            },
            onSelectPreset: { preset in
                model.load(preset: preset)
                closeTuningPicker()
            }
        )
    }

    /// Keep the headphone search list inside the visible screen when a status
    /// notice is also taking vertical space in the menubar popover.
    private var tuningPickerListHeight: CGFloat {
        // Reclaim roughly the notice banner height so opening search with a
        // notice present does not push the popover past the screen edges.
        let preferred = currentNotice == nil
            ? Theme.Layout.MenuBar.pickerHeight
            : Theme.Layout.MenuBar.pickerCompactHeight
        let screenHeight = NSScreen.main?.visibleFrame.height ?? 900
        let noticeAllowance: CGFloat = currentNotice == nil ? 0 : 52
        // Everything in the expanded popover except the scrollable result list.
        let chrome: CGFloat = 390 + noticeAllowance
        return min(preferred, max(110, screenHeight - chrome - 8))
    }

    private var currentHeadphoneProfile: HeadphoneProfile? {
        model.headphoneProfile(named: model.currentPreset.headphone)
    }

    private func toggleTuningPicker() {
        withAnimation(.easeOut(duration: 0.16)) {
            tuningPickerExpanded.toggle()
            if !tuningPickerExpanded {
                tuningQuery = ""
                browseAllHeadphones = false
            }
        }
    }

    private func closeTuningPicker() {
        withAnimation(.easeOut(duration: 0.16)) {
            tuningPickerExpanded = false
            tuningQuery = ""
            browseAllHeadphones = false
        }
    }

    // MARK: Compact controls

    private var compactControls: some View {
        HStack(spacing: 0) {
            compactToggle(
                L10n.text("EQ"),
                isOn: Binding(
                    get: { model.audioState.eqEnabled },
                    set: { model.setEQEnabled($0) }
                )
            )
            cellDivider
            compactToggle(
                L10n.text("Safe"),
                isOn: Binding(
                    get: { model.audioState.safeMode },
                    set: { model.setSafeMode($0) }
                )
            )
            .help(model.safeModeStatusText)
            cellDivider
            compactToggle(
                L10n.text("FIR"),
                isOn: Binding(
                    get: { model.measuredFIRRequested },
                    set: { model.setHQCorrectionMode($0) }
                )
            )
            .disabled(!model.measuredFIRRequestAllowed)
            .opacity(model.measuredFIRRequestAllowed ? 1 : 0.45)
            .help(model.measuredFIRHelpText)
            cellDivider
            Button {
                model.toggleAB()
            } label: {
                HStack(spacing: 6) {
                    Text(model.comparingBefore ? L10n.text("Before") : L10n.text("A/B"))
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 10, weight: .medium))
                }
                .font(Theme.Typo.label)
                .foregroundStyle(model.comparingBefore ? Theme.Palette.accent : Theme.Palette.textSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(model.beforeSnapshot == nil)
            .opacity(model.beforeSnapshot == nil ? 0.45 : 1)
        }
        .frame(height: 40)
        .background(panelBackground)
    }

    private var cellDivider: some View {
        Rectangle()
            .fill(Theme.Palette.lineSoft)
            .frame(width: 1)
            .padding(.vertical, 10)
    }

    private func compactToggle(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(title)
                .font(Theme.Typo.label)
                .foregroundStyle(Theme.Palette.textPrimary)
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .tint(Theme.Palette.accent)
        .fixedSize()
        .frame(maxWidth: .infinity)
    }

    // MARK: Quick tune

    private var quickTune: some View {
        let canSubmit = !tuneCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.Palette.accent)
                MenuBarTextField(
                    text: $tuneCommand,
                    placeholder: L10n.text("Describe a sound change…"),
                    onSubmit: submitQuickTune
                )
                .frame(height: 20)
                .layoutPriority(1)
                Button(L10n.text("Tune")) { submitQuickTune() }
                    .buttonStyle(FieldActionButtonStyle(enabled: canSubmit))
                    // The AppKit field claims all spare width; keep the label whole.
                    .fixedSize()
                    .disabled(!canSubmit)
                    .help(L10n.text("Apply quick tuning"))
            }
            .padding(.leading, 12)
            .padding(.trailing, 5)
            .frame(height: 38)
            .background(PromptFieldBackground())

            HStack(spacing: 14) {
                Button(L10n.text("Warmer")) { model.makeWarmer() }
                Button(L10n.text("Reduce harshness")) { model.reduceHarshness() }
            }
            .buttonStyle(.plain)
            .font(Theme.Typo.label)
            .foregroundStyle(Theme.Palette.accent)
            .padding(.horizontal, 4)
            .disabled(model.isTuning)
            .opacity(model.isTuning ? 0.5 : 1)
        }
    }

    private func submitQuickTune() {
        let command = tuneCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return }
        model.tuneAndApply(command: command)
        tuneCommand = ""
    }

    // MARK: Recent presets

    @ViewBuilder
    private var recentPresetsSection: some View {
        let presets = recentPresets
        if !presets.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                SectionLabel(L10n.text("Recent"))
                    .padding(.horizontal, 4)
                    .padding(.bottom, 4)

                ForEach(Array(presets.prefix(2).enumerated()), id: \.element.id) { index, preset in
                    let parts = compactPresetParts(preset)
                    Button {
                        model.load(preset: preset)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "waveform")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.Palette.textTertiary)
                                .frame(width: 16)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(parts.title)
                                    .font(Theme.Typo.body.weight(.medium))
                                    .foregroundStyle(Theme.Palette.textPrimary)
                                    .lineLimit(1)
                                if let detail = parts.detail {
                                    Text(detail)
                                        .font(Theme.Typo.caption)
                                        .foregroundStyle(Theme.Palette.textTertiary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(Theme.Palette.textTertiary)
                        }
                        .padding(.horizontal, 8)
                        .frame(minHeight: 40)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(RecentRowButtonStyle())
                    .accessibilityLabel(L10n.format("Load recent preset %@: %@", String(index + 1), String(preset.name)))
                }
            }
        }
    }

    private var recentPresets: [EQPreset] {
        model.recentPresetIds
            .filter { $0 != model.currentPreset.id }
            .compactMap { id in model.presets.first(where: { $0.id == id }) }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                openWindow(id: "editor")
            } label: {
                Label(L10n.text("Full Editor"), systemImage: "slider.horizontal.3")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(AuraButtonStyle(prominent: false))

            Button {
                openWindow(id: "monitor")
            } label: {
                Label(L10n.text("Monitor"), systemImage: "waveform.path.ecg")
            }
            .buttonStyle(AuraButtonStyle(prominent: false))
        }
    }

    private var panelBackground: some View {
        RoundedRectangle(cornerRadius: Theme.Metrics.radius, style: .continuous)
            .fill(Theme.Palette.surface)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Metrics.radius, style: .continuous)
                    .strokeBorder(Theme.Palette.lineSoft, lineWidth: 1)
            )
    }

    /// Avoid repeating the headphone name in the preset detail line.
    private func compactPresetDetail(_ preset: EQPreset) -> String {
        compactPresetParts(preset).detail ?? compactTitle(preset.name, limit: 30)
    }

    private func compactPresetParts(_ preset: EQPreset) -> (title: String, detail: String?) {
        let rawName = preset.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let headphone = preset.headphone?.trimmingCharacters(in: .whitespacesAndNewlines),
              !headphone.isEmpty else {
            return (compactTitle(rawName, limit: 30), nil)
        }

        let detail = presetNameDetail(rawName, removing: headphone)
        return (
            compactTitle(headphone, limit: 28),
            detail.isEmpty ? nil : compactTitle(detail, limit: 30)
        )
    }

    private func presetNameDetail(_ name: String, removing headphone: String) -> String {
        guard name.localizedCaseInsensitiveContains(headphone),
              let range = name.range(of: headphone, options: [.caseInsensitive, .diacriticInsensitive]) else {
            return name
        }

        var detail = name
        detail.removeSubrange(range)
        return detail.trimmingCharacters(
            in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "-–—·:|"))
        )
    }

    private func compactTitle(_ title: String, limit: Int) -> String {
        guard title.count > limit else { return title }
        return "\(title.prefix(max(1, limit - 1)))…"
    }
}

// MARK: - Menu-bar window position guard

private struct MenuBarContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// Keeps `MenuBarExtra(.window)` pinned under the menu bar when its SwiftUI
/// content grows or shrinks (status notice dismiss, headphone search expand).
/// Without this, macOS often leaves the window bottom-fixed so a shorter
/// layout floats with empty space above it, and a taller layout clips.
private struct MenuBarWindowAnchor: NSViewRepresentable {
    let nonce: Int
    let contentHeight: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ nsView: NSView, context: Context) {
        let heightChanged = abs(context.coordinator.lastHeight - contentHeight) > 0.5
        let appeared = context.coordinator.lastNonce != nonce
        guard appeared || heightChanged else { return }
        context.coordinator.lastNonce = nonce
        context.coordinator.lastHeight = contentHeight
        let preferredHeight = contentHeight
        // Wait until SwiftUI has committed layout; then pin using the measured
        // content height so a lagging MenuBarExtra frame cannot leave a gap.
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            Self.pinUnderMenuBar(
                window,
                preferredContentHeight: preferredHeight > 1 ? preferredHeight : nil,
                force: heightChanged
            )
        }
    }

    final class Coordinator {
        var lastNonce = -1
        var lastHeight: CGFloat = -1
    }

    private static func pinUnderMenuBar(
        _ window: NSWindow,
        preferredContentHeight: CGFloat?,
        force: Bool
    ) {
        let mouse = NSEvent.mouseLocation
        var screen: NSScreen?
        for candidate in NSScreen.screens where NSMouseInRect(mouse, candidate.frame, false) {
            screen = candidate
            break
        }
        screen = screen ?? window.screen ?? NSScreen.main
        guard let screen else { return }

        let visible = screen.visibleFrame
        var frame = window.frame
        if let preferredContentHeight {
            // Borderless MenuBarExtra windows track content size 1:1.
            frame.size.height = preferredContentHeight
        }
        let maxHeight = max(120, visible.height - 4)
        if frame.height > maxHeight {
            frame.size.height = maxHeight
        }

        let topGap = visible.maxY - frame.maxY
        let onActiveScreen = NSPointInRect(
            NSPoint(x: frame.midX, y: frame.maxY - 1),
            screen.frame
        )
        let sizeChanged = abs(frame.height - window.frame.height) > 0.5
        // Re-pin when floating below the bar, overflowing above it, off-screen,
        // resized, or after an explicit content-height change (notice / search).
        guard force || sizeChanged || topGap > 2 || topGap < -2 || !onActiveScreen else { return }

        let margin: CGFloat = 8
        var originX = mouse.x - frame.width / 2
        originX = min(max(originX, visible.minX + margin), visible.maxX - frame.width - margin)
        let pinnedY = visible.maxY - frame.height - 2
        frame.origin = NSPoint(x: originX, y: max(visible.minY + 2, pinnedY))
        window.setFrame(frame, display: true)
    }
}

/// Plain list row that highlights while hovered or pressed.
private struct RecentRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        RecentRow(configuration: configuration)
    }

    private struct RecentRow: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .background(
                    RoundedRectangle(cornerRadius: Theme.Metrics.radiusSm, style: .continuous)
                        .fill(hovering || configuration.isPressed ? Theme.Palette.lineSoft : Color.clear)
                )
                .onHover { hovering = $0 }
        }
    }
}
