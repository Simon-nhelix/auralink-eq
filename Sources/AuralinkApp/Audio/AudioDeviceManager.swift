import Foundation
import CoreAudio
import AuralinkCore

/// Enumerates the machine's audio output devices via the CoreAudio HAL.
///
/// This is the bridge between raw `AudioObjectID`s and the app's pure
/// `OutputDevice` model. It is read-only — it never changes the system audio
/// configuration — so it is safe to call from anywhere; the heavy lifting is a
/// handful of `AudioObjectGetPropertyData` calls.
public final class AudioDeviceManager {

    public init() {}

    // MARK: - Public API

    /// All devices that expose at least one output channel, newest CoreAudio
    /// snapshot. The system default output is flagged with `isDefault`, and
    /// CoreAudio virtual devices are flagged `isVirtual` so we do not accidentally
    /// use them as Auralink's playback target.
    public func outputDevices() -> [OutputDevice] {
        let defaultID = defaultOutputDeviceID()
        var seenUIDs = Set<String>()
        return allDeviceIDs().compactMap { id -> OutputDevice? in
            // Only keep devices that can actually play audio.
            guard outputChannelCount(of: id) > 0 else { return nil }
            guard let name = deviceName(of: id) else { return nil }
            let uid = deviceUID(of: id) ?? "id-\(id)"
            guard seenUIDs.insert(uid).inserted else { return nil }
            let sr = nominalSampleRate(of: id)
            let virtual = Self.looksVirtualOutput(name) || isVirtualTransport(id)
            return OutputDevice(
                uid: uid,
                name: name,
                sampleRate: sr,
                isVirtual: virtual,
                isDefault: id == defaultID
            )
        }
    }

    /// The first device whose product name marks it as a supported software
    /// loopback we can safely route system audio into. We intentionally do not
    /// accept every CoreAudio "Virtual" transport here: recorder/helper devices
    /// can expose input/output channels without actually looping system sound
    /// back, which would steal the user's output and feed Auralink silence.
    public func virtualCaptureDevice() -> OutputDevice? {
        let candidates = allDeviceIDs().compactMap { id -> OutputDevice? in
            guard inputChannelCount(of: id) > 0 else { return nil }
            guard outputChannelCount(of: id) > 0 else { return nil }
            guard let name = deviceName(of: id) else { return nil }
            guard Self.looksSupportedLoopback(name) else { return nil }
            let uid = deviceUID(of: id) ?? "id-\(id)"
            return OutputDevice(
                uid: uid,
                name: name,
                sampleRate: nominalSampleRate(of: id),
                isVirtual: true,
                isDefault: id == defaultOutputDeviceID()
            )
        }

        return candidates.sorted { lhs, rhs in
            let leftBlackHole = lhs.name.localizedCaseInsensitiveContains("blackhole")
            let rightBlackHole = rhs.name.localizedCaseInsensitiveContains("blackhole")
            if leftBlackHole != rightBlackHole { return leftBlackHole && !rightBlackHole }
            let leftNamedLoopback = Self.looksSupportedLoopback(lhs.name)
            let rightNamedLoopback = Self.looksSupportedLoopback(rhs.name)
            if leftNamedLoopback != rightNamedLoopback { return leftNamedLoopback && !rightNamedLoopback }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }.first
    }

    /// The current system default output device, as an `OutputDevice`.
    public func defaultOutputDevice() -> OutputDevice? {
        let id = defaultOutputDeviceID()
        guard id != kAudioObjectUnknown, let name = deviceName(of: id) else { return nil }
        let uid = deviceUID(of: id) ?? "id-\(id)"
        return OutputDevice(
            uid: uid,
            name: name,
            sampleRate: nominalSampleRate(of: id),
            isVirtual: Self.looksVirtualOutput(name) || isVirtualTransport(id),
            isDefault: true
        )
    }

    /// The current system default input device, as an `OutputDevice`.
    public func defaultInputDevice() -> OutputDevice? {
        let id = defaultInputDeviceID()
        guard id != kAudioObjectUnknown, let name = deviceName(of: id) else { return nil }
        let uid = deviceUID(of: id) ?? "id-\(id)"
        return OutputDevice(
            uid: uid,
            name: name,
            sampleRate: nominalSampleRate(of: id),
            isVirtual: Self.looksVirtualOutput(name) || isVirtualTransport(id),
            isDefault: true
        )
    }

