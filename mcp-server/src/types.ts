/**
 * TypeScript mirrors of the Swift `AuralinkCore/Models` Codable types.
 *
 * These interfaces must match the on-disk preset JSON and the app's
 * ControlServer wire format byte-for-byte: same field names (camelCase, as Swift
 * emits by default) and the same snake_case enum raw values (e.g. "low_shelf",
 * "ask_before_write"). Anything that crosses the app ⇄ MCP boundary is described
 * here so `store.ts`, `control.ts`, and `validate.ts` all speak one schema.
 */

// MARK: - Enums (raw values mirror the Swift `case … = "…"` declarations)

/** Filter shape of a single band. Mirrors Swift `BandType`. */
export type BandType =
  | "bell"
  | "low_shelf"
  | "high_shelf"
  | "low_pass"
  | "high_pass"
  | "notch";

export const BAND_TYPES: readonly BandType[] = [
  "bell",
  "low_shelf",
  "high_shelf",
  "low_pass",
  "high_pass",
  "notch",
];

/** Whether a band shape uses `gainDb`. Mirrors `BandType.usesGain`. */
export function bandTypeUsesGain(type: BandType): boolean {
  switch (type) {
    case "bell":
    case "low_shelf":
    case "high_shelf":
      return true;
    case "low_pass":
    case "high_pass":
    case "notch":
      return false;
  }
}

/** Which stereo channel(s) a band applies to. Mirrors Swift `BandChannel`. */
export type BandChannel = "stereo" | "left" | "right";

export const BAND_CHANNELS: readonly BandChannel[] = ["stereo", "left", "right"];

/** Who authored a preset. Mirrors Swift `CreatedBy`. */
export type CreatedBy = "user" | "ai";

/** Clipping-risk bucket. Mirrors Swift `ClippingRisk`. */
export type ClippingRisk = "low" | "medium" | "high";

/** Headphone form factor. Mirrors Swift `HeadphoneType`. */
export type HeadphoneType =
  | "open_back"
  | "closed_back"
  | "iem"
  | "earbud"
  | "on_ear"
  | "true_wireless";

export const HEADPHONE_TYPES: readonly HeadphoneType[] = [
  "open_back",
  "closed_back",
  "iem",
  "earbud",
  "on_ear",
  "true_wireless",
];

/** Trust level of a profile's characterization. Mirrors Swift `Credibility`. */
export type Credibility = "measured" | "manufacturer" | "community" | "estimated";

/** Target curve category. Mirrors Swift `TargetCategory`. */
export type TargetCategory = "genre" | "purpose" | "reference";

/** Severity of a validation finding. Mirrors Swift `ValidationSeverity`. */
export type ValidationSeverity = "info" | "warning" | "error";

/** AI autonomy level. Mirrors Swift `PermissionMode`. */
export type PermissionMode =
  | "read_only"
  | "ask_before_write"
  | "allow_preset_creation"
  | "full_control";

// MARK: - Core models

/** One band of the 20-band parametric EQ. Mirrors Swift `EQBand`. */
export interface EQBand {
  /** 1-based slot index (1...20). */
  index: number;
  type: BandType;
  /** Center frequency (bell/notch) or cutoff (shelf/pass), in Hz. 20…20000. */
  frequencyHz: number;
  /** Boost/cut in dB. -18…+18. Ignored when the type doesn't use gain. */
  gainDb: number;
  /** Bandwidth/resonance Q for all filter types, including shelves. 0.1…10. */
  q: number;
  channel: BandChannel;
  enabled: boolean;
}

/** Safety metadata stored alongside a preset. Mirrors Swift `PresetSafety`. */
export interface PresetSafety {
  autoGainEnabled: boolean;
  clippingRisk: ClippingRisk;
}

export type CorrectionRole = "generic" | "baseline" | "preference" | "combined";
export type CorrectionSourceConfidence =
  | "measured"
  | "manufacturer"
  | "community"
  | "estimated"
  | "unknown";

/** One point in a persisted measured correction curve. Gain excludes preamp. */
export interface MeasuredCorrectionPoint {
  frequencyHz: number;
  gainDb: number;
}

