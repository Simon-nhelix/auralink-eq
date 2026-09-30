/**
 * Auralink-only headphone baseline registration.
 *
 * Adding a headphone is an explicit request to put it in the user's collection,
 * so this writes both the profile and its baseline preset there, plus the working
 * preset copy the running app loads. Does not commit and does not touch Luxsin X8.
 */

import path from "node:path";

import { getCorrection, type AutoEqLookup } from "./autoeq.js";
import { reloadKnowledge, reloadPresets, type ControlResult } from "./control.js";
import { slugify } from "./helpers.js";
import {
  addPresetToCollection,
  getPreset,
  bandsFromSpecs,
  collectionDir,
  collectionHeadphonesDir,
  collectionPresetsDir,
  loadSafetyRules,
  normalizePreset,
  saveHeadphoneProfile,
  savePreset,
} from "./store.js";
import {
  Credibility,
  EQPreset,
  HeadphoneProfile,
  HeadphoneType,
  PREAMP_MAX,
  PREAMP_MIN,
  ValidationResult,
} from "./types.js";
import { validatePreset } from "./validate.js";
import { buildPreferenceTuning, isPureBaseline } from "./preference-tuning.js";

export const KNOWN_MULTI_WORD_BRANDS = [
  "Austrian Audio",
  "Audio-Technica",
  "Harmonic Empire",
  "Elysian Acoustic Labs",
  "Final Audio",
  "7Hz",
  "Moondrop",
  "Super Review",
  "Symphonium Audio",
] as const;

export type RegisterBandSpec = {
  index?: number;
  type?: EQPreset["bands"][number]["type"];
  frequencyHz: number;
  gainDb?: number;
  q?: number;
  channel?: EQPreset["bands"][number]["channel"];
  enabled?: boolean;
};

export type RegisterHeadphoneBaselineInput = {
  headphone: string;
  brand?: string;
  model?: string;
  type?: HeadphoneType;
  source?: string;
  provenance?: string;
  targetCurveId?: string;
  bands?: RegisterBandSpec[];
  preferenceBands?: RegisterBandSpec[];
  preferenceLabel?: string;
  preampDb?: number;
  signature?: string;
  correctionNotes?: string[];
  harshRegionsHz?: Array<{ lowHz: number; highHz: number }>;
  credibility?: Credibility;
  refreshAutoEq?: boolean;
};

export type RegisterHeadphoneBaselineDeps = {
  getAutoEqCorrection?: (options: {
    headphone: string;
    source?: string;
    refresh?: boolean;
  }) => Promise<AutoEqLookup>;
  reloadKnowledge?: typeof reloadKnowledge;
  reloadPresets?: typeof reloadPresets;
};

export type RegisterHeadphoneBaselineOk = {
  ok: true;
  collectionDir: string;
  written: { headphone: string; preset: string; baseline: string };
  baseline: EQPreset;
  baselineReused: boolean;
  profile: HeadphoneProfile;
  preset: {
    id: string;
    name: string;
    preampDb: number;
    preferenceBandIndexes: number[];
    tags: string[];
    inCollection: boolean;
  };
  validation: ValidationResult;
  appKnowledge: Record<string, unknown>;
  appPresetSync: Record<string, unknown>;
  autoeq:
    | { skipped: true; reason: "explicit_bands" }
    | {
        name: string;
        source: string;
        rig: string | null;
        preampDb: number;
        bandCount: number;
        measuredFIRAvailable: boolean;
        provenance: string;
      };
  note: string;
};

export type RegisterHeadphoneBaselineErr = {
  ok: false;
  reason: "autoeq_not_found" | "type_required" | "validation_failed";
  headphone?: string;
  suggestions?: string[];
  hint?: string;
  profile?: HeadphoneProfile;
  validation?: ValidationResult;
};

export type RegisterHeadphoneBaselineResult =
  | RegisterHeadphoneBaselineOk
  | RegisterHeadphoneBaselineErr;

export function inferBrandModel(
  displayName: string,
  brand?: string,
  model?: string
): { brand: string; model: string } {
  let inferredBrand = brand?.trim() || "";
  let inferredModel = model?.trim() || "";
  if (!inferredBrand || !inferredModel) {
    const hit = KNOWN_MULTI_WORD_BRANDS.find((b) =>
      displayName.toLowerCase().startsWith(b.toLowerCase() + " ")
    );
    if (hit) {
      inferredBrand = inferredBrand || hit;
      inferredModel = inferredModel || displayName.slice(hit.length).trim();
    } else {
      const parts = displayName.split(/\s+/);
      inferredBrand = inferredBrand || parts[0] || "Unknown";
      inferredModel =
        inferredModel || (parts.length > 1 ? parts.slice(1).join(" ") : displayName);
    }
  }
  return { brand: inferredBrand, model: inferredModel };
}

