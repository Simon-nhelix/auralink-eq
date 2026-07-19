# Auralink EQ — Build Spec (interface contract)

> Product: **Auralink EQ** — a macOS menubar 20-band parametric EQ for *system-wide* sound,
> with a local **MCP server** so an AI (Claude/ChatGPT) can read state and generate/validate/apply
> per-headphone tunings in natural language. Native Swift/SwiftUI + AVFoundation, BlackHole-style
> routing (capture from a virtual device → EQ → real output device).

This file is the **single source of truth** all modules conform to. Types in `AuralinkCore/Models`
and `AppModel`/`Theme` already exist — **import and use them, never redefine them.**

## Layout

```
Sources/AuralinkCore/        # pure logic, no UI/audio-hardware. Unit-tested.
  Models/        (DONE — contract)   EQBand, EQPreset, HeadphoneProfile, TargetCurve,
                                     SafetyRules, AudioState, Validation, Analysis(ResponsePoint),
                                     AITuning(AITuningRequest/TuningChange/TuningResult)
  AuralinkPaths.swift (DONE)
  DSP/           Biquad, EQProcessor, FrequencyResponse, MeasuredFIRDesigner,
                 PartitionedFIRConvolver (legacy FIRDesigner fixtures remain) [agent: core-dsp]
  Presets/       PresetStore, PresetValidator                             [agent: core-preset]
  Knowledge/     KnowledgeBase, TuningEngine                              [agent: core-knowledge]
  Resources/data/  headphone-profiles.json, target-curves.json, safety-rules.json [core-knowledge]
Sources/AuralinkRT/              # C11 SPSC audio ring, atomic telemetry, opaque-state retirement queue
Sources/AuralinkApp/
  AppModel.swift (DONE — contract), Views/DesignSystem/* (DONE)
  AuralinkApp.swift  @main, MenuBarExtra + editor Window                  [agent: app-audio]
  Audio/         AudioRoutingEngine, AudioDeviceManager, AudioTelemetry   [agent: app-audio]
  Control/       ControlServer (HTTP for MCP)                             [agent: app-audio]
  Views/         MenuBarView, PermissionDialogView, EditorWindow          [agent: views-shell]
                 EQGraphView, BandTableView, TopBarView                   [agent: views-editor]
                 AITuningPanelView, AIResultView, PresetLibraryView, HeadphonePanelView [agent: views-panels]
Tests/AuralinkCoreTests/  DSPTests, PresetTests, TuningTests
mcp-server/      Node/TypeScript MCP server                              [agent: mcp]
scripts/, docs/, README.md                                              [agent: docs]
```

## Conventions
- Swift language mode 5 (set in Package.swift). `import AuralinkCore` in app files.
- `@MainActor` for anything touching `AppModel`/UI. Audio engine may use its own queue but must
  hop to main when calling `onTelemetry`.
- No force-unwraps in non-test code. Clamp all user/AI input via the `.clamped()` / `.normalized()` helpers.
- Match existing comment density. Use `Theme.*` tokens and `AuraCard`/`AuraButtonStyle`/`Fmt` in views.

---

## CORE interfaces (must match exactly — `AppModel` calls these)

