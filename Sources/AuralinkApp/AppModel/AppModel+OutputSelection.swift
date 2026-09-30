import AuralinkLocalization
import Foundation
import Darwin
import AuralinkCore

extension AppModel {
    // MARK: Output selection

    @discardableResult
    func selectOutputDevice(uid: String) -> Bool {
        if let device = outputDevices.first(where: { $0.uid == uid && !$0.isVirtual })
            ?? devices.device(forUID: uid).flatMap({ $0.isVirtual ? nil : $0 }) {
            return selectOutputDevice(device)
        }
        lastError = L10n.format("Output device %@ not found.", String(uid))
        return false
    }

    @discardableResult
    func selectOutputDevice(_ device: OutputDevice) -> Bool {
        guard !device.isVirtual else {
            lastError = L10n.text("Choose a real playback output; loopback devices are capture-only.")
            return false
        }
        guard !audioPathTransactionInProgress else {
            statusMessage = L10n.text("Audio path is already changing.")
            return false
        }

        let pathWasLive = routingRequested || audioState.routingActive || systemOutputRoutedToAuralink
        if pathWasLive {
            return performRoutedOutputSwitch(to: device)
        }
        return commitOutputSelectionWhenStopped(device)
    }

    @discardableResult
    func commitOutputSelectionWhenStopped(_ device: OutputDevice, publish: Bool = true) -> Bool {
        UserDefaults.standard.set(device.uid, forKey: Self.lastOutputDefaultsKey)
        guard engine.selectOutput(device: device) else {
            lastError = L10n.format("Couldn't move the audio path to %@.", String(device.name))
            return false
        }
        if publish { publishCommittedOutput(device) }
        return true
    }

    func publishCommittedOutput(_ device: OutputDevice) {
        var next = audioState
        next.outputDeviceUID = device.uid
        next.outputDeviceName = device.name
        audioState = next
        commitOutputPickerSnapshot()
    }

    func waitForDefaultOutput(uid: String, attempts: Int = 20) -> Bool {
        for _ in 0..<attempts {
            if devices.defaultOutputDevice()?.uid == uid { return true }
            usleep(50_000)
        }
        return devices.defaultOutputDevice()?.uid == uid
    }

    @discardableResult
    func performRoutedOutputSwitch(to target: OutputDevice) -> Bool {
        withAudioPathTransaction {
            routingHealthCheckTask?.cancel()
            pendingEngineRecovery?.cancel()
            pendingEngineRecovery = nil

            let previousUID = audioState.outputDeviceUID
            let restoreTarget = previousUID.flatMap { uid in
                devices.device(forUID: uid)
            }.flatMap { $0.isVirtual ? nil : $0 } ?? target

            do {
                // 1. Move Mac sound to a real device and stop the realtime path
                // without publishing intermediate state.
                try devices.setDefaultOutputDevice(restoreTarget)
                engine.stop()
                routingRequested = false
                routingWatchdog.reset()
                autoRecoveryAttempts = 0
                recoveryDeferredWhileBackgrounded = false
                deferredRecoveryReason = nil
                clippingEventCooldownTicks = 0

                // 2. Commit the new output while stopped and publish only the
                // stable direct-output snapshot.
                guard commitOutputSelectionWhenStopped(target, publish: false) else {
                    _ = previousUID.flatMap { devices.device(forUID: $0) }
                        .map { commitOutputSelectionWhenStopped($0, publish: false) }
                    return false
                }

                // 3. Reuse the same verified start path as normal System EQ start.
                guard startSystemEQSilently(isRetry: false, outputOverride: target) else {
                    // startSystemEQSilently restores the system default to `target`
                    // on failure; keep the picker/engine on that same device so the
                    // next Start System EQ does not flip-flop back to the old one.
                    publishCommittedOutput(target)
                    return false
                }
                statusMessage = L10n.format("Output switched to %@.", String(target.name))
                return true
            } catch {
                engine.stop()
                try? devices.setDefaultOutputDevice(restoreTarget)
                refreshDevices()
                lastError = L10n.format("Couldn't switch output: %@", String(error.localizedDescription))
                return false
            }
        }
    }
}
