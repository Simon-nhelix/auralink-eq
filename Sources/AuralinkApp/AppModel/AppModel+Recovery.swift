import Foundation
import AVFoundation
import AuralinkCore


extension AppModel {
    func restoreDanglingSystemInputIfNeeded() {
        guard let input = devices.defaultInputDevice(), input.isVirtual else { return }
        guard let real = devices.firstRealInputDevice() else { return }
        try? devices.setDefaultInputDevice(real)
        statusMessage = "Auralink restored the Mac microphone to \(real.name)."
    }

    // MARK: App activation (background → foreground)

    /// Called by the AppDelegate when the app returns to the foreground.
    ///
    /// Unlike system sleep/wake (which fully stops & restarts the engine), an
    /// ordinary app switch doesn't tear the path down — but while we were away
    /// CoreAudio may have changed the device list, moved the default output, or
    /// altered the loopback's format. If routing is supposed to be live we
    /// re-validate the bindings and run only recoveries that are actually owed.
    /// We deliberately do *not* restart solely because the app was away for a
    /// long time: that foreground restart was the failure loop reported here.
    /// Once active again, the normal watchdog will detect real callback stalls.
    func handleAppBecameActive() {
        reevaluateUIPublishGate()
        let wasBackgrounded = isBackgrounded
        let absence = backgroundedAt.map { Date().timeIntervalSince($0) } ?? 0
        isBackgrounded = false
        backgroundedAt = nil
        guard wasBackgrounded else { return }

        // Always refresh HAL-derived state: the device list, default output,
        // and loopback availability may have changed while backgrounded.
        refreshDevices()
        ensureOutputSelection()

        guard routingRequested else {
            recoveryDeferredWhileBackgrounded = false
            deferredRecoveryReason = nil
            return
        }

        // Honor any restart that was requested while backgrounded (config
        // change, hardware churn, a hard stop). We held it back so the doomed
        // background bring-up couldn't crash-loop; now that we're active the
        // engine can actually start, so run it regardless of absence length or
        // how healthy the path looks.
        if recoveryDeferredWhileBackgrounded {
            let reason = deferredRecoveryReason ?? "deferred recovery on foreground"
            recoveryDeferredWhileBackgrounded = false
            deferredRecoveryReason = nil
            // Reset the attempt counter: failed background attempts shouldn't
            // count against the foreground budget that can actually succeed.
            autoRecoveryAttempts = 0
            if !engine.outputBindingHealthy() {
                _ = engine.reassertOutputBinding()
            }
            scheduleEngineRecovery(reason: reason)
            return
        }

        // A healthy path should keep flowing through ordinary app switches and
        // long absences alike. Do not proactively rebuild it just because the
        // app became active again; if callbacks are genuinely stalled, the
        // now-unsuppressed watchdog will schedule recovery within a few seconds.
        guard !engineIsHealthy() else { return }

        // If the output AU drifted off the selected device while we were away
        // (it can retarget on default-output changes), try an in-place re-pin
        // before the heavier recovery restart.
        if !engine.outputBindingHealthy() {
            if engine.reassertOutputBinding() {
                statusMessage = "Auralink re-pinned the output device after returning to the foreground."
                noteAudioEvent(kind: "repin", detail: "output binding reasserted on app activation")
            }
        }

        if !engineIsHealthy() {
            scheduleEngineRecovery(reason: absence >= 5.0
                                   ? "app returned after a long background absence"
                                   : "app returned to foreground")
        }
    }

    /// Called by the AppDelegate when the app resigns active. We don't stop the
    /// path (realtime EQ should keep running while backgrounded), but we mark
    /// the moment so the watchdog can tolerate the throttled capture cadence
    /// macOS imposes on background apps instead of mistaking it for a stall.
    func handleAppResignedActive() {
        reevaluateUIPublishGate()
        guard !isBackgrounded else { return }
        isBackgrounded = true
        backgroundedAt = Date()
    }

