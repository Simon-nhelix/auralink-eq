import Foundation
import Combine
import AppKit
import AVFoundation
import Darwin
import AuralinkCore

/// Which panel is showing on the right side of the full editor.
enum RightPanel: String, CaseIterable, Identifiable {
    case presets, headphone, aiTuning, diagnostics
    var id: String { rawValue }
    var title: String {
        switch self {
        case .presets:     return "Presets"
        case .headphone:   return "Headphone"
        case .aiTuning:    return "AI Tuning"
        case .diagnostics: return "Monitor"
        }
    }
}

struct OutputPickerOption: Identifiable, Equatable {
    var id: String { uid }
    let uid: String
    let name: String
    let isSelected: Bool
}

struct OutputPickerSnapshot: Equatable {
    var selectedName: String
    var selectedUID: String?
    var options: [OutputPickerOption]

    static let empty = OutputPickerSnapshot(
        selectedName: "Select device",
        selectedUID: nil,
        options: []
    )
}

/// The single source of truth the entire UI binds to.
///
/// AppModel owns the domain objects (preset store, knowledge base, tuning
/// engine, validator) and the live audio engine, and republishes their state
/// to SwiftUI. Views never touch the engine directly — they call intents
/// here, which keeps audio-thread concerns out of SwiftUI.
///
/// ## UI publish gate (macOS 26 DesignLibrary crash mitigation)
///
/// UI-facing properties below deliberately use `willSet { uiChanged() }`
/// instead of `@Published`. macOS 26's system-compiled DesignLibrary/SwiftUI
/// can crash dereferencing a bogus SerialExecutorRef during a *backgrounded*
/// display-cycle layout pass (Swift #87097/#89197; seen here as
/// EXC_BAD_ACCESS in swift_task_isCurrentExecutorWithFlagsImpl via
/// ZStack.init). We cannot patch the framework — but every one of those
/// layout passes was driven by our own invalidations, so while nobody can
/// see the UI (app inactive, no key window, no unoccluded window) we withhold
/// the `objectWillChange` notification and send one coalesced flush on
/// re-engagement. Only the *notification* is gated: property values are always
/// live, so the control API, the watchdog, and any body that does evaluate
/// read current state.
@MainActor
final class AppModel: ObservableObject {

    // MARK: Live state
    var audioState = AudioState() { willSet { uiChanged() } }
    /// The preset currently loaded into the engine and shown in the editor.
    var currentPreset: EQPreset = .flat() { willSet { uiChanged() } }
    /// All saved presets (the library).
    var presets: [EQPreset] = [] { willSet { uiChanged() } }
    /// Ids of presets kept in the user's own collection, so rows can show which
    /// ones are shared rather than machine-local.
    var collectionPresetIDs: Set<String> = [] { willSet { uiChanged() } }
    var outputDevices: [OutputDevice] = [] { willSet { uiChanged() } }
    /// Stable UI snapshot for output pickers. SwiftUI views must use this
    /// instead of reading live HAL/audioState fields directly; output switching
    /// commits this only after the audio path reaches a verified state.
    var outputPickerSnapshot: OutputPickerSnapshot = .empty { willSet { uiChanged() } }
    var recentPresetIds: [String] = [] { willSet { uiChanged() } }

    // MARK: Knowledge
    var headphoneProfiles: [HeadphoneProfile] = [] { willSet { uiChanged() } }
    var targetCurves: [TargetCurve] = [] { willSet { uiChanged() } }

    // MARK: Editor UI state
    var rightPanel: RightPanel = .aiTuning { willSet { uiChanged() } }
    var selectedBandIndex: Int? = nil { willSet { uiChanged() } }
    /// Cached magnitude curve for the current preset (recomputed on edits).
    var responseCurve: [ResponsePoint] = [] { willSet { uiChanged() } }

    // MARK: A/B compare
    /// Snapshot captured before an edit/AI change, for A/B comparison & rollback.
    var beforeSnapshot: EQPreset? = nil { willSet { uiChanged() } }
    /// When true the engine is auditioning the "before" snapshot.
    var comparingBefore: Bool = false { willSet { uiChanged() } }
    /// Temporary preamp cut applied only while auditioning the before snapshot.
    var abLoudnessMatchDb: Double = 0 { willSet { uiChanged() } }

    // MARK: AI flow
    /// A proposed tuning awaiting the user's Apply / Save Draft / Discard.
    var pendingProposal: TuningResult? = nil { willSet { uiChanged() } }
    var isTuning: Bool = false { willSet { uiChanged() } }

