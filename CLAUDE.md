# Auralink EQ

macOS menubar system-wide EQ: BlackHole loopback capture → 20-band EQ (Swift/AVFoundation,
realtime C ring) → real output device. A local MCP server (Node/TS) lets AI clients read
state and create/apply tunings.

**Golden rules**
- The app may be running and carrying live audio during development. Ask before
  killing/restarting it, batch restarts, and restore routing through the app UI.
- Treat user-provided hardware and routing details as the ground truth for the task.
- Never print, commit, or transmit the local ControlServer bearer token.

## Layout

| Path | What |
|---|---|
| `Sources/AuralinkApp` | Menubar app: `Audio/AudioRoutingEngine.swift` (two engines + lock-free ring + varispeed drift servo), `AppModel.swift` (state, watchdogs, event log), `Control/ControlServer.swift` (HTTP API), `Views/` (popover, editor, Monitor) |
| `Sources/AuralinkCore` | DSP (biquads, measured minimum-phase FIR + partitioned convolution, EQProcessor), presets, knowledge models, response math |
| `Sources/AuralinkRT` | C target: lock-free SPSC ring + atomic RT counters (`alk_*`) |
| `mcp-server/` | MCP server; thin client of the HTTP API (`npm run build` inside) |
| `scripts/bundle-app.sh` | Release build + .app bundle + dev signing (TCC-stable) |

## Build / test / deploy

```bash
swift build && swift test          # full Swift suites must stay green
./scripts/bundle-app.sh            # release bundle → build/Auralink EQ.app
# Restarting a running build interrupts audio; obtain user approval first and
# restore System EQ through the app UI afterwards.
```

## Control API — `http://127.0.0.1:8765`

The API requires the bearer capability generated at
`~/Library/Application Support/Auralink/control-token`. Use the MCP client for
normal control; do not place the token in commands, logs, or repository files.

- `GET /state` (live telemetry incl. `underrunsTotal`/`resyncsTotal`), `GET /debug`
  (engine internals, drift-servo ppm, `recentAudioEvents` trail), `GET /devices`,
  `GET /presets`, `GET /preset?id=`
- `POST /apply {id, confirmed}`, `/audition-preset`, `/save-current-preset`, `/rollback`,
  `/preset` (upsert), `/validate`, `/select-output {uid}`, `/route-system-audio`,
  `/restore-system-audio`, `/stop-routing`, `/reload-presets`, `/reload-knowledge`

## Common task recipes

### Add a headphone to the list
Use the MCP tool **`upsert_headphone_profile`** (or edit the data file, below, then
`POST /reload-knowledge`). Do NOT hunt the filesystem first.
1. Measured data exists? `get_autoeq_correction {model}` (AutoEq + disk cache).
2. Not in AutoEq (new release): read a squig.link measurement screenshot if the user
   provides one; otherwise text reviews → profile with `credibility: "estimated"`
   and honest `correctionNotes` (see TimeEar NH60 entry for the estimated style).
3. `upsert_headphone_profile`, then verify with `list_headphone_profiles`.
4. Full tuning flow afterwards: `get_agent_eq_guide` is the canonical guide
   (measured-first; audition → feedback → save-on-like).

### Data locations (user-level, survive updates)
`~/Library/Application Support/Auralink/`: `data/headphone-profiles.json`,
`data/target-curves.json`, `data/safety-rules.json`, `presets/`, `revisions/`,
`autoeq-cache/`. The app watches presets/knowledge files and also exposes the
reload endpoints.

### Shared git library
`library/headphones/*.json` (git) is dual-written to
`~/Library/Application Support/Auralink/library/headphones/` so the installed
app can load per-file profiles. After pulling library changes, run
`scripts/sync-runtime-library.sh` (or just use MCP tools, which dual-write).


### Debug a pop/glitch report
1. `GET /debug` → `recentAudioEvents` (underrun / resync / capture-gap / overload /
   recovery / repin, timestamped). Empty trail + clean counters ⇒ the app path was
   clean — suspect upstream (source app → BlackHole) or downstream (device chain).
2. Monitor window (popover → ECG icon): live seismograph; events auto-capture ±10 s
   incident reports with a Copy button for sharing in the issue or task.
3. Drift servo should hover within tens of ppm; fill pinned to target. Resync/underrun
   are last-resort backstops — recurring ones are a bug.

## Engine contracts & gotchas (violating these reintroduces fixed bugs)

