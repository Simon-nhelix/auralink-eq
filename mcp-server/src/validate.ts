/**
 * Offline EQ validation — a faithful TypeScript port of the Swift
 * `AuralinkCore/DSP/Biquad.magnitude`, `DSP/FrequencyResponse`, and
 * `Presets/PresetValidator` logic (per BUILD_SPEC §DSP + §Presets).
 *
 * The point of porting it (rather than calling the app) is that
 * `validate_eq_preset` and the clipping estimate must work even when the
 * Auralink app is offline. The math here is the RBJ "Audio EQ Cookbook" magnitude
 * response of each biquad, summed in dB across a log frequency sweep, then run
 * through the same safety-rule checks the Swift validator applies.
 */

import { createHash } from "node:crypto";

import { normalizePreset } from "./store.js";
import {
  BandType,
  EQBand,
  EQPreset,
  SafetyRules,
  ValidationIssue,
  ValidationResult,
  ResponsePoint,
  ClippingRisk,
  BandChannel,
  bandTypeUsesGain,
  clamp,
  FREQ_MIN,
  FREQ_MAX,
  GAIN_MIN,
  GAIN_MAX,
  Q_MIN,
  Q_MAX,
  PREAMP_MIN,
  MeasuredCorrectionPayload,
} from "./types.js";

function qDisplayName(_type: BandType): string {
  return "Q";
}

// MARK: - Biquad coefficients + magnitude (RBJ Audio EQ Cookbook)

/** Transfer-function coefficients for one biquad, normalized so a0 == 1. */
interface BiquadCoeffs {
  b0: number;
  b1: number;
  b2: number;
  a1: number;
  a2: number;
}

const IDENTITY: BiquadCoeffs = { b0: 1, b1: 0, b2: 0, a1: 0, a2: 0 };

/**
 * RBJ cookbook coefficients for one band at a sample rate. Mirrors
 * `Biquad.configure`: disabled bands and (for gain filters) ~0 dB gain collapse
 * to an identity passthrough.
 */
function coeffsFor(band: EQBand, sampleRate: number): BiquadCoeffs {
  if (!band.enabled) return IDENTITY;

  const type = band.type;
  const usesGain = bandTypeUsesGain(type);

  // Gain filters with negligible gain are a no-op (matches the DSP passthrough).
  if (usesGain && Math.abs(band.gainDb) < 1e-4) return IDENTITY;

  const f0 = clamp(band.frequencyHz, FREQ_MIN, FREQ_MAX);
  const q = clamp(band.q, Q_MIN, Q_MAX);
  const gainDb = clamp(band.gainDb, GAIN_MIN, GAIN_MAX);

  // RBJ intermediate terms.
  const a = Math.pow(10, gainDb / 40); // amplitude (sqrt of linear gain)
  const w0 = (2 * Math.PI * f0) / sampleRate;
  const cosw0 = Math.cos(w0);
  const sinw0 = Math.sin(w0);
  const alpha = sinw0 / (2 * q);

  let b0 = 1;
  let b1 = 0;
  let b2 = 0;
  let a0 = 1;
  let a1 = 0;
  let a2 = 0;

  switch (type) {
    case "bell": {
      b0 = 1 + alpha * a;
      b1 = -2 * cosw0;
      b2 = 1 - alpha * a;
      a0 = 1 + alpha / a;
      a1 = -2 * cosw0;
      a2 = 1 - alpha / a;
      break;
    }
    case "low_shelf": {
      const twoSqrtAAlpha = 2 * Math.sqrt(a) * alpha;
      b0 = a * (a + 1 - (a - 1) * cosw0 + twoSqrtAAlpha);
      b1 = 2 * a * (a - 1 - (a + 1) * cosw0);
      b2 = a * (a + 1 - (a - 1) * cosw0 - twoSqrtAAlpha);
      a0 = a + 1 + (a - 1) * cosw0 + twoSqrtAAlpha;
      a1 = -2 * (a - 1 + (a + 1) * cosw0);
      a2 = a + 1 + (a - 1) * cosw0 - twoSqrtAAlpha;
      break;
    }
    case "high_shelf": {
      const twoSqrtAAlpha = 2 * Math.sqrt(a) * alpha;
      b0 = a * (a + 1 + (a - 1) * cosw0 + twoSqrtAAlpha);
      b1 = -2 * a * (a - 1 + (a + 1) * cosw0);
      b2 = a * (a + 1 + (a - 1) * cosw0 - twoSqrtAAlpha);
      a0 = a + 1 - (a - 1) * cosw0 + twoSqrtAAlpha;
      a1 = 2 * (a - 1 - (a + 1) * cosw0);
      a2 = a + 1 - (a - 1) * cosw0 - twoSqrtAAlpha;
      break;
    }
    case "low_pass": {
      b0 = (1 - cosw0) / 2;
      b1 = 1 - cosw0;
      b2 = (1 - cosw0) / 2;
      a0 = 1 + alpha;
      a1 = -2 * cosw0;
      a2 = 1 - alpha;
      break;
    }
    case "high_pass": {
      b0 = (1 + cosw0) / 2;
      b1 = -(1 + cosw0);
      b2 = (1 + cosw0) / 2;
      a0 = 1 + alpha;
      a1 = -2 * cosw0;
      a2 = 1 - alpha;
      break;
    }
    case "notch": {
      b0 = 1;
      b1 = -2 * cosw0;
      b2 = 1;
      a0 = 1 + alpha;
      a1 = -2 * cosw0;
      a2 = 1 - alpha;
      break;
    }
  }

  // Normalize so a0 == 1 (matches the Swift implementation).
  return { b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0 };
}

