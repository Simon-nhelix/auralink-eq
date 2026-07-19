import Foundation
import AVFoundation
import CoreAudio
import AudioToolbox
import Accelerate
import Darwin
import AuralinkCore
import AuralinkRT

struct AudioEngineDebugSnapshot: Codable {
    var stateIsRunning: Bool
    var inputEngineRunning: Bool
    var outputEngineRunning: Bool
    var inputTapInstalled: Bool
    var selectedOutputName: String?
    var selectedOutputUID: String?
    var sampleRate: Double
    var bufferFrames: Int
    var ringAvailableFrames: Int
    var ringTargetFrames: Int
    /// The adaptive cushion the render thread actually aims for:
    /// max(ringTargetFrames, 2 × (max capture chunk + max render quantum)).
    var ringEffectiveTargetFrames: Int
    /// Largest capture chunk / render quantum seen since the last start.
    var maxCaptureFrames: Int
    var maxRenderFrames: Int
    /// Drift-servo rate trim currently applied to the varispeed node, ppm.
    var driftServoPpm: Double
    /// HAL device the output AUHAL is *actually* bound to vs. what we expect.
    /// A mismatch means the output fell back to the system default — which is
    /// the loopback while System EQ is on, i.e. a feedback loop.
    var outputBoundDeviceID: UInt32
    var outputExpectedDeviceID: UInt32
    var inputBoundDeviceID: UInt32
}

/// The live system-wide EQ path.
///
/// ## Why two engines + a ring buffer
/// macOS AVAudioEngine binds exactly one HAL device for its I/O graph. To EQ
/// *system* audio we must read from one device (a software loopback such as
/// BlackHole, into which the user routes their system output) and write to a
/// *different* physical device (their headphones/speakers). That is two HAL
/// devices, so one engine cannot do it.
///
/// The robust, well-trodden solution is two engines bridged by a lock-free ring
/// buffer:
///
/// ```
///  system audio ─▶ [virtual capture device] ─▶ AVAudioSinkNode receiver
///                                                      │  (writes device-cadence buffers)
///                                                      ▼
///                                                 ┌─────────┐
///                                                 │  ring   │   <- alk_ring (C, lock-free SPSC)
///                                                 └─────────┘
///                                                      ▲
///                                  AVAudioSourceNode ──┘  (pulls frames)
///                                          │  EQProcessor.processInPlace
///                                          ▼
///                            outputEngine ─▶ [selected output device]
/// ```
///
/// Capture goes through the **sink node's receiver**, not an input tap: taps
/// batch up to ~100 ms per buffer, which is far larger than the ring's cushion
/// and made the fill sawtooth into chronic underruns. The sink receives the
/// device's own I/O-size buffers (typically a few hundred frames).
///
/// ## Realtime discipline
/// The render block runs on a realtime audio thread, so it must never block or
/// allocate. Everything it touches is built for that:
///
/// - the ring (`alk_ring`) is a C lock-free single-producer/single-consumer
///   buffer — indices are C11 atomics, data moves with `memcpy`;
/// - scratch buffers are preallocated once and reused;
/// - meters/counters are C atomics (`alk_rt_state`), drained by the telemetry
///   timer — the audio threads take no Swift lock anywhere.
///
/// ## Clock-drift & cushion management
/// The capture device and the output device run on independent clocks. The
/// render side targets a cushion of max(~40 ms, 2 × (capture chunk + render
/// quantum)) — adapted at runtime to the I/O granularity the devices actually
/// use. Playback **primes** (holds silence) until the cushion is full, then
/// fades in. A hard underrun fades out and re-primes.
///
/// Left alone, the clock mismatch walks the fill away from the target by a few
/// frames per second until it ends in an audible event — a faded resync when
/// the fill doubled, or an underrun gap when it ran dry. Roughly every ten
/// minutes of listening, depending on the actual ppm drift. So the fill is
/// **continuously trimmed instead**: a varispeed node sits between the source
/// node and the mixer, and a slow proportional controller (10 Hz, on the
/// telemetry thread) nudges its rate by up to ±500 ppm to hold the smoothed
/// fill at the target. ±500 ppm is under a cent of pitch — inaudible — and
/// dwarfs real-world device drift, so the resync/underrun paths above become
/// true last-resort backstops. There is deliberately no per-callback sample
/// drop/duplicate servo: single-sample discontinuities hundreds of times per
/// second are exactly the "tick-tick" noise this design replaces.
///
/// ## Graceful degradation
/// If there is no virtual capture device, `start()` does **not** throw fatally —
/// it leaves the engine stopped, emits `running:false` telemetry, and lets
/// `AppModel.refreshDevices()` raise `needsVirtualDevice` so the UI can guide
/// the user through BlackHole setup.
public final class AudioRoutingEngine {

    // MARK: Telemetry

    /// Called ~10×/second with a fresh snapshot. The engine invokes this from a
    /// background timer; callers (AppModel) hop to the main actor themselves.
    public var onTelemetry: ((AudioTelemetry) -> Void)?

    /// Fired on the main operation queue when either AVAudioEngine reports a
    /// configuration change — device format/sample-rate changes, the bound
    /// device disappearing, etc. After this the engine graph is typically dead
    /// or stale; the owner should rebuild the path (`start()`), which is what
    /// `AppModel`'s recovery logic does.
    public var onConfigurationChange: (() -> Void)?

    /// Fired (on the telemetry queue) for HAL processor-overload notifications
    /// on either bound device — the OS saying an I/O deadline was missed, i.e.
    /// a glitch our ring-level counters cannot see. (kind, detail).
    public var onPathIncident: ((String, String) -> Void)?

    // MARK: Engines & nodes

    private var inputEngine = AVAudioEngine()
    private var outputEngine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    /// Sits between the source node and the mixer; the drift servo trims its
    /// rate by a few ppm to hold the ring fill at the target (see class doc).
    private var varispeedNode: AVAudioUnitVarispeed?
    private var inputSinkNode: AVAudioSinkNode?
    private var inputTapInstalled = false

    private let devices = AudioDeviceManager()

    // MARK: DSP

    /// Built once at construction; reconfigured as presets/sample-rate change.
    private let processor = EQProcessor(sampleRate: 48_000, channelCount: 2)
    /// Render-thread-only state. Preserves each channel's interpolation history
    /// across callbacks so buffer boundaries cannot hide an inter-sample peak.
    private var truePeakEstimator = TruePeakEstimator()

    // MARK: Shared control state (guarded by `stateLock`; never touched by the
    // audio threads — they use the atomic `rtState` instead)

    private let stateLock = NSLock()
    private var enabled = true
    private var safeMode = false
    private var renderMode: EQRenderMode = .standardIIR
    private var requestedRenderGeneration: UInt64 = 0
    private var preampDb: Double = 0
    private var currentPreset: EQPreset = .flat()
    private var selectedOutput: OutputDevice?
    private var isRunning = false
    /// Capture-input + physical-output HAL latency/safety offsets. Updated while
    /// the graph is stopped and read on the telemetry queue under `stateLock`.
    private var devicePathLatencyFrames = 0

    /// Working sample rate of the path. The capture device drives this.
    private var sampleRate: Double = 48_000

