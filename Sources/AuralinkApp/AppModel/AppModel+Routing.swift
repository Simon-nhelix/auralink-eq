import Foundation
import AVFoundation
import AuralinkCore

extension AppModel {
    // MARK: Routing

    @discardableResult
    func startRouting() -> Bool {
        lastError = nil
        refreshDevices()
        ensureOutputSelection()

        guard let capture = devices.virtualCaptureDevice(), !needsVirtualDevice else {
            routingRequested = false
            engine.stop()
            audioState.routingActive = false
            audioState.outputPeakDb = -120
            statusMessage = loopbackDriverInstalled
                ? "BlackHole is installed, but macOS has not exposed it yet. Restart your Mac, then refresh."
                : "Install BlackHole, then refresh audio setup."
            return false
        }

        guard ensureAudioInputPermissionForRouting() else {
            routingRequested = false
            engine.stop()
            audioState.routingActive = false
            audioState.outputPeakDb = -120
            audioState.capturePeakDb = -120
            return false
        }

        // Note: the engine binds the capture AUHAL directly to the loopback
        // device, so the system *default input* (the user's microphone) is left
        // alone — re-pointing it here used to feed system audio into any app
        // that records from the default mic.
        routingRequested = true
        do {
            try engine.start()
            applyPresetToEngineNow(currentPreset)
            engine.setEnabled(audioState.eqEnabled)
            guard engineIsHealthy() else {
                routingRequested = false
                engine.stop()
                audioState.routingActive = false
                audioState.outputPeakDb = -120
                audioState.capturePeakDb = -120
                lastError = "Audio engine did not start cleanly. Mac sound was not left routed through BlackHole."
                return false
            }
            audioState.routingActive = true
            audioState.captureDeviceName = capture.name
            audioState.outputPeakDb = -120
            audioState.capturePeakDb = -120
            scheduleBindingSpotCheck()
            statusMessage = "Audio routing started."
            return true
        } catch {
            routingRequested = false
            audioState.routingActive = false
            audioState.outputPeakDb = -120
            lastError = "Audio routing unavailable: \(error.localizedDescription)"
            return false
        }
    }

    var systemEQActive: Bool {
        systemOutputRoutedToAuralink && audioState.routingActive
    }

    func startSystemEQ() {
        routeMacSoundThroughAuralink()
    }

    func stopSystemEQ() {
        lastError = nil
        routingHealthCheckTask?.cancel()
        refreshDevices()

        let restoreTarget = previousSystemOutputDeviceUID.flatMap { uid in
            outputDevices.first(where: { $0.uid == uid && !$0.isVirtual })
        } ?? outputDevices.first(where: { !$0.isVirtual && $0.uid == audioState.outputDeviceUID })
          ?? outputDevices.first(where: { $0.isDefault && !$0.isVirtual })
          ?? outputDevices.first(where: { !$0.isVirtual })

        var restoredName: String?
        var restoreError: String?
        if systemOutputRoutedToAuralink {
            guard let target = restoreTarget else {
                lastError = "No real output device is available to restore."
                stopRouting()
                refreshDevices()
                return
            }
            do {
                try devices.setDefaultOutputDevice(target)
                restoredName = target.name
                previousSystemOutputDeviceUID = nil
            } catch {
                restoreError = "Couldn't restore Mac sound output: \(error.localizedDescription)"
            }
        }

        stopRouting()
        refreshDevices()
        if let restoreError {
            lastError = restoreError
        } else if let restoredName {
            statusMessage = "System EQ stopped. Mac sound restored to \(restoredName)."
        } else {
            statusMessage = "System EQ stopped."
        }
    }

    @discardableResult
    func restoreDanglingSystemOutputIfNeeded() -> String? {
        refreshDevices()
        guard systemOutputRoutedToAuralink else { return nil }

        // Prefer the device the (possibly crashed) previous session persisted.
        let restoreTarget = previousSystemOutputDeviceUID.flatMap { uid in
            outputDevices.first(where: { $0.uid == uid && !$0.isVirtual })
        }
            ?? outputDevices.first(where: { !$0.isVirtual && $0.uid == audioState.outputDeviceUID })
            ?? outputDevices.first(where: { $0.isDefault && !$0.isVirtual })
            ?? outputDevices.first(where: { !$0.isVirtual })

        guard let restoreTarget else {
            lastError = "Mac sound is routed to BlackHole, but no real output device is available to restore."
            return nil
        }

        do {
            try devices.setDefaultOutputDevice(restoreTarget)
            previousSystemOutputDeviceUID = nil
            refreshDevices()
            return "Auralink restored Mac sound to \(restoreTarget.name). System EQ is stopped."
        } catch {
            lastError = "Couldn't restore Mac sound output: \(error.localizedDescription)"
            return nil
        }
    }