export function niceTargetName(targetCurveId: string): string {
  if (targetCurveId === "harman-neutral") return "Harman Neutral";
  if (targetCurveId === "crinacle-ief-2025") return "Crinacle IEF Preference 2025";
  return targetCurveId;
}

function inferTypeFromAutoEq(displayName: string, url: string): HeadphoneType {
  const pathLower = url.toLowerCase();
  const nameLower = displayName.toLowerCase();
  if (pathLower.includes("/in-ear/") || /iem|earbud/.test(nameLower)) {
    return /earbud|open ear|open-ear/.test(nameLower) ? "earbud" : "iem";
  }
  if (/true wireless|tw[s]?/.test(nameLower)) return "true_wireless";
  if (/on-ear|on ear/.test(nameLower)) return "on_ear";
  if (/closed/.test(nameLower)) return "closed_back";
  return "open_back";
}

function toBandSpecs(bands: RegisterBandSpec[]): RegisterBandSpec[] {
  return bands.map((b) => ({
    index: b.index,
    type: b.type,
    frequencyHz: b.frequencyHz,
    gainDb: b.gainDb,
    q: b.q,
    channel: b.channel,
    enabled: b.enabled,
  }));
}

function appSyncPayload(
  result: ControlResult<{ ok: boolean; message?: string; profileCount?: number; presetCount?: number }>,
  kind: "knowledge" | "presets"
): Record<string, unknown> {
  if (result.online) {
    return {
      online: true,
      reloaded: result.data?.ok === true,
      message: result.data?.message,
      ...(kind === "knowledge" ? { profileCount: result.data?.profileCount } : {}),
      ...(kind === "presets" ? { presetCount: result.data?.presetCount } : {}),
    };
  }
  return { online: false, message: result.error };
}

function clampPreamp(value: number): number {
  return Math.max(PREAMP_MIN, Math.min(PREAMP_MAX, Number(value.toFixed(1))));
}

