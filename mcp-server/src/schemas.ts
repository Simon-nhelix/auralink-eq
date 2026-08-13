import { z } from "zod";

import { measuredPayloadFIREligibility } from "./validate.js";
import {
  BAND_TYPES,
  BAND_CHANNELS,
  FREQ_MIN,
  FREQ_MAX,
  GAIN_MIN,
  GAIN_MAX,
  Q_MIN,
  Q_MAX,
  PREAMP_MIN,
  PREAMP_MAX,
  type MeasuredCorrectionPayload,
} from "./types.js";

export const bandSpecSchema = z.object({
  index: z
    .number()
    .int()
    .min(1)
    .max(20)
    .optional()
    .describe("1-based slot (1–20). Omit to auto-assign the next free slot."),
  type: z
    .enum(BAND_TYPES as [string, ...string[]])
    .default("bell")
    .describe("Filter shape (snake_case): bell, low_shelf, high_shelf, low_pass, high_pass, notch."),
  frequencyHz: z
    .number()
    .min(FREQ_MIN)
    .max(FREQ_MAX)
    .describe("Center (bell/notch) or cutoff (shelf/pass) frequency in Hz, 20–20000."),
  gainDb: z
    .number()
    .min(GAIN_MIN)
    .max(GAIN_MAX)
    .default(0)
    .describe("Boost/cut in dB, -18…+18. Ignored for pass/notch filters."),
  q: z
    .number()
    .min(Q_MIN)
    .max(Q_MAX)
    .default(1.0)
    .describe("Bandwidth/resonance Q for all filter types, including shelves. 0.1–10."),
  channel: z
    .enum(BAND_CHANNELS as [string, ...string[]])
    .default("stereo")
    .describe("stereo, left, or right."),
  enabled: z.boolean().default(true).describe("Whether the band is active."),
});

export const correctionRoleSchema = z.enum(["generic", "baseline", "preference", "combined"]);
export const sourceConfidenceSchema = z.enum(["measured", "manufacturer", "community", "estimated", "unknown"]);
export const measuredCorrectionSchema = z.object({
  schemaVersion: z.literal(1),
  measurementId: z.string().trim().min(1),
  sourceFormat: z.literal("autoeq_graphic_eq"),
  source: z.string().trim().min(1),
  rig: z.string().trim().min(1).optional(),
  provenanceURL: z.string().trim().min(1),
  sourcePreampDb: z.number().min(PREAMP_MIN).max(PREAMP_MAX),
  contentHash: z.string().regex(/^[0-9a-f]{64}$/),
  channel: z.literal("stereo"),
  phaseData: z.literal("magnitude_only"),
  usableLowHz: z.number().min(10).max(24_000),
  usableHighHz: z.number().min(10).max(24_000),
  points: z
    .array(z.object({
      frequencyHz: z.number().min(10).max(24_000),
      gainDb: z.number().min(-24).max(24),
    }))
    .min(16)
    .max(512),
}).superRefine((payload, context) => {
  const eligibility = measuredPayloadFIREligibility(payload as MeasuredCorrectionPayload);
  if (!eligibility.eligible) {
    context.addIssue({
      code: z.ZodIssueCode.custom,
      message: `Invalid measured correction: ${eligibility.reason}.`,
    });
  }
});

export const targetSchema = z
  .enum(["auralink", "luxsin-x8"])
  .default("auralink")
  .describe("EQ backend target. Default auralink uses the macOS software EQ; luxsin-x8 writes/selects a hardware PEQ entry on the LAN X8.");

export const correctionInputSchema = {
  correctionRole: correctionRoleSchema
    .optional()
    .describe("Correction workflow role: baseline, preference, combined, or generic."),
  baselinePresetId: z
    .string()
    .optional()
    .describe("When this is a preference/combined tuning, the saved baseline preset id it builds on."),
  correctionSource: z
    .string()
    .optional()
    .describe("Measurement/profile source, e.g. 'AutoEq/oratory1990' or 'user profile notes'."),
  sourceConfidence: sourceConfidenceSchema
    .optional()
    .describe("How trustworthy the source is: measured, manufacturer, community, estimated, or unknown."),
  correctionStrength: z
    .number()
    .min(0)
    .max(1)
    .optional()
    .describe("0...1 strength for measured/model correction. Use <1 for lighter correction."),
  targetCurveId: z
    .string()
    .optional()
    .describe("Target curve id used for this tuning, e.g. harman-neutral, rock, late-night."),
  targetBlend: z
    .number()
    .min(0)
    .max(1)
    .optional()
    .describe("0...1 target curve blend/strength."),
  preferenceBandIndexes: z
    .array(z.number().int().min(1).max(20))
    .default([])
    .describe("Band indexes that are subjective preference moves rather than baseline correction."),
  measuredCorrection: measuredCorrectionSchema
    .optional()
    .describe("Dense measured magnitude payload from get_autoeq_correction. Auralink Measured FIR only; hardware PEQ uses bands."),
};

export const frequencyRangeSchema = z.object({
  lowHz: z.number().min(FREQ_MIN).max(FREQ_MAX),
  highHz: z.number().min(FREQ_MIN).max(FREQ_MAX),
});