    // MARK: Realtime primitives (C, lock-free)

    /// Atomic meters/counters + running/primed flags shared with the audio threads.
    private let rtState: OpaquePointer
    /// Lock-free SPSC ring bridging the capture tap and the render block.
    /// Created once; sized far above any watermark so it never reallocates.
    private let ring: OpaquePointer

    /// Base cushion target (~40 ms at the path rate). Written only while the
    /// engines are stopped (during `buildGraph`), read by the render thread —
    /// no lock needed. The render thread scales this up when the devices use
    /// large I/O chunks (see `render`).
    private var ringTargetFrames = 2_048
    /// Pending fade-in after (re)priming. Render-thread-only state (also set
    /// from the control thread, but only while the engines are stopped).
    private var renderFadeInPending = false

    private static let ringCapacityFrames: UInt32 = 65_536
    private static let maxRenderFrames = 8_192
    /// The adaptive cushion never exceeds half the ring.
    private static let maxTargetFrames = 32_768
    /// Quarantine time for replaced AVAudioEngine pairs so AVFAudio/AUHAL's
    /// asynchronous configuration-change work cannot release deallocated state.
    private static let retiredEngineQuarantineDelay: DispatchTimeInterval = .milliseconds(2_000)
    /// Requested I/O cycle size for both AUHALs at a given rate. The macOS
    /// default (512 frames) means a 2.7 ms deadline at 192 kHz — so a moment
    /// of system load glitches audio that a daemon-grade path would survive.
    /// Sized by *time* (~10.7 ms per cycle) rather than a fixed frame count,
    /// or the adaptive cushion (2 × quanta, in frames) balloons at low rates:
    /// a flat 2048 was 42 ms of cushion at 192 kHz but 85 ms at 96 kHz.
    /// Devices clamp to their supported range; a refusal keeps their default.
    private static func ioBufferFrames(for sampleRate: Double) -> UInt32 {
        switch sampleRate {
        case ..<72_000:  return 512    // 44.1/48 k → 10.7+ ms
        case ..<144_000: return 1_024  // 88.2/96 k → 10.7 ms
        default:         return 2_048  // 176.4/192 k → 10.7 ms
        }
    }

    /// Held while the path runs so macOS never App-Naps the process or
    /// coalesces its timers — this is a regular app doing daemon-grade
    /// realtime I/O, and a napped process misses I/O deadlines (audible pops)
    /// under load it would otherwise absorb.
    private var routingActivityToken: NSObjectProtocol?

    // MARK: Drift servo (telemetry thread only)

    /// EMA of the ring fill, frames. −1 = uninitialized (reset on restart and
    /// while unprimed) so the filter re-seeds from the live fill.
    private var servoFilteredFill: Double = -1
    /// Last applied rate trim in ppm. Written on the telemetry queue; read by
    /// `debugSnapshot` without synchronization (diagnostic-only value).
    private var servoRatePpm: Double = 0
    /// ±500 ppm is under a cent of pitch — inaudible — yet far more authority
    /// than real device-clock drift needs.
    private static let servoMaxTrimPpm = 500.0
    /// Servo loop time-constant, seconds. Slow enough to ignore chunk-cadence
    /// fill jitter, fast enough to recapture the target within a minute.
    private static let servoTimeConstant = 8.0
    /// Fill EMA time-constant, seconds (sampled at 10 Hz).
    private static let servoFilterAlpha = 0.05

    /// Render-side scratch (consumer thread only).
    private let renderScratchL: UnsafeMutablePointer<Float>
    private let renderScratchR: UnsafeMutablePointer<Float>

    // MARK: Capture-cadence watch (capture thread only)

