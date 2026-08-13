import {
  loadHeadphoneProfiles,
  loadAgentEQGuide,
  loadTargetCurves,
  loadSafetyRules,
} from "./store.js";
import { getState } from "./control.js";
import { createX8Target, type ApplyTuningRequest } from "./targets/index.js";
import { responseCurve, logFrequencies } from "./validate.js";
import {
  AudioState,
  EQPreset,
  HeadphoneProfile,
  BAND_TYPES,
  BAND_CHANNELS,
  FREQ_MIN,
  FREQ_MAX,
  GAIN_MIN,
  GAIN_MAX,
  Q_MIN,
  Q_MAX,
} from "./types.js";

export function correctionMetadataFromInput(input: {
  correctionRole?: "generic" | "baseline" | "preference" | "combined";
  baselinePresetId?: string;
  correctionSource?: string;
  sourceConfidence?: "measured" | "manufacturer" | "community" | "estimated" | "unknown";
  correctionStrength?: number;
  targetCurveId?: string;
  targetBlend?: number;
  preferenceBandIndexes?: number[];
  measuredCorrection?: NonNullable<EQPreset["correction"]>["measuredCorrection"];
  tags?: string[];
}): EQPreset["correction"] | undefined {
  const tags = input.tags ?? [];
  const hasMetadata =
    input.correctionRole !== undefined ||
    input.baselinePresetId !== undefined ||
    input.correctionSource !== undefined ||
    input.sourceConfidence !== undefined ||
    input.correctionStrength !== undefined ||
    input.targetCurveId !== undefined ||
    input.targetBlend !== undefined ||
    (input.preferenceBandIndexes?.length ?? 0) > 0 ||
    input.measuredCorrection !== undefined;

  if (!hasMetadata) return undefined;

  const preferenceCount = input.preferenceBandIndexes?.length ?? 0;
  const inferredRole =
    input.correctionRole ??
    (input.measuredCorrection && preferenceCount > 0
      ? "combined"
      : input.baselinePresetId || preferenceCount > 0
        ? "preference"
        : input.measuredCorrection || tags.includes("baseline")
          ? "baseline"
          : "generic");

  return {
    role: inferredRole,
    baselinePresetId: input.baselinePresetId,
    source: input.correctionSource,
    sourceConfidence: input.sourceConfidence ?? (input.measuredCorrection ? "measured" : "unknown"),
    correctionStrength: input.correctionStrength ?? 1,
    targetCurveId: input.targetCurveId,
    targetBlend: input.targetBlend ?? 1,
    preferenceBandIndexes: [...new Set(input.preferenceBandIndexes ?? [])].sort((a, b) => a - b),
    measuredCorrection: input.measuredCorrection,
  };
}

export function x8TargetCurveFromPreset(preset: EQPreset): string | undefined {
  const source = preset.correction?.source;
  const targetCurve = preset.correction?.targetCurveId;
  if (source && targetCurve) return `${source} + ${targetCurve}`;
  return source ?? targetCurve;
}

export function x8FormFromProfile(profile: HeadphoneProfile | undefined): string | undefined {
  switch (profile?.type) {
    case "iem":
    case "earbud":
    case "true_wireless":
      return "in-ear";
    case "open_back":
    case "closed_back":
    case "on_ear":
      return "over-ear";
    default:
      return undefined;
  }
}

export async function x8ApplyRequestFromPreset(preset: EQPreset): Promise<ApplyTuningRequest> {
  const profiles = await loadHeadphoneProfiles();
  const profile = findProfile(preset.headphone ?? preset.name, profiles);
  return {
    headphone: preset.name,
    brand: profile?.brand,
    model: profile?.model ?? preset.headphone ?? preset.name,
    form: x8FormFromProfile(profile),
    goal: preset.goal,
    targetCurve: x8TargetCurveFromPreset(preset),
    preampDb: preset.preampDb,
    bands: preset.bands,
  };
}

