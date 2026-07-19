import Foundation

/// An audio output device the user can route to.
public struct OutputDevice: Codable, Identifiable, Equatable, Sendable {
    /// CoreAudio device UID (stable across reconnects).
    public var uid: String
    public var name: String
    public var sampleRate: Double
    /// True for the BlackHole/virtual loopback device the app captures from.
    public var isVirtual: Bool
    public var isDefault: Bool

    public var id: String { uid }

    public init(uid: String, name: String, sampleRate: Double, isVirtual: Bool = false, isDefault: Bool = false) {
        self.uid = uid
        self.name = name
        self.sampleRate = sampleRate
        self.isVirtual = isVirtual
        self.isDefault = isDefault
    }
}

/// How much autonomy the connected AI/MCP client has. Mirrors the plan's
/// permission modes (Appendix B). The default is `.askBeforeWrite`.
public enum PermissionMode: String, Codable, CaseIterable, Sendable {
    case readOnly             = "read_only"
    case askBeforeWrite       = "ask_before_write"
    case allowPresetCreation  = "allow_preset_creation"
    case fullControl          = "full_control"

    public var displayName: String {
        switch self {
        case .readOnly:            return "Read Only"
        case .askBeforeWrite:      return "Ask Before Write"
        case .allowPresetCreation: return "Allow Preset Creation"
        case .fullControl:         return "Full Control"
        }
    }

    public var detail: String {
        switch self {
        case .readOnly:            return "AI can read current state and presets only."
        case .askBeforeWrite:      return "Confirm before any preset is created, edited, or applied."
        case .allowPresetCreation: return "AI may create presets; applying still needs confirmation."
        case .fullControl:         return "AI may create and apply presets automatically."
        }
    }

    /// May the AI create/modify presets without a per-action confirmation?
    public var allowsAutonomousCreate: Bool {
        self == .allowPresetCreation || self == .fullControl
    }
    /// May the AI apply a preset to live audio without confirmation?
    public var allowsAutonomousApply: Bool {
        self == .fullControl
    }
}

/// Live snapshot of the audio engine. This is what `get_current_audio_state`
/// returns and what the menubar reflects. Pure data so it can cross the
/// app⇄MCP boundary as JSON.
public struct AudioState: Codable, Equatable, Sendable {
    public var eqEnabled: Bool
    public var safeMode: Bool
    /// Renderer committed by the realtime thread, not merely requested.
    public var hqCorrectionMode: Bool
    /// Control intent while FIR is preparing or waiting for a render callback.
    /// Optional preserves decoding of older state snapshots.
    public var hqCorrectionRequested: Bool?
    /// DSP-state generation requested on control and committed by realtime.
    public var requestedRenderGeneration: UInt64?
    public var committedRenderGeneration: UInt64?
    public var currentPresetId: String?
    public var currentPresetName: String?
    public var outputDeviceUID: String?
    public var outputDeviceName: String?
    public var captureDeviceName: String?
    public var needsVirtualDevice: Bool
    public var loopbackDriverInstalled: Bool
    public var audioInputPermission: String
    public var systemOutputDeviceName: String?
    public var systemOutputRoutedToAuralink: Bool
    public var sampleRate: Double
    public var bufferFrames: Int
    /// One-way latency estimate through the routing path, milliseconds.
    public var latencyMs: Double
    /// True if the routing path is live (capture device present & engine running).
    public var routingActive: Bool
    public var clippingDetected: Bool
    /// Recent pre-clip-guard peak in dBFS. Can be above 0 when EQ overshoots.
    public var preClipPeakDb: Double
    /// Stateful 4x true peak before the optional clip-protection guard. Optional
    /// so older control-state JSON remains decodable.
    public var preClipTruePeakDb: Double?
    /// Lightweight inter-sample peak estimate after the clip guard. This can
    /// exceed `outputPeakDb`; pre-guard overs are reported separately.
    public var estimatedTruePeakDb: Double
    /// Pre-guard clipping windows since the app started.
    public var clippingEventsTotal: Int
    /// Last pre-guard peak seen during a clipping window, in dBFS.
    public var lastClippingPeakDb: Double
    /// Recent output peak in dBFS (≤ 0). -120 means silence.
    public var outputPeakDb: Double
    /// Recent captured-input peak in dBFS (≤ 0). -120 means silence.
    public var capturePeakDb: Double
    /// Capture callbacks observed in the last telemetry window.
    public var captureCallbacks: Int
    /// Render callbacks observed in the last telemetry window.
    public var renderCallbacks: Int
    /// Captured frames written into the ring in the last telemetry window.
    public var capturedFrames: Int
    /// Frames requested by the output render callback in the last telemetry window.
    public var renderedFrames: Int
    /// Frames actually read from the ring in the last telemetry window.
    public var ringReadFrames: Int
    /// Frames currently waiting in the ring at the telemetry snapshot.
    public var ringAvailableFrames: Int
    /// Ring underruns (audible dropout + re-prime) since the app started.
    public var underrunsTotal: Int
    /// Faded latency resyncs (fill > 2× target) since the app started.
    public var resyncsTotal: Int
    public var mcpConnected: Bool
    public var permissionMode: PermissionMode

