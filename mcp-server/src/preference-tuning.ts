import { randomUUID } from "node:crypto";
import { bandsFromSpecs, normalizePreset } from "./store.js";
import type { EQPreset } from "./types.js";
import type { RegisterBandSpec } from "./register-headphone-baseline.js";

/** Explicit roles win over inherited target/source tags, including legacy presets. */
export function isPureBaseline(preset: EQPreset): boolean {
  const correction = preset.correction;
  if (correction?.preferenceBandIndexes?.length || correction?.baselinePresetId) return false;
  if (correction) return correction.role === "baseline";
  return preset.tags.includes("baseline") && !preset.tags.includes("preference");
}

/** Keep the baseline intact; subjective filters occupy unused slots in a copy. */
export function buildPreferenceTuning(
  baseline: EQPreset,
  input: { id?: string; name: string; goal?: string; bands: RegisterBandSpec[]; preampDb?: number }
): EQPreset {
  if (!isPureBaseline(baseline)) {
    throw new Error("Select a pure baseline first. Use register_headphone_baseline to register one.");
  }
  if (input.id === baseline.id) throw new Error("A preference tuning cannot overwrite its baseline.");
  const freeSlots = baseline.bands.filter((b) => !b.enabled).map((b) => b.index);
  if (input.bands.length === 0 || input.bands.length > freeSlots.length) {
    throw new Error(`Preference tuning needs 1–${freeSlots.length} bands; baseline bands cannot be replaced or dropped.`);
  }
  // Slots supplied by the caller are intentionally reassigned: a preference
  // list often starts at 1, which must never overwrite baseline band 1.
  const specs = input.bands.map((b, i) => ({ ...b, index: freeSlots[i] }));
  const preferenceBandIndexes = specs.filter((b) => b.enabled !== false).map((b) => b.index);
  const maxBoost = Math.max(0, ...specs.filter((b) => b.enabled !== false).map((b) => b.gainDb ?? 0));
  return normalizePreset({
    ...baseline,
    id: input.id ?? `preset_ai_${randomUUID()}`,
    name: input.name,
    goal: input.goal ?? "Preference tuning layered on the device baseline.",
    bands: bandsFromSpecs([...baseline.bands.filter((b) => b.enabled), ...specs]),
    preampDb: input.preampDb ?? Math.max(-24, baseline.preampDb - maxBoost),
    createdBy: "ai",
    version: 1,
    createdAt: "",
    updatedAt: "",
    tags: [...new Set([...baseline.tags.filter((t) => t !== "baseline"), "preference"])],
    correction: {
      correctionStrength: 1,
      targetBlend: 1,
      sourceConfidence: "unknown",
      ...baseline.correction,
      role: "combined",
      baselinePresetId: baseline.id,
      preferenceBandIndexes,
    },
  });
}