export async function applyPresetToX8(
  preset: EQPreset,
  confirmed: boolean,
  options: { select?: boolean } = {}
): Promise<Record<string, unknown>> {
  const selectAfterWrite = options.select !== false; // default true for backward compatibility
  const target = createX8Target();
  const request = await x8ApplyRequestFromPreset(preset);
  const write = await target.applyTuning(request, confirmed);
  if (!write.online) {
    return {
      target: "luxsin-x8",
      applied: false,
      online: false,
      message: write.error,
    };
  }

  if (!write.data) {
    return {
      target: "luxsin-x8",
      applied: false,
      message: write.error ?? "The X8 target returned no response body.",
    };
  }

  const body = write.data;
  let select: unknown = { selected: false, skipped: true };
  if (confirmed && body.ok === true && body.ref && selectAfterWrite) {
    const selected = await target.selectHeadphone(String(body.ref));
    select = selected.online
      ? {
          selected: selected.data?.ok === true,
          index: selected.data?.index,
          message: selected.data?.ok === true ? `Selected '${body.ref}' on the X8.` : (selected.error ?? "The X8 did not select the entry."),
        }
      : { selected: false, online: false, message: selected.error };
  } else if (confirmed && body.ok === true && !selectAfterWrite) {
    select = {
      selected: false,
      skipped: true,
      message: "Import-only: left the previous X8 entry selected (applyTuning restores active entry by name).",
    };
  }

  return {
    target: "luxsin-x8",
    applied: body.ok === true,
    needsConfirm: body.needsConfirm === true,
    entryName: body.ref,
    appliedBandCount: body.appliedBands?.length,
    notes: body.notes,
    select,
  };
}

export function profileDisplayName(profile: HeadphoneProfile): string {
  return `${profile.brand} ${profile.model}`;
}

export function slugify(input: string): string {
  return input
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "");
}

export function findProfile(input: string | undefined, profiles: HeadphoneProfile[]): HeadphoneProfile | undefined {
  if (!input || input.trim().length === 0) return undefined;
  const needle = input.toLowerCase();
  return profiles.find((p) => {
    const names = [p.id, p.model, profileDisplayName(p), `${p.brand} ${p.model}`].map((s) => s.toLowerCase());
    return names.some((name) => needle.includes(name) || name.includes(needle));
  });
}