    /// Host time + frame count of the previous capture callback. A delta well
    /// past the chunk period means the capture device skipped an I/O cycle —
    /// audio that is simply gone from the stream. The ring cushion absorbs it
    /// (no underrun), so without this check such pops would be invisible.
    private var lastCaptureHostTime: UInt64 = 0
    private var lastCaptureFrames: Int = 0
    /// Sample rate for the cadence math. Written only while the engines are
    /// stopped (`buildGraph`), read lock-free by the capture thread — same
    /// discipline as `ringTargetFrames` on the render side.
    private var captureCadenceRate: Double = 0
    /// mach_absolute_time ticks → microseconds (resolved once; constant).
    private static let hostTicksToUs: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1_000.0
    }()

    // MARK: HAL overload listeners

    /// Devices we registered kAudioDeviceProcessorOverload listeners on, with
    /// the block needed to unregister. Control thread only.
    private var overloadListeners: [(AudioObjectID, AudioObjectPropertyListenerBlock)] = []

    // MARK: Telemetry timer

    private var telemetryTimer: DispatchSourceTimer?
    private let telemetryQueue = DispatchQueue(label: "com.auralink.eq.telemetry")

    // MARK: Engine configuration-change observation

    private var configurationObservers: [NSObjectProtocol] = []

    /// Bumped on every `recreateEnginesForFreshStart()`. Captured by each batch of
    /// configuration-change observers so a stale notification from a retired
    /// engine pair (still alive in `retiredEngines` but logically replaced) is
    /// ignored instead of triggering a spurious recovery restart.
    private var engineGeneration = 0

    /// Old engine pairs are kept alive briefly after replacement. AVAudioEngine /
    /// AUHAL tear-down posts asynchronous `IOUnitConfigurationChanged` blocks and
    /// fires device-listener clean-ups; releasing the engines immediately lets
    /// those blocks outlive their owning object and crash in `objc_release`.
    private var retiredEngines: [AVAudioEngine] = []

    public init() {
        guard let state = alk_state_create(), let ringBuffer = alk_ring_create(Self.ringCapacityFrames) else {
            preconditionFailure("could not allocate realtime audio state")
        }
        rtState = state
        ring = ringBuffer
        renderScratchL = .allocate(capacity: Self.maxRenderFrames)
        renderScratchR = .allocate(capacity: Self.maxRenderFrames)
        renderScratchL.initialize(repeating: 0, count: Self.maxRenderFrames)
        renderScratchR.initialize(repeating: 0, count: Self.maxRenderFrames)

        installConfigurationObservers()
    }

    deinit {
        removeConfigurationObservers()
        stopTelemetry()
        removeOverloadListeners()
        alk_ring_destroy(ring)
        alk_state_destroy(rtState)
        renderScratchL.deallocate()
        renderScratchR.deallocate()
    }

    private func installConfigurationObservers() {
        // AVAudioEngine stops (or silently stalls) when the device it is bound
        // to changes format or goes away. Surface that so the owner can rebuild.
        let center = NotificationCenter.default
        let gen = engineGeneration
        for engine in [inputEngine, outputEngine] {
            let observer = center.addObserver(
                forName: .AVAudioEngineConfigurationChange,
                object: engine,
                queue: .main
            ) { [weak self] _ in
                guard let self, self.engineGeneration == gen else { return }
                self.onConfigurationChange?()
            }
            configurationObservers.append(observer)
        }
    }

    private func removeConfigurationObservers() {
        let center = NotificationCenter.default
        for observer in configurationObservers {
            center.removeObserver(observer)
        }
        configurationObservers.removeAll()
    }

    private func recreateEnginesForFreshStart() {
        removeConfigurationObservers()
        engineGeneration += 1
        retireCurrentEngines()
        inputEngine = AVAudioEngine()
        outputEngine = AVAudioEngine()
        sourceNode = nil
        varispeedNode = nil
        inputSinkNode = nil
        inputTapInstalled = false
        installConfigurationObservers()
    }

    private func retireCurrentEngines() {
        let oldInput = inputEngine
        let oldOutput = outputEngine
        retiredEngines.append(oldInput)
        retiredEngines.append(oldOutput)

        // Give AVFAudio/AUHAL's asynchronous configuration-change blocks and
        // destructors time to drain before the old pair is released.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.retiredEngineQuarantineDelay) { [weak self] in
            guard let self else { return }
            self.retiredEngines.removeAll { $0 === oldInput || $0 === oldOutput }
        }
    }

    // MARK: - Lifecycle

    /// Starts (or restarts) the routing path. Never throws for the common
    /// "no virtual device installed" case — instead it reports `running:false`.
    public func start() throws {
        stop()
        // A fresh AUHAL pair avoids stale device/format state when switching
        // between outputs with different clocks (e.g. built-in speaker ⇄ HDMI).
        // Reusing an AVAudioEngine can leave CurrentDevice writes returning
        // 'nope' after a previous output path was torn down.
        recreateEnginesForFreshStart()

        // Resolve the capture (virtual) device. Absent ⇒ graceful degradation.
        guard var capture = devices.virtualCaptureDevice() else {
            stateLock.lock(); isRunning = false; stateLock.unlock()
            startTelemetry()
            emitTelemetry()   // immediate running:false so the UI updates now
            return
        }

        // Resolve the output device: explicit selection, else system default.
        let output = currentSelectedOutput() ?? devices.defaultOutputDevice()

        // Align the loopback's nominal rate with the output device so the path
        // has at most one resample stage (the output engine's). Mismatched
        // rates mean macOS resamples apps into the loopback AND we resample to
        // the DAC — two SRC passes degrading the signal for nothing.
        if let output, output.sampleRate > 0,
           abs(capture.sampleRate - output.sampleRate) > 1 {
            let captureID = devices.deviceID(forUID: capture.uid)
            if captureID != kAudioObjectUnknown,
               devices.setNominalSampleRate(output.sampleRate, deviceID: captureID) {
                // Rate switches settle asynchronously; wait briefly for the
                // device to report the new rate before building the graph.
                for _ in 0..<20 {
                    usleep(10_000)
                    if let updated = devices.device(forUID: capture.uid),
                       abs(updated.sampleRate - output.sampleRate) <= 1 {
                        capture = updated
                        break
                    }
                }
            }
        }

        do {
            // The graph must run at the rate the input AU will actually
            // deliver. After a nominal-rate switch the HAL reports the new
            // rate quickly, but a reused AVAudioEngine's input node can keep
            // serving its cached format for a while — long past a polite
            // retry window. So probe the AU (briefly nudging it toward the
            // aligned rate) and treat WHATEVER it settles on as the truth:
            // a stale rate just means one extra (output-stage) SRC for this
            // start, and the rate-change configuration event triggers a
            // recovery restart moments later, which converges to alignment.
            // Resilient start beats a hard "capture format mismatch" failure.
            let captureRate = try settledCaptureRate(for: capture, preferring: capture.sampleRate)

            try bindOutputEngine(to: output)
            setIOBufferFrames(Self.ioBufferFrames(for: captureRate), on: outputEngine.outputNode.audioUnit)
            try buildGraph(renderSampleRate: captureRate)

            // Open the realtime render path before AVAudioEngine starts. The
            // source node can be pulled during start(), and returning early as
            // "not running" there can leave the graph apparently started but
            // producing no render callbacks.
            processor.setSampleRate(currentSampleRate())
            processor.update(preset: currentPresetSnapshot())
            processor.setEnabled(currentEnabled())
            let requestedMode = currentRenderMode()
            let modeAccepted = processor.setRenderMode(requestedMode)
            let requestedGeneration = processor.requestedRenderStateGeneration()
            stateLock.lock()
            if !modeAccepted { renderMode = .standardIIR }
            requestedRenderGeneration = requestedGeneration
            stateLock.unlock()
            processor.setPreamp(effectivePreamp())
            truePeakEstimator.reset()

            stateLock.lock()
            isRunning = true
            selectedOutput = output
            devicePathLatencyFrames = devices.latencyFrames(forUID: capture.uid, input: true)
                + (output.map { devices.latencyFrames(forUID: $0.uid, input: false) } ?? 0)
            stateLock.unlock()
            alk_state_set_primed(rtState, false)
            alk_state_reset_quanta(rtState)
            alk_state_set_active_render_mode(rtState, 0)
            alk_state_set_active_render_generation(rtState, 0)
            renderFadeInPending = true
            alk_state_set_running(rtState, true)

            outputEngine.prepare()
            // Re-assert the device binding after prepare: (re)initializing the
            // AU chain on a previously-used engine can revert it, and a
            // reverted output node lands on the system default — which is the
            // loopback while System EQ is on, i.e. a full-scale feedback loop.
            try bindOutputEngine(to: output)
            try outputEngine.start()
            guard outputEngine.isRunning else {
                throw RoutingError.engineFailure("output engine did not stay running")
            }
            try ensureOutputBinding(expected: output)

            try startInputEngine(from: capture)
            installOverloadListeners(
                on: [(devices.deviceID(forUID: capture.uid), capture.name)]
                    + (output.map { [(devices.deviceID(forUID: $0.uid), $0.name)] } ?? [])
            )
            if routingActivityToken == nil {
                routingActivityToken = ProcessInfo.processInfo.beginActivity(
                    options: [.latencyCritical, .userInitiated],
                    reason: "Auralink live system-audio routing"
                )
            }
        } catch {
            // Anything hard went wrong (device vanished mid-bind, format
            // mismatch). Tear down and report not-running rather than crash.
            stop()
            startTelemetry()
            emitTelemetry()
            throw error
        }

        startTelemetry()
        emitTelemetry()
    }

    public func stop() {
        stopTelemetry()
        stateLock.lock()
        isRunning = false
        stateLock.unlock()
        alk_state_set_running(rtState, false)
        alk_state_set_active_render_mode(rtState, 0)
        alk_state_set_active_render_generation(rtState, 0)
        alk_state_set_primed(rtState, false)
        removeOverloadListeners()
        if let token = routingActivityToken {
            ProcessInfo.processInfo.endActivity(token)
            routingActivityToken = nil
        }

        inputTapInstalled = false
        if inputEngine.isRunning { inputEngine.stop() }
        if outputEngine.isRunning { outputEngine.stop() }
        if let node = sourceNode {
            outputEngine.detach(node)
            sourceNode = nil
        }
        if let node = varispeedNode {
            outputEngine.detach(node)
            varispeedNode = nil
        }
        if let node = inputSinkNode {
            inputEngine.detach(node)
            inputSinkNode = nil
        }
        inputEngine.reset()
        outputEngine.reset()
        // Both audio threads are quiesced now, so resetting the ring is safe.
        alk_ring_reset(ring)
        _ = alk_state_drain(rtState)

        emitTelemetry()
    }

    // MARK: - Controls (called from the main actor by AppModel)

    public func setEnabled(_ on: Bool) {
        stateLock.lock(); enabled = on; stateLock.unlock()
        processor.setEnabled(on)
    }

    /// Safe mode forces a guard preamp so an aggressive preset cannot clip.
    public func setSafeMode(_ on: Bool) {
        stateLock.lock(); safeMode = on; stateLock.unlock()
        processor.setClipProtectionEnabled(on)
        processor.setPreamp(effectivePreamp())
    }

    public func setPreamp(_ db: Double) {
        stateLock.lock(); preampDb = db; stateLock.unlock()
        processor.setPreamp(effectivePreamp())
    }

    @discardableResult
    public func setRenderMode(_ mode: EQRenderMode) -> Bool {
        let accepted = processor.setRenderMode(mode)
        let generation = processor.requestedRenderStateGeneration()
        stateLock.lock()
        renderMode = accepted ? mode : .standardIIR
        requestedRenderGeneration = generation
        stateLock.unlock()
        return accepted
    }

    public func requestedRenderStateGeneration() -> UInt64 {
        stateLock.lock(); defer { stateLock.unlock() }
        return requestedRenderGeneration
    }

    public func measuredFIRQuality() -> MeasuredFIRQualitySummary? {
        processor.measuredFIRQuality()
    }

    @discardableResult
    public func apply(preset: EQPreset) -> UInt64 {
        let p = preset.normalized()
        let generation = processor.update(preset: p)
        stateLock.lock()
        currentPreset = p
        preampDb = p.preampDb
        requestedRenderGeneration = generation
        stateLock.unlock()
        processor.setPreamp(effectivePreamp())
        return generation
    }

    /// Re-points the output engine at a new device. Restarts the graph if we are
    /// currently running so the change takes effect immediately. Returns `false`
    /// when the restart failed — the caller must surface that instead of letting
    /// the UI believe the new device is live.
    @discardableResult
    public func selectOutput(device: OutputDevice) -> Bool {
        stateLock.lock()
        selectedOutput = device
        let running = isRunning
        stateLock.unlock()
        guard running else { return true }
        do {
            // Simplest correct path: restart with the new output bound.
            try start()
            return true
        } catch {
            return false
        }
    }

    public func clearOutputSelection() {
        stateLock.lock()
        selectedOutput = nil
        let running = isRunning
        stateLock.unlock()
        guard running else { return }
        stop()
    }

    func debugSnapshot() -> AudioEngineDebugSnapshot {
        stateLock.lock()
        let stateRunning = isRunning
        let output = selectedOutput
        let sr = sampleRate
        stateLock.unlock()

        let expectedID = output.map { devices.deviceID(forUID: $0.uid) } ?? kAudioObjectUnknown
        let captureQuantum = Int(alk_state_max_capture_frames(rtState))
        let renderQuantum = Int(alk_state_max_render_frames(rtState))
        return AudioEngineDebugSnapshot(
            stateIsRunning: stateRunning,
            inputEngineRunning: inputEngine.isRunning,
            outputEngineRunning: outputEngine.isRunning,
            inputTapInstalled: inputTapInstalled,
            selectedOutputName: output?.name,
            selectedOutputUID: output?.uid,
            sampleRate: sr,
            bufferFrames: Int(alk_state_last_buffer_frames(rtState)),
            ringAvailableFrames: Int(alk_ring_readable(ring)),
            ringTargetFrames: ringTargetFrames,
            ringEffectiveTargetFrames: min(
                Self.maxTargetFrames,
                max(ringTargetFrames, 2 * (captureQuantum + renderQuantum))
            ),
            maxCaptureFrames: captureQuantum,
            maxRenderFrames: renderQuantum,
            driftServoPpm: servoRatePpm,
            outputBoundDeviceID: currentHALDevice(of: outputEngine.outputNode.audioUnit),
            outputExpectedDeviceID: expectedID,
            inputBoundDeviceID: currentHALDevice(of: inputEngine.inputNode.audioUnit)
        )
    }

    // MARK: - Engine binding

    /// Points the output engine's AUHAL at the selected output device. A nil
    /// device leaves the engine on the system default.
    private func bindOutputEngine(to device: OutputDevice?) throws {
        guard let device else { return }   // default output is fine
        let deviceID = devices.deviceID(forUID: device.uid)
        guard deviceID != kAudioObjectUnknown else {
            throw RoutingError.deviceUnavailable("output device \(device.uid) not found")
        }
        try setHALDevice(deviceID, on: outputEngine.outputNode.audioUnit)
    }

    private func bindInputEngine(to device: OutputDevice) throws {
        let deviceID = devices.deviceID(forUID: device.uid)
        guard deviceID != kAudioObjectUnknown else {
            throw RoutingError.deviceUnavailable("capture device \(device.uid) not found")
        }
        try setHALDevice(deviceID, on: inputEngine.inputNode.audioUnit)
    }

    /// Reads back which HAL device an AUHAL is actually bound to.
    private func currentHALDevice(of audioUnit: AudioUnit?) -> AudioObjectID {
        guard let audioUnit else { return kAudioObjectUnknown }
        var deviceID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioUnitGetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            &size
        )
        return status == noErr ? deviceID : kAudioObjectUnknown
    }

    /// Pins the output AU to the selected device *after* the engine started
    /// and keeps re-pinning until the readback agrees (up to ~300 ms).
    ///
    /// Empirically the output AU re-adopts the **system default** device while
    /// a reused engine (re)initializes — and the default is the loopback when
    /// System EQ is on, which would feed our own output straight back into the
    /// capture: a full-scale feedback loop. A pin applied once the AU is
    /// running sticks, so retry-set-verify converges; only a persistent
    /// mismatch aborts the start (recovery retries moments later).
    private func ensureOutputBinding(expected: OutputDevice?) throws {
        guard let expected else { return }
        let expectedID = devices.deviceID(forUID: expected.uid)
        guard expectedID != kAudioObjectUnknown else {
            throw RoutingError.deviceUnavailable("output device \(expected.uid) not found")
        }
        for _ in 0..<6 {
            if currentHALDevice(of: outputEngine.outputNode.audioUnit) == expectedID { return }
            try? setHALDevice(expectedID, on: outputEngine.outputNode.audioUnit)
            usleep(50_000)
        }
        let actualID = currentHALDevice(of: outputEngine.outputNode.audioUnit)
        guard actualID == expectedID else {
            throw RoutingError.engineFailure(
                "output engine bound to HAL device \(actualID) instead of \(expected.name) (\(expectedID)) — refusing to run (feedback risk)"
            )
        }
    }

    /// True when the output AU is bound to the selected device (or no explicit
    /// selection exists). The output AU can retarget itself to the system
    /// default when the default changes — and while System EQ is on the
    /// default IS the loopback, so a retarget is a feedback loop.
    public func outputBindingHealthy() -> Bool {
        guard let output = currentSelectedOutput() else { return true }
        let expected = devices.deviceID(forUID: output.uid)
        guard expected != kAudioObjectUnknown else { return false }
        return currentHALDevice(of: outputEngine.outputNode.audioUnit) == expected
    }

    /// Attempts an in-place re-pin of the output AU to the selected device.
    /// Returns true when the binding reads back correct afterward.
    @discardableResult
    public func reassertOutputBinding() -> Bool {
        guard let output = currentSelectedOutput() else { return true }
        let expected = devices.deviceID(forUID: output.uid)
        guard expected != kAudioObjectUnknown else { return false }
        if currentHALDevice(of: outputEngine.outputNode.audioUnit) == expected { return true }
        try? setHALDevice(expected, on: outputEngine.outputNode.audioUnit)
        return currentHALDevice(of: outputEngine.outputNode.audioUnit) == expected
    }

    // MARK: - HAL overload listeners

    /// Registers for `kAudioDeviceProcessorOverload` on the bound devices: the
    /// HAL posts it when an I/O cycle missed its deadline — a glitch that can
    /// be completely invisible to the ring (the cushion absorbs it) yet
    /// perfectly audible. Surfaced through `onPathIncident` for the event log.
    private func installOverloadListeners(on deviceList: [(AudioObjectID, String)]) {
        removeOverloadListeners()
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDeviceProcessorOverload,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        for (deviceID, name) in deviceList where deviceID != kAudioObjectUnknown {
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.onPathIncident?("overload", "HAL reported an I/O deadline miss on \(name)")
            }
            let status = AudioObjectAddPropertyListenerBlock(deviceID, &address, telemetryQueue, block)
            if status == noErr {
                overloadListeners.append((deviceID, block))
            }
        }
    }

    private func removeOverloadListeners() {
        guard !overloadListeners.isEmpty else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDeviceProcessorOverload,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        for (deviceID, block) in overloadListeners {
            AudioObjectRemovePropertyListenerBlock(deviceID, &address, telemetryQueue, block)
        }
        overloadListeners.removeAll()
    }

    /// Requests an I/O cycle size for an AUHAL's device IOProc. Best-effort:
    /// the device clamps to its supported range, and a refusal simply keeps
    /// its default — never fatal, so failures are ignored.
    private func setIOBufferFrames(_ frames: UInt32, on audioUnit: AudioUnit?) {
        guard let audioUnit else { return }
        var value = frames
        AudioUnitSetProperty(
            audioUnit,
            kAudioDevicePropertyBufferFrameSize,
            kAudioUnitScope_Global,
            0,
            &value,
            UInt32(MemoryLayout<UInt32>.size)
        )
    }

    /// Sets `kAudioOutputUnitProperty_CurrentDevice` on an AUHAL audio unit.
    private func setHALDevice(_ deviceID: AudioObjectID, on audioUnit: AudioUnit?) throws {
        guard let audioUnit else {
            throw RoutingError.engineFailure("audio unit unavailable")
        }
        var id = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &id,
            UInt32(MemoryLayout<AudioObjectID>.size)
        )
        guard status == noErr else {
            throw RoutingError.engineFailure("AudioUnitSetProperty(CurrentDevice) = \(status)")
        }
    }

    // MARK: - Graph construction

    /// Wires capture tap → ring → source node → output, and derives the ring's
    /// target fill / watermarks for this sample rate.
    private func buildGraph(renderSampleRate: Double) throws {
        // The capture device's rate drives the source node. The output engine
        // resamples this to the hardware output rate, which avoids draining a
        // 48 kHz loopback ring at a 192 kHz HDMI clock.
        let sr = renderSampleRate > 0 ? renderSampleRate : 48_000

        stateLock.lock(); sampleRate = sr; stateLock.unlock()

        // ~40 ms base cushion between the two clocks. The render thread scales
        // this up when the devices use large I/O chunks (see `render`).
        ringTargetFrames = Int(min(max(sr * 0.04, 1_536), 8_192))
        alk_ring_reset(ring)

        // Reset the capture-cadence watch for the new path (engines stopped).
        captureCadenceRate = sr
        lastCaptureHostTime = 0
        lastCaptureFrames = 0

        guard let renderFormat = AVAudioFormat(
            standardFormatWithSampleRate: sr, channels: 2
        ) else {
            throw RoutingError.engineFailure("could not build render format @ \(sr)Hz")
        }

        // --- Output side: a source node that pulls from the ring + EQs it. ---
        let node = AVAudioSourceNode(format: renderFormat) { [weak self] _, _, frameCount, audioBufferList -> OSStatus in
            guard let self else { return noErr }
            return self.render(frameCount: Int(frameCount), into: audioBufferList)
        }
        sourceNode = node
        outputEngine.attach(node)

        // Varispeed between the source and the mixer: the drift servo trims its
        // rate by ppm so ring consumption tracks the capture clock exactly.
        let varispeed = AVAudioUnitVarispeed()
        varispeed.rate = 1.0
        varispeedNode = varispeed
        outputEngine.attach(varispeed)

        outputEngine.connect(node, to: varispeed, format: renderFormat)
        outputEngine.connect(varispeed, to: outputEngine.mainMixerNode, format: renderFormat)
        outputEngine.mainMixerNode.outputVolume = 1.0
    }

    /// Binds the input engine to the capture device and returns the sample
    /// rate its AU actually reports — the rate the sink node will receive.
    /// Gives a freshly aligned nominal rate a moment to propagate into the
    /// AU's cached format (reset + re-probe), then accepts whatever the AU
    /// settles on rather than failing: a stale rate costs one extra SRC
    /// stage for this start and converges on the recovery restart that the
    /// rate-change configuration event triggers anyway.
    private func settledCaptureRate(for capture: OutputDevice, preferring target: Double) throws -> Double {
        try bindInputEngine(to: capture)
        let inputNode = inputEngine.inputNode
        var format = inputNode.outputFormat(forBus: 0)
        for _ in 0..<8 {
            if format.sampleRate > 0, target <= 0 || abs(format.sampleRate - target) <= 1 { break }
            usleep(150_000)
            inputEngine.reset()
            format = inputNode.outputFormat(forBus: 0)
        }
        guard format.channelCount > 0, format.sampleRate > 0 else {
            throw RoutingError.engineFailure("capture input format unavailable for \(capture.name)")
        }
        return format.sampleRate
    }

    private func startInputEngine(from capture: OutputDevice) throws {
        try bindInputEngine(to: capture)
        let renderRate = currentSampleRate()
        setIOBufferFrames(Self.ioBufferFrames(for: renderRate), on: inputEngine.inputNode.audioUnit)
        let inputNode = inputEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            throw RoutingError.engineFailure("capture input format unavailable for \(capture.name)")
        }

        // The graph was just built at the AU-probed rate; if the AU shifted
        // in between (a rate change landing mid-start), fail this attempt and
        // let recovery rebuild at the settled rate.
        guard abs(format.sampleRate - renderRate) <= 1 else {
            throw RoutingError.engineFailure(
                "capture format is \(Int(format.sampleRate)) Hz but the graph expects \(Int(renderRate)) Hz"
            )
        }

        // Also require the *hardware*-side format to agree. AVFAudio validates
        // the sink connection against the HW format and raises an ObjC
        // NSException on mismatch ("Input HW format and tap format not
        // matching") — Swift cannot catch it, and when it unwinds through a
        // main-actor task AppKit swallows it and the main actor wedges forever
        // (API + UI dead, process alive). Observed on stop→start while
        // BlackHole was still resettling: outputFormat reported 44.1 kHz while
        // the HW side already ran 192 kHz. Fail as a recoverable RoutingError
        // instead; recovery rebuilds once the rate settles.
        let hwFormat = inputNode.inputFormat(forBus: 0)
        guard hwFormat.sampleRate > 0, abs(hwFormat.sampleRate - format.sampleRate) <= 1 else {
            throw RoutingError.engineFailure(
                "capture hardware runs \(Int(hwFormat.sampleRate)) Hz but the client graph expects \(Int(format.sampleRate)) Hz"
            )
        }

        // Capture through the sink node's receiver, which runs at the device's
        // own I/O cadence (typically a few hundred frames). An input *tap*
        // would batch up to ~100 ms per buffer — a chunk far larger than the
        // ring's cushion, which made the fill sawtooth into chronic underruns.
        let sink = AVAudioSinkNode { [weak self] _, frameCount, audioBufferList -> OSStatus in
            self?.captureSink(frameCount: Int(frameCount), abl: audioBufferList)
            return noErr
        }
        inputSinkNode = sink
        inputEngine.attach(sink)
        inputEngine.connect(inputNode, to: sink, format: format)
        inputTapInstalled = true
        inputEngine.prepare()
        // Re-assert the capture binding after prepare for the same reason as
        // the output side: AU re-initialization on a reused engine can revert
        // it to the default input device.
        try bindInputEngine(to: capture)
        try inputEngine.start()
        guard inputEngine.isRunning else {
            throw RoutingError.engineFailure("capture engine did not stay running")
        }
        // Same retry-pin as the output side: a reused input AU can re-adopt
        // the default input device while (re)initializing.
        let expectedInput = devices.deviceID(forUID: capture.uid)
        guard expectedInput != kAudioObjectUnknown else {
            throw RoutingError.deviceUnavailable("capture device \(capture.uid) not found")
        }
        for _ in 0..<6 {
            if currentHALDevice(of: inputEngine.inputNode.audioUnit) == expectedInput { break }
            try? setHALDevice(expectedInput, on: inputEngine.inputNode.audioUnit)
            usleep(50_000)
        }
        let boundInput = currentHALDevice(of: inputEngine.inputNode.audioUnit)
        guard boundInput == expectedInput else {
            throw RoutingError.engineFailure(
                "capture engine bound to HAL device \(boundInput) instead of \(capture.name) (\(expectedInput))"
            )
        }
    }

    // MARK: - Capture → ring (producer thread)

    /// Pushes one device-cadence capture buffer into the ring. Runs on the
    /// input engine's realtime I/O thread (AVAudioSinkNode receiver):
    /// allocation-free, lock-free. The sink connection format is the device's
    /// standard deinterleaved float32 layout; interleaved/mono are handled
    /// defensively.
    private func captureSink(frameCount: Int, abl: UnsafePointer<AudioBufferList>) {
        guard alk_state_running(rtState), frameCount > 0 else { return }

        // Cadence watch: the sink receives at the device's own I/O cycle, so
        // the callback spacing should equal the previous chunk's duration. A
        // delta well past that (1.5× + 1 ms slack ⇒ a missed cycle, not
        // scheduling jitter) means a few ms of audio never reached us.
        let now = mach_absolute_time()
        let sr = captureCadenceRate
        if lastCaptureHostTime != 0, lastCaptureFrames > 0, sr > 0 {
            let deltaUs = Double(now - lastCaptureHostTime) * Self.hostTicksToUs
            let periodUs = Double(lastCaptureFrames) / sr * 1_000_000
            if deltaUs > 1.5 * periodUs + 1_000 {
                alk_state_note_capture_gap(rtState, UInt32(min(deltaUs - periodUs, 4_000_000)))
            }
        }
        lastCaptureHostTime = now
        lastCaptureFrames = frameCount

        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: abl))
        guard list.count > 0, let firstRaw = list[0].mData else { return }

        if list.count >= 2, let secondRaw = list[1].mData {
            let left = firstRaw.assumingMemoryBound(to: Float.self)
            let right = secondRaw.assumingMemoryBound(to: Float.self)
            var peakL: Float = 0, peakR: Float = 0
            vDSP_maxmgv(left, 1, &peakL, vDSP_Length(frameCount))
            vDSP_maxmgv(right, 1, &peakR, vDSP_Length(frameCount))
            alk_state_note_capture(rtState, UInt64(frameCount), max(peakL, peakR))
            _ = alk_ring_write_planar(ring, left, right, UInt32(frameCount))
            return
        }

        let channels = max(1, Int(list[0].mNumberChannels))
        let ptr = firstRaw.assumingMemoryBound(to: Float.self)
        var peak: Float = 0
        vDSP_maxmgv(ptr, 1, &peak, vDSP_Length(frameCount * channels))
        alk_state_note_capture(rtState, UInt64(frameCount), peak)
        if channels == 1 {
            _ = alk_ring_write_planar(ring, ptr, ptr, UInt32(frameCount))
        } else {
            _ = alk_ring_write_interleaved(ring, ptr, UInt32(channels), UInt32(frameCount))
        }
    }

    // MARK: - Ring → EQ → output (realtime render block, consumer thread)

    /// The source node's render callback. Pulls frames from the ring into the
    /// preallocated scratch, runs the EQ in place, meters, and scatters into
    /// the node's (deinterleaved float) ABL. Realtime-safe: no allocation, no
    /// Swift locks — only C atomics and the processor's non-blocking try-lock.
    private func render(frameCount: Int, into abl: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        let listPtr = UnsafeMutableAudioBufferListPointer(abl)
        guard alk_state_running(rtState), frameCount > 0 else {
            clearOutputBuffers(listPtr)
            return noErr
        }

        let frames = min(frameCount, Self.maxRenderFrames)
        if frames < frameCount {
            clearOutputBuffers(listPtr)   // absurdly large ask; render what we can
        }
        alk_state_note_render(rtState, UInt32(frames))

        // Effective cushion target, adapted to the I/O granularity the devices
        // actually use: surviving one late chunk requires roughly two chunks of
        // headroom. With small device buffers this stays at the ~40 ms base.
        let captureQuantum = Int(alk_state_max_capture_frames(rtState))
        let renderQuantum = max(frames, Int(alk_state_max_render_frames(rtState)))
        let effectiveTarget = min(
            Self.maxTargetFrames,
            max(ringTargetFrames, 2 * (captureQuantum + renderQuantum))
        )

        let avail = Int(alk_ring_readable(ring))

        // Prime: hold silence until the ring reaches the target fill so playback
        // starts (and resumes after an underrun) with a full cushion instead of
        // stuttering at fill ≈ 0.
        if !alk_state_primed(rtState) {
            if avail >= effectiveTarget {
                alk_state_set_primed(rtState, true)
                renderFadeInPending = true
            } else {
                clearOutputBuffers(listPtr)
                return noErr
            }
        }

        // Latency resync: slow clock drift grows the fill over minutes. Once it
        // exceeds twice the target, fade this buffer to silence, jump the read
        // position back to the target, and fade back in — one brief managed dip
        // instead of a click (and instead of latency creeping forever).
        let resync = avail > 2 * effectiveTarget + 2_048

        let got = Int(alk_ring_read(ring, renderScratchL, renderScratchR, UInt32(frames)))
        alk_state_note_ring_read(rtState, UInt64(got))

        if got < frames {
            // Hard underrun. Fade the edge to soften the click, zero the rest,
            // and re-prime so we come back with a full cushion (and a fade-in).
            if got > 0 {
                let fade = min(64, got)
                for i in 0..<fade {
                    let gain = Float(fade - 1 - i) / Float(fade)
                    renderScratchL[got - fade + i] *= gain
                    renderScratchR[got - fade + i] *= gain
                }
            }
            for n in got..<frames {
                renderScratchL[n] = 0
                renderScratchR[n] = 0
            }
            alk_state_set_primed(rtState, false)
            alk_state_note_underrun(rtState)
        } else if renderFadeInPending {
            // First buffer after (re)priming: ramp in over ~10 ms so playback
            // resumes without an attack click.
            let ramp = min(frames, max(64, ringTargetFrames / 4))
            for n in 0..<ramp {
                let gain = Float(n) / Float(ramp)
                renderScratchL[n] *= gain
                renderScratchR[n] *= gain
            }
            renderFadeInPending = false
        }

        if resync && got == frames {
            for n in 0..<frames {
                let gain = Float(frames - 1 - n) / Float(frames)
                renderScratchL[n] *= gain
                renderScratchR[n] *= gain
            }
            let after = Int(alk_ring_readable(ring))
            if after > effectiveTarget {
                _ = alk_ring_drop(ring, UInt32(after - effectiveTarget))
            }
            renderFadeInPending = true
            alk_state_note_resync(rtState)
        }

        // EQ in place (preamp + cascade + clip guard). The returned pre-guard
        // peak is the honest clipping signal — the guard caps output below 1.0,
        // so the post-output peak alone can't reveal an overshoot anymore.
        let processMetrics = processor.processInPlaceWithMetrics(
            left: renderScratchL,
            right: renderScratchR,
            frames: frames
        )
        alk_state_set_active_render_mode(
            rtState,
            processor.activeRenderModeOnRenderThread == .hqFIR ? 1 : 0
        )
        alk_state_set_active_render_generation(
            rtState,
            processor.activeRenderStateGenerationOnRenderThread
        )
        let preClipPeak = processMetrics.preProtectionSamplePeak
        let preClipTruePeak = processMetrics.preProtectionTruePeak

        // Meter the post-EQ sample peak and a lightweight inter-sample peak
        // estimate. Per-channel state carries the interpolation context across
        // render callbacks; this remains telemetry, not a mastering limiter.
        let peaks = truePeakEstimator.processStereo(
            left: renderScratchL,
            right: renderScratchR,
            frames: frames
        )
        // With protection off, post-EQ equals pre-protection and the stateful
        // output estimator supplies the inter-sample component. With protection
        // on, the processor's pre-guard estimator wins whenever it was hotter.
        let detectedPreClipTruePeak = max(preClipTruePeak, peaks.estimatedTruePeak)
        alk_state_note_output(
            rtState,
            peaks.samplePeak,
            preClipPeak,
            detectedPreClipTruePeak,
            peaks.estimatedTruePeak,
            detectedPreClipTruePeak >= 1.0
        )

        scatter(left: renderScratchL, right: renderScratchR, frames: frames, into: listPtr)
        return noErr
    }

    private func clearOutputBuffers(_ list: UnsafeMutableAudioBufferListPointer) {
        for buffer in list {
            guard let raw = buffer.mData else { continue }
            memset(raw, 0, Int(buffer.mDataByteSize))
        }
    }

    /// Writes planar L/R into the node's AudioBufferList (handles 1..N channels).
    private func scatter(
        left: UnsafeMutablePointer<Float>,
        right: UnsafeMutablePointer<Float>,
        frames: Int,
        into list: UnsafeMutableAudioBufferListPointer
    ) {
        for (idx, buffer) in list.enumerated() {
            guard let raw = buffer.mData else { continue }
            let src = (idx % 2 == 0) ? left : right
            let bytes = min(frames * MemoryLayout<Float>.size, Int(buffer.mDataByteSize))
            memcpy(raw, src, bytes)
        }
    }

    // MARK: - Telemetry timer (~10 Hz)

    private func startTelemetry() {
        stopTelemetry()
        // Re-seed the servo before the first tick (ordered ahead of the timer
        // on the serial queue) so a restart never reuses a stale fill average.
        telemetryQueue.async { [weak self] in
            self?.servoFilteredFill = -1
            self?.servoRatePpm = 0
        }
        let timer = DispatchSource.makeTimerSource(queue: telemetryQueue)
        timer.schedule(deadline: .now() + 0.1, repeating: 0.1)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.updateDriftServo()
            self.emitTelemetry()
        }
        telemetryTimer = timer
        timer.resume()
    }

    /// One drift-servo step (~10 Hz, telemetry queue only).
    ///
    /// The capture and output devices run on independent clocks, so left alone
    /// the ring fill walks away from its target until it ends in an audible
    /// event — a faded resync (fill doubled) or an underrun gap (ring dry).
    /// Transient scheduling stalls erode the cushion the same way: frames not
    /// captured during a stall are simply gone, and nothing refills the gap.
    ///
    /// This loop holds the smoothed fill at the render thread's own effective
    /// target by trimming the varispeed rate a few ppm — a proportional
    /// controller with a ~8 s time constant. Correction this slow and this
    /// small (≤ ±500 ppm ≈ under a cent of pitch) is inaudible, unlike the
    /// per-callback ±1-sample servo this design deliberately avoids.
    private func updateDriftServo() {
        guard let varispeed = varispeedNode else { return }
        let sr = currentSampleRate()
        let engineRunning = currentIsRunning() && outputEngine.isRunning && inputEngine.isRunning
        guard engineRunning, sr > 0, alk_state_primed(rtState) else {
            // Unprimed/stopped: forget the average (priming jumps the fill) and
            // park the rate at unity so re-prime fades start from neutral speed.
            servoFilteredFill = -1
            servoRatePpm = 0
            if varispeed.rate != 1.0 { varispeed.rate = 1.0 }
            return
        }

        // Mirror the render thread's effective cushion target.
        let captureQuantum = Int(alk_state_max_capture_frames(rtState))
        let renderQuantum = Int(alk_state_max_render_frames(rtState))
        let target = Double(min(
            Self.maxTargetFrames,
            max(ringTargetFrames, 2 * (captureQuantum + renderQuantum))
        ))

        // Smooth the bursty instantaneous fill (it swings by a whole capture
        // chunk between callbacks) so the servo tracks drift, not cadence.
        let fill = Double(alk_ring_readable(ring))
        servoFilteredFill = servoFilteredFill < 0
            ? fill
            : servoFilteredFill + Self.servoFilterAlpha * (fill - servoFilteredFill)

        // P-control: fill error → consumption-rate trim. rate > 1 drains the
        // ring faster (fill too high), rate < 1 lets it refill (fill too low).
        let errorFrames = servoFilteredFill - target
        let trim = errorFrames / (Self.servoTimeConstant * sr)
        let ppm = Swift.min(Self.servoMaxTrimPpm, Swift.max(-Self.servoMaxTrimPpm, trim * 1_000_000))
        servoRatePpm = ppm
        let newRate = Float(1.0 + ppm / 1_000_000)
        if newRate != varispeed.rate { varispeed.rate = newRate }
    }

    private func stopTelemetry() {
        // Drop the handler before cancel so an in-flight tick can't dispatch a
        // fresh telemetry emit while we're tearing the engine down — that emit
        // would hop to the main actor and touch state that stop() is mutating
        // on this thread right below.
        telemetryTimer?.setEventHandler {}
        telemetryTimer?.cancel()
        telemetryTimer = nil
        // Barrier drain. stop()/startTelemetry() are only ever called from the
        // main actor (via AppModel), never from telemetryQueue, so this .sync
        // can't deadlock. It guarantees any tick already dequeued has finished
        // — including any in-flight emitTelemetry() — before we return, so the
        // caller can't observe a half-torn-down timer. The previous
        // getSpecific-gated sync could be skipped if the key wasn't set, which
        // left a race window open right where it mattered most.
        telemetryQueue.sync {}
    }

    /// Builds and dispatches one telemetry snapshot by draining the atomic
    /// counters the audio threads filled since the last tick.
    private func emitTelemetry() {
        stateLock.lock()
        let stateRunning = isRunning
        let sr = sampleRate
        let hardwareLatencyFrames = devicePathLatencyFrames
        let measuredFIRRequested = renderMode == .hqFIR
        let requestedGeneration = requestedRenderGeneration
        stateLock.unlock()

        let stats = alk_state_drain(rtState)
        let running = stateRunning && outputEngine.isRunning && inputEngine.isRunning
        let frames = stats.last_buffer_frames > 0 ? Int(stats.last_buffer_frames) : 256
        let ringAvailable = Int(alk_ring_readable(ring))

        let peak = running ? Double(stats.out_peak) : 0
        let preClipPeak = running ? Double(stats.pre_clip_peak) : 0
        let preClipTruePeak = running ? Double(stats.pre_clip_true_peak) : 0
        let truePeak = running ? Double(stats.true_peak) : 0
        let capturePeak = running ? Double(stats.cap_peak) : 0
        let peakDb = peak > 0 ? 20.0 * log10(peak) : -120.0
        let preClipPeakDb = preClipPeak > 0 ? 20.0 * log10(preClipPeak) : -120.0
        let preClipTruePeakDb = preClipTruePeak > 0 ? 20.0 * log10(preClipTruePeak) : -120.0
        let truePeakDb = truePeak > 0 ? 20.0 * log10(truePeak) : -120.0
        let capturePeakDb = capturePeak > 0 ? 20.0 * log10(capturePeak) : -120.0
        // One-way path latency ≈ HAL capture/output latency + live ring fill +
        // one output quantum. This is still an estimate (not a loopback impulse
        // measurement), but it includes the hardware offsets CoreAudio reports.
        let latency = running && sr > 0
            ? (Double(hardwareLatencyFrames + ringAvailable + frames) / sr) * 1000.0
            : 0

        let telemetry = AudioTelemetry(
            sampleRate: sr,
            bufferFrames: frames,
            latencyMs: latency,
            peakDb: max(peakDb, -120),
            preClipPeakDb: max(preClipPeakDb, -120),
            preClipTruePeakDb: max(preClipTruePeakDb, -120),
            estimatedTruePeakDb: max(truePeakDb, -120),
            capturePeakDb: max(capturePeakDb, -120),
            clipping: stats.clipped && running,
            clippingEvents: running ? Int(stats.clip_events) : 0,
            running: running,
            captureCallbacks: running ? Int(stats.capture_callbacks) : 0,
            renderCallbacks: running ? Int(stats.render_callbacks) : 0,
            capturedFrames: running ? Int(stats.captured_frames) : 0,
            renderedFrames: running ? Int(stats.rendered_frames) : 0,
            ringReadFrames: running ? Int(stats.ring_read_frames) : 0,
            ringAvailableFrames: running ? ringAvailable : 0,
            underruns: running ? Int(stats.underruns) : 0,
            resyncs: running ? Int(stats.resyncs) : 0,
            captureGaps: running ? Int(stats.capture_gaps) : 0,
            maxCaptureGapMs: running ? Double(stats.max_capture_gap_us) / 1_000.0 : 0,
            ringTargetFrames: min(
                Self.maxTargetFrames,
                max(ringTargetFrames,
                    2 * (Int(alk_state_max_capture_frames(rtState)) + Int(alk_state_max_render_frames(rtState))))
            ),
            driftServoPpm: servoRatePpm,
            measuredFIRActive: running && stats.active_render_mode == 1,
            measuredFIRRequested: measuredFIRRequested,
            requestedRenderGeneration: requestedGeneration,
            committedRenderGeneration: running ? stats.active_render_generation : 0
        )
        onTelemetry?(telemetry)
    }

    // MARK: - State snapshots

    private func currentEnabled() -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }; return enabled
    }
    private func currentIsRunning() -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }; return isRunning
    }
    private func currentPresetSnapshot() -> EQPreset {
        stateLock.lock(); defer { stateLock.unlock() }; return currentPreset
    }
    private func currentRenderMode() -> EQRenderMode {
        stateLock.lock(); defer { stateLock.unlock() }; return renderMode
    }
    private func currentSelectedOutput() -> OutputDevice? {
        stateLock.lock(); defer { stateLock.unlock() }; return selectedOutput
    }
    private func currentSampleRate() -> Double {
        stateLock.lock(); defer { stateLock.unlock() }; return sampleRate
    }

    /// Effective preamp = preset preamp, plus a guard cut in Safe Mode so a hot
    /// preset cannot push the output into clipping.
    private func effectivePreamp() -> Double {
        stateLock.lock()
        let base = preampDb
        let safe = safeMode
        let preset = currentPreset
        let sr = sampleRate
        stateLock.unlock()
        let guarded = safe ? Swift.min(base, safePreamp(for: preset, sampleRate: sr)) : base
        return Swift.min(Swift.max(guarded, EQPreset.preampRange.lowerBound), EQPreset.preampRange.upperBound)
    }

    private func safePreamp(for preset: EQPreset, sampleRate: Double) -> Double {
        var noPreamp = preset.normalized()
        noPreamp.preampDb = 0
        return PresetValidator(
            rules: .default,
            sampleCount: 256,
            estimationSampleRate: sampleRate
        ).autoPreamp(for: noPreamp)
    }

    // MARK: - Errors

    enum RoutingError: LocalizedError {
        case deviceUnavailable(String)
        case engineFailure(String)

        var errorDescription: String? {
            switch self {
            case .deviceUnavailable(let s): return "Audio device unavailable: \(s)"
            case .engineFailure(let s):     return "Audio engine error: \(s)"
            }
        }
    }
}
