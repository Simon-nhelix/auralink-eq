import Foundation
import AuralinkCore

extension AppModel {
    // MARK: EQ controls

    func toggleEQ() { setEQEnabled(!audioState.eqEnabled) }

    var suggestedAutoPreampDb: Double {
        validator.autoPreamp(for: currentPreset)
    }

    var effectivePreampDb: Double {
        audioState.safeMode
            ? min(currentPreset.preampDb, suggestedAutoPreampDb)
            : currentPreset.preampDb
    }

    var safeModeGuardReductionDb: Double {
        min(0, effectivePreampDb - currentPreset.preampDb)
    }

    var safeModeStatusText: String {
        guard audioState.safeMode else { return "Preamp guard off" }
        if safeModeGuardReductionDb < -0.05 {
            return "Guard \(Self.formatDb(effectivePreampDb)) active"
        }
        return "Guard ready"
    }

    var preampStatusText: String {
        if audioState.safeMode && safeModeGuardReductionDb < -0.05 {
            return "\(Self.formatDb(currentPreset.preampDb)) -> \(Self.formatDb(effectivePreampDb)) effective"
        }
        return "\(Self.formatDb(currentPreset.preampDb)) preset"
    }

    /// Measured FIR is available only when the preset carries a valid dense
    /// measured baseline. The engine still applies its sample-rate-specific
    /// accuracy/superiority gate before accepting activation.
    var measuredFIRAvailable: Bool {
        guard currentPreset.correction?.sourceConfidence == .measured,
              let payload = currentPreset.correction?.measuredCorrection else { return false }
        return payload.isFIREligible
    }

    var measuredFIRRequested: Bool {
        audioState.hqCorrectionRequested ?? audioState.hqCorrectionMode
    }

    var measuredFIRRequestAllowed: Bool {
        measuredFIRAvailable && measuredFIRRejectionReason == nil
    }

    var measuredFIRHelpText: String {
        if let rejection = measuredFIRRejectionReason { return rejection }
        guard measuredFIRAvailable else {
            return "Measured FIR requires a measured AutoEq GraphicEQ baseline for this preset."
        }
        if let quality = engine.measuredFIRQuality() {
            let state = audioState.hqCorrectionMode
                ? "active"
                : (measuredFIRRequested ? "ready / awaiting RT commit" : "available")
            return String(
                format: "Measured FIR %@: %d taps, %.3f dB RMS; %.3f dB better than PEQ.",
                state,
                quality.tapCount,
                quality.rmsErrorDb,
                quality.absoluteRmsImprovementDb
            )
        }
        return "Measured FIR will verify target fidelity at the current sample rate before activation."
    }

    var currentBaselinePreset: EQPreset? {
        guard let baselineId = currentPreset.correction?.baselinePresetId else { return nil }
        return presets.first { $0.id == baselineId }
    }

    var currentCorrectionRoleText: String? {
        guard let role = currentPreset.correction?.role else { return nil }
        return PresetFormatting.roleLabel(role)
    }

    func setEQEnabled(_ on: Bool) {
        audioState.eqEnabled = on
        engine.setEnabled(on)
    }

    func setSafeMode(_ on: Bool) {
        audioState.safeMode = on
        engine.setSafeMode(on)
        statusMessage = on ? "Safe Mode: \(safeModeStatusText)" : "Safe Mode off"
    }