/**
 * Linear magnitude of a normalized biquad at frequency `f`. Mirrors
 * `Biquad.magnitude(atHz:sampleRate:)`. Evaluates |H(e^jw)| of the digital
 * transfer function H(z) = (b0 + b1 z^-1 + b2 z^-2) / (1 + a1 z^-1 + a2 z^-2).
 */
function biquadMagnitude(c: BiquadCoeffs, f: number, sampleRate: number): number {
  const w = (2 * Math.PI * f) / sampleRate;
  const cosw = Math.cos(w);
  const cos2w = Math.cos(2 * w);
  const sinw = Math.sin(w);
  const sin2w = Math.sin(2 * w);

  // Numerator: b0 + b1 e^-jw + b2 e^-2jw
  const numRe = c.b0 + c.b1 * cosw + c.b2 * cos2w;
  const numIm = -(c.b1 * sinw + c.b2 * sin2w);
  // Denominator: 1 + a1 e^-jw + a2 e^-2jw
  const denRe = 1 + c.a1 * cosw + c.a2 * cos2w;
  const denIm = -(c.a1 * sinw + c.a2 * sin2w);

  const numMag = Math.sqrt(numRe * numRe + numIm * numIm);
  const denMag = Math.sqrt(denRe * denRe + denIm * denIm);
  if (denMag < 1e-12) return numMag; // guard against pathological denominators
  return numMag / denMag;
}

// MARK: - FrequencyResponse port

/**
 * Log-spaced frequencies across the audible band. Mirrors
 * `FrequencyResponse.logFrequencies`.
 */
export function logFrequencies(
  count: number,
  from: number = 20,
  to: number = 20_000
): number[] {
  const n = Math.max(2, Math.floor(count));
  const lo = Math.log10(Math.max(1, from));
  const hi = Math.log10(Math.max(from + 1, to));
  const step = (hi - lo) / (n - 1);
  const out: number[] = [];
  for (let i = 0; i < n; i++) out.push(Math.pow(10, lo + step * i));
  return out;
}

/**
 * Magnitude (in dB) of the preset at frequency `f`, NOT including preamp.
 * `.left` and `.right` represent actual output-channel routing; `.stereo`
 * preserves the legacy folded response by including every enabled band.
 */
