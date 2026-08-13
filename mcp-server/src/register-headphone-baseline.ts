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
  written: { headphone: string; preset: string };
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

  const prefSpecs = toBandSpecs(preferenceBands);
  const builtBands = bandsFromSpecs([...measuredSpecs, ...prefSpecs]);
  const enabledIndexes = builtBands.filter((b) => b.enabled).map((b) => b.index);
  const preferenceBandIndexes = enabledIndexes.slice(measuredSpecs.length);

  const prefTag = input.preferenceLabel?.trim();
  const finalName = prefTag
    ? `${displayName} – ${niceTarget} (${prefTag})`
    : `${displayName} – ${niceTarget}`;

  const maxMeasuredBoost = Math.max(0, ...measuredSpecs.map((b) => b.gainDb ?? 0));
  const maxPrefBoost = Math.max(0, ...preferenceBands.map((b) => b.gainDb ?? 0));
  let rawPreamp: number;
  if (input.preampDb !== undefined) {
    rawPreamp = input.preampDb;
  } else if (autoeqPreamp !== undefined) {
    rawPreamp =
      preferenceBands.length > 0
        ? Math.min(autoeqPreamp, -(maxMeasuredBoost + Math.min(maxPrefBoost, 3)) - 0.5)
        : autoeqPreamp;
  } else {
    const maxBoost = Math.max(maxMeasuredBoost, maxPrefBoost);
    rawPreamp = maxBoost > 0 ? -(maxBoost + 0.5) : 0;
  }
  const chosenPreamp = clampPreamp(rawPreamp);

  const presetId = `ai_${profileId}_${slugify(targetCurveId)}${prefTag ? `_${slugify(prefTag)}` : ""}`;
  const tags = ["ai", "baseline", targetCurveId, profileId];
  if (!hasExplicitBands) {
    tags.push("autoeq", autoeqSourceTag ?? "autoeq", "measured-fir");
  }
  if (prefTag) tags.push(slugify(prefTag));

  const draft: EQPreset = normalizePreset({
    id: presetId,
    name: finalName,
    headphone: displayName,
    goal:
      (hasExplicitBands
        ? `Explicit PEQ toward ${niceTarget}`
        : `AutoEq measured correction toward ${niceTarget}`) +
      (prefTag ? `, plus preference layer (${prefTag}).` : "."),
    preampDb: chosenPreamp,
    bands: builtBands,
    safety: { autoGainEnabled: false, clippingRisk: "low" },
    createdBy: "ai",
    version: 1,
    tags,
    createdAt: "",
    updatedAt: "",
    correction: {
      role: preferenceBandIndexes.length > 0 ? "combined" : "baseline",
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

  // Validate BEFORE writing anything: a validation failure leaves no orphan profile.
  const rules = await loadSafetyRules();
  const validation = validatePreset(draft, rules, 48_000, "all");
  if (!validation.ok) {
    return {
      ok: false,
      reason: "validation_failed",
      profile: profileData,
      validation,
    };
  }

  // Validation passed — now write profile and preset.
  const profile = await saveHeadphoneProfile(profileData);
  const appKnowledge = await reloadKnowledgeFn();

  const finalPreset: EQPreset = {
    ...draft,
    preampDb: chosenPreamp,
    safety: { autoGainEnabled: false, clippingRisk: validation.clippingRisk },
  };
  const saved = await savePreset(finalPreset);
  // A headphone with no baseline is useless, so registering one keeps its measured
  // baseline in the collection alongside the profile.
  const inCollection = (await addPresetToCollection(saved.id)) != null;
  const appPresetSync = await reloadPresetsFn();

  return {
    ok: true,
    collectionDir: collectionDir(),
    written: {
      headphone: path.join(collectionHeadphonesDir(), `${profile.id}.json`),
      preset: path.join(collectionPresetsDir(), `${saved.id}.json`),
    },
    profile,
    preset: {
      id: saved.id,
      name: saved.name,
      preampDb: saved.preampDb,
      preferenceBandIndexes,
      tags: saved.tags,
      inCollection,
    },
    validation,
    appKnowledge: appSyncPayload(appKnowledge, "knowledge"),
    appPresetSync: appSyncPayload(appPresetSync, "presets"),
    autoeq: autoeqMeta,
    note:
      `Profile + baseline preset written to your collection at ${collectionDir()}, ` +
      "and the baseline is live in the working preset library. Commit the collection " +
      "when you want it in git. Luxsin X8 is a separate target — use " +
      "apply_eq_preset/create_eq_preset with target luxsin-x8.",
  };
}