    // MARK: Status / errors
    var statusMessage: String? = nil { willSet { uiChanged() } }
    var lastError: String? = nil { willSet { uiChanged() } }
    /// Current preset/rate rejection; cleared when either input changes.
    var measuredFIRRejectionReason: String? = nil { willSet { uiChanged() } }
    /// True when no supported virtual capture device is exposed by CoreAudio.
    var needsVirtualDevice: Bool = false { willSet { uiChanged() } }
    /// True when a supported loopback driver exists on disk but may not be
    /// exposed by CoreAudio yet.
    var loopbackDriverInstalled: Bool = false { willSet { uiChanged() } }
    /// True when the app's localhost control API is listening for MCP clients.
    var controlServerRunning: Bool = false { willSet { uiChanged() } }
    /// User intent for the live capture -> EQ -> output path.
    var routingRequested: Bool = false { willSet { uiChanged() } }
    var systemOutputDeviceName: String? = nil { willSet { uiChanged() } }
    var systemOutputRoutedToAuralink: Bool = false { willSet { uiChanged() } }
    /// The real output device the user had before Auralink took over. Persisted
    /// so a crash + relaunch restores the *exact* device instead of guessing.
    var previousSystemOutputDeviceUID: String? =
        UserDefaults.standard.string(forKey: AppModel.previousOutputDefaultsKey) {
        willSet { uiChanged() }
        didSet {
            let defaults = UserDefaults.standard
            if let uid = previousSystemOutputDeviceUID {
                defaults.set(uid, forKey: Self.previousOutputDefaultsKey)
            } else {
                defaults.removeObject(forKey: Self.previousOutputDefaultsKey)
            }
        }
    }

    // MARK: UI publish gate

    /// SwiftUI's invalidation funnel. With no `@Published` properties Combine's
    /// synthesized `objectWillChange` would not be stable across accesses, so
    /// the instance is explicit; all sends go through `uiChanged()`.
    nonisolated let objectWillChange = ObservableObjectPublisher()
    /// True while SwiftUI invalidations are withheld because nobody can see
    /// the UI. See the class doc comment for why this exists.
    var uiPublishesSuppressed = false
    /// An invalidation arrived while suppressed; owed to SwiftUI on re-engagement.
    var uiPublishFlushPending = false

    static let previousOutputDefaultsKey = "auralink.previousSystemOutputDeviceUID"
    static let lastPresetDefaultsKey = "auralink.lastPresetId"
    static let lastOutputDefaultsKey = "auralink.lastOutputDeviceUID"

    // MARK: Dependencies (Core + audio)
    let store: PresetStore
    var knowledge: KnowledgeBase
    var validator: PresetValidator
    var tuner: TuningEngine
    let engine: AudioRoutingEngine
    let devices: AudioDeviceManager

    let responseFrequencies = FrequencyResponse.logFrequencies(count: 240)
    let fileWatchQueue = DispatchQueue(label: "com.auralink.eq.file-watch")
    var presetsWatcher: DispatchSourceFileSystemObject?
    var knowledgeWatcher: DispatchSourceFileSystemObject?
    var collectionHeadphonesWatcher: DispatchSourceFileSystemObject?
    var collectionPresetsWatcher: DispatchSourceFileSystemObject?
    var pendingPresetReload: Task<Void, Never>?
    var pendingKnowledgeReload: Task<Void, Never>?
    var recomputeTask: Task<Void, Never>?
    var pendingEngineApplyTask: Task<Void, Never>?
    var routingHealthCheckTask: Task<Void, Never>?
    var wakeRecoveryTask: Task<Void, Never>?
    var audioPathTransactionInProgress = false
    var deferredHardwareRefreshAfterTransaction = false
    var pendingSystemEQStartAfterPermission = false
    var resumeSystemEQAfterWake = false
    /// True while the app is in the background. While backgrounded macOS
    /// throttles/coalesces the capture device's I/O, so a routing path can
    /// legitimately show zero capture callbacks for seconds — which the
    /// watchdog must NOT mistake for a dead engine and try to recover from
    /// (a recovery restart mid-throttle just piles on a real glitch).
    var isBackgrounded = false
    /// Wall-clock time the app went into the background, so on return we can
    /// tell a brief ⌘Tab from a long absence that may have reconfigured HAL.
    var backgroundedAt: Date? = nil
    /// A recovery restart was requested while the app was backgrounded and held
    /// back until the next foreground activation. Restarting the realtime
    /// AVAudioEngine under macOS's background I/O throttling fails, gets retried
    /// in a tight backoff loop, and takes the app down — the "keeps trying to
    /// re-run on return from the background, fails, and crashes" symptom. We
    /// never bring the engine up while backgrounded; we record that one is owed
    /// and run it once from `handleAppBecameActive()`.
    var recoveryDeferredWhileBackgrounded = false
    /// The reason string for the deferred recovery, surfaced when it finally runs.
    var deferredRecoveryReason: String? = nil
    /// Last authenticated ControlServer request. `mcpConnected` expires after this.
    var lastMCPActivityAt: Date? = nil
    static let mcpActivityTimeout: TimeInterval = 30

