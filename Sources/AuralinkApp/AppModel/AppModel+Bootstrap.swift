import Foundation
import AuralinkCore

extension AppModel {
    // MARK: Lifecycle

    func bootstrap() {
        // Publish the bundled knowledge data to a stable on-disk location so the
        // external MCP server can read the same profiles/curves/rules the app uses.
        knowledge.seedDataDirectory(AuralinkPaths.dataDirectory)
        startFileWatchers()
        loadPresets()
        refreshDevices()
        ensureOutputSelection()
        let restoredDanglingOutput = restoreDanglingSystemOutputIfNeeded()
        restoreDanglingSystemInputIfNeeded()
        engine.onTelemetry = { [weak self] telemetry in
            Task { @MainActor in self?.ingest(telemetry: telemetry) }
        }
        engine.onConfigurationChange = { [weak self] in
            Task { @MainActor in
                self?.scheduleEngineRecovery(reason: "audio device configuration changed")
            }
        }
        engine.onPathIncident = { [weak self] kind, detail in
            Task { @MainActor in self?.noteAudioEvent(kind: kind, detail: detail) }
        }
        hardwareMonitor.onEvent = { [weak self] event in
            Task { @MainActor in self?.handleHardwareChange(event) }
        }
        hardwareMonitor.start()
        // Restore the preset from the previous session; fall back to unity for
        // a fresh install. Losing the user's EQ on every app update reads as
        // "the app forgot my sound".
        let lastId = UserDefaults.standard.string(forKey: Self.lastPresetDefaultsKey)
        if let lastId, let last = presets.first(where: { $0.id == lastId }) {
            load(preset: last, audition: false)
        } else if let flat = presets.first(where: { $0.id == "preset_flat" }) ?? presets.first {
            load(preset: flat, audition: false)
        }
        recomputeResponse()
        statusMessage = restoredDanglingOutput
            ?? "Auralink is ready. Audio routing is stopped until you start it."
    }

    func startFileWatchers() {
        presetsWatcher?.cancel()
        knowledgeWatcher?.cancel()

        presetsWatcher = makeDirectoryWatcher(url: AuralinkPaths.presetsDirectory) { [weak self] in
            Task { @MainActor in self?.schedulePresetReloadFromDisk() }
        }
        knowledgeWatcher = makeDirectoryWatcher(url: AuralinkPaths.dataDirectory) { [weak self] in
            Task { @MainActor in self?.scheduleKnowledgeReloadFromDisk() }
        }
    }

    func makeDirectoryWatcher(
        url: URL,
        onChange: @escaping @Sendable () -> Void
    ) -> DispatchSourceFileSystemObject? {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else {
            lastError = "Couldn't watch \(url.lastPathComponent) for MCP changes."
            return nil
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .extend, .attrib, .link, .revoke],
            queue: fileWatchQueue
        )
        source.setEventHandler(handler: onChange)
        source.setCancelHandler { close(fd) }
        source.resume()
        return source
    }

    func schedulePresetReloadFromDisk() {
        pendingPresetReload?.cancel()
        pendingPresetReload = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                self.loadPresets()
                self.statusMessage = "Preset library auto-refreshed."
            }
        }
    }

    func scheduleKnowledgeReloadFromDisk() {
        pendingKnowledgeReload?.cancel()
        pendingKnowledgeReload = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                _ = self.reloadKnowledge()
            }
        }
    }

    @discardableResult
    func reloadKnowledge() -> (profileCount: Int, targetCurveCount: Int) {
        let kb = KnowledgeBase(dataDirectory: AuralinkPaths.dataDirectory)
        let val = PresetValidator(rules: kb.safetyRules)
        self.knowledge = kb
        self.validator = val
        self.tuner = TuningEngine(knowledge: kb, validator: val)
        self.headphoneProfiles = kb.headphoneProfiles
        self.targetCurves = kb.targetCurves
        statusMessage = "Knowledge refreshed: \(kb.headphoneProfiles.count) headphones, \(kb.targetCurves.count) targets."
        return (kb.headphoneProfiles.count, kb.targetCurves.count)
    }

    func loadPresets() {
        do {
            presets = (try store.loadAll()).map { $0.normalized() }
                .sorted { $0.updatedAt > $1.updatedAt }
        } catch {
            lastError = "Couldn't load presets: \(error.localizedDescription)"
        }
    }

    func refreshDevices() {
        let outputs = devices.outputDevices()
        let capture = devices.virtualCaptureDevice()
        let systemOutput = devices.defaultOutputDevice()

        outputDevices = outputs
        needsVirtualDevice = capture == nil
        loopbackDriverInstalled = devices.supportedLoopbackDriverInstalled()
        systemOutputDeviceName = systemOutput?.name
        systemOutputRoutedToAuralink = capture != nil && systemOutput?.uid == capture?.uid

        var next = audioState
        next.needsVirtualDevice = needsVirtualDevice
        next.loopbackDriverInstalled = loopbackDriverInstalled
        next.audioInputPermission = audioInputPermissionStatusText()
        next.systemOutputDeviceName = systemOutputDeviceName
        next.systemOutputRoutedToAuralink = systemOutputRoutedToAuralink
        next.captureDeviceName = capture?.name
        audioState = next

        commitOutputPickerSnapshot(outputs: outputs)
    }

    func makeOutputPickerSnapshot(outputs: [OutputDevice]) -> OutputPickerSnapshot {
        let selectedUID = audioState.outputDeviceUID
        let selectedName = audioState.outputDeviceName
            ?? outputs.first(where: { $0.uid == selectedUID })?.name
            ?? outputs.first(where: { $0.isDefault && !$0.isVirtual })?.name
            ?? "Select device"
        let options = outputs
            .filter { !$0.isVirtual }
            .map { device in
                OutputPickerOption(
                    uid: device.uid,
                    name: device.name,
                    isSelected: device.uid == selectedUID
                )
            }
        return OutputPickerSnapshot(
            selectedName: selectedName,
            selectedUID: selectedUID,
            options: options
        )
    }

    func commitOutputPickerSnapshot(outputs: [OutputDevice]? = nil) {
        outputPickerSnapshot = makeOutputPickerSnapshot(outputs: outputs ?? outputDevices)
    }
}
