import Foundation

/// One audible-or-notable incident on the audio path, kept in a short
/// in-memory log (`AppModel.recentAudioEvents`) and exposed via `/debug`.
///
/// This exists because "the sound popped a minute ago" is otherwise
/// undiagnosable: the counters are drained every 100 ms and the moment is
/// gone. With a timestamped trail, a reported pop can be matched to the
/// exact mechanism (underrun, resync, recovery restart, …) after the fact.
public struct AudioPathEvent: Codable, Sendable {
    public var at: Date
    /// Machine-readable kind: `underrun`, `resync`, `recovery`, `repin`,
    /// `clip`, `feedback-stop`.
    public var kind: String
    public var detail: String

    public init(at: Date = Date(), kind: String, detail: String) {
        self.at = at
        self.kind = kind
        self.detail = detail
    }
}

/// A lightweight, value-type snapshot of the live routing engine.
///
/// The audio engine emits one of these ~10×/second from its own thread; the
/// `AudioRoutingEngine.onTelemetry` callback hops it to the main actor where
/// `AppModel.ingest(telemetry:)` folds it into `AudioState`. It is `Sendable`
/// so it can cross that thread boundary safely, and carries only plain numbers
/// so it never retains engine internals.
public struct AudioTelemetry: Sendable {
    /// Working sample rate of the output path, in Hz.
    public var sampleRate: Double
    /// Render buffer size in frames (per channel).
    public var bufferFrames: Int
    /// Estimated one-way latency through the routing path, in milliseconds.
    public var latencyMs: Double
    /// Recent output peak in dBFS (≤ 0). `-120` represents silence.
    public var peakDb: Double
    /// Recent pre-clip-guard peak in dBFS. Can be above 0 when EQ overshoots.
    public var preClipPeakDb: Double
    /// Stateful 4x true peak before Safe Mode's nonlinear guard.
    public var preClipTruePeakDb: Double
    /// Lightweight inter-sample peak estimate for headroom telemetry. It is
    /// computed after the clip guard and can exceed the sample peak.
    public var estimatedTruePeakDb: Double
    /// Recent captured-input peak in dBFS (≤ 0). `-120` represents silence.
    public var capturePeakDb: Double
    /// True when a sample reached/exceeded full scale in the last window.
    public var clipping: Bool
    /// Render callbacks whose pre-guard peak reached full scale in the last window.
    public var clippingEvents: Int
    /// True while the engine is actively capturing → processing → playing.
    public var running: Bool
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
    /// Ring underruns (audible re-prime gaps) in the last telemetry window.
    public var underruns: Int
    /// Faded latency resyncs (fill > 2× target) in the last telemetry window.
    public var resyncs: Int
    /// Capture-cadence gaps in the last telemetry window: the capture device
    /// skipped ≥ 1 I/O cycle, so a few ms of audio are simply missing from the
    /// stream. Too small to disturb the ring, but audible as a tiny pop.
    public var captureGaps: Int
    /// Largest capture-cadence gap in the window, milliseconds (0 when none).
    public var maxCaptureGapMs: Double
    /// The adaptive cushion the render thread aims for, frames.
    public var ringTargetFrames: Int
    /// Drift-servo rate trim currently applied, ppm.
    public var driftServoPpm: Double
    /// Renderer actually committed by the realtime thread at a callback boundary.
    public var measuredFIRActive: Bool
    /// Control intent, which can differ while waiting for a callback or after a
    /// sample-rate-specific preparation rejection.
    public var measuredFIRRequested: Bool
    /// Control generation requested/prepared versus generation installed by RT.
    public var requestedRenderGeneration: UInt64
    public var committedRenderGeneration: UInt64

    public init(
        sampleRate: Double = 48_000,
        bufferFrames: Int = 256,
        latencyMs: Double = 0,
        peakDb: Double = -120,
        preClipPeakDb: Double = -120,
        preClipTruePeakDb: Double = -120,
        estimatedTruePeakDb: Double = -120,
        capturePeakDb: Double = -120,
        clipping: Bool = false,
        clippingEvents: Int = 0,
        running: Bool = false,
        captureCallbacks: Int = 0,
        renderCallbacks: Int = 0,
        capturedFrames: Int = 0,
        renderedFrames: Int = 0,
        ringReadFrames: Int = 0,
        ringAvailableFrames: Int = 0,
        underruns: Int = 0,
        resyncs: Int = 0,
        captureGaps: Int = 0,
        maxCaptureGapMs: Double = 0,
        ringTargetFrames: Int = 0,
        driftServoPpm: Double = 0,
        measuredFIRActive: Bool = false,
        measuredFIRRequested: Bool = false,
        requestedRenderGeneration: UInt64 = 0,
        committedRenderGeneration: UInt64 = 0
    ) {
        self.sampleRate = sampleRate
        self.bufferFrames = bufferFrames
        self.latencyMs = latencyMs
        self.peakDb = peakDb
        self.preClipPeakDb = preClipPeakDb
        self.preClipTruePeakDb = preClipTruePeakDb
        self.estimatedTruePeakDb = estimatedTruePeakDb
        self.capturePeakDb = capturePeakDb
        self.clipping = clipping
        self.clippingEvents = clippingEvents
        self.running = running
        self.captureCallbacks = captureCallbacks
        self.renderCallbacks = renderCallbacks
        self.capturedFrames = capturedFrames
        self.renderedFrames = renderedFrames
        self.ringReadFrames = ringReadFrames
        self.ringAvailableFrames = ringAvailableFrames
        self.underruns = underruns
        self.resyncs = resyncs
        self.captureGaps = captureGaps
        self.maxCaptureGapMs = maxCaptureGapMs
        self.ringTargetFrames = ringTargetFrames
        self.driftServoPpm = driftServoPpm
        self.measuredFIRActive = measuredFIRActive
        self.measuredFIRRequested = measuredFIRRequested
        self.requestedRenderGeneration = requestedRenderGeneration
        self.committedRenderGeneration = committedRenderGeneration
    }
}