### DSP  [core-dsp]
```swift
// Biquad.swift — RBJ Audio EQ Cookbook coefficients.
public struct Biquad {
    public init()
    // Configure for one band at a sample rate. No-op/passthrough if !enabled or gain≈0 for gain types.
    public mutating func configure(type: BandType, frequencyHz: Double, gainDb: Double, q: Double, sampleRate: Double)
    public mutating func reset()                  // clear filter state (z1,z2)
    public mutating func process(_ x: Float) -> Float
    // Complex magnitude (linear) at a frequency, for the response curve.
    public func magnitude(atHz f: Double, sampleRate: Double) -> Double
}

// EQProcessor.swift — cascade of up to 20 biquads per channel + preamp, real-time safe.
public final class EQProcessor {
    public init(sampleRate: Double, channelCount: Int = 2)
    public func update(preset: EQPreset)          // prepare off RT; install at a buffer boundary
    public func setSampleRate(_ sr: Double)
    public func setEnabled(_ on: Bool)            // bypass
    public func setPreamp(_ db: Double)
    public func setRenderMode(_ mode: EQRenderMode) -> Bool // prepares/request; false = fail-closed to standard_iir
    public var activeRenderModeOnRenderThread: EQRenderMode { get } // callback-committed, RT read only
    public func setClipProtectionEnabled(_ enabled: Bool) // Safe Mode only
    // Process interleaved-free planar buffers in place. right may be nil (mono).
    public func processInPlace(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>?, frames: Int) -> Float
    public func processInPlaceWithMetrics(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>?, frames: Int) -> EQProcessMetrics
}

// EQPreset.CorrectionMetadata may carry a versioned MeasuredCorrectionPayload:
// dense preamp-excluded magnitude points, usable bounds, source/result URLs,
// source rig/target/revision, content hash, and retrieval timestamp. Normalize
// at Swift and TypeScript boundaries; malformed/legacy payloads remain PEQ-only.
public enum EQRenderMode: String, Codable, Sendable { case standardIIR = "standard_iir", hqFIR = "hq_fir" }
public enum MeasuredFIRDesigner {
    // Sample-rate-adaptive minimum-phase design from the persisted dense curve.
    // Returns nil unless implementation-error AND independent-benefit gates pass.
    public static func design(for preset: EQPreset, sampleRate: Double) -> MeasuredStereoFIRResult?
}
public final class MeasuredFIRDesignCache {
    public func design(for preset: EQPreset, sampleRate: Double) -> MeasuredStereoFIRResult?
}
public final class PartitionedFIRConvolver {
    // Direct head + partitioned FFT tail; no block delay; arbitrary callbacks.
    public init(taps: [Float] = [1], partitionSize: Int = 128)
    public func process(_ x: Float) -> Float
    public func processInPlace(_ buffer: UnsafeMutablePointer<Float>, frames: Int)
    public func reset()
}
// FIRDesigner/FIRDesignCache remain only as legacy 512-tap IIR-approximation
// quality fixtures. They are not the production hq_fir renderer.

// FrequencyResponse.swift — for the editor graph + clipping estimate.
public enum FrequencyResponse {
    public static func logFrequencies(count: Int, from: Double = 20, to: Double = 20_000) -> [Double]
    public static func magnitudeDb(of preset: EQPreset, atHz f: Double, sampleRate: Double) -> Double
    public static func magnitudeDb(of preset: EQPreset, atHz f: Double, sampleRate: Double, renderMode: EQRenderMode) -> Double
    public static func curve(for preset: EQPreset, at frequencies: [Double], sampleRate: Double, renderMode: EQRenderMode) -> [ResponsePoint]
}
```
DSP notes: Standard IIR renders all enabled bands. Measured FIR renders the persisted
preamp-excluded baseline curve, then only `correction.preferenceBandIndexes` as IIR,
then global preamp exactly once. Missing data or a failed accuracy/benefit/CPU gate
must keep Standard IIR active. Both response and validator math must use the same
renderer semantics. FIR does not imply better sound; promotion means only lower
measured target error than the PEQ fallback. Tests cover 44.1/48/96/192 kHz,
arbitrary callback segmentation, transitions, no steady render allocation, and
legacy preset fallback.