export async function tuningGuidePayload(options: {
  headphone?: string;
  goal?: string;
  includeLiveState?: boolean;
} = {}): Promise<Record<string, unknown>> {
  const [profiles, curves, rules, live] = await Promise.all([
    loadHeadphoneProfiles(),
    loadTargetCurves(),
    loadSafetyRules(),
    options.includeLiveState === false ? Promise.resolve(undefined) : getState(),
  ]);
  const agentGuide = await loadAgentEQGuide();
  const profile = findProfile(options.headphone, profiles);
  const liveState = live?.online ? live.data : undefined;

  return {
    agentGuide: {
      resource: "eq://agent-guide",
      tool: "get_agent_eq_guide",
      source: agentGuide.source,
      path: agentGuide.path ?? null,
      summary:
        "Use the agent guide for the product workflow: adding a model saves a Harman baseline; preference tuning auditions first and saves only when the user likes it.",
    },
    roleSplit: {
      aiClient:
        "Interprets the user's language, chooses the headphone/target direction, designs explicit parametric EQ bands, explains tradeoffs, and asks before live changes.",
      mcpServer:
        "Provides state, headphone profiles, target curves, safety rules, validation, preset writing, and live apply/routing tools. It does not run an LLM.",
      auralinkApp:
        "Runs the audio engine, stores presets, validates/apply requests, and reports setup/routing state. It has no AI model.",
    },
    liveState: live
      ? live.online
        ? {
            online: true,
            routingActive: liveState?.routingActive,
            systemOutputRoutedToAuralink: liveState?.systemOutputRoutedToAuralink,
            needsVirtualDevice: liveState?.needsVirtualDevice,
            loopbackDriverInstalled: liveState?.loopbackDriverInstalled,
            systemOutputDeviceName: liveState?.systemOutputDeviceName,
            outputDeviceName: liveState?.outputDeviceName,
            audioInputPermission: liveState?.audioInputPermission,
            capturePeakDb: liveState?.capturePeakDb,
            outputPeakDb: liveState?.outputPeakDb,
            captureCallbacks: liveState?.captureCallbacks,
            renderCallbacks: liveState?.renderCallbacks,
            capturedFrames: liveState?.capturedFrames,
            renderedFrames: liveState?.renderedFrames,
            ringReadFrames: liveState?.ringReadFrames,
            ringAvailableFrames: liveState?.ringAvailableFrames,
            currentPresetId: liveState?.currentPresetId,
            currentPresetName: liveState?.currentPresetName,
            setupMeaning:
              liveState?.audioInputPermission && liveState.audioInputPermission !== "authorized"
                ? "Auralink does not have audio input permission; live capture cannot work until Microphone access is granted."
                : liveState?.needsVirtualDevice && liveState.loopbackDriverInstalled
                ? "BlackHole is installed but not exposed by CoreAudio yet; tell the user to restart macOS, then refresh."
                : liveState?.needsVirtualDevice
                  ? "No supported loopback device is available; live system EQ cannot run yet."
                  : "A supported loopback device is available.",
          }
        : { online: false, message: live.error }
      : undefined,
    requestedContext: {
      headphone: options.headphone ?? null,
      matchedHeadphone: profile
        ? {
            id: profile.id,
            displayName: profileDisplayName(profile),
            signature: profile.signature,
            correctionNotes: profile.correctionNotes,
            harshRegionsHz: profile.harshRegionsHz,
            suggestedTargetCurveId: profile.suggestedTargetCurveId,
          }
        : null,
      goal: options.goal ?? null,
    },
    workflow: [
      "Call get_agent_eq_guide and get_current_audio_state. If needsVirtualDevice is true, do not route or promise audible changes.",
      "Resolve the headphone with list_headphone_profiles/get_headphone_profile, or add it with upsert_headphone_profile when the user provides enough model data.",
      "MEASURED FIRST: call get_autoeq_correction with the model name. A hit returns AutoEq's measured PEQ fallback and, when published, a dense measuredCorrection payload. Use the exact bands/preamp as the baseline and copy measuredCorrection unchanged into Auralink software presets so Measured FIR can reproduce the dense curve. Record the source/rig in the preset goal or tags.",
      "Only when no measurement exists: read eq://target-curves and eq://safety-rules and design a conservative baseline from the profile's correction notes.",
      "For a newly added model, save the baseline with create_eq_preset (tags: baseline + the evidence source, e.g. autoeq-oratory1990).",
      "For preference changes, preserve measuredCorrection, mark only the new subjective slots in preferenceBandIndexes, and audition with audition_eq_preset instead of saving every experiment. Measured FIR then renders the dense baseline plus those preference bands, without applying baseline PEQ twice.",
      "After designing or editing bands, call get_response_curve and check the curve does what the user asked (e.g. '+3 dB shelf below 100 Hz, mids flat, 7 kHz dip') before auditioning.",
      "Prefer 3-8 meaningful bands for preference moves; measured baselines may legitimately use 10.",
      "Favor cuts for harsh/problem regions. If the user says a change is too subtle, scale the relevant moves up (±3-4 dB) rather than adding more tiny bands.",
      "Audition level: keep AutoEq's preamp for measured baselines. For small tweaks preampDb:0/autoGain:false preserves level; for bigger boost stacks enable autoGain.",
      "Call validate_eq_preset for a dry run when uncertain. The write/audition paths validate again.",
      "If the user says they like the current audition or asks to save it, call save_current_preset.",
      "If the user only asked to add/save a profile or baseline preset, do not apply it unless they also asked to hear it.",
      "Call apply_eq_preset separately only when applying an already-saved preset. Pass confirmed:true only for explicit user requests.",
      "Call route_system_audio only when the user asked for live system sound routing and state shows a loopback device is available.",
    ],
    bandDesignHeuristics: {
      warm: [
        { type: "low_shelf", frequencyHz: 100, gainDb: 1.5, q: 0.7, note: "Gentle warmth/body." },
        { type: "bell", frequencyHz: 250, gainDb: 0.8, q: 1.0, note: "Lower-mid body; skip if muddy." },
      ],
      clearerVocals: [
        { type: "bell", frequencyHz: 2500, gainDb: 1.0, q: 1.1, note: "Presence/intelligibility." },
        { type: "bell", frequencyHz: 300, gainDb: -0.8, q: 1.0, note: "Optional mud reduction." },
      ],
      smootherTreble: [
        { type: "bell", frequencyHz: 6000, gainDb: -1.5, q: 1.6, note: "General glare reduction." },
        { type: "bell", frequencyHz: 8000, gainDb: -1.5, q: 2.0, note: "Sibilance/peak control." },
      ],
      moreBass: [
        { type: "low_shelf", frequencyHz: 70, gainDb: 2.0, q: 0.7, note: "Sub/low bass lift; keep conservative." },
      ],
    },
    koreanIntentHints: {
      "따뜻하게": "warm/body; usually low shelf around 100-120 Hz plus maybe lower-mid body.",
      "보컬 선명하게": "clearer vocals; presence around 2-4 kHz, sometimes reduce 200-400 Hz mud.",
      "저음 더": "more bass; low shelf around 60-90 Hz, avoid excessive aggregate boost.",
      "쏘는 고음 줄여줘": "smoother treble; cuts around headphone harsh regions or common 5-9 kHz.",
      "부드럽게": "smooth/less fatiguing; reduce harsh treble before boosting anything.",
    },
    createPresetContract: {
      tool: "create_eq_preset",
      required: ["name", "bands"],
      importantFields: ["headphone", "goal", "autoGain", "tags", "applyNow", "confirmed"],
      bandFields: {
        type: BAND_TYPES,
        frequencyHz: `${FREQ_MIN}-${FREQ_MAX}`,
        gainDb: `${GAIN_MIN}-${GAIN_MAX}`,
        q: `${Q_MIN}-${Q_MAX}`,
        channel: BAND_CHANNELS,
      },
      safetyLimits: rules,
    },
    availableTargetCurves: curves.map((curve) => ({
      id: curve.id,
      name: curve.name,
      category: curve.category,
      description: curve.description,
      hintCount: curve.hints.length,
    })),
  };
}