- **Measured FIR is data- and quality-gated, never an IIR copy.** Standard IIR renders all bands and remains the default/Luxsin path. Measured mode is global preamp once + persisted preamp-excluded GraphicEQ baseline FIR + only `preferenceBandIndexes` as IIR. Invalid hash/schema/confidence, failed per-rate fit, or insufficient PEQ improvement must fail closed to Standard IIR; never market FIR as inherently better sound.
- **FIR render-state ownership is RT-critical.** Prepared/active/fading states are class-owned; every state discarded on the callback must be retained into the C11 SPSC retirement queue and destroyed on control. Gain/bypass/mode transitions through 8,192 frames use preallocated block buffers so FIR never falls back to scalar 512-tap ramp work. Do not reintroduce callback ARC destruction/CoW/allocation. All `EQProcessor` control methods are called from one serialized thread (the MainActor via AppModel/AudioRoutingEngine) — preparation intentionally runs outside `controlLock`, so concurrent control callers would publish generations out of order.
- **Live apply truth requires exact generation commit.** Audio state separates requested versus callback-committed render mode and DSP generation. MCP `audible:true` requires expected preset/generation = requested = committed, routing active, system output routed through Auralink, and EQ enabled. Control `ok` alone is not an audible change. The MCP client polls `/state` (≤3 reads, 75 ms apart) through transient telemetry/commit lag; stable routing/EQ failures are not retried.
- **No per-sample drift correction.** Clock drift is absorbed by the varispeed P-servo
  (±500 ppm, telemetry thread). Per-callback ±1-sample drop/dup = audible tick source.
- **Capture via AVAudioSinkNode**, never an input tap (taps batch ~100 ms → underruns).
- **Rate switches:** the graph is built at the rate the *input AU actually reports*
  (`settledCaptureRate`) — a reused AVAudioEngine can serve stale formats long past
  polite retries. Never hard-fail start on a rate mismatch; let recovery converge.
- **Output AU re-pinning:** a (re)initialized output AU silently re-adopts the system
  default device (= BlackHole while System EQ is on ⇒ feedback loop). Keep retry-pin,
  sentinel, and feedback breaker intact.
- **Recreate the AVAudioEngine pair on every start** (`recreateEnginesForFreshStart`):
  a reused AUHAL refuses a `CurrentDevice` change ("nope") when switching between
  outputs on different clocks (built-in speaker ↔ HDMI). Fresh
  `inputEngine`/`outputEngine` per start is what makes device switching safe.
- **Output switching while routing = a verified transaction**, not a timing tweak.
  `performRoutedOutputSwitch` stops the realtime path (without publishing
  intermediate state), commits the new output while stopped, then reuses the verified
  start path — each step checked against real CoreAudio/engine state
  (`waitForDefaultOutput`, `engineIsHealthy`, `outputBindingHealthy`). While the
  transaction (`audioPathTransactionInProgress`) is in progress, `ingest()` is
  suppressed and hardware refresh is deferred; pickers read the stable
  `OutputPickerSnapshot`, not live fields. A field-by-field / half-transitioned
  publish during a switch reintroduces the SwiftUI executor-check crash.
- **UI target only disables actor-isolation runtime checks.** `Package.swift` sets
  `-Xfrontend -disable-dynamic-actor-isolation` + `-disable-actor-data-race-checks`
  for `AuralinkApp` only (works around the macOS 26 / Swift 6.2 executor-check
  crash). `AuralinkCore`/`AuralinkRT` keep the checks. AppModel is `@MainActor` and
  all audio callbacks hop back — don't remove this asymmetry blindly; revisit once
  the compiler fix (Swift #87097, backported to 6.3) ships.
- **Coalesce all telemetry into one `audioState` write per tick** and gate the
  seismograph `TimelineView` behind `scenePhase == .active`. Field-by-field
  `@Published` writes (≈25/tick) and a 10 Hz diag push redraw the editor ZStack
  millions of times over a long session and crash on background→foreground return.
  While backgrounded: suppress the watchdog and defer recovery to foreground
  (`recoveryDeferredWhileBackgrounded`) — macOS throttles capture cadence in the
  background, which is not a dead engine.
- **UI publish gate — do NOT reintroduce `@Published` on AppModel.** macOS 26's
  system-compiled DesignLibrary/SwiftUI crashes on a bogus SerialExecutorRef during
  *backgrounded* display-cycle layout passes (Swift #87097/#89197) — those passes are
  driven by our own invalidations. AppModel properties notify via
  `willSet { uiChanged() }` into an explicit `objectWillChange`; while nobody can see
  the UI (app inactive, no key window, no visible titled window —
  `reevaluateUIPublishGate()`, fed by AppDelegate window observers) notifications are
  withheld and flushed once on re-engagement. Values stay live (control API/watchdog
  read current state); only SwiftUI invalidation is gated. Belt-and-braces:
  `LSEnvironment SWIFT_IS_CURRENT_EXECUTOR_LEGACY_MODE_OVERRIDE=legacy` in the
  bundle's Info.plist (bundle-app.sh).
- I/O buffers are sized by time (~10.7 ms: 512/1024/2048 @ 48/96/192 kHz); a
  latency-critical NSActivity is held while routing runs (App Nap kills RT deadlines).
- EQProcessor test contract: gain ramps apply only after audio has flowed; initial
  settings snap immediately. `AudioTelemetry`/`AudioState` inits use defaulted
  parameters — extend by appending defaulted fields, never reorder.
- Output device selection and last preset persist via UserDefaults — keep both.
- Realtime threads (capture sink / render block): no Swift locks, no allocation,
  C atomics only. The telemetry thread owns the servo state.