    func setHQCorrectionMode(_ on: Bool) {
        if !on {
            audioState.hqCorrectionRequested = false
            _ = engine.setRenderMode(.standardIIR)
            audioState.requestedRenderGeneration = engine.requestedRenderStateGeneration()
            statusMessage = audioState.hqCorrectionMode
                ? "Measured FIR off requested — PEQ commits at the next audio buffer."
                : "Measured FIR off — using the parametric fallback."
            return
        }
        guard measuredFIRAvailable else {
            audioState.hqCorrectionRequested = false
            _ = engine.setRenderMode(.standardIIR)
            audioState.requestedRenderGeneration = engine.requestedRenderStateGeneration()
            statusMessage = "Measured FIR unavailable: this preset has no valid dense measured baseline."
            return
        }
        guard engine.setRenderMode(.hqFIR), let quality = engine.measuredFIRQuality() else {
            audioState.hqCorrectionRequested = false
            audioState.requestedRenderGeneration = engine.requestedRenderStateGeneration()
            measuredFIRRejectionReason = "Measured FIR is locked at this sample rate because it did not improve target accuracy enough."
            statusMessage = measuredFIRRejectionReason
            return
        }
        measuredFIRRejectionReason = nil
        audioState.hqCorrectionRequested = true
        audioState.requestedRenderGeneration = engine.requestedRenderStateGeneration()
        statusMessage = String(
            format: audioState.routingActive
                ? "Measured FIR ready — committing at the next audio buffer (%d taps, %.3f dB RMS; PEQ %.3f dB)."
                : "Measured FIR ready — it will become active when routing starts (%d taps, %.3f dB RMS; PEQ %.3f dB).",
            quality.tapCount,
            quality.rmsErrorDb,
            quality.peqRmsErrorDb
        )
    }


    func applyHeadphoneProfile(_ profile: HeadphoneProfile?) {
        guard let profile else {
            applyGenericFlat()
            return
        }

        captureBeforeSnapshot()

        let request = AITuningRequest(
            headphone: profile.displayName,
            targetCurveId: profile.suggestedTargetCurveId,
            goalText: "Balanced correction for \(profile.displayName)",
            preference: "Correct the headphone's known tonal issues while keeping a natural balance.",
            maxBoostDb: 6,
            avoidHarshTreble: true
        )

        let result = tuner.makeTuning(request: request, basePreset: EQPreset.flat())
        var preset = result.preset.normalized()
        preset.goal = result.intent.joined(separator: " ")

        do {
            let applied: EQPreset
            if let existing = try store.get(id: preset.id) {
                applied = existing
                statusMessage = "Loaded saved \(profile.displayName) correction."
            } else {
                applied = try store.save(preset)
                statusMessage = "Applied \(profile.displayName): \(applied.activeBands.count) active bands."
            }
            loadPresets()
            load(preset: applied, audition: true)
        } catch {
            load(preset: preset, audition: true)
            lastError = "Applied in memory, but couldn't save headphone tuning: \(error.localizedDescription)"
        }

        rightPanel = .headphone
    }

    func tuneAndApply(command rawText: String) {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            lastError = "Type a tuning request first."
            return
        }

        captureBeforeSnapshot()
        let profile = profileMentioned(in: text)
            ?? headphoneProfile(named: currentPreset.headphone)

        let request = AITuningRequest(
            headphone: profile?.displayName ?? currentPreset.headphone,
            targetCurveId: nil,
            goalText: text,
            preference: text,
            maxBoostDb: 6,
            avoidHarshTreble: true
        )

        var preset = tuner.makeTuning(request: request, basePreset: currentPreset).preset.normalized()
        if preset.name == currentPreset.name {
            preset.name = "\(currentPreset.name) – Tuned"
        }