/** Region-average summary of a preset's magnitude response (preamp included).
 *  Uses the SAME region buckets as get_response_curve so the AI sees one vocabulary. */
export function curveSummary(
  preset: EQPreset,
  sampleRate = 48_000
): {
  peak: { hz: number; db: number };
  dip: { hz: number; db: number };
  regions: {
    subBass20to60: number;
    bass60to250: number;
    mids250to2k: number;
    presence2kTo6k: number;
    treble6kTo20k: number;
  };
} {
  const freqs = logFrequencies(61);
  const curve = responseCurve(preset, freqs, sampleRate);
  const round = (x: number, p: number) => Math.round(x * p) / p;
  const pts = curve.map((pt) => ({
    hz: round(pt.frequencyHz, 10),
    db: round(pt.magnitudeDb, 100),
  }));
  let peak = pts[0];
  let dip = pts[0];
  for (const pt of pts) {
    if (pt.db > peak.db) peak = pt;
    if (pt.db < dip.db) dip = pt;
  }
  const avgIn = (lo: number, hi: number) => {
    const inBand = pts.filter((pt) => pt.hz >= lo && pt.hz <= hi);
    if (inBand.length === 0) return 0;
    return round(inBand.reduce((sum, pt) => sum + pt.db, 0) / inBand.length, 100);
  };
  return {
    peak,
    dip,
    regions: {
      subBass20to60: avgIn(20, 60),
      bass60to250: avgIn(60, 250),
      mids250to2k: avgIn(250, 2_000),
      presence2kTo6k: avgIn(2_000, 6_000),
      treble6kTo20k: avgIn(6_000, 20_000),
    },
  };
}