### Presets  [core-preset]
```swift
// PresetStore.swift — one JSON file per preset under `directory`; prior versions snapshotted under `revisionsDirectory/<id>/`.
public final class PresetStore {
    public init(directory: URL, revisionsDirectory: URL)
    public func loadAll() throws -> [EQPreset]                      // seeds 3 factory presets if dir empty
    public func get(id: String) throws -> EQPreset?
    public func save(_ preset: EQPreset) throws -> EQPreset          // snapshot current on-disk → revisions, bump version, set updatedAt(now)
    public func delete(id: String) throws
    public func duplicate(id: String, newName: String) throws -> EQPreset   // new id, version 1
    public func revisions(of id: String) throws -> [EQPreset]        // newest first
    public func previousRevision(of id: String) throws -> EQPreset?  // most recent snapshot
    public func export(_ preset: EQPreset, to url: URL) throws       // pretty JSON
    public func importPreset(from url: URL) throws -> EQPreset       // validates JSON, assigns fresh id if collision
}
```
Use `JSONEncoder` with `.prettyPrinted`, `.sortedKeys`, `.iso8601` dates. `loadAll` must call `.normalized()`.
Factory seed presets: "Flat", "Warm & Smooth", "Vocal Clarity" (use sensible bands).
NOTE: `Date()`/`UUID()` are allowed in app/core code (this is a real app), just not in workflow scripts.

```swift
// PresetValidator.swift — enforces SafetyRules; estimates clipping from the response peak.
public final class PresetValidator {
    public init(rules: SafetyRules)
    public func validate(_ preset: EQPreset) -> ValidationResult
    public func autoPreamp(for preset: EQPreset) -> Double   // ≤0; offsets peak boost to keep targetHeadroom
}
```
Estimate peak gain by sampling `FrequencyResponse.curve` (without preamp) → peakDb. clippingRisk:
peak+preamp ≤ -targetHeadroom → low; ≤ +1 → medium; else high. Emit issues for: any band gain beyond
maxBoostDb (warning), aggregate beyond maxAggregateBoostDb (warning), Q/gain out of range (error).
ok = no `.error` issues. `autoPreamp = -max(0, peakDb - targetHeadroom... )` rounded to 0.5 dB.

### Knowledge + Tuning  [core-knowledge]
```swift
// KnowledgeBase.swift — loads bundled JSON (dataDirectory first, else Bundle.module/data).
public final class KnowledgeBase {
    public init(dataDirectory: URL?)
    public var headphoneProfiles: [HeadphoneProfile] { get }
    public var targetCurves: [TargetCurve] { get }
    public var safetyRules: SafetyRules { get }
    public func profile(id: String) -> HeadphoneProfile?
    public func profileMatching(_ name: String) -> HeadphoneProfile?   // fuzzy: slug/brand/model contains
    public func targetCurve(id: String) -> TargetCurve?
    public func seedDataDirectory(_ dir: URL)   // copy bundled JSON into dir if missing (for MCP)
}

// TuningEngine.swift — DETERMINISTIC heuristic "AI" used by the in-app AI Tuning Panel and as the
// engine behind the MCP create_eq_preset/validate flow. Combines HeadphoneProfile + TargetCurve +
// preference text into an EQPreset, then validates and explains.
public final class TuningEngine {
    public init(knowledge: KnowledgeBase, validator: PresetValidator)
    public func makeTuning(request: AITuningRequest, basePreset: EQPreset?) -> TuningResult
    public func warmer(_ preset: EQPreset) -> TuningResult           // +low/low-mid shelf, gentle
    public func reduceHarshness(in preset: EQPreset, amountDb: Double) -> TuningResult  // cut 5–9kHz
}
```
makeTuning algorithm: start from target curve hints (or parse goalText keywords: rock/vocal/bass/
bright/warm/footstep/late-night), map hints to bands, scale by headphone correctionNotes & harsh
regions, apply preference keyword nudges, clamp to `maxBoostDb`/`avoidHarshTreble`, set name
"<Headphone> – <Goal>", createdBy=.ai, run validator, set safety.clippingRisk + preampDb=autoPreamp,
build `intent`/`changes` from the diff vs base. Must be pure (no randomness).

### JSON data schema  [core-knowledge authors these files]
`Resources/data/headphone-profiles.json` = `[HeadphoneProfile]`, `target-curves.json` = `[TargetCurve]`,
`safety-rules.json` = `SafetyRules`. Encode with the same field names as the Swift Codable types
(BandType/etc. use snake_case raw values). Provide ≥8 real headphones (Sennheiser HD600, HD650,
Beyerdynamic DT770/DT990, AirPods Max, Sony WH-1000XM5, HIFIMAN Sundara, Audeze, Apple AirPods Pro 2)
and ≥7 target curves (rock, vocal-focus, fps-footstep, late-night, bass-boost, podcast, harman-neutral).
**Also copy identical files into `mcp-server/data/`** so the MCP server has them standalone.