    // MARK: Self-recovery (hardware monitor + telemetry watchdog)

    let hardwareMonitor = AudioHardwareMonitor()
    var pendingHardwareRefresh: Task<Void, Never>?
    var pendingEngineRecovery: Task<Void, Never>?
    /// Consecutive ~100 ms telemetry windows in which the engine looked dead.
    var stalledTelemetryTicks = 0
    /// Consecutive healthy windows; a long healthy stretch forgets past attempts.
    var healthyTelemetryTicks = 0
    /// Auto-restart attempts since the last healthy stretch or manual action.
    var autoRecoveryAttempts = 0
    /// Consecutive windows whose capture peak sat pinned at full scale with
    /// clipping lit — the signature of a routing feedback loop.
    var feedbackSuspectTicks = 0
    /// Telemetry ticks since the last output-binding check (checked ~1×/s).
    var bindingCheckTicks = 0
    /// Consecutive binding checks that found (and tried to fix) a mismatch.
    var bindingMismatchStreak = 0
    static let maxAutoRecoveryAttempts = 3
    /// Coalesce live graph/table edits to roughly one display frame before
    /// rebuilding the realtime filter cascade.
    static let liveEditEngineApplyDelayNs: UInt64 = 16_000_000
    /// ~3 s of continuous stall before the watchdog intervenes.
    static let stallTicksBeforeRecovery = 30
    /// ~10 s of continuous health clears the attempt counter.
    static let healthyTicksToReset = 100

    /// Timestamped trail of audible/notable path incidents (underruns,
    /// resyncs, recovery restarts…), newest last, capped. Exposed via /debug
    /// and the Diagnostics panel so a reported pop can be matched to its
    /// mechanism after the fact.
    var recentAudioEvents: [AudioPathEvent] = [] { willSet { uiChanged() } }
    static let maxAudioEvents = 50
    var clippingEventCooldownTicks = 0
    static let clippingEventCooldownReset = 10

    /// One 100 ms telemetry sample for the Diagnostics seismograph.
    struct DiagSample: Identifiable {
        let id: Int
        let at: Date
        /// Ring fill minus its target, frames — the path's calm breathing.
        let fillError: Double
        /// Drift-servo trim, ppm.
        let servoPpm: Double
        let running: Bool
    }

    /// Rolling ~2 minutes of samples (10 Hz), newest last. Feeds the live
    /// Diagnostics trace; events spike the same timeline. Calm stretches are
    /// never persisted — they simply roll off.
    var diagSamples: [DiagSample] = [] { willSet { uiChanged() } }
    var diagSampleCounter = 0
    static let maxDiagSamples = 1_200
    /// Telemetry samples accumulate here between flushes so the published
    /// `diagSamples` array only changes ~2×/s instead of 10×/s. The Diagnostics
    /// seismograph doesn't need finer resolution, and each publish redraws the
    /// whole editor view tree — which is the path this app was crashing on.
    var diagSampleStaging: [DiagSample] = []
    /// Ticks since the last `diagSamples` flush; flush when ≥ `diagFlushTicks`.
    var diagStagingTicks = 0
    /// Flush every ~5 telemetry ticks (≈500 ms at 10 Hz).
    static let diagFlushTicks = 5

    /// Dashcam-style incident captures: when an event fires, the surrounding
    /// ±10 s of telemetry is snapshotted (10 s later, once the post-roll
    /// exists) into a compact, copy-pasteable report. In-memory only.
    struct AudioIncident: Identifiable {
        let id: Int
        let at: Date
        let kind: String
        /// Ready-to-share plain-text report (clipboard-friendly).
        let report: String
    }

    var incidents: [AudioIncident] = [] { willSet { uiChanged() } }
    var incidentCounter = 0
    var incidentSnapshotPending = false
    static let maxIncidents = 20