    func ingest(telemetry: AudioTelemetry) {
        guard !audioPathTransactionInProgress else { return }
        // Fold the whole window into one local, then assign `audioState` once.
        // Doing this field-by-field on `audioState` fired objectWillChange ~25×
        // per 100 ms tick — a backgrounded app redrawn into SwiftUI's editor
        // ZStack millions of times over a long session. One write = one publish.
        var next = audioState
        let sampleRateChanged = abs(next.sampleRate - telemetry.sampleRate) > 0.5
        let renderModeChanged = next.hqCorrectionMode != (telemetry.running && telemetry.measuredFIRActive)
        next.sampleRate = telemetry.sampleRate
        next.bufferFrames = telemetry.bufferFrames
        next.latencyMs = telemetry.latencyMs
        next.outputPeakDb = telemetry.peakDb
        next.preClipPeakDb = telemetry.preClipPeakDb
        next.preClipTruePeakDb = telemetry.preClipTruePeakDb
        next.estimatedTruePeakDb = telemetry.estimatedTruePeakDb
        next.capturePeakDb = telemetry.capturePeakDb
        next.captureCallbacks = telemetry.captureCallbacks
        next.renderCallbacks = telemetry.renderCallbacks
        next.capturedFrames = telemetry.capturedFrames
        next.renderedFrames = telemetry.renderedFrames
        next.ringReadFrames = telemetry.ringReadFrames
        next.ringAvailableFrames = telemetry.ringAvailableFrames
        next.clippingDetected = telemetry.clipping
        next.routingActive = telemetry.running
        next.hqCorrectionMode = telemetry.running && telemetry.measuredFIRActive
        next.hqCorrectionRequested = telemetry.measuredFIRRequested
        next.requestedRenderGeneration = telemetry.requestedRenderGeneration
        next.committedRenderGeneration = telemetry.committedRenderGeneration
        next.underrunsTotal += telemetry.underruns
        next.resyncsTotal += telemetry.resyncs

        if clippingEventCooldownTicks > 0 {
            clippingEventCooldownTicks -= 1
        }
        if telemetry.clippingEvents > 0 {
            next.clippingEventsTotal += telemetry.clippingEvents
            next.lastClippingPeakDb = telemetry.preClipTruePeakDb
            if clippingEventCooldownTicks == 0 {
                noteAudioEvent(
                    kind: "clip",
                    detail: String(
                        format: "%d× — pre-guard %.1f dBTP (sample %.1f dBFS); post %.1f dBTP",
                        telemetry.clippingEvents,
                        telemetry.preClipTruePeakDb,
                        telemetry.preClipPeakDb,
                        telemetry.estimatedTruePeakDb
                    )
                )
                clippingEventCooldownTicks = Self.clippingEventCooldownReset
            }
        }
        if telemetry.underruns > 0 {
            noteAudioEvent(
                kind: "underrun",
                detail: "\(telemetry.underruns)× — ring ran dry and re-primed "
                    + "(fill \(telemetry.ringAvailableFrames), \(Int(telemetry.latencyMs)) ms)"
            )
        }
        if telemetry.resyncs > 0 {
            noteAudioEvent(
                kind: "resync",
                detail: "\(telemetry.resyncs)× — fill grew past 2× target; faded back "
                    + "(fill \(telemetry.ringAvailableFrames), \(Int(telemetry.latencyMs)) ms)"
            )
        }
        if telemetry.captureGaps > 0 {
            noteAudioEvent(
                kind: "capture-gap",
                detail: "\(telemetry.captureGaps)× — capture skipped an I/O cycle; "
                    + String(format: "up to %.1f ms of audio lost upstream of the ring", telemetry.maxCaptureGapMs)
            )
        }

        // audioState has to reflect what just happened for the watchdog, so this
        // assignment can't be deferred — but it is now the *only* publish here.
        audioState = next
        if sampleRateChanged { measuredFIRRejectionReason = nil }
        if renderModeChanged {
            if next.hqCorrectionMode, let quality = engine.measuredFIRQuality() {
                statusMessage = String(
                    format: "Measured FIR active — %d taps, %.3f dB RMS (PEQ %.3f dB).",
                    quality.tapCount,
                    quality.rmsErrorDb,
                    quality.peqRmsErrorDb
                )
            } else if next.hqCorrectionRequested != true {
                statusMessage = "Standard IIR active."
            }
            recomputeResponse()
        }

        // Append to the staging buffer; the seismograph doesn't need 10 Hz
        // resolution on the stored array, and pushing diagSamples every tick
        // was a second independent ~10 Hz publish into the same view tree.
        // Flush coalesces ~5 ticks (≈500 ms) into one assignment.
        diagSampleCounter += 1
        diagSampleStaging.append(DiagSample(
            id: diagSampleCounter,
            at: Date(),
            fillError: Double(telemetry.ringAvailableFrames - telemetry.ringTargetFrames),
            servoPpm: telemetry.driftServoPpm,
            running: telemetry.running
        ))
        diagStagingTicks += 1
        if diagStagingTicks >= Self.diagFlushTicks {
            flushDiagSamples()
        }

        updateWatchdog(with: telemetry)
    }