        auditionTransientPreset(preset, message: "Auditioning \(preset.name). Save it if you like this version.")
        if !systemOutputRoutedToAuralink {
            statusMessage = (statusMessage ?? "") + " Mac sound is still direct; click Start System EQ."
        }
    }

    func profileMentioned(in text: String) -> HeadphoneProfile? {
        let lower = text.lowercased()
        return headphoneProfiles.first { profile in
            lower.contains(profile.id.lowercased())
                || lower.contains(profile.model.lowercased())
                || lower.contains(profile.displayName.lowercased())
                || lower.contains("\(profile.brand) \(profile.model)".lowercased())
        }
    }

    func applyGenericFlat() {
        captureBeforeSnapshot()
        if let flat = presets.first(where: { $0.id == "preset_flat" }) {
            load(preset: flat, audition: true)
        } else {
            load(preset: EQPreset.flat(), audition: true)
        }
        statusMessage = "Loaded Flat / generic tuning."
    }

    // MARK: Preset loading / editing

    func load(preset: EQPreset, audition: Bool = true) {
        let p = preset.normalized()
        measuredFIRRejectionReason = nil
        if measuredFIRRequested,
           !(p.correction?.sourceConfidence == .measured
             && p.correction?.measuredCorrection?.isFIREligible == true) {
            setHQCorrectionMode(false)
        }
        comparingBefore = false
        abLoudnessMatchDb = 0
        currentPreset = p
        audioState.currentPresetId = p.id
        audioState.currentPresetName = p.name
        UserDefaults.standard.set(p.id, forKey: Self.lastPresetDefaultsKey)
        if audition {
            applyPresetToEngineNow(p)
        } else {
            cancelScheduledEngineApply()
        }
        pushRecent(p.id)
        recomputeResponse()
    }

    func auditionTransientPreset(_ preset: EQPreset, message: String? = nil) {
        captureBeforeSnapshot()
        load(preset: preset.normalized(), audition: true)
        statusMessage = message ?? "Auditioning \"\(currentPreset.name)\". It is not saved yet."
    }

    /// Live edit from the graph or the parameter table.
    func updateBand(_ band: EQBand) {
        measuredFIRRejectionReason = nil
        guard let i = currentPreset.bands.firstIndex(where: { $0.index == band.index }) else { return }
        currentPreset.bands[i] = band.clamped()
        applyAutoPreampIfNeeded(updateEngine: false)
        scheduleEngineApply()
        recomputeResponse()
    }

    func setBandEnabled(_ index: Int, _ enabled: Bool) {
        measuredFIRRejectionReason = nil
        guard let i = currentPreset.bands.firstIndex(where: { $0.index == index }) else { return }
        currentPreset.bands[i].enabled = enabled
        scheduleEngineApply()
        recomputeResponse()
    }

    func setPreamp(_ db: Double) {
        currentPreset.preampDb = min(max(db, EQPreset.preampRange.lowerBound), EQPreset.preampRange.upperBound)
        engine.setPreamp(currentPreset.preampDb)
        recomputeResponse()
    }

    func resetBand(_ index: Int) {
        updateBand(EQBand.emptyBand(index: index))
    }

    func resetAll() {
        currentPreset.bands = EQBand.defaultBands()
        currentPreset.preampDb = 0
        applyPresetToEngineNow(currentPreset)
        recomputeResponse()
    }

    func applyAutoPreampIfNeeded(updateEngine: Bool = true) {
        guard currentPreset.safety.autoGainEnabled else { return }
        currentPreset.preampDb = validator.autoPreamp(for: currentPreset)
        if updateEngine {
            engine.setPreamp(currentPreset.preampDb)
        }
    }

    // MARK: Persistence

    @discardableResult
    func saveLoadedPreset(name: String? = nil, id: String? = nil, extraTags: [String] = []) throws -> EQPreset {
        var preset = currentPreset
        if let id, !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            preset.id = id.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            preset.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for tag in extraTags.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) where !tag.isEmpty {
            if !preset.tags.contains(tag) { preset.tags.append(tag) }
        }

        let saved = try store.save(preset)
        currentPreset = saved
        audioState.currentPresetId = saved.id
        audioState.currentPresetName = saved.name
        loadPresets()
        statusMessage = "Saved \"\(saved.name)\" (v\(saved.version))"
        return saved
    }

    func saveCurrent() {
        do {
            _ = try saveLoadedPreset()
        } catch {
            lastError = "Save failed: \(error.localizedDescription)"
        }
    }

    func newPreset(name: String = "New Preset") {
        let id = "preset_" + UUID().uuidString.prefix(8).lowercased()
        let p = EQPreset(id: id, name: name, bands: EQBand.defaultBands(), createdBy: .user)
        load(preset: p, audition: true)
        saveCurrent()
    }

    func duplicate(_ preset: EQPreset) {
        do {
            let copy = try store.duplicate(id: preset.id, newName: preset.name + " Copy")
            loadPresets()
            load(preset: copy)
        } catch { lastError = "Duplicate failed: \(error.localizedDescription)" }
    }

    func delete(_ preset: EQPreset) {
        do {
            try store.delete(id: preset.id)
            loadPresets()
            if currentPreset.id == preset.id, let first = presets.first { load(preset: first) }
        } catch { lastError = "Delete failed: \(error.localizedDescription)" }
    }

    func rename(_ preset: EQPreset, to name: String) {
        var p = preset; p.name = name
        do { _ = try store.save(p); loadPresets() }
        catch { lastError = "Rename failed: \(error.localizedDescription)" }
    }

    func importPreset(from url: URL) {
        do {
            let p = try store.importPreset(from: url)
            loadPresets(); load(preset: p)
            statusMessage = "Imported \"\(p.name)\""
        } catch { lastError = "Import failed: \(error.localizedDescription)" }
    }

    func exportPreset(_ preset: EQPreset, to url: URL) {
        do { try store.export(preset, to: url) }
        catch { lastError = "Export failed: \(error.localizedDescription)" }
    }

    // MARK: A/B compare & rollback

    func captureBeforeSnapshot() { beforeSnapshot = currentPreset }

    func toggleAB() {
        guard let before = beforeSnapshot else { return }
        comparingBefore.toggle()
        if comparingBefore {
            let match = LoudnessMatcher.match(
                before,
                to: currentPreset,
                sampleRate: audioState.sampleRate,
                renderMode: audioState.hqCorrectionMode ? .hqFIR : .standardIIR
            )
            abLoudnessMatchDb = match.adjustmentDb
            applyPresetToEngineNow(match.preset)
            statusMessage = abs(match.adjustmentDb) > 0.05
                ? "A/B Before matched \(Self.formatDb(match.adjustmentDb))"
                : "A/B Before"
        } else {
            abLoudnessMatchDb = 0
            applyPresetToEngineNow(currentPreset)
            statusMessage = "A/B Current"
        }
    }

    @discardableResult
    func rollback() -> EQPreset? {
        do {
            if let prev = try store.previousRevision(of: currentPreset.id),
               prev.normalized() != currentPreset.normalized() {
                load(preset: prev)
                statusMessage = "Rolled back to v\(prev.version)"
                return currentPreset
            }
            if let before = beforeSnapshot,
               before.normalized() != currentPreset.normalized() {
                beforeSnapshot = nil
                load(preset: before)
                statusMessage = "Reverted unsaved changes"
                return currentPreset
            }
            statusMessage = "Nothing to roll back."
            return nil
        } catch {
            lastError = "Rollback failed: \(error.localizedDescription)"
            return nil
        }
    }

    // MARK: AI tuning

    func requestTuning(_ request: AITuningRequest) {
        isTuning = true
        captureBeforeSnapshot()
        // The in-app tuner is deterministic and synchronous; wrap to keep UI snappy.
        let result = tuner.makeTuning(request: request, basePreset: currentPreset)
        pendingProposal = result
        isTuning = false
    }

    func makeWarmer() {
        captureBeforeSnapshot()
        pendingProposal = tuner.warmer(currentPreset)
    }

    func reduceHarshness() {
        captureBeforeSnapshot()
        pendingProposal = tuner.reduceHarshness(in: currentPreset, amountDb: 2.0)
    }

    func applyProposal() {
        guard let p = pendingProposal else { return }
        load(preset: p.preset, audition: true)
        saveCurrent()
        pendingProposal = nil
        statusMessage = "Applied \"\(p.preset.name)\""
    }

    func saveProposalAsDraft() {
        guard let p = pendingProposal else { return }
        do { _ = try store.save(p.preset); loadPresets(); statusMessage = "Saved draft" }
        catch { lastError = "Save draft failed: \(error.localizedDescription)" }
        pendingProposal = nil
    }

    func discardProposal() {
        pendingProposal = nil
        if let before = beforeSnapshot { applyPresetToEngineNow(before) }
    }

    // MARK: Helpers

    func cancelScheduledEngineApply() {
        pendingEngineApplyTask?.cancel()
        pendingEngineApplyTask = nil
    }

    func applyPresetToEngineNow(_ preset: EQPreset) {
        cancelScheduledEngineApply()
        let generation = engine.apply(preset: preset)
        audioState.requestedRenderGeneration = generation
        if measuredFIRRequested, engine.measuredFIRQuality() == nil {
            audioState.hqCorrectionRequested = false
            measuredFIRRejectionReason = "Measured FIR is locked because the updated preset did not pass its quality gate."
            _ = engine.setRenderMode(.standardIIR)
            audioState.requestedRenderGeneration = engine.requestedRenderStateGeneration()
            statusMessage = measuredFIRRejectionReason
        }
    }

    func scheduleEngineApply() {
        pendingEngineApplyTask?.cancel()
        pendingEngineApplyTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.liveEditEngineApplyDelayNs)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, !Task.isCancelled else { return }
                self.pendingEngineApplyTask = nil
                let generation = self.engine.apply(preset: self.currentPreset)
                self.audioState.requestedRenderGeneration = generation
                if self.measuredFIRRequested, self.engine.measuredFIRQuality() == nil {
                    self.audioState.hqCorrectionRequested = false
                    self.measuredFIRRejectionReason = "Measured FIR is locked because the edit did not pass its quality gate."
                    _ = self.engine.setRenderMode(.standardIIR)
                    self.audioState.requestedRenderGeneration = self.engine.requestedRenderStateGeneration()
                    self.statusMessage = self.measuredFIRRejectionReason
                    self.recomputeResponse()
                }
            }
        }
    }

    func recomputeResponse() {
        recomputeTask?.cancel()
        recomputeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                self.responseCurve = FrequencyResponse.curve(
                    for: self.currentPreset,
                    at: self.responseFrequencies,
                    sampleRate: self.audioState.sampleRate,
                    renderMode: self.audioState.hqCorrectionMode ? .hqFIR : .standardIIR
                )
            }
        }
    }

    func pushRecent(_ id: String) {
        recentPresetIds.removeAll { $0 == id }
        recentPresetIds.insert(id, at: 0)
        if recentPresetIds.count > 5 { recentPresetIds.removeLast() }
    }

    func headphoneProfile(named name: String?) -> HeadphoneProfile? {
        guard let name else { return nil }
        return knowledge.profileMatching(name)
    }

    func presets(for profile: HeadphoneProfile?) -> [EQPreset] {
        let matched = presets.filter { preset in
            if let profile {
                return presetMatches(preset, profile: profile)
            }
            return preset.headphone?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
        }
        return matched.sorted { lhs, rhs in
            let lBaseline = lhs.tags.contains("baseline") || lhs.tags.contains("harman-neutral")
            let rBaseline = rhs.tags.contains("baseline") || rhs.tags.contains("harman-neutral")
            if lBaseline != rBaseline { return lBaseline && !rBaseline }
            if lhs.createdBy != rhs.createdBy { return lhs.createdBy == .ai }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    func presetsForCurrentHeadphone() -> [EQPreset] {
        presets(for: headphoneProfile(named: currentPreset.headphone))
    }

    func presetMatches(_ preset: EQPreset, profile: HeadphoneProfile) -> Bool {
        let id = profile.id.lowercased()
        if preset.tags.contains(where: { $0.lowercased() == id }) { return true }
        if preset.id.lowercased().contains(id) { return true }
        guard let headphone = preset.headphone?.trimmingCharacters(in: .whitespacesAndNewlines),
              !headphone.isEmpty else {
            return false
        }
        if knowledge.profile(id: headphone)?.id == profile.id { return true }
        return knowledge.profileMatching(headphone)?.id == profile.id
    }

    static func formatDb(_ value: Double) -> String {
        String(format: "%+.1f dB", value)
    }
}