    /// Captures one incident report ~10 s after `event`, so the trace shows
    /// both lead-up and aftermath. Bursts within the window coalesce into the
    /// single pending capture.
    private func scheduleIncidentCapture(for event: AudioPathEvent) {
        guard !incidentSnapshotPending else { return }
        incidentSnapshotPending = true
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            await MainActor.run {
                guard let self else { return }
                self.incidentSnapshotPending = false
                self.captureIncident(for: event)
            }
        }
    }

    private func captureIncident(for event: AudioPathEvent) {
        let windowStart = event.at.addingTimeInterval(-10)
        let windowEnd = event.at.addingTimeInterval(10)
        let window = diagSamples.filter { $0.at >= windowStart && $0.at <= windowEnd }
        let related = recentAudioEvents.filter { $0.at >= windowStart && $0.at <= windowEnd }

        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

        var lines: [String] = []
        lines.append("Auralink incident — \(timeFormatter.string(from: event.at))")
        for ev in related {
            timeFormatter.dateFormat = "HH:mm:ss.S"
            lines.append("  [\(timeFormatter.string(from: ev.at))] \(ev.kind): \(ev.detail)")
        }
        lines.append("device: \(audioState.outputDeviceName ?? "?") @ \(Int(audioState.sampleRate)) Hz, buffer \(audioState.bufferFrames)")
        lines.append(
            "totals since start: underruns \(audioState.underrunsTotal), "
                + "resyncs \(audioState.resyncsTotal), clips \(audioState.clippingEventsTotal)"
        )

        if !window.isEmpty {
            let errs = window.map(\.fillError)
            let ppms = window.map(\.servoPpm)
            lines.append(String(
                format: "fill error ±10s: min %.0f / max %.0f frames · servo %.0f…%.0f ppm",
                errs.min() ?? 0, errs.max() ?? 0, ppms.min() ?? 0, ppms.max() ?? 0
            ))
            lines.append("trace: \(Self.sparkline(errs, width: 60))")
            // Mark the event moment on the strip.
            if let firstAt = window.first?.at, let lastAt = window.last?.at, windowEnd > firstAt {
                let span = lastAt.timeIntervalSince(firstAt)
                if span > 0 {
                    let pos = Int(event.at.timeIntervalSince(firstAt) / span * 59.0)
                    lines.append(String(repeating: " ", count: max(0, min(59, pos)) + 7) + "^ event")
                }
            }
        }

        incidentCounter += 1
        incidents.append(AudioIncident(
            id: incidentCounter,
            at: event.at,
            kind: related.count > 1 ? related.map(\.kind).joined(separator: "+") : event.kind,
            report: lines.joined(separator: "\n")
        ))
        if incidents.count > Self.maxIncidents {
            incidents.removeFirst(incidents.count - Self.maxIncidents)
        }
    }

    /// Downsamples a signed series into a unicode sparkline (zero = middle).
    private static func sparkline(_ values: [Double], width: Int) -> String {
        guard !values.isEmpty, width > 0 else { return "" }
        let glyphs: [Character] = ["▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"]
        let bucketSize = max(1, values.count / width)
        var buckets: [Double] = []
        var index = 0
        while index < values.count {
            let slice = values[index..<min(index + bucketSize, values.count)]
            // Keep the most extreme excursion in each bucket — pops are spikes.
            let extreme = slice.max(by: { abs($0) < abs($1) }) ?? 0
            buckets.append(extreme)
            index += bucketSize
        }
        let scale = max(1, buckets.map(abs).max() ?? 1)
        return String(buckets.map { value in
            let norm = (value / scale + 1) / 2   // -scale…+scale → 0…1
            let level = max(0, min(glyphs.count - 1, Int(norm * Double(glyphs.count - 1) + 0.5)))
            return glyphs[level]
        })
    }

    func noteAudioEvent(kind: String, detail: String) {
        let event = AudioPathEvent(kind: kind, detail: detail)
        recentAudioEvents.append(event)
        if recentAudioEvents.count > Self.maxAudioEvents {
            recentAudioEvents.removeFirst(recentAudioEvents.count - Self.maxAudioEvents)
        }
        scheduleIncidentCapture(for: event)
    }

    init() {
        // Core domain objects.
        do {
            try AuralinkPaths.ensureDirectories()
        } catch {
            NSLog("Auralink: could not create data directories: \(error.localizedDescription)")
        }
        let kb = KnowledgeBase(
            dataDirectory: AuralinkPaths.dataDirectory,
            collectionHeadphonesDirectory: AuralinkPaths.collectionHeadphonesDirectory
        )
        let val = PresetValidator(rules: kb.safetyRules)
        self.knowledge = kb
        self.validator = val
        self.tuner = TuningEngine(knowledge: kb, validator: val)
        self.store = PresetStore(directory: AuralinkPaths.presetsDirectory,
                                 revisionsDirectory: AuralinkPaths.revisionsDirectory,
                                 collectionPresetsDirectory: AuralinkPaths.collectionPresetsDirectory)
        self.devices = AudioDeviceManager()
        self.engine = AudioRoutingEngine()

        self.headphoneProfiles = kb.headphoneProfiles
        self.targetCurves = kb.targetCurves
    }

    deinit {
        presetsWatcher?.cancel()
        knowledgeWatcher?.cancel()
        collectionHeadphonesWatcher?.cancel()
        collectionPresetsWatcher?.cancel()
        recomputeTask?.cancel()
        pendingEngineApplyTask?.cancel()
        pendingPresetReload?.cancel()
        pendingKnowledgeReload?.cancel()
        routingHealthCheckTask?.cancel()
        wakeRecoveryTask?.cancel()
        pendingHardwareRefresh?.cancel()
        pendingEngineRecovery?.cancel()
    }

}