function presetMagnitudeDbNoPreamp(
  preset: EQPreset,
  f: number,
  sampleRate: number,
  channel: BandChannel,
  includedBandIndexes?: Set<number>
): number {
  let totalDb = 0;
  for (const band of preset.bands) {
    if (!band.enabled) continue;
    if (includedBandIndexes && !includedBandIndexes.has(band.index)) continue;
    if (channel !== "stereo" && band.channel !== "stereo" && band.channel !== channel) continue;
    const c = coeffsFor(band, sampleRate);
    const mag = biquadMagnitude(c, f, sampleRate);
    // Mirror Swift `FrequencyResponse.magnitudeDb`: an ideal notch can reach
    // zero at its center, so both ports floor the linear magnitude before log10.
    totalDb += 20 * Math.log10(Math.max(mag, 1e-9));
  }
  return totalDb;
}

export type EQResponseRenderMode = "standard_iir" | "hq_fir";

export interface MeasuredFIREligibility {
  eligible: boolean;
  reason?: string;
}

export function measuredPayloadFIREligibility(
  payload: MeasuredCorrectionPayload
): MeasuredFIREligibility {
  if (payload.schemaVersion !== 1) return { eligible: false, reason: "unsupported_schema" };
  if (payload.sourceFormat !== "autoeq_graphic_eq") return { eligible: false, reason: "unsupported_source_format" };
  if (payload.channel !== "stereo") return { eligible: false, reason: "unsupported_channel" };
  if (payload.phaseData !== "magnitude_only") return { eligible: false, reason: "unsupported_phase_data" };
  if (!payload.measurementId.trim() || !payload.source.trim() || !payload.provenanceURL.trim()) {
    return { eligible: false, reason: "missing_provenance" };
  }
  if (!Number.isFinite(payload.sourcePreampDb)) return { eligible: false, reason: "invalid_source_preamp" };
  if (payload.points.length < 16 || payload.points.length > 512) {
    return { eligible: false, reason: "invalid_point_count" };
  }
  if (
    !Number.isFinite(payload.usableLowHz) ||
    !Number.isFinite(payload.usableHighHz) ||
    payload.usableLowHz < 10 ||
    payload.usableHighHz > 24_000 ||
    payload.usableHighHz <= payload.usableLowHz
  ) return { eligible: false, reason: "invalid_usable_bounds" };

  let previous = -Infinity;
  for (const point of payload.points) {
    if (
      !Number.isFinite(point.frequencyHz) ||
      !Number.isFinite(point.gainDb) ||
      point.frequencyHz < 10 || point.frequencyHz > 24_000 ||
      point.gainDb < -24 || point.gainDb > 24 ||
      point.frequencyHz <= previous
    ) return { eligible: false, reason: "noncanonical_points" };
    previous = point.frequencyHz;
  }
  if (
    payload.points[0].frequencyHz > payload.usableLowHz ||
    payload.points[payload.points.length - 1].frequencyHz < payload.usableHighHz
  ) return { eligible: false, reason: "insufficient_point_coverage" };

  const canonical = payload.points
    .map((point) => `${point.frequencyHz.toFixed(6)}:${point.gainDb.toFixed(6)}`)
    .join("|");
  const expectedHash = createHash("sha256")
    .update(`${payload.schemaVersion}|${canonical}`)
    .digest("hex");
  if (!/^[0-9a-f]{64}$/.test(payload.contentHash) || payload.contentHash !== expectedHash) {
    return { eligible: false, reason: "content_hash_mismatch" };
  }
  return { eligible: true };
}

export function measuredFIREligibility(preset: EQPreset): MeasuredFIREligibility {
  const correction = preset.correction;
  const payload = correction?.measuredCorrection;
  if (!correction || !payload) return { eligible: false, reason: "missing_measured_payload" };
  if (correction.sourceConfidence !== "measured") {
    return { eligible: false, reason: "source_confidence_not_measured" };
  }
  return measuredPayloadFIREligibility(payload);
}