    /// Drains `diagSampleStaging` into the published `diagSamples` in one
    /// assignment so the array's publish rate is bounded (~2 Hz) regardless of
    /// the 10 Hz telemetry cadence.
    func flushDiagSamples() {
        guard !diagSampleStaging.isEmpty else {
            diagStagingTicks = 0
            return
        }
        diagSamples.append(contentsOf: diagSampleStaging)
        diagSampleStaging.removeAll(keepingCapacity: true)
        if diagSamples.count > Self.maxDiagSamples {
            diagSamples.removeFirst(diagSamples.count - Self.maxDiagSamples)
        }
        diagStagingTicks = 0
    }

    // MARK: Self-recovery

    /// One quick output-binding check shortly after a successful start: the
    /// output AU's async retarget-to-default (if any) lands within the first
    /// few hundred ms, well before the 1 Hz sentinel would catch it.
    func scheduleBindingSpotCheck() {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            await MainActor.run {
                guard let self, self.routingRequested else { return }
                if !self.engine.outputBindingHealthy() {
                    _ = self.engine.reassertOutputBinding()
                }
            }
        }
    }

    /// Telemetry-driven watchdog (~10 Hz). Catches both the hard stop
    /// (`running == false`) and the zombie state where the engines claim to run
    /// but no frames flow, then triggers a recovery attempt.
    func updateWatchdog(with telemetry: AudioTelemetry) {
        guard routingRequested else {
            stalledTelemetryTicks = 0
            healthyTelemetryTicks = 0
            feedbackSuspectTicks = 0
            return
        }

        // While backgrounded, macOS throttles the capture device's I/O cadence
        // (and can suspend render callbacks for the output engine), so zero
        // capture/render callbacks in a window is *expected*, not a dead engine.
        // Restarting into that throttle would only add a real glitch, so we hold
        // the watchdog and let it re-evaluate once the app is active again.
        // A genuine hard stop (`running == false`) is still surfaced, since that
        // is a definite state, not a cadence artifact.
        if isBackgrounded && telemetry.running {
            stalledTelemetryTicks = 0
            healthyTelemetryTicks = 0
            return
        }

        // Output-binding sentinel (~1×/s). The output AU retargets itself to
        // the system default when the default changes — and the default is the
        // loopback while System EQ is on, which turns our output into a
        // feedback loop. Re-pin in place; if it won't stick, rebuild the path.
        bindingCheckTicks += 1
        if telemetry.running, bindingCheckTicks >= 10 {
            bindingCheckTicks = 0
            if engine.outputBindingHealthy() {
                bindingMismatchStreak = 0
            } else {
                bindingMismatchStreak += 1
                let repinned = engine.reassertOutputBinding()
                if repinned {
                    statusMessage = "Auralink re-pinned the output device (it had reverted to the system default)."
                    noteAudioEvent(kind: "repin", detail: "output AU had reverted to the system default")
                }
                if !repinned || bindingMismatchStreak >= 2 {
                    bindingMismatchStreak = 0
                    scheduleEngineRecovery(reason: "output device binding kept reverting")
                }
            }
        }

        // Feedback breaker. A mis-bound output feeds our own signal back into
        // the loopback; the loop saturates to full scale within milliseconds
        // and stays pinned there. Real program material can graze 0 dBFS, but
        // not in every single 100 ms window for 5 s straight with clipping lit.
        if telemetry.running && systemOutputRoutedToAuralink
            && telemetry.clipping && telemetry.capturePeakDb >= -0.02 {
            feedbackSuspectTicks += 1
            if feedbackSuspectTicks >= 50 {
                feedbackSuspectTicks = 0
                noteAudioEvent(kind: "feedback-stop", detail: "sustained full-scale feedback signature; System EQ stopped")
                stopSystemEQ()
                lastError = "Auralink detected a sustained full-scale feedback signature and stopped System EQ. "
                    + "Mac sound was restored to a real output. Try Start System EQ again."
                return
            }
        } else {
            feedbackSuspectTicks = 0
        }

        // No render callbacks ⇒ the output side is dead. No capture callbacks
        // while the system mix is supposed to flow into us ⇒ capture is dead.
        let stalled = !telemetry.running
            || telemetry.renderCallbacks == 0
            || (systemOutputRoutedToAuralink && telemetry.captureCallbacks == 0)

        if stalled {
            healthyTelemetryTicks = 0
            stalledTelemetryTicks += 1
            if stalledTelemetryTicks >= Self.stallTicksBeforeRecovery, pendingEngineRecovery == nil {
                stalledTelemetryTicks = 0
                scheduleEngineRecovery(reason: "audio engine stalled")
            }
        } else {
            stalledTelemetryTicks = 0
            healthyTelemetryTicks += 1
            if healthyTelemetryTicks >= Self.healthyTicksToReset {
                healthyTelemetryTicks = 0
                autoRecoveryAttempts = 0
            }
        }
    }

    /// Debounced reaction to HAL-level hardware churn (device list / default
    /// output changes): refresh state, repair the output selection, and restart
    /// the engine if routing should be live but the change killed it.
    func handleHardwareChange(_ event: AudioHardwareMonitor.Event) {
        pendingHardwareRefresh?.cancel()
        pendingHardwareRefresh = Task { [weak self] in
            // Device add/remove fires bursts of events; let CoreAudio settle.
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                guard !self.audioPathTransactionInProgress else {
                    self.deferredHardwareRefreshAfterTransaction = true
                    return
                }
                let selectedUID = self.audioState.outputDeviceUID
                let selectedName = self.audioState.outputDeviceName
                let wasRouting = self.routingRequested
                    || self.audioState.routingActive
                    || self.systemOutputRoutedToAuralink
                let wasRoutedToAuralink = self.systemOutputRoutedToAuralink
                self.refreshDevices()
                if let selectedUID,
                   !self.outputDevices.contains(where: { $0.uid == selectedUID && !$0.isVirtual }) {
                    self.handleSelectedOutputDisappeared(
                        uid: selectedUID,
                        name: selectedName,
                        wasRouting: wasRouting
                    )
                    return
                }
                self.ensureOutputSelection()
                guard self.routingRequested else { return }

                if !self.engineIsHealthy() {
                    self.scheduleEngineRecovery(reason: "audio hardware changed")
                } else if wasRoutedToAuralink && !self.systemOutputRoutedToAuralink
                            && event == .defaultOutputChanged {
                    // The user (or another app) moved the system output away
                    // from the loopback. Respect the choice, but say so instead
                    // of silently EQ-ing nothing.
                    self.statusMessage = "Mac sound is no longer routed into "
                        + "\(self.audioState.captureDeviceName ?? "the loopback device"). System EQ is bypassed."
                }
            }
        }
    }

    func handleSelectedOutputDisappeared(uid: String, name: String?, wasRouting: Bool) {
        let deviceName: String
        if let name, !name.isEmpty {
            deviceName = name
        } else {
            deviceName = "Selected output"
        }
        noteAudioEvent(kind: "device-removed", detail: "\(deviceName) disappeared from CoreAudio")

        if wasRouting {
            stopRouting()
            if let fallback = fallbackRealOutput(excluding: uid) {
                var restoreError: String?
                do {
                    try devices.setDefaultOutputDevice(fallback)
                    previousSystemOutputDeviceUID = nil
                } catch {
                    restoreError = "Couldn't restore Mac sound to \(fallback.name): \(error.localizedDescription)"
                }
                refreshDevices()
                selectOutputDevice(fallback)
                if let restoreError {
                    lastError = "Output device \(deviceName) disappeared. \(restoreError)"
                } else {
                    lastError = "Output device \(deviceName) disappeared. System EQ was stopped and Mac sound was restored to \(fallback.name)."
                }
            } else {
                clearOutputSelection()
                refreshDevices()
                lastError = "Output device \(deviceName) disappeared. System EQ was stopped, but no real output device is available yet."
            }
            return
        }

        if let fallback = fallbackRealOutput(excluding: uid) {
            selectOutputDevice(fallback)
            statusMessage = "Output device \(deviceName) disappeared. Auralink switched to \(fallback.name)."
        } else {
            clearOutputSelection()
            statusMessage = "Output device \(deviceName) disappeared. Choose an output when one is available."
        }
    }

    /// Schedules one engine restart with exponential backoff (0.5s/1s/2s).
    /// After `maxAutoRecoveryAttempts` consecutive failures it stops trying and
    /// restores Mac sound to a real output — the user is never left in silence.
    func scheduleEngineRecovery(reason: String) {
        guard routingRequested, pendingEngineRecovery == nil,
              !audioPathTransactionInProgress else { return }

        // Never restart the realtime engine while backgrounded. macOS throttles
        // (and can suspend) a background app's audio I/O, so AVAudioEngine
        // bring-up fails; the backoff loop then retries every 0.5–2 s and the
        // repeated failed restarts are what crash the app on return from the
        // background. Record that a recovery is owed and run it once we're
        // active again (handleAppBecameActive). Any restart trigger that fires
        // while backgrounded — config-change, hardware churn, a hard stop, or a
        // recovery task that fires after we re-backgrounded — funnels here.
        guard !isBackgrounded else {
            let wasAlreadyDeferred = recoveryDeferredWhileBackgrounded
            recoveryDeferredWhileBackgrounded = true
            deferredRecoveryReason = reason
            if !wasAlreadyDeferred {
                noteAudioEvent(kind: "recovery", detail: "\(reason) — deferred until foreground (app backgrounded)")
            }
            return
        }

        autoRecoveryAttempts += 1
        let attempt = autoRecoveryAttempts
        let delayNs: UInt64 = 500_000_000 << UInt64(min(attempt - 1, 2))
        statusMessage = "Audio engine needs a restart (\(reason)). "
            + "Attempt \(attempt)/\(Self.maxAutoRecoveryAttempts)…"
        noteAudioEvent(kind: "recovery", detail: "\(reason) — attempt \(attempt)")

        pendingEngineRecovery = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delayNs)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                self.pendingEngineRecovery = nil
                guard self.routingRequested else { return }
                // We may have slipped back into the background during the backoff
                // delay. Re-defer rather than attempt a doomed background restart.
                guard !self.isBackgrounded else {
                    self.recoveryDeferredWhileBackgrounded = true
                    self.deferredRecoveryReason = reason
                    return
                }
                self.stalledTelemetryTicks = 0
                if self.startRouting() {
                    self.statusMessage = "Audio engine recovered (\(reason))."
                } else if self.autoRecoveryAttempts >= Self.maxAutoRecoveryAttempts {
                    self.giveUpAndRestoreAudio(reason: reason)
                } else {
                    // startRouting() clears the request on failure; keep trying.
                    self.routingRequested = true
                    self.scheduleEngineRecovery(reason: reason)
                }
            }
        }
    }

    func giveUpAndRestoreAudio(reason: String) {
        autoRecoveryAttempts = 0
        stopSystemEQ()
        lastError = "Auralink couldn't restart the audio engine (\(reason)) after "
            + "\(Self.maxAutoRecoveryAttempts) attempts, so Mac sound was restored to a real output device."
    }

    func refreshAudioSetup() {
        refreshDevices()
        ensureOutputSelection()
        if routingRequested { startRouting() }
        if needsVirtualDevice {
            statusMessage = loopbackDriverInstalled
                ? "BlackHole is installed, but macOS has not exposed it yet. Restart your Mac, then refresh."
                : "No BlackHole/loopback device found yet."
        } else {
            statusMessage = "Audio setup refreshed."
        }
    }

    func ensureOutputSelection() {
        if let uid = audioState.outputDeviceUID,
           outputDevices.contains(where: { $0.uid == uid && !$0.isVirtual }) {
            return
        }
        // Prefer the persisted last selection (when that device is present),
        // then the system default, then any real output.
        let lastUID = UserDefaults.standard.string(forKey: Self.lastOutputDefaultsKey)
        guard let device = outputDevices.first(where: { $0.uid == lastUID && !$0.isVirtual })
            ?? outputDevices.first(where: { $0.isDefault && !$0.isVirtual })
            ?? outputDevices.first(where: { !$0.isVirtual }) else {
            return
        }
        selectOutputDevice(device)
    }

    func fallbackRealOutput(excluding uid: String?) -> OutputDevice? {
        outputDevices.first(where: { $0.uid != uid && $0.isDefault && !$0.isVirtual })
            ?? outputDevices.first(where: { $0.uid != uid && !$0.isVirtual })
    }

    func clearOutputSelection() {
        audioState.outputDeviceUID = nil
        audioState.outputDeviceName = nil
        engine.clearOutputSelection()
    }

    func setControlServerRunning(_ running: Bool) {
        controlServerRunning = running
        if !running { audioState.mcpConnected = false }
    }

    func noteMCPActivity() {
        audioState.mcpConnected = true
    }

    func audioInputPermissionStatusText() -> String {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return "authorized"
        case .notDetermined: return "not_determined"
        case .denied: return "denied"
        case .restricted: return "restricted"
        @unknown default: return "unknown"
        }
    }

    func ensureAudioInputPermissionForRouting(retryStartSystemEQ: Bool = false) -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        audioState.audioInputPermission = audioInputPermissionStatusText()

        switch status {
        case .authorized:
            pendingSystemEQStartAfterPermission = false
            return true
        case .notDetermined:
            pendingSystemEQStartAfterPermission = retryStartSystemEQ
            statusMessage = retryStartSystemEQ
                ? "Auralink needs macOS audio input permission to capture BlackHole. Approve the prompt and System EQ will start."
                : "Auralink needs macOS audio input permission to capture BlackHole."
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                Task { @MainActor in
                    guard let self else { return }
                    self.audioState.audioInputPermission = self.audioInputPermissionStatusText()
                    if granted {
                        if self.pendingSystemEQStartAfterPermission {
                            self.pendingSystemEQStartAfterPermission = false
                            self.statusMessage = "Audio input permission granted. Starting System EQ."
                            self.startSystemEQ()
                        } else {
                            self.statusMessage = "Audio input permission granted."
                        }
                    } else {
                        self.pendingSystemEQStartAfterPermission = false
                        self.lastError = "Audio input permission was denied. Enable Microphone access for Auralink EQ in System Settings."
                    }
                }
            }
            return false
        case .denied, .restricted:
            pendingSystemEQStartAfterPermission = false
            lastError = "Audio input permission is \(audioInputPermissionStatusText()). Enable Microphone access for Auralink EQ in System Settings."
            return false
        @unknown default:
            pendingSystemEQStartAfterPermission = false
            lastError = "Audio input permission is unknown. Check Microphone access for Auralink EQ in System Settings."
            return false
        }
    }
}