/** Tuning-relevant subset of the live AudioState (drops the telemetry noise). */
export function condensedLiveState(s: AudioState) {
  return {
    online: true as const,
    routingActive: s.routingActive,
    systemOutputRoutedToAuralink: s.systemOutputRoutedToAuralink,
    eqEnabled: s.eqEnabled,
    safeMode: s.safeMode,
    outputDeviceName: s.outputDeviceName ?? null,
    systemOutputDeviceName: s.systemOutputDeviceName ?? null,
    currentPresetId: s.currentPresetId ?? null,
    currentPresetName: s.currentPresetName ?? null,
    clippingDetected: s.clippingDetected,
    clippingEventsTotal: s.clippingEventsTotal,
    outputPeakDb: s.outputPeakDb,
    permissionMode: s.permissionMode,
  };
}

/** True when a preset plausibly belongs to the given headphone display name. */
export function headphoneMatchesPreset(preset: EQPreset, needle: string): boolean {
  if (!needle || needle.trim().length === 0) return false;
  const n = needle.toLowerCase();
  const haystack = `${preset.headphone ?? ""} ${preset.name}`.toLowerCase();
  return haystack.includes(n);
}

/** True when a preset is a measured/Harman baseline (not a preference variation).
 *  Per the agent guide, baselines are saved with the `harman-neutral` tag and/or a
 *  measured source (autoeq/crinacle/oratory); preference variations carry other tags. */
export function presetIsBaseline(preset: EQPreset): boolean {
  if (preset.correction?.role === "baseline") return true;
  const tags = preset.tags.map((t) => t.toLowerCase());
  if (tags.includes("baseline")) return true;
  if (tags.includes("harman-neutral")) return true;
  const blob = `${preset.name} ${preset.correction?.source ?? ""} ${preset.goal ?? ""} ${tags.join(" ")}`.toLowerCase();
  return /autoeq|crinacle|oratory|\bmeasured\b|harman.?baseline/.test(blob);
}

/** Resolve the best baseline preset for a headphone + list the alternates.
 *  `bestAvailable` is the newest matching preset regardless of baseline status,
 *  used as a fallback starting point when no measured baseline exists yet. */
export function resolveBaselineForHeadphone(
  needle: string,
  presets: EQPreset[]
): {
  recommendedBaseline: EQPreset | null;
  otherBaselines: EQPreset[];
  bestAvailable: EQPreset | null;
  matchCount: number;
} {
  const matches = presets.filter((p) => headphoneMatchesPreset(p, needle));
  const byNewest = (a: EQPreset, b: EQPreset) => (b.updatedAt ?? "").localeCompare(a.updatedAt ?? "");
  const sortedMatches = [...matches].sort(byNewest);
  const baselines = sortedMatches.filter(presetIsBaseline);
  return {
    recommendedBaseline: baselines[0] ?? null,
    otherBaselines: baselines.slice(1),
    bestAvailable: sortedMatches[0] ?? null,
    matchCount: matches.length,
  };
}

/** A compact, AI-facing digest of one preset: identity, curve summary, active bands. */
export function presetDigest(p: EQPreset) {
  return {
    id: p.id,
    name: p.name,
    headphone: p.headphone ?? null,
    goal: p.goal ?? null,
    preampDb: p.preampDb,
    activeBands: p.bands.filter((b) => b.enabled).length,
    tags: p.tags,
    correction: p.correction
      ? {
          role: p.correction.role,
          source: p.correction.source ?? null,
          sourceConfidence: p.correction.sourceConfidence,
          baselinePresetId: p.correction.baselinePresetId ?? null,
        }
      : null,
    curve: curveSummary(p),
    bands: p.bands
      .filter((b) => b.enabled)
      .map((b) => ({
        index: b.index,
        type: b.type,
        frequencyHz: b.frequencyHz,
        gainDb: b.gainDb,
        q: b.q,
        channel: b.channel,
      })),
    updatedAt: p.updatedAt,
  };
}

/** Compact taste hint for the brief: just the headline aggregates, no full entries. */
export function compactPreferenceHint(summary: import("./store.js").TuningPreferenceSummary) {
  return {
    totalEntries: summary.totalEntries,
    sentimentCounts: summary.sentimentCounts,
    topDislikedIssues: summary.topDislikedIssues.slice(0, 3),
    topLikedIssues: summary.topLikedIssues.slice(0, 3),
    tagFrequency: summary.tagFrequency.slice(0, 5),
    derivedNotes: summary.derivedNotes,
  };
}