/** Portable magnitude-only correction used by Auralink's measured FIR path. */
export interface MeasuredCorrectionPayload {
  schemaVersion: number;
  measurementId: string;
  sourceFormat: string;
  source: string;
  rig?: string;
  provenanceURL: string;
  /** Source GraphicEQ preamp removed from every point. Informational only. */
  sourcePreampDb: number;
  contentHash: string;
  channel: string;
  phaseData: string;
  usableLowHz: number;
  usableHighHz: number;
  points: MeasuredCorrectionPoint[];
}

/** Optional workflow metadata separating baseline correction from preference moves. */
export interface CorrectionMetadata {
  role: CorrectionRole;
  baselinePresetId?: string;
  source?: string;
  sourceConfidence: CorrectionSourceConfidence;
  /** 0...1 scale for how strongly the measured/model correction is applied. */
  correctionStrength: number;
  targetCurveId?: string;
  /** 0...1 scale for target curve blending/strength. */
  targetBlend: number;
  /** Band indexes that are subjective preference moves rather than baseline correction. */
  preferenceBandIndexes: number[];
  /** Dense measured baseline; hardware PEQ targets continue to use `bands`. */
  measuredCorrection?: MeasuredCorrectionPayload;
}

/** A complete, saveable EQ preset. Mirrors Swift `EQPreset`. */
export interface EQPreset {
  id: string;
  name: string;
  /** Target headphone model, e.g. "Sennheiser HD600". Optional. */
  headphone?: string;
  /** Free-text tuning intent. Optional. */
  goal?: string;
  /** Global pre-amplification in dB (usually negative). */
  preampDb: number;
  bands: EQBand[];
  safety: PresetSafety;
  createdBy: CreatedBy;
  /** Monotonic version number, bumped on every saved edit. */
  version: number;
  tags: string[];
  /** ISO-8601 string (Swift encodes Date with `.iso8601`). */
  createdAt: string;
  /** ISO-8601 string. */
  updatedAt: string;
  correction?: CorrectionMetadata;
}

/** An inclusive frequency window in Hz. Mirrors Swift `FrequencyRange`. */
export interface FrequencyRange {
  lowHz: number;
  highHz: number;
}

/** Tonal-balance knowledge for one headphone model. Mirrors `HeadphoneProfile`. */
export interface HeadphoneProfile {
  /** Stable slug, e.g. "sennheiser-hd600". */
  id: string;
  brand: string;
  model: string;
  type: HeadphoneType;
  /** One-line tonal signature. */
  signature: string;
  /** Human/AI-readable correction notes. */
  correctionNotes: string[];
  /** Frequency regions that commonly read as harsh/fatiguing (Hz). */
  harshRegionsHz: FrequencyRange[];
  /** Optional default target curve id appropriate for this can. */
  suggestedTargetCurveId?: string;
  /** Where the characterization comes from. */
  source: string;
  credibility: Credibility;
}

/** A single suggested move within a target curve. Mirrors Swift `BandHint`. */
export interface BandHint {
  type: BandType;
  frequencyHz: number;
  gainDb: number;
  q: number;
  /** Why this move exists, in plain language. */
  rationale: string;
}

/** A genre/purpose tuning template. Mirrors Swift `TargetCurve`. */
export interface TargetCurve {
  /** Stable slug, e.g. "rock", "vocal-focus". */
  id: string;
  name: string;
  category: TargetCategory;
  description: string;
  /** Suggested band moves, relative to flat. */
  hints: BandHint[];
}

/** Guardrails every preset is checked against. Mirrors Swift `SafetyRules`. */
export interface SafetyRules {
  gainMinDb: number;
  gainMaxDb: number;
  qMin: number;
  qMax: number;
  /** Largest single-band boost allowed without explicit opt-in. */
  maxBoostDb: number;
  /** Largest summed boost across overlapping bands before it's flagged. */
  maxAggregateBoostDb: number;
  /** Estimated true-peak headroom (dB) to keep below 0 dBFS. */
  targetHeadroomDb: number;
  /** When true, the validator proposes a compensating preamp. */
  autoPreampEnabled: boolean;
}

/** The shipped defaults — authoritative fallback when no JSON is present. */
export const DEFAULT_SAFETY_RULES: SafetyRules = {
  gainMinDb: -18,
  gainMaxDb: 18,
  qMin: 0.1,
  qMax: 10,
  maxBoostDb: 6,
  maxAggregateBoostDb: 9,
  targetHeadroomDb: 1.0,
  autoPreampEnabled: true,
};

