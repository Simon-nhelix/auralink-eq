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
    @Environment(\.openWindow) private var openWindow

    @State private var tuningPickerExpanded = false
    @State private var browseAllHeadphones = false
    @State private var tuningQuery = ""
    @State private var tuneCommand = ""
    @State private var appearNonce = 0
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            header

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
        .padding(14)
        .frame(width: Theme.Metrics.popoverWidth)
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
                .frame(width: 28, height: 20)
            Text("Auralink EQ")
                .font(Theme.Typo.title)
                .foregroundStyle(Theme.Palette.textPrimary)
            Spacer(minLength: 0)
            StatusDot(
                color: model.controlServerRunning ? Theme.Palette.success : Theme.Palette.danger,
                label: apiStatusLabel,
                glow: model.audioState.mcpConnected
            )
            overflowMenu
        }
    }

    private var apiStatusLabel: String {
        if !model.controlServerRunning { return "API off" }
        return model.audioState.mcpConnected ? "AI linked" : "API ready"
    }

    private var overflowMenu: some View {
        Menu {
            Button("Refresh audio setup", systemImage: "arrow.clockwise") {
                model.refreshAudioSetup()
            }
            Button("Open setup guide", systemImage: "book") {
                model.openSetupGuide()
            }
            Divider()
            Button("Reset EQ", systemImage: "arrow.counterclockwise") {
                model.resetAll()
            }
            Button(
                model.measuredFIRRequested ? "Disable Measured FIR" : "Enable Measured FIR",
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
                .background(
                    Circle()
                        .fill(Theme.Palette.surfaceHi)
                        .overlay(Circle().strokeBorder(Theme.Palette.line, lineWidth: 1))
                )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help("More Auralink controls")
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
                    ? "Restart macOS to finish BlackHole setup."
                    : "BlackHole is required for system audio.",
                isError: false,
                needsSetup: true
            )
        }
        if let status = model.statusMessage {
            if status.hasPrefix("Auralink is ready.") { return nil }
            return MiniNotice(text: status, isError: false, needsSetup: false)
        }
        return nil
    }

    private func noticeView(_ notice: MiniNotice) -> some View {
        HStack(spacing: 8) {
            Image(systemName: notice.isError ? "exclamationmark.octagon.fill" : "info.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(notice.isError ? Theme.Palette.danger : Theme.Palette.warning)
            Text(notice.text)
                .font(Theme.Typo.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
                .lineLimit(2)
            Spacer(minLength: 4)
            if notice.needsSetup {
                Button("Set Up") { model.openSetupGuide() }
                    .buttonStyle(.plain)
                    .font(Theme.Typo.label)
                    .foregroundStyle(Theme.Palette.accent)
            } else {
                Button {
                    model.lastError = nil
                    model.statusMessage = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.Palette.textTertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: Theme.Metrics.radiusSm, style: .continuous)
                .fill((notice.isError ? Theme.Palette.danger : Theme.Palette.warning).opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Metrics.radiusSm, style: .continuous)
                        .strokeBorder((notice.isError ? Theme.Palette.danger : Theme.Palette.warning).opacity(0.25), lineWidth: 1)
                )
        )
    }

    // MARK: Route

    private var routePanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: model.systemEQActive ? "waveform" : "speaker.wave.2.fill")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(model.systemEQActive ? Theme.Palette.success : Theme.Palette.textSecondary)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 3) {
                    Text(model.systemEQActive ? "Mac sound processed" : "Mac sound direct")
                        .font(Theme.Typo.headline)
                        .foregroundStyle(Theme.Palette.textPrimary)
                    outputMenu
                }

                Spacer(minLength: 4)

                Button {
                    model.systemEQActive ? model.stopSystemEQ() : model.startSystemEQ()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: model.systemEQActive ? "stop.fill" : "play.fill")
                        Text(model.systemEQActive ? "Stop System EQ" : "Start System EQ")
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
                .buttonStyle(AuraButtonStyle(prominent: !model.systemEQActive, role: .route))
                .disabled(model.needsVirtualDevice && !model.systemEQActive)
                .opacity(model.needsVirtualDevice && !model.systemEQActive ? 0.45 : 1)
            }
            .padding(12)

            Divider().overlay(Theme.Palette.line)

            HStack(spacing: 9) {
                miniPeakMeter
                    .frame(height: 4)
                Text(peakLabel)
                    .font(Theme.Typo.mono)
                    .foregroundStyle(model.audioState.clippingDetected ? Theme.Palette.danger : Theme.Palette.textSecondary)
                StatusDot(
                    color: model.audioState.clippingDetected ? Theme.Palette.danger : Theme.Palette.success,
                    label: model.audioState.clippingDetected ? "Clipping" : "Clean"
                )
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
        }
        .background(panelBackground)
    }

    private var outputMenu: some View {
        Menu {
            if model.outputPickerSnapshot.options.isEmpty {
                Text("No output devices")
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
                    .font(Theme.Typo.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(maxWidth: 145, alignment: .leading)
    }

    private var miniPeakMeter: some View {
        GeometryReader { geometry in
            let level = max(0, min(1, (model.audioState.estimatedTruePeakDb + 60) / 60))
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.Palette.line)
                Capsule()
                    .fill(model.audioState.clippingDetected ? Theme.Palette.danger : Theme.Palette.accent)
                    .frame(width: geometry.size.width * CGFloat(level))
            }
        }
    }

    private var peakLabel: String {
        let value = model.audioState.estimatedTruePeakDb
        return value <= -120 ? "−∞ dBTP" : String(format: "%.1f dBTP", value)
    }

    // MARK: Current tuning + search

    private var tuningPanel: some View {
        VStack(spacing: 0) {
            Button {
                toggleTuningPicker()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "headphones")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(currentHeadphoneProfile?.displayName ?? "Generic / Flat")
                            .font(Theme.Typo.headline)
                            .foregroundStyle(Theme.Palette.textPrimary)
                            .lineLimit(1)
                        Text(compactPresetDetail(model.currentPreset))
                            .font(Theme.Typo.body)
                            .foregroundStyle(Theme.Palette.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: tuningPickerExpanded ? "chevron.up" : "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 8)

            if tuningPickerExpanded {
                Divider().overlay(Theme.Palette.line)
                tuningPicker
                    .transition(.opacity.combined(with: .move(edge: .top)))
            } else {
                Button {
                    openWindow(id: "editor")
                } label: {
                    MiniResponseGraphView(
                        curve: model.responseCurve,
                        bands: model.currentPreset.bands
                    )
                    .frame(height: 126)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open the full response graph")

                Divider().overlay(Theme.Palette.line)

                HStack {
                    StatusDot(
                        color: model.currentPreset.activeBands.isEmpty ? Theme.Palette.textTertiary : Theme.Palette.success,
                        label: "\(model.currentPreset.activeBands.count) bands"
                    )
                    Spacer()
                    Text(Fmt.db(model.currentPreset.preampDb))
                        .font(Theme.Typo.mono)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
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
        let preferred: CGFloat = currentNotice == nil ? 190 : 138
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
                "EQ",
                isOn: Binding(
                    get: { model.audioState.eqEnabled },
                    set: { model.setEQEnabled($0) }
                ),
                tint: Theme.Palette.accent
            )
            Divider().overlay(Theme.Palette.line).padding(.vertical, 8)
            compactToggle(
                "Safe",
                isOn: Binding(
                    get: { model.audioState.safeMode },
                    set: { model.setSafeMode($0) }
                ),
                tint: Theme.Palette.success
            )
            Divider().overlay(Theme.Palette.line).padding(.vertical, 8)
            compactToggle(
                "FIR",
                isOn: Binding(
                    get: { model.measuredFIRRequested },
                    set: { model.setHQCorrectionMode($0) }
                ),
                tint: Theme.Palette.auraViolet
            )
            .disabled(!model.measuredFIRRequestAllowed)
            .opacity(model.measuredFIRRequestAllowed ? 1 : 0.45)
            .help(model.measuredFIRHelpText)
            Divider().overlay(Theme.Palette.line).padding(.vertical, 8)
            Button {
                model.toggleAB()
            } label: {
                HStack(spacing: 6) {
                    Text(model.comparingBefore ? "Before" : "A/B")
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 10, weight: .medium))
                }
                .font(Theme.Typo.label)
                .foregroundStyle(model.comparingBefore ? Theme.Palette.accent : Theme.Palette.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
            }
            .buttonStyle(.plain)
            .disabled(model.beforeSnapshot == nil)
            .opacity(model.beforeSnapshot == nil ? 0.45 : 1)
        }
        .background(panelBackground)
    }

    private func compactToggle(
        _ title: String,
        isOn: Binding<Bool>,
        tint: Color
    ) -> some View {
        Toggle(isOn: isOn) {
            Text(title)
                .font(Theme.Typo.label)
                .foregroundStyle(Theme.Palette.textPrimary)
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .tint(tint)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 7)
    }

    // MARK: Quick tune

    private var quickTune: some View {
        let canSubmit = !tuneCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 0) {
                Image(systemName: "sparkles")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.Gradients.aura)
                    .frame(width: 34)
                MenuBarTextField(
                    text: $tuneCommand,
                    placeholder: "Describe a sound change…",
                    onSubmit: submitQuickTune
                )
                .frame(height: 20)
                .layoutPriority(1)
                Button {
                    submitQuickTune()
                } label: {
                    Text("Tune")
                        .font(Theme.Typo.label)
                        .foregroundStyle(canSubmit ? Theme.Palette.textPrimary : Theme.Palette.textTertiary)
                        .padding(.horizontal, 11)
                        .frame(height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Theme.Palette.surface)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .strokeBorder(
                                            canSubmit
                                                ? Theme.Palette.auraViolet.opacity(0.38)
                                                : Theme.Palette.line,
                                            lineWidth: 1
                                        )
                                )
                        )
                }
                .buttonStyle(.plain)
                .disabled(!canSubmit)
                .help("Apply quick tuning")
            }
            .padding(4)
            .background(
                RoundedRectangle(cornerRadius: Theme.Metrics.radiusSm, style: .continuous)
                    .fill(Theme.Palette.surfaceHi)
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Metrics.radiusSm, style: .continuous)
                            .strokeBorder(Theme.Palette.line, lineWidth: 1)
                    )
            )

            HStack(spacing: 12) {
                Button("Warmer") { model.makeWarmer() }
                Text("•").foregroundStyle(Theme.Palette.textTertiary)
                Button("Reduce harshness") { model.reduceHarshness() }
            }
            .buttonStyle(.plain)
            .font(Theme.Typo.label)
            .foregroundStyle(Theme.Palette.auraViolet)
            .padding(.horizontal, 8)
            .disabled(model.isTuning)
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
            VStack(spacing: 0) {
                HStack {
                    Text("Recent")
                        .font(Theme.Typo.body)
                        .foregroundStyle(Theme.Palette.textSecondary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 8)

                ForEach(Array(presets.prefix(2).enumerated()), id: \.element.id) { index, preset in
                    let parts = compactPresetParts(preset)
                    Divider().overlay(Theme.Palette.line)
                    Button {
                        model.load(preset: preset)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "waveform")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.Palette.textTertiary)
                                .frame(width: 18)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(parts.title)
                                    .font(Theme.Typo.label)
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
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(Theme.Palette.textTertiary)
                        }
                        .padding(.horizontal, 11)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Load recent preset \(index + 1): \(preset.name)")
                }
            }
            .background(panelBackground)
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
                Label("Full Editor", systemImage: "slider.horizontal.3")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(AuraButtonStyle(prominent: false))

            Button {
                openWindow(id: "monitor")
            } label: {
                Label("Monitor", systemImage: "waveform.path.ecg")
            }
            .buttonStyle(AuraButtonStyle(prominent: false))
        }
    }

    private var panelBackground: some View {
        RoundedRectangle(cornerRadius: Theme.Metrics.radius, style: .continuous)
            .fill(Theme.Palette.surface)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Metrics.radius, style: .continuous)
                    .strokeBorder(Theme.Palette.line, lineWidth: 1)
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

// MARK: - Aura waveform mark

struct AuraWaveformMark: View {
    var body: some View {
        GeometryReader { geometry in
            let heights: [CGFloat] = [0.30, 0.62, 0.95, 0.55, 0.80, 0.40]
            Theme.Gradients.aura
                .mask(
                    HStack(alignment: .center, spacing: max(1, geometry.size.width * 0.035)) {
                        ForEach(heights.indices, id: \.self) { index in
                            Capsule()
                                .frame(height: max(2, geometry.size.height * heights[index]))
                        }
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                )
        }
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
