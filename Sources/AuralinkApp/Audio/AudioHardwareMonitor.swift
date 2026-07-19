import Foundation
import CoreAudio

/// Observes CoreAudio *hardware-level* changes the routing path must react to:
/// devices appearing/disappearing and the system default output moving.
///
/// `AVAudioEngine` only tells us about changes to the devices it is already
/// bound to (via `AVAudioEngineConfigurationChange`); it says nothing when the
/// user yanks a DAC we are not bound to yet, installs BlackHole, or flips the
/// system output in Control Center. Those are exactly the events that used to
/// leave Auralink silently wedged, so we listen for them at the HAL and let
/// `AppModel` re-evaluate routing.
///
/// Events are delivered on a private queue; the owner hops to the main actor.
final class AudioHardwareMonitor {

    enum Event {
        /// The set of audio devices changed (added/removed/driver loaded).
        case devicesChanged
        /// The system default output device changed.
        case defaultOutputChanged
    }

    /// Called on `queue` for every observed hardware event.
    var onEvent: ((Event) -> Void)?

    private let queue = DispatchQueue(label: "com.auralink.eq.hw-monitor")
    private var registrations: [(address: AudioObjectPropertyAddress, block: AudioObjectPropertyListenerBlock)] = []

    deinit { stop() }

    func start() {
        guard registrations.isEmpty else { return }
        register(selector: kAudioHardwarePropertyDevices, event: .devicesChanged)
        register(selector: kAudioHardwarePropertyDefaultOutputDevice, event: .defaultOutputChanged)
    }

    func stop() {
        for registration in registrations {
            var address = registration.address
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                queue,
                registration.block
            )
        }
        registrations.removeAll()
    }

    private func register(selector: AudioObjectPropertySelector, event: Event) {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.onEvent?(event)
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            queue,
            block
        )
        if status == noErr {
            registrations.append((address, block))
        }
    }
}
