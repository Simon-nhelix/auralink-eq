import { z } from "zod";
import { BAND_TYPES, BAND_CHANNELS, type EQPreset } from "./types.js";

// Check the stored shape before normalization. Unlike tool input validation,
// decoding must retain future measured schema versions and invalid hashes so
// the FIR eligibility gate can reject them without silently repairing a curve.
const measuredPayload = z.looseObject({
  schemaVersion: z.number().int(),
  measurementId: z.string(),
  sourceFormat: z.string(),
  source: z.string(),
  rig: z.string().nullish().transform(v => v ?? undefined),
  provenanceURL: z.string(),
  sourcePreampDb: z.number(),
  contentHash: z.string(),
  channel: z.string(),
  phaseData: z.string(),
  usableLowHz: z.number(),
  usableHighHz: z.number(),
  points: z.array(z.looseObject({ frequencyHz: z.number(), gainDb: z.number() })),
});

const correction = z.looseObject({
  role: z.enum(["generic", "baseline", "preference", "combined"]),
  baselinePresetId: z.string().nullish().transform(v => v ?? undefined),
  source: z.string().nullish().transform(v => v ?? undefined),
  sourceConfidence: z.enum(["measured", "manufacturer", "community", "estimated", "unknown"]),
  correctionStrength: z.number(),
  targetCurveId: z.string().nullish().transform(v => v ?? undefined),
  targetBlend: z.number(),
  preferenceBandIndexes: z.array(z.number().int()),
  measuredCorrection: measuredPayload.nullish().transform(v => v ?? undefined),
});

const epoch = "1970-01-01T00:00:00Z";
export const persistedPresetSchema: z.ZodType<EQPreset> = z.looseObject({
  id: z.string(),
  name: z.string(),
  headphone: z.string().nullish().transform(v => v ?? undefined),
  goal: z.string().nullish().transform(v => v ?? undefined),
  preampDb: z.number().nullish().transform(v => v ?? 0),
  bands: z.array(z.looseObject({
    index: z.number().int(),
    type: z.enum(BAND_TYPES),
    frequencyHz: z.number(),
    gainDb: z.number(),
    q: z.number(),
    channel: z.enum(BAND_CHANNELS),
    enabled: z.boolean(),
  })),
  safety: z.looseObject({
    autoGainEnabled: z.boolean(),
    clippingRisk: z.enum(["low", "medium", "high"]),
  }).nullish().transform(v => v ?? { autoGainEnabled: false, clippingRisk: "low" as const }),
  createdBy: z.enum(["user", "ai"]).nullish().transform(v => v ?? "user"),
  version: z.number().int().nullish().transform(v => v ?? 1),
  tags: z.array(z.string()).nullish().transform(v => v ?? []),
  createdAt: z.string().nullish().transform(v => v ?? epoch),
  updatedAt: z.string().nullish().transform(v => v ?? epoch),
  correction: correction.nullish().transform(v => v ?? undefined),
});