/** Live snapshot of the audio engine. Mirrors Swift `AudioState`. */
export interface AudioState {
  eqEnabled: boolean;
  safeMode: boolean;
  /** Renderer committed by the realtime callback. */
  hqCorrectionMode: boolean;
  /** Control intent while FIR is preparing/waiting for a callback. */
  hqCorrectionRequested?: boolean;
  /** Prepared control generation and exact RT-committed DSP generation. */
  requestedRenderGeneration?: number;
  committedRenderGeneration?: number;
  currentPresetId?: string;
  currentPresetName?: string;
  outputDeviceUID?: string;
  outputDeviceName?: string;
  captureDeviceName?: string;
  needsVirtualDevice: boolean;
  loopbackDriverInstalled: boolean;
  audioInputPermission: string;
  systemOutputDeviceName?: string;
  systemOutputRoutedToAuralink: boolean;
  sampleRate: number;
  bufferFrames: number;
  /** One-way latency estimate through the routing path, milliseconds. */
  latencyMs: number;
  /** True if the routing path is live. */
  routingActive: boolean;
  clippingDetected: boolean;
  /** Recent pre-clip-guard peak in dBFS. Can exceed 0 when EQ overshoots. */
  preClipPeakDb: number;
  preClipTruePeakDb?: number;
  /** Lightweight inter-sample peak estimate after the clip guard. */
  estimatedTruePeakDb: number;
  /** Pre-guard clipping windows since the app started. */
  clippingEventsTotal: number;
  /** Last pre-guard peak seen during a clipping window, in dBFS. */
  lastClippingPeakDb: number;
  /** Recent output peak in dBFS (≤ 0). -120 means silence. */
  outputPeakDb: number;
  /** Recent captured-input peak in dBFS (≤ 0). -120 means silence. */
  capturePeakDb: number;
  /** Capture callbacks observed in the last telemetry window. */
  captureCallbacks: number;
  /** Render callbacks observed in the last telemetry window. */
  renderCallbacks: number;
  /** Captured frames written into the ring in the last telemetry window. */
  capturedFrames: number;
  /** Frames requested by the output render callback in the last telemetry window. */
  renderedFrames: number;
  /** Frames actually read from the ring in the last telemetry window. */
  ringReadFrames: number;
  /** Frames currently waiting in the ring at the telemetry snapshot. */
  ringAvailableFrames: number;
  /** Ring underruns since the app started. */
  underrunsTotal: number;
  /** Faded latency resyncs since the app started. */
  resyncsTotal: number;
  mcpConnected: boolean;
  permissionMode: PermissionMode;
}

/** An audio output device. Mirrors Swift `OutputDevice`. */
export interface OutputDevice {
  /** CoreAudio device UID (stable across reconnects). */
  uid: string;
  name: string;
  sampleRate: number;
  /** True for the BlackHole/virtual loopback device. */
  isVirtual: boolean;
  isDefault: boolean;
}

/** One issue found while validating a preset. Mirrors Swift `ValidationIssue`. */
export interface ValidationIssue {
  severity: ValidationSeverity;
  message: string;
  /** Band index this issue refers to, if any. */
  bandIndex?: number;
}

/** Result of running a preset through the safety validator. Mirrors `ValidationResult`. */
export interface ValidationResult {
  ok: boolean;
  clippingRisk: ClippingRisk;
  /** Worst-case summed boost (dB) across the response. */
  estimatedPeakGainDb: number;
  /** Preamp (≤ 0 dB) that brings the estimated peak back under headroom. */
  suggestedPreampDb: number;
  issues: ValidationIssue[];
}

/** One point on the EQ magnitude-response curve. Mirrors Swift `ResponsePoint`. */
export interface ResponsePoint {
  frequencyHz: number;
  magnitudeDb: number;
}

// MARK: - Parameter ranges (single source of truth for clamping, mirrors EQBand extension)

export const FREQ_MIN = 20;
export const FREQ_MAX = 20_000;
export const GAIN_MIN = -18;
export const GAIN_MAX = 18;
export const Q_MIN = 0.1;
export const Q_MAX = 10;
export const PREAMP_MIN = -24;
export const PREAMP_MAX = 0;
export const BAND_COUNT = 20;

/** Clamp a value into an inclusive range. */
export function clamp(value: number, lo: number, hi: number): number {
  return Math.min(Math.max(value, lo), hi);
}