---

## APP audio + control  [app-audio]

```swift
// AudioTelemetry.swift
public struct AudioTelemetry: Sendable {
    public var sampleRate: Double; public var bufferFrames: Int; public var latencyMs: Double
    public var peakDb: Double; public var preClipPeakDb: Double; public var preClipTruePeakDb: Double
    public var estimatedTruePeakDb: Double; public var clipping: Bool; public var running: Bool
    public var measuredFIRActive: Bool       // C-atomic RT-committed renderer
    public var measuredFIRRequested: Bool    // control intent/prepared state
    public var requestedRenderGeneration: UInt64
    public var committedRenderGeneration: UInt64 // C-atomic exact DSP state
}

// AudioDeviceManager.swift — CoreAudio device enumeration.
public final class AudioDeviceManager {
    public init()
    public func outputDevices() -> [OutputDevice]
    public func virtualCaptureDevice() -> OutputDevice?   // first device whose name contains "BlackHole"/"Auralink"/"Loopback"
    public func defaultOutputDevice() -> OutputDevice?
    public func latencyFrames(forUID uid: String, input: Bool) -> Int
}

// AudioRoutingEngine.swift — AVAudioEngine: capture from virtual device → EQProcessor → selected output.
public final class AudioRoutingEngine {
    public init()
    public var onTelemetry: ((AudioTelemetry) -> Void)?
    public func start() throws
    public func stop()
    public func setEnabled(_ on: Bool)
    public func setSafeMode(_ on: Bool)         // forces preamp guard + soft clip guard
    public func setPreamp(_ db: Double)
    public func apply(preset: EQPreset)
    public func selectOutput(device: OutputDevice)
}
```
Routing reality: macOS AVAudioEngine binds one HAL device for I/O. Use the documented approach:
set the engine's **input** AUHAL `kAudioOutputUnitProperty_CurrentDevice` to the virtual capture device,
install a tap or use a `AVAudioSourceNode`/manual-render that pulls input, run frames through
`EQProcessor.processInPlace`, and play to the selected output. If a single-engine two-device path is
not achievable, use **two engines bridged by a ring buffer** (input engine on capture device →
ring buffer → output engine on selected device) — this is the robust path; comment it clearly.
**Graceful degradation:** if no virtual device, `start()` must NOT throw fatally — set running=false,
emit telemetry(running:false), and let the app surface `needsVirtualDevice`. Emit telemetry ~10/s.
Add `NSMicrophoneUsageDescription` need to docs (bundle Info.plist handles entitlement).

```swift
// ControlServer.swift — authenticated localhost HTTP server (Network framework / NWListener).
public final class ControlServer {
    public init(model: AppModel, port: UInt16 = 8765)
    @discardableResult public func start() -> Bool
    public func stop()
}
```
Endpoints (JSON, 127.0.0.1 only):
- `GET /state` → `AudioState` (+ currentPreset id/name, requested/active render mode, requested/committed DSP generation, and measured-FIR status)
- `GET /devices` → `[OutputDevice]`
- `GET /presets` → `[EQPreset]`   ·  `GET /preset?id=` → `EQPreset`
- `POST /apply` body `{ "id": "..." }` → applies preset (respects permissionMode; returns {ok, needsConfirm})
- `POST /rollback` → `{ok:false}` when no target exists; otherwise target id/name + requested render generation
- `POST /preset` body `EQPreset` → save (create/update)
- `POST /validate` body `EQPreset` → `ValidationResult`
All endpoints require `Authorization: Bearer <capability>`. The app creates the
capability at `~/Library/Application Support/Auralink/control-token` with mode
0600; the MCP process reads it directly. Reject browser `Origin` requests,
never emit CORS headers, and require `application/json` for POST. All handlers
hop to `@MainActor` to touch AppModel. Keep it dependency-free (no Vapor).