function measuredCorrectionEligible(preset: EQPreset): boolean {
  return measuredFIREligibility(preset).eligible;
}

function interpolateMeasuredDb(preset: EQPreset, frequencyHz: number, sampleRate: number): number {
  const correction = preset.correction!;
  const payload = correction.measuredCorrection!;
  const points = payload.points;
  const frequency = Math.max(frequencyHz, 1e-6);
  const upper = Math.min(payload.usableHighHz, 20_000, sampleRate * 0.45);
  let lookupFrequency = Math.min(frequency, upper);
  let measured: number;
  if (lookupFrequency <= points[0].frequencyHz) {
    measured = points[0].gainDb;
  } else if (lookupFrequency >= points[points.length - 1].frequencyHz) {
    measured = points[points.length - 1].gainDb;
  } else {
    let low = 0;
    let high = points.length - 1;
    while (high - low > 1) {
      const middle = Math.floor((low + high) / 2);
      if (points[middle].frequencyHz <= lookupFrequency) low = middle;
      else high = middle;
    }
    const lo = points[low];
    const hi = points[high];
    const t = (Math.log(lookupFrequency) - Math.log(lo.frequencyHz)) /
      (Math.log(hi.frequencyHz) - Math.log(lo.frequencyHz));
    measured = lo.gainDb + (hi.gainDb - lo.gainDb) * t;
  }
  measured *= clamp(correction.correctionStrength, 0, 1);
  if (frequency <= upper) return measured;
  const transitionEnd = Math.min(20_000, sampleRate * 0.48, Math.max(upper + 2_000, upper * 1.6));
  if (transitionEnd <= upper || frequency >= transitionEnd) return 0;
  const t = clamp(
    (Math.log(frequency) - Math.log(upper)) / (Math.log(transitionEnd) - Math.log(upper)),
    0,
    1
  );
  return measured * 0.5 * (1 + Math.cos(Math.PI * t));
}

function renderMagnitudeDbNoPreamp(
  preset: EQPreset,
  f: number,
  sampleRate: number,
  channel: BandChannel,
  renderMode: EQResponseRenderMode
): number {
  if (renderMode !== "hq_fir" || !measuredCorrectionEligible(preset)) {
    return presetMagnitudeDbNoPreamp(preset, f, sampleRate, channel);
  }
  const preferenceIndexes = new Set(preset.correction?.preferenceBandIndexes ?? []);
  return interpolateMeasuredDb(preset, f, sampleRate)
    + presetMagnitudeDbNoPreamp(preset, f, sampleRate, channel, preferenceIndexes);
}

/** The selected renderer's magnitude-response curve including preamp. */
export function responseCurve(
  preset: EQPreset,
  frequencies: number[],
  sampleRate: number,
  renderMode: EQResponseRenderMode = "standard_iir"
): ResponsePoint[] {
  const normalized = normalizePreset(preset);
  return frequencies.map((f) => ({
    frequencyHz: f,
    magnitudeDb: renderMagnitudeDbNoPreamp(normalized, f, sampleRate, "stereo", renderMode) + normalized.preampDb,
  }));
}

/** Actual left or right response, including preamp. */
export function responseCurveForChannel(
  preset: EQPreset,
  frequencies: number[],
  sampleRate: number,
  channel: Exclude<BandChannel, "stereo">,
  renderMode: EQResponseRenderMode = "standard_iir"
): ResponsePoint[] {
  const normalized = normalizePreset(preset);
  return frequencies.map((f) => ({
    frequencyHz: f,
    magnitudeDb: renderMagnitudeDbNoPreamp(normalized, f, sampleRate, channel, renderMode) + normalized.preampDb,
  }));
}

/** Largest magnitude (dB) of one output-channel response without preamp. */
function channelPeakGainDbNoPreamp(
  preset: EQPreset,
  sampleRate: number,
  channel: Exclude<BandChannel, "stereo">,
  renderMode: EQResponseRenderMode
): number {
  const freqs = logFrequencies(256);
  let peak = -Infinity;
  for (const f of freqs) {
    const db = renderMagnitudeDbNoPreamp(preset, f, sampleRate, channel, renderMode);
    if (db > peak) peak = db;
  }
  return Number.isFinite(peak) ? peak : 0;
}