    func stopRouting() {
        lastError = nil
        routingHealthCheckTask?.cancel()
        pendingEngineRecovery?.cancel()
        pendingEngineRecovery = nil
        autoRecoveryAttempts = 0
        stalledTelemetryTicks = 0
        healthyTelemetryTicks = 0
        routingRequested = false
        // Drop any background-deferred restart: the path is being torn down on
        // purpose, so it must not spring back to life on the next foreground.
        recoveryDeferredWhileBackgrounded = false
        deferredRecoveryReason = nil
        // Flush any staged telemetry samples so the Diagnostics trace shows the
        // final state instead of dropping the last <500 ms on the floor.
        flushDiagSamples()
        engine.stop()
        audioState.routingActive = false
        audioState.outputPeakDb = -120
        audioState.preClipPeakDb = -120
        audioState.preClipTruePeakDb = -120
        audioState.estimatedTruePeakDb = -120
        audioState.capturePeakDb = -120
        audioState.captureCallbacks = 0
        audioState.renderCallbacks = 0
        audioState.capturedFrames = 0
        audioState.renderedFrames = 0
        audioState.ringReadFrames = 0
        audioState.ringAvailableFrames = 0
        audioState.clippingDetected = false
        clippingEventCooldownTicks = 0
        statusMessage = "Audio routing stopped."
    }

    func toggleRouting() {
        if routingRequested || audioState.routingActive {
            stopSystemEQ()
        } else {
            startSystemEQ()
        }
    }

    func withAudioPathTransaction<T>(_ body: () throws -> T) rethrows -> T {
        audioPathTransactionInProgress = true
        defer {
            audioPathTransactionInProgress = false
            flushDeferredHardwareRefreshAfterTransaction()
        }
        return try body()
    }

    func flushDeferredHardwareRefreshAfterTransaction() {
        if deferredHardwareRefreshAfterTransaction {
            deferredHardwareRefreshAfterTransaction = false
            refreshDevices()
        }
    }

    func routeMacSoundThroughAuralink() {
        guard !audioPathTransactionInProgress else { return }
        withAudioPathTransaction {
            _ = startSystemEQSilently(isRetry: false)
        }
    }

    @discardableResult
    func startSystemEQSilently(isRetry: Bool, outputOverride: OutputDevice? = nil) -> Bool {
        routingHealthCheckTask?.cancel()
        pendingEngineRecovery?.cancel()
        pendingEngineRecovery = nil

        let outputs = devices.outputDevices()
        let loopbackInstalled = devices.supportedLoopbackDriverInstalled()
        guard let capture = devices.virtualCaptureDevice() else {
            refreshDevices()
            lastError = loopbackInstalled
                ? "BlackHole is installed, but macOS has not exposed it yet. Restart your Mac, then refresh."
                : "No supported loopback device is available. Install BlackHole, then refresh."
            return false
        }

        let selectedUID = outputOverride?.uid
            ?? audioState.outputDeviceUID
            ?? UserDefaults.standard.string(forKey: Self.lastOutputDefaultsKey)
        guard let output = outputOverride
            ?? selectedUID.flatMap({ uid in outputs.first(where: { $0.uid == uid && !$0.isVirtual }) })
            ?? outputs.first(where: { $0.isDefault && !$0.isVirtual })
            ?? outputs.first(where: { !$0.isVirtual }) else {
            refreshDevices()
            lastError = "Choose a real playback output before routing Mac sound through Auralink."
            return false
        }

        let permission = AVCaptureDevice.authorizationStatus(for: .audio)
        guard permission == .authorized else {
            // Permission prompts are inherently user-visible; use the existing
            // path only before the engine is live.
            return ensureAudioInputPermissionForRouting(retryStartSystemEQ: true)
        }

        do {
            if let current = devices.defaultOutputDevice(), !current.isVirtual {
                previousSystemOutputDeviceUID = current.uid
            }

            // Settle the real output first so AUHAL can bind to a concrete
            // playback target, then move system output into the loopback.
            try devices.setDefaultOutputDevice(output)
            guard waitForDefaultOutput(uid: output.uid) else {
                refreshDevices()
                lastError = "CoreAudio did not settle on \(output.name)."
                return false
            }

            guard engine.selectOutput(device: output) else {
                refreshDevices()
                lastError = "Couldn't move the audio path to \(output.name)."
                return false
            }

            // Start the engine while the system default is still the real
            // output. This prevents the output AUHAL from briefly binding to
            // the loopback during initialization and then fighting a device
            // change notification.
            routingRequested = true
            try engine.start()
            applyPresetToEngineNow(currentPreset)
            engine.setEnabled(audioState.eqEnabled)
            guard engineIsHealthy(), engine.outputBindingHealthy() else {
                routingRequested = false
                engine.stop()
                try? devices.setDefaultOutputDevice(output)
                refreshDevices()
                if !isRetry {
                    // Engine bring-up can fail transiently right after a stop
                    // (device still settling). One automatic retry absorbs it.
                    return startSystemEQSilently(isRetry: true, outputOverride: outputOverride)
                }
                lastError = "Audio engine did not start cleanly. Mac sound stayed on \(output.name)."
                return false
            }

            // Now route other apps into the loopback. Changing the system
            // default can cause a running AUHAL to revert, so re-pin it and
            // verify immediately.
            try devices.setDefaultOutputDevice(capture)
            guard waitForDefaultOutput(uid: capture.uid) else {
                routingRequested = false
                engine.stop()
                try? devices.setDefaultOutputDevice(output)
                refreshDevices()
                lastError = "Couldn't route system output into \(capture.name)."
                return false
            }
            _ = engine.reassertOutputBinding()
            guard engine.outputBindingHealthy() else {
                routingRequested = false
                engine.stop()
                try? devices.setDefaultOutputDevice(output)
                refreshDevices()
                lastError = "Output drifted to the loopback after routing. Mac sound stayed on \(output.name)."
                return false
            }

            refreshDevices()
            var next = audioState
            next.outputDeviceUID = output.uid
            next.outputDeviceName = output.name
            next.routingActive = true
            next.captureDeviceName = capture.name
            next.outputPeakDb = -120
            next.capturePeakDb = -120
            audioState = next
            commitOutputPickerSnapshot(outputs: outputs)
            scheduleBindingSpotCheck()
            scheduleRoutingHealthCheck(restoreTo: output)
            statusMessage = "Mac sound is now routed into \(capture.name). Auralink outputs to \(output.name)."
            return true
        } catch {
            routingRequested = false
            engine.stop()
            try? devices.setDefaultOutputDevice(output)
            refreshDevices()
            lastError = "Couldn't route Mac sound through Auralink: \(error.localizedDescription)"
            return false
        }
    }