```swift
// AuralinkApp.swift — @main
@main struct AuralinkApp: App {
  // @StateObject AppModel; .onAppear bootstrap(); NSApp.setActivationPolicy(.accessory)
  // MenuBarExtra("Auralink", systemImage: "waveform") { MenuBarView() }.menuBarExtraStyle(.window)
  // Window("Auralink EQ", id: "editor") { EditorWindow() }  (frame min 920x600)
  // start ControlServer(model:).start()
}
```

---

## VIEWS (the "claude design" surface — dark, aura-accented, pro-audio)

All views take `@EnvironmentObject var model: AppModel` (the @main injects it). Use `Theme`/`AuraCard`/
`AuraButtonStyle`/`StatusDot`/`AuraTag`/`SectionLabel`/`Fmt`. Background = `Theme.Palette.bg`.

### [views-shell]
- `MenuBarView` — width `Theme.Metrics.popoverWidth`. Header (app name + aura mark), big **EQ On/Off**
  toggle, current preset name + headphone tag, **output device** menu, **Safe Mode** toggle, recent
  presets (≤5 quick switch), MCP connection `StatusDot`, routing/clipping status, and an
  **"Open Full Editor"** button using `@Environment(\.openWindow) openWindow; openWindow(id:"editor")`.
  If `model.needsVirtualDevice`, show an inline "Set up system audio" notice.
- `PermissionDialogView(result: TuningResult, onApply, onSaveDraft, onCompare, onEdit, onDiscard)` —
  summarizes an AI write action (intent bullets, change list, validation/clipping badge) per plan §8.1.
- `EditorWindow` — the full editor shell: `TopBarView` on top; center = `EQGraphView` over
  `BandTableView`; right = panel switcher (`PresetLibraryView`/`HeadphonePanelView`/`AITuningPanelView`)
  driven by `model.rightPanel`. If `model.pendingProposal != nil`, overlay `AIResultView`.

### [views-editor]
- `EQGraphView` — THE centerpiece. Canvas drawing: log-frequency X axis (20Hz–20kHz grid),
  dB Y axis (−18…+18 grid), the filled aura response curve from `model.responseCurve`, and 20
  **draggable nodes** (one per band, tinted by channel). Drag X→frequency, Y→gain;
  scroll/modifier→Q. Selecting a node sets `model.selectedBandIndex`. Glow on the active curve.
  Show a faint "before" curve when `model.comparingBefore`. Use `Theme.Gradients.curveFill`.
- `BandTableView` — 20-row table: enabled toggle, type menu, frequency, gain, Q, channel. Numeric
  cells editable; reflect/commit via `model.updateBand`. Monospaced (`Theme.Type.mono`).
- `TopBarView` — output device picker, sample rate, latency (ms), buffer, **clipping indicator**
  (red when `audioState.clippingDetected`), EQ On/Off, Safe Mode, A/B button (`model.toggleAB`),
  preamp slider (`model.setPreamp`), Reset.

### [views-panels]
- `AITuningPanelView` — inputs: Headphone (Picker from `model.headphoneProfiles`), Goal
  (Picker/segmented from `model.targetCurves`), Preference (TextField), Safety (max boost stepper,
  "avoid harsh treble" toggle). **"Generate Tuning"** → `model.requestTuning(AITuningRequest(...))`.
  Quick buttons: "Warmer" (`makeWarmer`), "Reduce harshness" (`reduceHarshness`). Show `isTuning`.
- `AIResultView` — renders `model.pendingProposal` (TuningResult) per plan §8.1 with
  [Apply] [Save Draft] [Compare A/B] [Edit Manually] [Discard] wired to AppModel methods.
- `PresetLibraryView` — searchable list of `model.presets` grouped/taggable by headphone & createdBy;
  rows show name, headphone `AuraTag`, version, ai/user badge. Select→`model.load(preset:)`.
  Buttons: New, Duplicate, Delete, Import, Export, Rename.