function rendererPeakGainDbNoPreamp(
  preset: EQPreset,
  sampleRate: number,
  renderMode: EQResponseRenderMode
): number {
  return Math.max(
    0,
    channelPeakGainDbNoPreamp(preset, sampleRate, "left", renderMode),
    channelPeakGainDbNoPreamp(preset, sampleRate, "right", renderMode)
  );
}

export type ValidationRendererScope = "all" | "standard_iir";

/** Largest magnitude across the renderers the selected backend can use. */
function peakGainDbNoPreamp(
  preset: EQPreset,
  sampleRate: number,
  rendererScope: ValidationRendererScope = "all"
): number {
  const standard = rendererPeakGainDbNoPreamp(preset, sampleRate, "standard_iir");
  return rendererScope === "all" && measuredCorrectionEligible(preset)
    ? Math.max(standard, rendererPeakGainDbNoPreamp(preset, sampleRate, "hq_fir"))
    : standard;
}

// MARK: - PresetValidator port

/** Round to the nearest 0.5 dB (matches the Swift auto-preamp rounding). */
function roundHalf(x: number): number {
  return Math.round(x * 2) / 2;
}

/**
 * Preamp (≤ 0 dB) that offsets the peak boost to keep `targetHeadroomDb`.
 * Mirrors `PresetValidator.autoPreamp`: bring the boosted peak down to
 * **-targetHeadroom** (`preamp = -(peak + headroom)`), rounded *down* to the
 * next 0.5 dB so the headroom is never under-shot, clamped to the legal range.
 * (An earlier port subtracted the headroom instead of adding it, leaving
 * "auto-gained" presets ~2 dB hot — peaks above 0 dBFS with autoGain on.)
 */
export function autoPreamp(
  preset: EQPreset,
  rules: SafetyRules,
  sampleRate: number = 48_000,
  rendererScope: ValidationRendererScope = "all"
): number {
  const peakDb = peakGainDbNoPreamp(preset, sampleRate, rendererScope);
  if (peakDb <= 0) return 0;
  const needed = -(peakDb + rules.targetHeadroomDb);
  const floored = Math.floor(Math.min(0, needed) * 2) / 2;
  return Math.max(PREAMP_MIN, floored);
}

/**
 * Validate a preset against the safety rules and estimate clipping risk.
 * Mirrors `PresetValidator.validate`:
 *  - Per-band gain beyond `maxBoostDb` → warning.
 *  - Aggregate boost beyond `maxAggregateBoostDb` → warning.
 *  - Low-bass boosts and narrow boosted treble bands → warning.
 *  - Q or gain out of legal range → error.
 *  - `ok` is true iff there are no `.error` issues.
 *  - clippingRisk: (peak + preamp) ≤ -targetHeadroom → low; ≤ +1 → medium; else high.
 */