    /// The first non-virtual device with input channels (e.g. the built-in
    /// microphone). Used to repair a default-input setting that a crashed
    /// session left pointing at a loopback device.
    public func firstRealInputDevice() -> OutputDevice? {
        for id in allDeviceIDs() {
            guard inputChannelCount(of: id) > 0 else { continue }
            guard let name = deviceName(of: id) else { continue }
            guard !Self.looksVirtualOutput(name), !isVirtualTransport(id) else { continue }
            let uid = deviceUID(of: id) ?? "id-\(id)"
            return OutputDevice(
                uid: uid,
                name: name,
                sampleRate: nominalSampleRate(of: id),
                isVirtual: false,
                isDefault: id == defaultInputDeviceID()
            )
        }
        return nil
    }

    /// True when a supported loopback HAL driver appears to be installed on
    /// disk even if CoreAudio has not exposed it as a live device yet.
    public func supportedLoopbackDriverInstalled() -> Bool {
        let paths = [
            "/Library/Audio/Plug-Ins/HAL/BlackHole2ch.driver",
            "/Library/Audio/Plug-Ins/HAL/BlackHole16ch.driver",
            "/Library/Audio/Plug-Ins/HAL/BlackHole.driver",
            "/Library/Audio/Plug-Ins/HAL/Loopback.driver",
            "/Library/Audio/Plug-Ins/HAL/Soundflower.driver",
            "/Library/Audio/Plug-Ins/HAL/GroundControl.driver"
        ]
        return paths.contains { FileManager.default.fileExists(atPath: $0) }
    }

    /// Makes `device` the macOS default output and system-output device.
    ///
    /// This is the missing piece for audible system-wide EQ: the system has to
    /// send sound into the virtual capture device, while Auralink sends the
    /// processed result to a separate real output device.
    public func setDefaultOutputDevice(_ device: OutputDevice) throws {
        let id = deviceID(forUID: device.uid)
        guard id != kAudioObjectUnknown else {
            throw AudioDeviceError.deviceUnavailable(device.name)
        }
        try setDefaultDeviceID(id, selector: kAudioHardwarePropertyDefaultOutputDevice)
        try setDefaultDeviceID(id, selector: kAudioHardwarePropertyDefaultSystemOutputDevice)
    }

    /// Makes `device` the macOS default input device.
    public func setDefaultInputDevice(_ device: OutputDevice) throws {
        let id = deviceID(forUID: device.uid)
        guard id != kAudioObjectUnknown else {
            throw AudioDeviceError.deviceUnavailable(device.name)
        }
        try setDefaultDeviceID(id, selector: kAudioHardwarePropertyDefaultInputDevice)
    }