export async function registerHeadphoneBaseline(
  input: RegisterHeadphoneBaselineInput,
  deps: RegisterHeadphoneBaselineDeps = {}
): Promise<RegisterHeadphoneBaselineResult> {
  const headphone = input.headphone.trim();
  const targetCurveId = input.targetCurveId?.trim() || "harman-neutral";
  const preferenceBands = input.preferenceBands ?? [];
  const explicitBands = (input.bands ?? []).filter((b) => b != null);
  const hasExplicitBands = explicitBands.length > 0;
  const lookupAutoEq = deps.getAutoEqCorrection ?? getCorrection;
  const reloadKnowledgeFn = deps.reloadKnowledge ?? reloadKnowledge;
  const reloadPresetsFn = deps.reloadPresets ?? reloadPresets;

  if (!hasExplicitBands && targetCurveId !== "harman-neutral") {
    throw new Error("AutoEq supplies Harman correction. For a different target, provide explicit bands and provenance.");
  }

  if (hasExplicitBands && !input.type) {
    return {
      ok: false,
      reason: "type_required",
      headphone,
      hint: "Pass type (open_back / closed_back / iem / earbud / on_ear / true_wireless) when registering explicit bands.",
    };
  }

  let displayName = headphone;
  let measuredSpecs: RegisterBandSpec[] = [];
  let autoeqPreamp: number | undefined;
  let autoeqMeta: RegisterHeadphoneBaselineOk["autoeq"];
  let autoNotes: string[] = [];
  let inferredType = input.type;
  let correctionSource = input.provenance?.trim() || "";
  let credibility: Credibility = input.credibility ?? (hasExplicitBands ? "estimated" : "measured");
  let measuredCorrection: NonNullable<EQPreset["correction"]>["measuredCorrection"] | undefined;
  let autoeqSourceTag: string | undefined;

  if (hasExplicitBands) {
    measuredSpecs = toBandSpecs(explicitBands);
    const provenance =
      input.provenance?.trim() ||
      input.source?.trim() ||
      `Explicit PEQ for ${headphone}; not from AutoEq.`;
    correctionSource = provenance;
    autoNotes = [`Explicit PEQ toward ${niceTargetName(targetCurveId)}. Provenance: ${provenance}`];
    autoeqMeta = { skipped: true, reason: "explicit_bands" };
  } else {
    const lookup = await lookupAutoEq({
      headphone,
      source: input.source,
      refresh: input.refreshAutoEq,
    });
    if (!lookup.found || !lookup.correction) {
      return {
        ok: false,
        reason: "autoeq_not_found",
        headphone,
        suggestions: lookup.suggestions ?? [],
        hint:
          lookup.suggestions.length > 0
            ? "Retry with one of the AutoEq suggestions, or pass bands + type for a non-AutoEq baseline."
            : "No AutoEq match. Pass bands + type to register an explicit Auralink baseline.",
      };
    }
    const c = lookup.correction;
    displayName = c.name;
    measuredSpecs = c.bands.map((b) => ({
      type: b.type,
      frequencyHz: b.frequencyHz,
      gainDb: b.gainDb,
      q: b.q,
    }));
    autoeqPreamp = c.preampDb;
    measuredCorrection = c.measuredCorrection;
    autoeqSourceTag = c.source.toLowerCase().replace(/\s+/g, "-");
    credibility = "measured";
    if (!inferredType) inferredType = inferTypeFromAutoEq(c.name, c.url ?? "");
    autoNotes = [
      `AutoEq/${c.source} measured correction toward the Harman target (preamp ${c.preampDb} dB, ${c.bands.length} bands).`,
      c.rig ? `Measurement rig: ${c.rig}.` : "Measurement rig not listed in the AutoEq index.",
      `Provenance: ${c.url}`,
    ];
    if (c.conversionNotes?.length) {
      autoNotes.push(`Conversion notes: ${c.conversionNotes.join(" ")}`);
    }
    correctionSource = `AutoEq/${c.source}${c.rig ? ` (${c.rig})` : ""} — ${c.url}`;
    autoeqMeta = {
      name: c.name,
      source: c.source,
      rig: c.rig ?? null,
      preampDb: c.preampDb,
      bandCount: c.bands.length,
      measuredFIRAvailable: c.measuredCorrection !== undefined,
      provenance: c.url,
    };
  }

  const { brand, model } = inferBrandModel(displayName, input.brand, input.model);
  const profileId = slugify(`${brand}-${model}`);
  const form: HeadphoneType = inferredType ?? "open_back";
  const niceTarget = niceTargetName(targetCurveId);

  // Build the profile object (not yet saved — validation happens first).
  const profileData: HeadphoneProfile = {
    id: profileId,
    brand,
    model,
    type: form,
    signature:
      input.signature?.trim() ||
      (hasExplicitBands
        ? `${form.replace(/_/g, " ")} profile; baseline target ${targetCurveId}.`
        : `Measured ${form.replace(/_/g, " ")} profile from AutoEq; baseline target ${targetCurveId}.`),
    correctionNotes: [...autoNotes, ...(input.correctionNotes ?? [])],
    harshRegionsHz: input.harshRegionsHz ?? [],
    suggestedTargetCurveId: targetCurveId,
    source: correctionSource,
    credibility,
  };

  const explicitIndexes = measuredSpecs.flatMap((b) => b.index === undefined ? [] : [b.index]);
  const occupied = new Set(explicitIndexes);
  if (measuredSpecs.length > 20 || occupied.size !== explicitIndexes.length ||
      explicitIndexes.some((i) => !Number.isInteger(i) || i < 1 || i > 20)) {
    throw new Error("Baseline must fit in 20 distinct band slots; no correction bands may be dropped.");
  }
  const assignedSpecs = measuredSpecs.map((b) => {
    if (b.index !== undefined) return b;
    const index = Array.from({ length: 20 }, (_, i) => i + 1).find((i) => !occupied.has(i))!;
    occupied.add(index);
    return { ...b, index };
  });
  const builtBands = bandsFromSpecs(assignedSpecs);
  const preferenceBandIndexes: number[] = [];

  const prefTag = input.preferenceLabel?.trim();
  const finalName = `${displayName} – ${niceTarget} Baseline`;

  const maxMeasuredBoost = Math.max(0, ...measuredSpecs.map((b) => b.gainDb ?? 0));
  let rawPreamp: number;
  if (input.preampDb !== undefined) {
    rawPreamp = input.preampDb;
  } else if (autoeqPreamp !== undefined) {
    rawPreamp = autoeqPreamp;
  } else {
    const maxBoost = maxMeasuredBoost;
    rawPreamp = maxBoost > 0 ? -(maxBoost + 0.5) : 0;
  }
  const chosenPreamp = clampPreamp(rawPreamp);

  const presetId = `ai_${profileId}_${slugify(targetCurveId)}`;
  const tags = ["ai", "baseline", targetCurveId, profileId];
  if (!hasExplicitBands) {
    tags.push("autoeq", autoeqSourceTag ?? "autoeq");
    if (measuredCorrection) tags.push("measured-fir");
  }

  const draft: EQPreset = normalizePreset({
    id: presetId,
    name: finalName,
    headphone: displayName,
    goal:
      (hasExplicitBands
        ? `Explicit PEQ toward ${niceTarget}`
        : `AutoEq measured correction toward ${niceTarget}`) +
      ".",
    preampDb: chosenPreamp,
    bands: builtBands,
    safety: { autoGainEnabled: false, clippingRisk: "low" },
    createdBy: "ai",
    version: 1,
    tags,
    createdAt: "",
    updatedAt: "",
    correction: {
      role: "baseline",
      source: hasExplicitBands
        ? correctionSource
        : `autoeq-${autoeqSourceTag ?? "unknown"}`,
      sourceConfidence: credibility,
      correctionStrength: 1,
      targetCurveId,
      targetBlend: 1,
      preferenceBandIndexes,
      measuredCorrection,
    },
  });

  // Registration reuses the original baseline. Preference requests never mutate it.
  let existing = await getPreset(presetId);
  if (existing && !isPureBaseline(existing)) {
    // Older registrations sometimes mixed preferences into the baseline id.
    // Preserve that tuning and create the pure baseline under a distinct id.
    draft.id = `${presetId}_baseline`;
    existing = await getPreset(draft.id);
    if (existing && !isPureBaseline(existing)) {
      throw new Error(`Preset '${draft.id}' is not a pure baseline. Choose a distinct registration target id.`);
    }
  }
  const baseline = existing ?? draft;
  const tuning = preferenceBands.length > 0 ? buildPreferenceTuning(baseline, {
    name: `${displayName} – ${niceTarget} (${prefTag || "Preference"})`,
    bands: preferenceBands,
    goal: `Preference layer (${prefTag || "custom"}) on ${baseline.name}.`,
  }) : undefined;

  // Validate both presets BEFORE writing any profile or preset.
  const rules = await loadSafetyRules();
  const baselineValidation = validatePreset(baseline, rules, 48_000, "all");
  const validation = tuning ? validatePreset(tuning, rules, 48_000, "all") : baselineValidation;
  if (!baselineValidation.ok || !validation.ok) {
    return {
      ok: false,
      reason: "validation_failed",
      profile: profileData,
      validation: !baselineValidation.ok ? baselineValidation : validation,
    };
  }

  const savedBaseline = existing ?? await savePreset({
    ...baseline,
    safety: { autoGainEnabled: false, clippingRisk: baselineValidation.clippingRisk },
  });
  await addPresetToCollection(savedBaseline.id);
  const saved = tuning ? await savePreset({
    ...tuning,
    safety: { autoGainEnabled: false, clippingRisk: validation.clippingRisk },
  }) : savedBaseline;
  const inCollection = (await addPresetToCollection(saved.id)) != null;
  const profile = await saveHeadphoneProfile(profileData);
  const appKnowledge = await reloadKnowledgeFn();
  const appPresetSync = await reloadPresetsFn();

  return {
    ok: true,
    collectionDir: collectionDir(),
    written: {
      baseline: path.join(collectionPresetsDir(), `${savedBaseline.id}.json`),
      headphone: path.join(collectionHeadphonesDir(), `${profile.id}.json`),
      preset: path.join(collectionPresetsDir(), `${saved.id}.json`),
    },
    profile,
    baseline: savedBaseline,
    baselineReused: existing !== null,
    preset: {
      id: saved.id,
      name: saved.name,
      preampDb: saved.preampDb,
      preferenceBandIndexes: saved.correction?.preferenceBandIndexes ?? [],
      tags: saved.tags,
      inCollection,
    },
    validation,
    appKnowledge: appSyncPayload(appKnowledge, "knowledge"),
    appPresetSync: appSyncPayload(appPresetSync, "presets"),
    autoeq: autoeqMeta,
    note:
      `Profile, baseline and any preference tuning saved to your collection at ${collectionDir()}. ` +
      "The original baseline is preserved separately; live audio was not changed. Commit the collection " +
      "when you want it in git. Luxsin X8 is a separate target — use " +
      "apply_eq_preset/create_eq_preset with target luxsin-x8.",
  };
}