export function validatePreset(
  preset: EQPreset,
  rules: SafetyRules,
  sampleRate: number = 48_000,
  rendererScope: ValidationRendererScope = "all"
): ValidationResult {
  preset = normalizePreset(preset);
  const issues: ValidationIssue[] = [];

  if (rendererScope === "all" && preset.correction?.measuredCorrection) {
    const eligibility = measuredFIREligibility(preset);
    if (!eligibility.eligible) {
      issues.push({
        severity: "error",
        message: `Measured correction is not operational: ${eligibility.reason}.`,
      });
    }
  }

  // Per-band range + boost checks.
  for (const band of preset.bands) {
    if (!band.enabled) continue;
    const usesGain = bandTypeUsesGain(band.type);

    // Q out of range → error.
    if (band.q < rules.qMin || band.q > rules.qMax) {
      issues.push({
        severity: "error",
        message: `Band ${band.index}: ${qDisplayName(band.type)} ${band.q.toFixed(2)} is outside the allowed range ${rules.qMin}–${rules.qMax}.`,
        bandIndex: band.index,
      });
    }

    if (usesGain) {
      // Gain out of legal range → error.
      if (band.gainDb < rules.gainMinDb || band.gainDb > rules.gainMaxDb) {
        issues.push({
          severity: "error",
          message: `Band ${band.index}: gain ${band.gainDb.toFixed(1)} dB is outside the allowed range ${rules.gainMinDb}…${rules.gainMaxDb} dB.`,
          bandIndex: band.index,
        });
      }
      // Single-band boost beyond the soft ceiling → warning.
      if (band.gainDb > rules.maxBoostDb) {
        issues.push({
          severity: "warning",
          message: `Band ${band.index}: +${band.gainDb.toFixed(1)} dB boost exceeds the recommended single-band limit of +${rules.maxBoostDb} dB.`,
          bandIndex: band.index,
        });
      }
      if (band.gainDb > 3 && band.frequencyHz < 80) {
        issues.push({
          severity: "warning",
          message: `Band ${band.index}: +${band.gainDb.toFixed(1)} dB below 80 Hz can spend headroom quickly on bass-heavy material.`,
          bandIndex: band.index,
        });
      }
      if (band.gainDb > 2 && band.frequencyHz >= 5_000 && band.q >= 4) {
        issues.push({
          severity: "warning",
          message: `Band ${band.index}: narrow boosted treble (${qDisplayName(band.type)} ${band.q.toFixed(2)}) can sound sharp or highlight artifacts.`,
          bandIndex: band.index,
        });
      }
    }

    // Frequency out of range → error (defensive; inputs are normally clamped).
    if (band.frequencyHz < FREQ_MIN || band.frequencyHz > FREQ_MAX) {
      issues.push({
        severity: "error",
        message: `Band ${band.index}: frequency ${band.frequencyHz.toFixed(0)} Hz is outside ${FREQ_MIN}–${FREQ_MAX} Hz.`,
        bandIndex: band.index,
      });
    }
  }

  // Clipping estimate from the actual response peak (without the preset preamp),
  // then add whichever preamp will be in effect.
  const peakDb = peakGainDbNoPreamp(preset, sampleRate, rendererScope);
  if (peakDb > rules.maxAggregateBoostDb) {
    issues.push({
      severity: "warning",
      message: `Combined response boost peaks at ${peakDb.toFixed(1)} dB, above the recommended +${rules.maxAggregateBoostDb} dB aggregate limit. Lower overlapping bands or accept more preamp.`,
    });
  }

  const effectivePreamp = preset.preampDb;
  const peakAfterPreamp = peakDb + effectivePreamp;

  let clippingRisk: ClippingRisk;
  if (peakAfterPreamp <= -rules.targetHeadroomDb) {
    clippingRisk = "low";
  } else if (peakAfterPreamp <= 1) {
    clippingRisk = "medium";
  } else {
    clippingRisk = "high";
  }

  if (clippingRisk === "high") {
    issues.push({
      severity: "warning",
      message: `Estimated peak reaches ${peakAfterPreamp.toFixed(1)} dBFS after preamp and may clip; reduce boosts or lower preamp toward ${autoPreamp(preset, rules, sampleRate, rendererScope).toFixed(1)} dB.`,
    });
  } else if (clippingRisk === "medium") {
    issues.push({
      severity: "warning",
      message: `Estimated peak reaches ${peakAfterPreamp.toFixed(1)} dBFS after preamp, leaving less than ${rules.targetHeadroomDb} dB headroom.`,
    });
  }

  const ok = issues.every((i) => i.severity !== "error");

  return {
    ok,
    clippingRisk,
    estimatedPeakGainDb: roundHalf(peakDb),
    suggestedPreampDb: autoPreamp(preset, rules, sampleRate, rendererScope),
    issues,
  };
}
