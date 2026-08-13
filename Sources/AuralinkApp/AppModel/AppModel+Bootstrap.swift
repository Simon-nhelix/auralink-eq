import Foundation
import AuralinkCore

extension AppModel {
    // MARK: Lifecycle

    func bootstrap() {
        // Publish the bundled target curves and safety rules to a stable on-disk
        // location so the external MCP server reads the same values the app uses.
        // Nothing seeds headphone profiles: the collection is the user's to fill.
        knowledge.seedDataDirectory(AuralinkPaths.dataDirectory)
        CollectionManifest.ensureExists(at: AuralinkPaths.collectionManifestFile)
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
            ?? collectionStatusMessage()
            ?? "Auralink is ready. Audio routing is stopped until you start it."
    }

    /// Surfaces the two collection states the user has to act on: profiles left
    /// behind in the pre-split location, and a collection written by a newer build.
    func collectionStatusMessage() -> String? {
        if AuralinkPaths.needsCollectionMigration {
            return "Your headphone profiles are still in the old location. "
                + "Run scripts/migrate-collection.mjs to move them into "
                + AuralinkPaths.collectionDirectory.path
        }
        if let manifest = CollectionManifest.read(from: AuralinkPaths.collectionManifestFile),
           manifest.isFromNewerBuild {
            return "This collection was written by a newer Auralink "
                + "(schema \(manifest.schemaVersion)); some entries may not load."
        }
        return nil
    }

    func startFileWatchers() {
        presetsWatcher?.cancel()
        knowledgeWatcher?.cancel()
        collectionHeadphonesWatcher?.cancel()
        collectionPresetsWatcher?.cancel()

        presetsWatcher = makeDirectoryWatcher(url: AuralinkPaths.presetsDirectory) { [weak self] in
            Task { @MainActor in self?.schedulePresetReloadFromDisk() }
        }
        knowledgeWatcher = makeDirectoryWatcher(url: AuralinkPaths.dataDirectory) { [weak self] in
            Task { @MainActor in self?.scheduleKnowledgeReloadFromDisk() }
        }
        collectionHeadphonesWatcher = makeDirectoryWatcher(
            url: AuralinkPaths.collectionHeadphonesDirectory
        ) { [weak self] in
            Task { @MainActor in self?.scheduleKnowledgeReloadFromDisk() }
        }
        // A `git pull` in the collection changes presets too, so watch both halves.
        collectionPresetsWatcher = makeDirectoryWatcher(
            url: AuralinkPaths.collectionPresetsDirectory
        ) { [weak self] in
            Task { @MainActor in self?.schedulePresetReloadFromDisk() }
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
        let kb = KnowledgeBase(
            dataDirectory: AuralinkPaths.dataDirectory,
            collectionHeadphonesDirectory: AuralinkPaths.collectionHeadphonesDirectory
        )
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
            refreshCollectionMembership()
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