    /// Sets a device's nominal sample rate. Used to align the loopback capture
    /// device with the output device's rate so the path avoids an extra
    /// resample stage. Returns true when CoreAudio accepted the change (the
    /// switch itself settles asynchronously).
    @discardableResult
    public func setNominalSampleRate(_ rate: Double, deviceID: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = Float64(rate)
        let status = AudioObjectSetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            UInt32(MemoryLayout<Float64>.size),
            &value
        )
        return status == noErr
    }

    /// Resolves an `OutputDevice` back to its live CoreAudio object id (used by
    /// the routing engine when binding the output AUHAL). Returns
    /// `kAudioObjectUnknown` if the device is no longer present.
    public func deviceID(forUID uid: String) -> AudioObjectID {
        for id in allDeviceIDs() where deviceUID(of: id) == uid {
            return id
        }
        return kAudioObjectUnknown
    }

    /// Resolves any CoreAudio device by UID, including input-only devices.
    public func device(forUID uid: String) -> OutputDevice? {
        for id in allDeviceIDs() where deviceUID(of: id) == uid {
            guard let name = deviceName(of: id) else { return nil }
            return OutputDevice(
                uid: uid,
                name: name,
                sampleRate: nominalSampleRate(of: id),
                isVirtual: Self.looksVirtualOutput(name) || isVirtualTransport(id),
                isDefault: id == defaultOutputDeviceID() || id == defaultInputDeviceID()
            )
        }
        return nil
    }

    /// HAL-reported device latency plus safety offset, in frames, for one side
    /// of the path. This is queried off the realtime thread and complements the
    /// routing engine's live ring-fill latency estimate.
    public func latencyFrames(forUID uid: String, input: Bool) -> Int {
        let id = deviceID(forUID: uid)
        guard id != kAudioObjectUnknown else { return 0 }
        let scope = input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput
        return Int(uint32Property(kAudioDevicePropertyLatency, of: id, scope: scope))
            + Int(uint32Property(kAudioDevicePropertySafetyOffset, of: id, scope: scope))
    }

    // MARK: - Naming heuristic

    /// Names that identify a supported software loopback device suitable for
    /// capture. Keep this strict: a generic recorder device is not enough.
    private static let supportedLoopbackMarkers = [
        "blackhole",
        "auralink",
        "loopback",
        "soundflower",
        "groundcontrol"
    ]

    private static func looksSupportedLoopback(_ name: String) -> Bool {
        let lower = name.lowercased()
        return supportedLoopbackMarkers.contains { lower.contains($0) }
    }

    private static func looksVirtualOutput(_ name: String) -> Bool {
        looksSupportedLoopback(name)
    }

    // MARK: - CoreAudio property helpers

    /// Every audio device object the HAL currently knows about.
    private func allDeviceIDs() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize
        )
        guard status == noErr, dataSize > 0 else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: kAudioObjectUnknown, count: count)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &ids
        )
        guard status == noErr else { return [] }
        return ids
    }

    /// The system default output device id, or `kAudioObjectUnknown`.
    private func defaultOutputDeviceID() -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        )
        return status == noErr ? deviceID : kAudioObjectUnknown
    }

    /// The system default input device id, or `kAudioObjectUnknown`.
    private func defaultInputDeviceID() -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        )
        return status == noErr ? deviceID : kAudioObjectUnknown
    }

    private func setDefaultDeviceID(_ id: AudioObjectID, selector: AudioObjectPropertySelector) throws {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = id
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            UInt32(MemoryLayout<AudioObjectID>.size),
            &deviceID
        )
        guard status == noErr else {
            throw AudioDeviceError.setDefaultFailed(status)
        }
    }

    /// Human-readable device name (kAudioObjectPropertyName).
    private func deviceName(of id: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: CFString? = nil
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &name) { ptr -> OSStatus in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, ptr)
        }
        guard status == noErr, let cf = name else { return nil }
        return cf as String
    }

    /// Stable device UID (kAudioDevicePropertyDeviceUID) used as `OutputDevice.uid`.
    private func deviceUID(of id: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: CFString? = nil
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &uid) { ptr -> OSStatus in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, ptr)
        }
        guard status == noErr, let cf = uid else { return nil }
        return cf as String
    }

    /// Nominal sample rate of the device; defaults to 48 kHz if unavailable.
    private func nominalSampleRate(of id: AudioObjectID) -> Double {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &rate)
        return (status == noErr && rate > 0) ? Double(rate) : 48_000
    }

    private func uint32Property(
        _ selector: AudioObjectPropertySelector,
        of id: AudioObjectID,
        scope: AudioObjectPropertyScope
    ) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(id, &address) else { return 0 }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value)
        return status == noErr ? value : 0
    }

    /// CoreAudio transport type; `kAudioDeviceTransportTypeVirtual` catches
    /// loopback drivers whose product names do not contain "BlackHole".
    private func isVirtualTransport(_ id: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &transport)
        return status == noErr && transport == kAudioDeviceTransportTypeVirtual
    }

    /// Total output channel count across all streams (0 ⇒ input-only device).
    private func outputChannelCount(of id: AudioObjectID) -> Int {
        channelCount(of: id, scope: kAudioObjectPropertyScopeOutput)
    }

    private func inputChannelCount(of id: AudioObjectID) -> Int {
        channelCount(of: id, scope: kAudioObjectPropertyScopeInput)
    }

    private func channelCount(of id: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(id, &address, 0, nil, &dataSize)
        guard status == noErr, dataSize > 0 else { return 0 }

        let bufferList = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { bufferList.deallocate() }

        status = AudioObjectGetPropertyData(id, &address, 0, nil, &dataSize, bufferList)
        guard status == noErr else { return 0 }

        let listPtr = UnsafeMutableAudioBufferListPointer(
            bufferList.assumingMemoryBound(to: AudioBufferList.self)
        )
        var channels = 0
        for buffer in listPtr {
            channels += Int(buffer.mNumberChannels)
        }
        return channels
    }

    public enum AudioDeviceError: LocalizedError {
        case deviceUnavailable(String)
        case setDefaultFailed(OSStatus)

        public var errorDescription: String? {
            switch self {
            case .deviceUnavailable(let name):
                return "Audio device unavailable: \(name)"
            case .setDefaultFailed(let status):
                return "CoreAudio could not change the system output device (\(status))."
            }
        }
    }
}
