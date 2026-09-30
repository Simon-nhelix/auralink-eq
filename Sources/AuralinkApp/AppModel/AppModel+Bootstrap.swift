import AuralinkLocalization
import Foundation
import AuralinkCore

extension AppModel {
    // MARK: Lifecycle

    func bootstrap() {
        // Publish the bundled target curves and safety rules to a stable on-disk
        // location so the external MCP server reads the same values the app uses.
        // Refreshed-on-upgrade files require a knowledge reload; a copy the user
        // modified after seeding is kept and surfaced instead of silently kept stale.
        let seedResult = knowledge.seedDataDirectory(AuralinkPaths.dataDirectory)
        if !seedResult.refreshed.isEmpty {
            _ = reloadKnowledge()
        }
        if !seedResult.keptUserModified.isEmpty {
            NSLog("Auralink: keeping user-modified knowledge files: \(seedResult.keptUserModified.joined(separator: ", "))")
        }
        // Ensure collection manifest exists — but never overwrite a corrupt one.
        // A corrupt manifest indicates a newer build or manual editing; silently
        // replacing it would erase the schema marker and permit incompatible writes.
        //
        // Only do this when the collection directory already exists: a fresh
        // install must not create ~/auralink-collection, because that would
        // block the documented `git clone <remote> ~/auralink-collection` flow.
        var collectionIsDir: ObjCBool = false
        if FileManager.default.fileExists(
            atPath: AuralinkPaths.collectionDirectory.path,
            isDirectory: &collectionIsDir
        ), collectionIsDir.boolValue {
            switch CollectionManifest.ensureExists(at: AuralinkPaths.collectionManifestFile) {
            case .success:
                break
            case .failure(let error):
                NSLog("Auralink: collection manifest issue: \(error.localizedDescription)")
            }
        }
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
            ?? Self.initialReadyMessage
    }

    /// Surfaces the two collection states the user has to act on: profiles left
    /// behind in the pre-split location, and a collection written by a newer build.
    func collectionStatusMessage() -> String? {
        if AuralinkPaths.needsCollectionMigration {
            return L10n.format("Your headphone profiles are still in the old location. Run scripts/migrate-collection.mjs to move them into %@.", String(AuralinkPaths.collectionDirectory.path))
        }
        switch CollectionManifest.read(from: AuralinkPaths.collectionManifestFile) {
        case .success(let manifest?):
            if manifest.isFromNewerBuild {
                return L10n.format("This collection was written by a newer Auralink (schema %@); some entries may not load.", String(manifest.schemaVersion))
            }
        case .failure(let error):
            return L10n.format("Collection manifest is corrupt or unreadable. %@", String(error.localizedDescription))
        case .success(nil):
            break
        }
        return nil
    }

    func startFileWatchers() {
        presetsWatcher?.cancel()
        knowledgeWatcher?.cancel()
        collectionHeadphonesWatcher?.cancel()
        collectionPresetsWatcher?.cancel()

        presetsWatcher = DirectoryWatcher(url: AuralinkPaths.presetsDirectory) { [weak self] in
            Task { @MainActor in self?.schedulePresetReloadFromDisk() }
        }
        knowledgeWatcher = DirectoryWatcher(url: AuralinkPaths.dataDirectory) { [weak self] in
            Task { @MainActor in self?.scheduleKnowledgeReloadFromDisk() }
        }
        // Observe missing collections without creating them, then reconnect
        // automatically after a clone, checkout replacement, or deletion.
        collectionHeadphonesWatcher = DirectoryWatcher(url: AuralinkPaths.collectionHeadphonesDirectory) { [weak self] in
            Task { @MainActor in self?.scheduleKnowledgeReloadFromDisk() }
        }
        collectionPresetsWatcher = DirectoryWatcher(url: AuralinkPaths.collectionPresetsDirectory) { [weak self] in
            Task { @MainActor in self?.schedulePresetReloadFromDisk() }
        }
    }

    func schedulePresetReloadFromDisk() {
        pendingPresetReload?.cancel()
        pendingPresetReload = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                self.loadPresets()
                self.statusMessage = L10n.text("Preset library auto-refreshed.")
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
        statusMessage = L10n.format("Knowledge refreshed: %@ headphones, %@ targets.", String(kb.headphoneProfiles.count), String(kb.targetCurves.count))
        return (kb.headphoneProfiles.count, kb.targetCurves.count)
    }

    func loadPresets() {
        do {
            presets = (try store.loadAll()).map { $0.normalized() }
                .sorted { $0.updatedAt > $1.updatedAt }
            refreshCollectionMembership()
        } catch {
            lastError = L10n.format("Couldn't load presets: %@", String(error.localizedDescription))
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
            ?? L10n.text("Select device")
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