    public init(
        eqEnabled: Bool = true,
        safeMode: Bool = false,
        hqCorrectionMode: Bool = false,
        currentPresetId: String? = nil,
        currentPresetName: String? = nil,
        outputDeviceUID: String? = nil,
        outputDeviceName: String? = nil,
        captureDeviceName: String? = nil,
        needsVirtualDevice: Bool = false,
        loopbackDriverInstalled: Bool = false,
        audioInputPermission: String = "unknown",
        systemOutputDeviceName: String? = nil,
        systemOutputRoutedToAuralink: Bool = false,
        sampleRate: Double = 48_000,
        bufferFrames: Int = 256,
        latencyMs: Double = 0,
        routingActive: Bool = false,
        clippingDetected: Bool = false,
        preClipPeakDb: Double = -120,
        preClipTruePeakDb: Double? = nil,
        estimatedTruePeakDb: Double = -120,
        clippingEventsTotal: Int = 0,
        lastClippingPeakDb: Double = -120,
        outputPeakDb: Double = -120,
        capturePeakDb: Double = -120,
        captureCallbacks: Int = 0,
        renderCallbacks: Int = 0,
        capturedFrames: Int = 0,
        renderedFrames: Int = 0,
        ringReadFrames: Int = 0,
        ringAvailableFrames: Int = 0,
        underrunsTotal: Int = 0,
        resyncsTotal: Int = 0,
        mcpConnected: Bool = false,
        permissionMode: PermissionMode = .askBeforeWrite,
        hqCorrectionRequested: Bool? = nil,
        requestedRenderGeneration: UInt64? = nil,
        committedRenderGeneration: UInt64? = nil
    ) {
        self.eqEnabled = eqEnabled
        self.safeMode = safeMode
        self.hqCorrectionMode = hqCorrectionMode
        self.hqCorrectionRequested = hqCorrectionRequested
        self.requestedRenderGeneration = requestedRenderGeneration
        self.committedRenderGeneration = committedRenderGeneration
        self.currentPresetId = currentPresetId
        self.currentPresetName = currentPresetName
        self.outputDeviceUID = outputDeviceUID
        self.outputDeviceName = outputDeviceName
        self.captureDeviceName = captureDeviceName
        self.needsVirtualDevice = needsVirtualDevice
        self.loopbackDriverInstalled = loopbackDriverInstalled
        self.audioInputPermission = audioInputPermission
        self.systemOutputDeviceName = systemOutputDeviceName
        self.systemOutputRoutedToAuralink = systemOutputRoutedToAuralink
        self.sampleRate = sampleRate
        self.bufferFrames = bufferFrames
        self.latencyMs = latencyMs
        self.routingActive = routingActive
        self.clippingDetected = clippingDetected
        self.preClipPeakDb = preClipPeakDb
        self.preClipTruePeakDb = preClipTruePeakDb
        self.estimatedTruePeakDb = estimatedTruePeakDb
        self.clippingEventsTotal = clippingEventsTotal
        self.lastClippingPeakDb = lastClippingPeakDb
        self.outputPeakDb = outputPeakDb
        self.capturePeakDb = capturePeakDb
        self.captureCallbacks = captureCallbacks
        self.renderCallbacks = renderCallbacks
        self.capturedFrames = capturedFrames
        self.renderedFrames = renderedFrames
        self.ringReadFrames = ringReadFrames
        self.ringAvailableFrames = ringAvailableFrames
        self.underrunsTotal = underrunsTotal
        self.resyncsTotal = resyncsTotal
        self.mcpConnected = mcpConnected
        self.permissionMode = permissionMode
    }
}