- `HeadphonePanelView` — shows the profile for `currentPreset.headphone` (signature, correction
  notes, harsh regions, credibility `AuraTag`); list of all profiles to pick from.

---

## MCP server  [mcp]
Node + TypeScript, `@modelcontextprotocol/sdk` (v1.29). stdio transport. Reads/writes the SAME preset
dir (`~/Library/Application Support/Auralink/presets`, override `AURALINK_PRESETS_DIR`) and knowledge
data (`mcp-server/data` or `AURALINK_DATA_DIR`). Live state/apply via the app's ControlServer at
`http://127.0.0.1:8765` (override `AURALINK_CONTROL_URL`) with the shared bearer capability
(`AURALINK_CONTROL_TOKEN_FILE` or explicit `AURALINK_CONTROL_TOKEN`); degrade gracefully if offline.

**Tools** (exact names): `get_current_audio_state`, `list_output_devices`, `list_headphone_profiles`,
`get_headphone_profile`, `list_presets`, `get_preset`, `create_eq_preset`, `validate_eq_preset`,
`apply_eq_preset`, `rollback_preset`. Read tools never require confirm; `create_eq_preset` validates
before writing; `apply_eq_preset`/`rollback_preset` are "destructive" (annotate) and POST to control API.
Additional read/agreement tools: `get_agent_eq_guide`, `get_tuning_guidance`, `get_tuning_brief`
(one-call state bundle: current preset + resolved baseline + safety + recommended start point),
`get_autoeq_correction` (PEQ plus validated/cached GraphicEQ measured payload when available),
`get_response_curve`, `validate_eq_preset`, `upsert_headphone_profile`,
`delete_headphone_profile`, `audition_eq_preset`, `save_current_preset`, `delete_preset`,
`route_system_audio`, `restore_system_audio`, `stop_audio_routing`, `record_tuning_feedback`,
`get_user_tuning_preferences` (AI taste-memory: feedback log at
`~/Library/Application Support/Auralink/data/user-tuning-preferences.json`, aggregated at read time).

**EQ targets**: default `target:"auralink"` uses the macOS software EQ via ControlServer. Optional
`target:"luxsin-x8"` writes/selects a hardware PEQ entry on the LAN Luxsin X8 for
`get_current_audio_state`, `create_eq_preset(applyNow:true)`, `audition_eq_preset`, and
`apply_eq_preset`. The X8 target must: discover/cache changed device IPs, return `online:false`
when absent, verify `syncData.device == "Luxsin-X8"` before writes, encode/decode the custom
base64 CGI protocol, write `peqChange`/`peqRemove` with `data=<encoded>`, map to the X8 numeric
filter type codes, trim to 10 bands, pad with transparent `PEAKING 0 dB` filters (never
`LOW_PASS@0`), and restore active entries by name after DB mutations.

**Resources**: `eq://current-state`, `eq://presets`, `eq://headphones/{id}`, `eq://target-curves`,
`eq://safety-rules`. **Prompts**: `create_headphone_tuning`, `reduce_harshness`, `make_genre_tuning`.
Port the validation/clipping math (mirror PresetValidator) in TS so `validate_eq_preset` works offline.
Include `package.json` (build/start scripts), `tsconfig.json`, and a `claude_desktop_config.json` snippet.

## docs/bundle  [docs]
- `scripts/bundle-app.sh`: `swift build -c release` then assemble `Auralink EQ.app` with a generated
  `Info.plist` (LSUIElement=YES, bundle id `com.auralink.eq`, `NSMicrophoneUsageDescription`,
  `LSMinimumSystemVersion 14.0`), copy the `AuralinkApp` binary + AuralinkCore resource bundle, ad-hoc
  codesign (`codesign -s - --deep`). Print next steps.
- `README.md` (overview, architecture diagram, build/run, BlackHole setup, MCP wiring) +
  `docs/SETUP.md` (BlackHole install, set system output, Claude Desktop MCP config) + `.gitignore`.