    func scheduleRoutingHealthCheck(restoreTo output: OutputDevice) {
        routingHealthCheckTask?.cancel()
        routingHealthCheckTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 750_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                self.refreshDevices()
                guard self.systemOutputRoutedToAuralink else {
                    return
                }
                guard !self.audioState.routingActive || !self.engineIsHealthy() else {
                    return
                }

                try? self.devices.setDefaultOutputDevice(output)
                self.stopRouting()
                self.refreshDevices()
                self.lastError = "System EQ did not start cleanly, so Auralink restored Mac sound to \(output.name). Try Start System EQ again."
            }
        }
    }

    func engineIsHealthy() -> Bool {
        let snapshot = engine.debugSnapshot()
        return snapshot.stateIsRunning
            && snapshot.inputEngineRunning
            && snapshot.outputEngineRunning
            && snapshot.inputSinkInstalled
    }

    func restoreMacSoundOutput() {
        stopSystemEQ()
    }

    func prepareForSystemSleep() {
        wakeRecoveryTask?.cancel()
        let shouldResume = systemOutputRoutedToAuralink || routingRequested || audioState.routingActive
        resumeSystemEQAfterWake = shouldResume
        guard shouldResume else { return }

        stopSystemEQ()
        statusMessage = "System sleep detected. Auralink paused System EQ and restored Mac sound."
    }

    func recoverFromSystemWake() {
        wakeRecoveryTask?.cancel()
        wakeRecoveryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                self.refreshDevices()
                if self.systemOutputRoutedToAuralink && !self.audioState.routingActive {
                    _ = self.restoreDanglingSystemOutputIfNeeded()
                }
                guard self.resumeSystemEQAfterWake else {
                    self.statusMessage = "System wake detected. Audio setup refreshed."
                    return
                }
                self.resumeSystemEQAfterWake = false
                self.statusMessage = "System wake detected. Restarting System EQ."
                self.routeMacSoundThroughAuralink()
            }

            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                self.refreshDevices()
                // Sleep notifications can arrive late or be missed (forced
                // sleep, lid-close with display-only sleep). After wake we may
                // find the path still flagged active but the engines stale, or
                // — if `prepareForSystemSleep` never ran — the system still
                // routed to the loopback with a zombie engine. Either way, if
                // routing is supposed to be live but isn't healthy, restore Mac
                // sound rather than leave the user in silence.
                let routingSupposedlyLive = self.routingRequested
                    || self.systemOutputRoutedToAuralink
                    || self.audioState.routingActive
                guard routingSupposedlyLive else { return }
                guard !self.systemOutputRoutedToAuralink
                        || !self.audioState.routingActive
                        || !self.engineIsHealthy() else { return }

                let restoreTarget = self.previousSystemOutputDeviceUID.flatMap { uid in
                    self.outputDevices.first(where: { $0.uid == uid && !$0.isVirtual })
                } ?? self.outputDevices.first(where: { !$0.isVirtual && $0.uid == self.audioState.outputDeviceUID })
                  ?? self.outputDevices.first(where: { $0.isDefault && !$0.isVirtual })
                  ?? self.outputDevices.first(where: { !$0.isVirtual })

                if let restoreTarget {
                    try? self.devices.setDefaultOutputDevice(restoreTarget)
                }
                self.stopRouting()
                self.refreshDevices()
                self.lastError = "Auralink could not restart System EQ after wake, so Mac sound was restored to a real output."
            }
        }
    }
}
