import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";

import {
  loadAllPresets,
  getPreset,
  savePreset,
  deletePreset,
  addPresetToCollection,
  removePresetFromCollection,
  collectionPresetIds,
  collectionDir,
  loadHeadphoneProfiles,
  getHeadphoneProfile,
  saveHeadphoneProfile,
  deleteHeadphoneProfile,
  loadAgentEQGuide,
  loadSafetyRules,
  bandsFromSpecs,
  normalizePreset,
  loadUserTuningPreferences,
  appendTuningFeedback,
  summarizeTuningPreferences,
  PERCEIVED_ISSUES,
  type PerceivedIssue,
  type TuningFeedbackEntry,
} from "./store.js";
import {
  getState,
  getDevices,
  applyPreset,
  auditionPreset,
  saveCurrentPreset,
  rollbackPreset,
  reloadKnowledge,
  reloadPresets,
  routeSystemAudio,
  restoreSystemAudio,
  stopRouting,
} from "./control.js";
import { createX8Target } from "./targets/index.js";
import {
  validatePreset,
  responseCurve,
  logFrequencies,
  measuredFIREligibility,
} from "./validate.js";
import { getCorrection as getAutoEqCorrection } from "./autoeq.js";
import { acceptedRollbackTarget } from "./live-verification.js";
import {
  EQPreset,
  HeadphoneProfile,
  HEADPHONE_TYPES,
  CREDIBILITIES,
  PREAMP_MIN,
  PREAMP_MAX,
} from "./types.js";
import { registerHeadphoneBaseline, type RegisterHeadphoneBaselineInput } from "./register-headphone-baseline.js";
import { jsonResult, errorResult, verifyAuralinkLiveRequest } from "./result.js";
import {
  bandSpecSchema,
  targetSchema,
  correctionInputSchema,
  frequencyRangeSchema,
} from "./schemas.js";
import {
  applyPresetToX8,
  correctionMetadataFromInput,
  findProfile,
  profileDisplayName,
  slugify,
  tuningGuidePayload,
  condensedLiveState,
  resolveBaselineForHeadphone,
  presetDigest,
  compactPreferenceHint,
} from "./helpers.js";

export function registerTools(server: McpServer): void {
  // MARK: - Tools

  // 1. get_current_audio_state — live state from the app (read).
  server.registerTool(
    "get_current_audio_state",
    {
      title: "Get current audio state",
      description:
        "Returns the live AudioState from the running Auralink app (EQ on/off, current preset, " +
        "output device, sample rate, latency, clipping, MCP/permission mode). If the app is offline, " +
        "returns a clear offline notice instead of failing. Pass target:'luxsin-x8' to read the LAN X8 hardware state instead.",
      inputSchema: {
        target: targetSchema,
      },
      annotations: { readOnlyHint: true, destructiveHint: false, openWorldHint: true },
    },
    async ({ target }) => {
      if (target === "luxsin-x8") {
        const x8 = createX8Target();
        const [mapped, full] = await Promise.all([x8.getState(), x8.getX8State()]);
        if (!mapped.online || !full.online) {
          return jsonResult({
            target,
            online: false,
            message: mapped.error ?? full.error,
            hint: "Make sure the Luxsin X8 is powered on and reachable on the local network (default http://192.168.1.2 or X8_URL).",
          });
        }
        return jsonResult({
          target,
          online: true,
          state: mapped.data,
          x8: full.data,
          note: "Read-only. This does not write presets or affect live audio.",
        });
      }

      const res = await getState();
      if (!res.online) {
        return jsonResult({
          target: "auralink",
          online: false,
          message: res.error,
          hint: "Start the Auralink app to read live state. Disk-based reads (presets, profiles) still work.",
        });
      }
      if (!res.data) return errorResult(res.error ?? "ControlServer returned no state.");
      return jsonResult({ target: "auralink", online: true, state: res.data });
    }
  );

  server.registerTool(
    "get_agent_eq_guide",
    {
      title: "Get agent EQ guide",
      description:
        "Returns the agent-facing EQ tuning guide. Use this before interpreting links, adding headphones, " +
        "creating Harman baselines, auditioning preference changes, or saving liked variations.",
      inputSchema: {
        includeLiveState: z
          .boolean()
          .default(false)
          .describe("When true, include the running app's routing/setup state if reachable."),
      },
      annotations: { readOnlyHint: true, destructiveHint: false, openWorldHint: true },
    },
    async ({ includeLiveState }) => {
      const guide = await loadAgentEQGuide();
      const live = includeLiveState ? await getState() : undefined;
      return jsonResult({
        guide,
        recommendedToolFlow: {
          addModel: [
            "upsert_headphone_profile",
            "create_eq_preset with goal='Harman baseline' and tags including baseline/harman-neutral",
          ],
          auditionPreference: [
            "audition_eq_preset with confirmed:true only when the user asked to hear it",
            "save_current_preset only if the user likes it or asks to save",
          ],
          savedPresetApply: ["apply_eq_preset for an existing saved preset"],
        },
        defaultPolicy: {
          baselineTarget: "harman-neutral",
          preferenceSavePolicy: "audition_only_until_user_likes_it",
          auditionAutoGain: false,
          auditionPreampDb: 0,
        },
        liveState: live
          ? live.online
            ? { online: true, state: live.data }
            : { online: false, message: live.error }
          : undefined,
      });
    }
  );

  server.registerTool(
    "get_tuning_guidance",
    {
      title: "Get tuning guidance",
      description:
        "Returns the workflow and guardrails an AI client should follow to design explicit EQ bands for Auralink. " +
        "Use this before creating presets from natural-language requests. Auralink itself is not an AI model.",
      inputSchema: {
        headphone: z
          .string()
          .optional()
          .describe("Optional headphone name or slug from the user's request, e.g. 'HD600'."),
        goal: z
          .string()
          .optional()
          .describe("Optional natural-language tuning goal, e.g. '좀 더 따뜻하게'."),
        includeLiveState: z
          .boolean()
          .default(true)
          .describe("When true, include the running app's routing/setup state if reachable."),
      },
      annotations: { readOnlyHint: true, destructiveHint: false, openWorldHint: true },
    },
    async ({ headphone, goal, includeLiveState }) => {
      return jsonResult(await tuningGuidePayload({ headphone, goal, includeLiveState }));
    }
  );

  // get_tuning_brief — one-call, state-focused tuning context (read).
  server.registerTool(
    "get_tuning_brief",
    {
      title: "Get tuning brief",
      description:
        "Returns a compact, tuning-ready bundle for one headphone and optional goal: condensed live state, " +
        "the matched headphone profile, the resolved baseline preset (with its bands + a response-curve " +
        "summary), the currently applied preset (with its bands + curve), the key safety limits, and a " +
        "concrete recommended starting point. Use this at the START of a tuning task so the current state " +
        "and the baseline to build on are never missed. Read-only; disk data works offline (live state is " +
        "best-effort). For workflow/guardrails/heuristics, also call get_tuning_guidance.",
      inputSchema: {
        headphone: z
          .string()
          .optional()
          .describe("Headphone name or slug, e.g. 'HD600'. Resolved against profiles and preset headphone fields."),
        goal: z
          .string()
          .optional()
          .describe("Optional natural-language tuning goal, e.g. 'a bit warmer'. Echoed back for context."),
      },
      annotations: { readOnlyHint: true, destructiveHint: false, openWorldHint: true },
    },
    async ({ headphone, goal }) => {
      const [profiles, presets, rules, live, prefs] = await Promise.all([
        loadHeadphoneProfiles(),
        loadAllPresets(),
        loadSafetyRules(),
        getState(),
        loadUserTuningPreferences(),
      ]);

      const profile = findProfile(headphone, profiles);
      const liveState = live?.online && live.data ? live.data : undefined;

      // Currently applied preset (from live state), if online & resolvable.
      let currentPresetDigest: unknown = null;
      let currentPreset: EQPreset | null = null;
      if (liveState?.currentPresetId) {
        currentPreset =
          presets.find((p) => p.id === liveState.currentPresetId) ??
          (await getPreset(liveState.currentPresetId));
        if (currentPreset) currentPresetDigest = presetDigest(currentPreset);
      }

      // Resolve the baseline + alternates. When no headphone was named, infer it
      // from the currently playing preset so "make it warmer" still finds a baseline.
      const needle = profile
        ? profileDisplayName(profile)
        : (headphone && headphone.trim().length > 0
            ? headphone
            : currentPreset?.headphone ?? "");
      const inferredHeadphone = !headphone && currentPreset?.headphone ? currentPreset.headphone : null;
      const { recommendedBaseline, otherBaselines, bestAvailable, matchCount } =
        resolveBaselineForHeadphone(needle, presets);

      // Taste hints derived from recorded feedback (global + this headphone).
      const userPreferences = {
        global: compactPreferenceHint(summarizeTuningPreferences(prefs.entries, {})),
        headphone: needle
          ? compactPreferenceHint(summarizeTuningPreferences(prefs.entries, { headphoneNeedle: needle }))
          : null,
      };

      // Concrete recommended starting point. Branch on `needle` (which may have
      // been inferred from the currently playing preset), not on the raw input.
      let recommendation: { situation: string; action: string; startFromPresetId?: string };
      if (!needle || (!profile && matchCount === 0)) {
        recommendation = {
          situation: "unknown_headphone",
          action:
            needle && !profile
              ? `No profile or presets match '${needle}'. If the user is adding a model, gather brand/model/signature and call upsert_headphone_profile; for a known model call get_autoeq_correction first.`
              : "No headphone was named and none could be inferred from the current preset. Ask which headphone/earphone the user means, or, if they are adding a model, gather brand/model/signature and call upsert_headphone_profile.",
        };
      } else if (recommendedBaseline) {
        recommendation = {
          situation: "has_baseline",
          action:
            `Start preference tuning from baseline '${recommendedBaseline.name}'. Layer small explicit bands ON TOP of its bands (don't rewrite them). ` +
            `Verify the combined curve with get_response_curve, then audition_eq_preset only when the user asks to hear it.`,
          startFromPresetId: recommendedBaseline.id,
        };
      } else if (matchCount === 0) {
        recommendation = {
          situation: "profile_without_presets",
          action:
            `No saved presets for '${needle}'` +
            (profile ? " (a profile exists, but no baseline preset)." : ".") +
            ` Call get_autoeq_correction('${needle}') for the measured correction, then save a baseline with create_eq_preset (tags: baseline, harman-neutral).`,
        };
      } else {
        recommendation = {
          situation: "matches_but_no_baseline",
          action:
            `Found ${matchCount} preset(s) for '${needle}' but none is a measured/Harman baseline. ` +
            (bestAvailable
              ? `You can build on the newest match '${bestAvailable.name}' as a starting point, but call get_autoeq_correction('${needle}') to get the measured correction and save a proper baseline so preference moves have a solid foundation.`
              : `Call get_autoeq_correction('${needle}') to get the measured correction and save a proper baseline.`),
          startFromPresetId: bestAvailable?.id,
        };
      }

      return jsonResult({
        requested: { headphone: headphone ?? null, inferredHeadphone, goal: goal ?? null },
        headphone: profile
          ? {
              id: profile.id,
              displayName: profileDisplayName(profile),
              signature: profile.signature,
              credibility: profile.credibility,
              correctionNotes: profile.correctionNotes,
              harshRegionsHz: profile.harshRegionsHz,
              suggestedTargetCurveId: profile.suggestedTargetCurveId ?? null,
            }
          : null,
        live: liveState
          ? condensedLiveState(liveState)
          : {
              online: false,
              message: live?.error ?? "Auralink app not reachable. Disk data below is still valid.",
            },
        currentPreset: currentPresetDigest,
        baselinePreset: recommendedBaseline ? presetDigest(recommendedBaseline) : null,
        bestAvailablePreset: !recommendedBaseline && bestAvailable ? presetDigest(bestAvailable) : null,
        otherBaselines: otherBaselines.map((p) => ({
          id: p.id,
          name: p.name,
          updatedAt: p.updatedAt,
        })),
        headphonePresetCount: matchCount,
        userPreferences,
        safety: {
          maxBoostDb: rules.maxBoostDb,
          maxAggregateBoostDb: rules.maxAggregateBoostDb,
          targetHeadroomDb: rules.targetHeadroomDb,
          autoPreampEnabled: rules.autoPreampEnabled,
        },
        recommendation,
        workflow: [
          "Read this brief first — it already has the current preset, the baseline, the safety limits, and the user's taste hints.",
          "Honor userPreferences.derivedNotes: avoid the things they repeatedly dislike and lean into what they like.",
          "If recommendation.situation is 'has_baseline': design 3-8 small preference bands layered on top of baselinePreset.bands.",
          "Verify the combined curve with get_response_curve before auditioning.",
          "Audition with audition_eq_preset only when the user explicitly asks to hear it; save with save_current_preset only when the user likes it.",
          "For descriptor-to-frequency mapping and band-design heuristics, call get_tuning_guidance.",
        ],
      });
    }
  );

  // record_tuning_feedback — record the user's reaction so taste accumulates over time (write, disk only).
  server.registerTool(
    "record_tuning_feedback",
    {
      title: "Record tuning feedback",
      description:
        "Records the user's reaction to a tuning (liked / disliked / mixed) plus an optional perceived issue, " +
        "goal, their own words, and a snapshot of the auditioned bands. This is the AI's taste-memory: call it " +
        "whenever the user reacts to an audition (positively or negatively) so future tunings converge on what " +
        "they like. Writes one JSON file on disk; does not touch live audio or the preset library.",
      inputSchema: {
        sentiment: z
          .enum(["liked", "disliked", "mixed"])
          .describe("How the user reacted: liked, disliked, or mixed."),
        headphone: z
          .string()
          .optional()
          .describe("Headphone display name or slug this feedback is about. Omit for global taste."),
        presetId: z
          .string()
          .optional()
          .describe("The audition/saved preset id that was reacted to, if known."),
        presetName: z
          .string()
          .optional()
          .describe("The preset name that was reacted to, for readability in the log."),
        perceivedIssue: z
          .enum([...PERCEIVED_ISSUES] as [string, ...string[]])
          .optional()
          .describe(
            "Optional categorized issue: too_bright, too_dark, too_bassy, not_enough_bass, harsh, sibilant, " +
              "muddy, boomy, thin, nasal, boxy, too_much_change, not_enough_change, good_balance, other."
          ),
        goal: z
          .string()
          .optional()
          .describe("What the tuning was attempting, e.g. 'warmer' or 'less sibilance'."),
        feedbackText: z
          .string()
          .optional()
          .describe("The user's own words verbatim, if they said something specific."),
        tags: z
          .array(z.string())
          .default([])
          .describe("Freeform preference markers you infer, e.g. 'less-treble-bite', 'likes-warm-low-mids'."),
        bands: z
          .array(bandSpecSchema)
          .max(20)
          .optional()
          .describe("Optional snapshot of the bands that were auditioned, so the magnitude of the move is learnable."),
      },
      annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: false },
    },
    async ({ sentiment, headphone, presetId, presetName, perceivedIssue, goal, feedbackText, tags, bands }) => {
      const entry: TuningFeedbackEntry = {
        id: `fb_${Date.now().toString(36)}${Math.random().toString(36).slice(2, 6)}`,
        createdAt: new Date().toISOString(),
        sentiment,
        ...(headphone && headphone.trim().length > 0 ? { headphone: headphone.trim() } : {}),
        ...(presetId && presetId.trim().length > 0 ? { presetId: presetId.trim() } : {}),
        ...(presetName && presetName.trim().length > 0 ? { presetName: presetName.trim() } : {}),
        ...(perceivedIssue ? { perceivedIssue: perceivedIssue as PerceivedIssue } : {}),
        ...(goal && goal.trim().length > 0 ? { goal: goal.trim() } : {}),
        ...(feedbackText && feedbackText.trim().length > 0 ? { feedbackText: feedbackText.trim() } : {}),
        ...(tags && tags.length > 0 ? { tags: [...new Set(tags.map((t) => t.trim().toLowerCase()).filter(Boolean))] } : {}),
        ...(bands && bands.length > 0
          ? {
              bands: bands.map((b) => ({
                type: b.type as import("./types.js").BandType,
                frequencyHz: b.frequencyHz,
                gainDb: b.gainDb,
                q: b.q,
              })),
            }
          : {}),
      };

      await appendTuningFeedback(entry);
      const prefs = await loadUserTuningPreferences();
      const summary = summarizeTuningPreferences(prefs.entries, {
        headphoneNeedle: headphone,
        limit: 5,
      });

      return jsonResult({
        recorded: true,
        entry,
        updatedPreferenceSummary: {
          scope: summary.scope,
          headphone: summary.headphone,
          totalEntries: summary.totalEntries,
          sentimentCounts: summary.sentimentCounts,
          topDislikedIssues: summary.topDislikedIssues,
          topLikedIssues: summary.topLikedIssues,
          tagFrequency: summary.tagFrequency,
          derivedNotes: summary.derivedNotes,
        },
        note:
          "Feedback recorded to the AI taste-memory (~/Library/Application Support/Auralink/data/user-tuning-preferences.json). " +
          "It does not change sound. Future get_user_tuning_preferences and get_tuning_brief calls will reflect it.",
      });
    }
  );

  // get_user_tuning_preferences — aggregated taste summary (read, offline).
  server.registerTool(
    "get_user_tuning_preferences",
    {
      title: "Get user tuning preferences",
      description:
        "Returns the aggregated tuning-preference summary derived from recorded feedback: sentiment counts, " +
        "most frequent complaints and likes, directions that landed or missed, freeform preference markers, " +
        "derived notes, and recent entries. Scope to one headphone, or omit for the global taste. Read-only; " +
        "works offline. Use this before designing preference moves so they align with what the user tends to like.",
      inputSchema: {
        headphone: z
          .string()
          .optional()
          .describe("Optional headphone to scope to (fuzzy match). Omit for the global taste."),
        limit: z
          .number()
          .int()
          .min(0)
          .max(50)
          .default(10)
          .describe("How many recent feedback entries to include. Default 10."),
      },
      annotations: { readOnlyHint: true, destructiveHint: false, openWorldHint: false },
    },
    async ({ headphone, limit }) => {
      const prefs = await loadUserTuningPreferences();
      const summary = summarizeTuningPreferences(prefs.entries, {
        headphoneNeedle: headphone,
        limit,
      });

      // Distinct headphones that have feedback, so the AI knows what data exists.
      const seen = new Map<string, number>();
      for (const e of prefs.entries) {
        if (e.headphone) seen.set(e.headphone, (seen.get(e.headphone) ?? 0) + 1);
      }
      const headphonesWithFeedback = [...seen.entries()]
        .map(([name, count]) => ({ name, count }))
        .sort((a, b) => b.count - a.count);

      return jsonResult({
        ...summary,
        globalTotal: prefs.entries.length,
        headphonesWithFeedback,
        usage:
          "Use derivedNotes as the headline taste guidance when designing preference moves. " +
          "recent[] shows concrete past reactions (with auditioned bands) you can pattern-match against.",
      });
    }
  );

  // 2. list_output_devices — devices from the app (read).
  server.registerTool(
    "list_output_devices",
    {
      title: "List output devices",
      description:
        "Lists the audio output devices CoreAudio reports to the running app, including which is the " +
        "virtual capture device and which is the system default. Requires the app to be running.",
      inputSchema: {},
      annotations: { readOnlyHint: true, destructiveHint: false, openWorldHint: true },
    },
    async () => {
      const res = await getDevices();
      if (!res.online) {
        return jsonResult({ online: false, message: res.error, devices: [] });
      }
      return jsonResult({ online: true, devices: res.data ?? [] });
    }
  );

  // 3. list_headphone_profiles — knowledge data (read, offline).
  server.registerTool(
    "list_headphone_profiles",
    {
      title: "List headphone profiles",
      description:
        "Lists the headphone profiles in the user's own collection (id, brand, model, type, signature, " +
        "credibility). Use this to pick the right profile id before tuning. Works offline. Auralink ships " +
        "no headphone database, so an empty list means the user has not added anything yet — call " +
        "get_autoeq_correction to look a model up rather than treating it as an error.",
      inputSchema: {},
      annotations: { readOnlyHint: true, destructiveHint: false, openWorldHint: false },
    },
    async () => {
      const profiles = await loadHeadphoneProfiles();
      const summary = profiles.map((p) => ({
        id: p.id,
        brand: p.brand,
        model: p.model,
        type: p.type,
        signature: p.signature,
        credibility: p.credibility,
        suggestedTargetCurveId: p.suggestedTargetCurveId,
      }));
      return jsonResult({
        count: summary.length,
        collectionDir: collectionDir(),
        profiles: summary,
        ...(summary.length === 0
          ? {
              note:
                "The user's collection has no headphone profiles yet. This is the normal state for a " +
                "fresh install — Auralink ships no headphone database. Ask which model they use, then " +
                "call get_autoeq_correction and register_headphone_baseline.",
            }
          : {}),
      });
    }
  );

  // 4. get_headphone_profile — one profile, fuzzy id (read, offline).
  server.registerTool(
    "get_headphone_profile",
    {
      title: "Get headphone profile",
      description:
        "Returns the full tonal-balance profile for one headphone: signature, correction notes, harsh " +
        "regions, suggested target curve, source and credibility. Look up by exact slug id " +
        "(e.g. 'sennheiser-hd600'). Works offline.",
      inputSchema: {
        id: z
          .string()
          .min(1)
          .describe("Headphone profile slug, e.g. 'sennheiser-hd600'. Use list_headphone_profiles to discover ids."),
      },
      annotations: { readOnlyHint: true, destructiveHint: false, openWorldHint: false },
    },
    async ({ id }) => {
      const profile = await getHeadphoneProfile(id);
      if (!profile) {
        return errorResult(
          `No headphone profile with id '${id}'. Call list_headphone_profiles to see valid ids.`
        );
      }
      return jsonResult(profile);
    }
  );

  // 5. upsert_headphone_profile — add/update user knowledge from links, measurements, or notes.
  server.registerTool(
    "upsert_headphone_profile",
    {
      title: "Add or update headphone profile",
      description:
        "Creates or updates a headphone/earphone profile in the user's own collection. Use this after " +
        "the AI client has read a product page, review, measurement graph, or user notes and extracted a " +
        "tonal signature. This writes one profile file only; it does not create or apply an EQ preset.",
      inputSchema: {
        id: z
          .string()
          .optional()
          .describe("Stable slug. Omit to derive from brand + model, e.g. 'timeear-nh60-nianhua'."),
        brand: z.string().min(1).describe("Brand/manufacturer, e.g. 'TimeEar'."),
        model: z.string().min(1).describe("Clean model name, e.g. 'NH60' or 'HD600'. Put aliases/subtitles in source notes."),
        type: z
          .enum(HEADPHONE_TYPES as [string, ...string[]])
          .default("iem")
          .describe("Form factor: open_back, closed_back, iem, earbud, on_ear, true_wireless."),
        signature: z
          .string()
          .min(1)
          .describe("One-line tonal signature inferred from measurements/reviews/user notes."),
        correctionNotes: z
          .array(z.string().min(1))
          .default([])
          .describe("Actionable tuning notes: what usually needs correction and why."),
        harshRegionsHz: z
          .array(frequencyRangeSchema)
          .default([])
          .describe("Likely harsh/fatiguing frequency windows in Hz, if known."),
        suggestedTargetCurveId: z
          .string()
          .optional()
          .describe("Optional default target curve id, e.g. 'harman-neutral' or 'late-night'."),
        source: z
          .string()
          .min(1)
          .describe("Evidence string: URL(s), measurement source, or 'user notes'. Include caveats."),
        credibility: z
          .enum(["measured", "manufacturer", "community", "estimated"])
          .default("estimated")
          .describe("Trust level. Use measured for graph data; estimated for text-only review inference."),
      },
      annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: true },
    },
    async ({
      id,
      brand,
      model,
      type,
      signature,
      correctionNotes,
      harshRegionsHz,
      suggestedTargetCurveId,
      source,
      credibility,
    }) => {
      const profileId = id && id.trim().length > 0 ? id.trim() : slugify(`${brand}-${model}`);
      if (profileId.length === 0) {
        return errorResult("Could not derive a profile id. Provide a non-empty id, brand, or model.");
      }

      const saved = await saveHeadphoneProfile({
        id: profileId,
        brand,
        model,
        type: type as HeadphoneProfile["type"],
        signature,
        correctionNotes,
        harshRegionsHz,
        suggestedTargetCurveId,
        source,
        credibility: credibility as HeadphoneProfile["credibility"],
      });
      const appSync = await reloadKnowledge();

      return jsonResult({
        saved: true,
        profile: saved,
        appSync: appSync.online
          ? {
              online: true,
              reloaded: appSync.data?.ok === true,
              profileCount: appSync.data?.profileCount,
              message: appSync.data?.message,
            }
          : {
              online: false,
              reloaded: false,
              message:
                "Profile was written to disk. The running app did not refresh because its ControlServer is offline or older than this endpoint.",
              detail: appSync.error,
            },
        note:
          "Headphone profile written to the user knowledge base. For a new model, create a saved Harman baseline preset next.",
      });
    }
  );

  server.registerTool(
    "delete_headphone_profile",
    {
      title: "Delete headphone profile",
      description:
        "Deletes a headphone/earphone profile from the user's collection. Use when the user says a model " +
        "was added by mistake or asks to remove it. The running app is asked to reload knowledge afterward.",
      inputSchema: {
        id: z.string().min(1).describe("Profile id to delete, e.g. 'timeear-nh60'."),
      },
      annotations: {
        readOnlyHint: false,
        destructiveHint: true,
        idempotentHint: true,
        openWorldHint: false,
      },
    },
    async ({ id }) => {
      const deleted = await deleteHeadphoneProfile(id);
      if (!deleted) {
        return jsonResult({
          deleted: false,
          id,
          message: "No visible headphone profile with that id.",
        });
      }
      const appSync = await reloadKnowledge();
      return jsonResult({
        deleted: true,
        profile: deleted,
        appSync: appSync.online
          ? {
              online: true,
              reloaded: appSync.data?.ok === true,
              profileCount: appSync.data?.profileCount,
              message: appSync.data?.message,
            }
          : {
              online: false,
              reloaded: false,
              message:
                "Profile was deleted on disk. The running app did not refresh because its ControlServer is offline.",
              detail: appSync.error,
            },
      });
    }
  );

  // 6. list_presets — the shared preset library (read, offline from disk).
  server.registerTool(
    "list_presets",
    {
      title: "List presets",
      description:
        "Lists every saved EQ preset (newest-updated first): id, name, headphone, goal, createdBy " +
        "(user/ai), version, tags, clipping risk, and whether it is in the user's own collection. " +
        "Reads the working preset directory the app uses plus the collection, so it works whether or " +
        "not the app is running.",
      inputSchema: {
        headphone: z
          .string()
          .optional()
          .describe("Optional case-insensitive filter on the preset's headphone field."),
        createdBy: z
          .enum(["user", "ai"])
          .optional()
          .describe("Optional filter by author."),
        inCollection: z
          .boolean()
          .optional()
          .describe("Optional filter: true for collection presets only, false for working-only ones."),
      },
      annotations: { readOnlyHint: true, destructiveHint: false, openWorldHint: false },
    },
    async ({ headphone, createdBy, inCollection }) => {
      let presets = await loadAllPresets();
      const collectionIds = new Set(await collectionPresetIds());
      if (headphone) {
        const needle = headphone.toLowerCase();
        presets = presets.filter((p) => (p.headphone ?? "").toLowerCase().includes(needle));
      }
      if (createdBy) {
        presets = presets.filter((p) => p.createdBy === createdBy);
      }
      if (inCollection !== undefined) {
        presets = presets.filter((p) => collectionIds.has(p.id) === inCollection);
      }
      const summary = presets.map((p) => ({
        id: p.id,
        name: p.name,
        headphone: p.headphone,
        goal: p.goal,
        createdBy: p.createdBy,
        version: p.version,
        tags: p.tags,
        preampDb: p.preampDb,
        clippingRisk: p.safety.clippingRisk,
        updatedAt: p.updatedAt,
        inCollection: collectionIds.has(p.id),
      }));
      return jsonResult({
        count: summary.length,
        collectionDir: collectionDir(),
        presets: summary,
      });
    }
  );

  // add_preset_to_collection / remove_preset_from_collection — the only way a
  // preset enters or leaves the user's own (often git-tracked) collection. There is
  // deliberately no heuristic that promotes presets automatically.
  server.registerTool(
    "add_preset_to_collection",
    {
      title: "Add preset to your collection",
      description:
        "Copies a saved preset into the user's own collection directory so it is kept and shared " +
        "(typically a git checkout). Ask before doing this: everything else stays machine-local. " +
        "Does not change sound.",
      inputSchema: {
        id: z.string().min(1).describe("Preset id to add. Use list_presets to discover ids."),
      },
      annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: true },
    },
    async ({ id }) => {
      const preset = await addPresetToCollection(id);
      if (!preset) {
        return errorResult(`No preset with id '${id}'. Call list_presets to see valid ids.`);
      }
      return jsonResult({
        added: true,
        id: preset.id,
        name: preset.name,
        collectionDir: collectionDir(),
        note: "Commit your collection when you want this in git.",
      });
    }
  );

  server.registerTool(
    "remove_preset_from_collection",
    {
      title: "Remove preset from your collection",
      description:
        "Removes a preset from the user's collection directory, leaving the working copy the app " +
        "loads untouched. Does not change sound.",
      inputSchema: {
        id: z.string().min(1).describe("Preset id to remove from the collection."),
      },
      annotations: { readOnlyHint: false, destructiveHint: true, idempotentHint: true },
    },
    async ({ id }) => {
      const removed = await removePresetFromCollection(id);
      return jsonResult({
        removed,
        id,
        collectionDir: collectionDir(),
        note: removed
          ? "Working copy kept; only the collection entry was removed."
          : "That id was not in the collection.",
      });
    }
  );

  // 6. get_preset — full preset by id (read, offline from disk).
  server.registerTool(
    "get_preset",
    {
      title: "Get preset",
      description:
        "Returns one complete EQ preset by id — all 20 bands, preamp, safety metadata, version and " +
        "timestamps. Reads from disk; works offline.",
      inputSchema: {
        id: z.string().min(1).describe("Preset id. Use list_presets to discover ids."),
      },
      annotations: { readOnlyHint: true, destructiveHint: false, openWorldHint: false },
    },
    async ({ id }) => {
      const preset = await getPreset(id);
      if (!preset) {
        return errorResult(`No preset with id '${id}'. Call list_presets to see valid ids.`);
      }
      return jsonResult(preset);
    }
  );

  server.registerTool(
    "delete_preset",
    {
      title: "Delete preset",
      description:
        "Deletes a saved preset from the shared library. Use only when the user asks to remove a mistaken or unwanted preset. " +
        "If the deleted preset is currently loaded, the app is moved back to Flat when reachable.",
      inputSchema: {
        id: z.string().min(1).describe("Preset id to delete."),
      },
      annotations: {
        readOnlyHint: false,
        destructiveHint: true,
        idempotentHint: true,
        openWorldHint: false,
      },
    },
    async ({ id }) => {
      const stateBefore = await getState();
      const deleted = await deletePreset(id);
      if (!deleted) {
        return jsonResult({
          deleted: false,
          id,
          message: "No saved preset with that id.",
        });
      }

      const appPresetSync = await reloadPresets();
      let fallbackApply: unknown = { applied: false, skipped: true };
      if (stateBefore.online && stateBefore.data?.currentPresetId === id) {
        // Fall back to any bypass-shaped preset: `preset_flat` is seeded by the app
        // but a user with their own collection may have renamed or removed it.
        const flat =
          (await getPreset("preset_flat")) ??
          (await loadAllPresets()).find((p) => p.bands.every((b) => !b.enabled)) ??
          null;
        if (flat) {
          // Deleting a preset is not live-audio confirmation. Ask the app's
          // permission mode whether Flat may be applied, then verify audible.
          const res = await applyPreset(flat.id, false);
          if (!res.online) {
            fallbackApply = {
              online: false,
              applied: false,
              message: res.error,
            };
          } else if (res.data?.needsConfirm === true) {
            fallbackApply = {
              online: true,
              applied: false,
              needsConfirm: true,
              message:
                `Deleted preset was current. Pass apply_eq_preset('${flat.id}', confirmed:true) to load ${flat.name}.`,
            };
          } else {
            const requestAccepted = res.data?.ok === true;
            const verification = await verifyAuralinkLiveRequest(
              requestAccepted,
              flat.id,
              res.data?.requestedRenderGeneration
            );
            fallbackApply = {
              online: true,
              applied: verification.audible,
              requestAccepted,
              audible: verification.audible,
              needsConfirm: false,
              verification,
              message: verification.audible
                ? `Deleted preset was current, so Auralink loaded ${flat.name}.`
                : `Deleted preset was current, but live audio did not switch to ${flat.name}.`,
            };
          }
        } else {
          fallbackApply = {
            applied: false,
            skipped: true,
            message:
              "Deleted preset was current and no bypass preset exists to fall back to. Disable EQ or load another preset.",
          };
        }
      }

      return jsonResult({
        deleted: true,
        preset: deleted,
        appPresetSync: appPresetSync.online
          ? {
              online: true,
              reloaded: appPresetSync.data?.ok === true,
              presetCount: appPresetSync.data?.presetCount,
              message: appPresetSync.data?.message,
            }
          : {
              online: false,
              reloaded: false,
              message:
                "Preset was deleted on disk. The running app did not refresh because its ControlServer is offline.",
              detail: appPresetSync.error,
            },
        fallbackApply,
      });
    }
  );

  // 7. create_eq_preset — synthesize + VALIDATE before writing, optionally audition live.
  server.registerTool(
    "create_eq_preset",
    {
      title: "Create EQ preset",
      description:
        "Creates (or updates, if 'id' matches an existing preset) an EQ preset from a list of band " +
        "specs and saves it to the shared library. The preset is ALWAYS validated against the safety " +
        "rules first; if validation finds an error it is NOT written and the issues are returned. " +
        "Use this for saved baselines or user-approved presets, not every audition. Auto-preamp is applied only when autoGain is on. By default this only writes a preset file. " +
        "Set applyNow:true with confirmed:true only when the user explicitly asked to hear it now.",
      inputSchema: {
        name: z.string().min(1).describe("Human-readable preset name, e.g. 'HD600 – Warm Rock'."),
        id: z
          .string()
          .optional()
          .describe("Optional explicit id. Omit for a fresh auto-generated id. If it matches an existing preset, that preset is updated (version bumps)."),
        headphone: z
          .string()
          .optional()
          .describe("Target headphone display name or slug, e.g. 'Sennheiser HD600'."),
        goal: z
          .string()
          .optional()
          .describe("Free-text tuning intent, e.g. 'Rock: punchy kick, clear guitars, preserved vocals'."),
        preampDb: z
          .number()
          .min(PREAMP_MIN)
          .max(PREAMP_MAX)
          .optional()
          .describe("Manual preamp in dB (-24…0). Default 0 to preserve level unless autoGain is enabled."),
        autoGain: z
          .boolean()
          .default(false)
          .describe("When true, the validator's suggested preamp is applied to keep headroom. Default false preserves audition level/dynamics."),
        bands: z
          .array(bandSpecSchema)
          .min(1)
          .max(20)
          .describe("Band moves. Each is a parametric EQ band; up to 20."),
        tags: z.array(z.string()).default([]).describe("Optional tags for the library."),
        target: targetSchema,
        ...correctionInputSchema,
        applyNow: z
          .boolean()
          .default(false)
          .describe("When true, apply the saved preset to live audio after writing. Requires confirmed:true."),
        confirmed: z
          .boolean()
          .default(false)
          .describe("Set true only when the user explicitly asked for this live-audio change."),
      },
      annotations: { readOnlyHint: false, destructiveHint: true, idempotentHint: false },
    },
    async ({
      name,
      id,
      headphone,
      goal,
      preampDb,
      autoGain,
      bands,
      tags,
      target,
      correctionRole,
      baselinePresetId,
      correctionSource,
      sourceConfidence,
      correctionStrength,
      targetCurveId,
      targetBlend,
      preferenceBandIndexes,
      measuredCorrection,
      applyNow,
      confirmed,
    }) => {
      const rules = await loadSafetyRules();

      // Materialize a normalized 20-band preset from the sparse specs.
      const builtBands = bandsFromSpecs(
        bands.map((b) => ({
          index: b.index,
          type: b.type as EQPreset["bands"][number]["type"],
          frequencyHz: b.frequencyHz,
          gainDb: b.gainDb,
          q: b.q,
          channel: b.channel as EQPreset["bands"][number]["channel"],
          enabled: b.enabled,
        }))
      );

      const presetId =
        id && id.trim().length > 0
          ? id.trim()
          : `preset_ai_${Date.now().toString(36)}`;

      const draft: EQPreset = normalizePreset({
        id: presetId,
        name,
        headphone,
        goal,
        preampDb: preampDb ?? 0,
        bands: builtBands,
        safety: { autoGainEnabled: autoGain, clippingRisk: "low" },
        createdBy: "ai",
        version: 1,
        tags,
        createdAt: "",
        updatedAt: "",
        correction: correctionMetadataFromInput({
          correctionRole,
          baselinePresetId,
          correctionSource,
          sourceConfidence,
          correctionStrength,
          targetCurveId,
          targetBlend,
          preferenceBandIndexes,
          measuredCorrection,
          tags,
        }),
      });

      // VALIDATE before writing. Luxsin is PEQ-only, so its headroom must not
      // be changed by an Auralink-only measured FIR renderer.
      const validation = validatePreset(
        draft,
        rules,
        48_000,
        target === "luxsin-x8" ? "standard_iir" : "all"
      );
      if (!validation.ok) {
        return jsonResult({
          saved: false,
          reason: "Validation failed; preset was not written.",
          validation,
        });
      }

      // Apply auto-preamp and the validator's clipping verdict, then persist.
      const finalPreset: EQPreset = {
        ...draft,
        preampDb: autoGain ? validation.suggestedPreampDb : draft.preampDb,
        safety: { autoGainEnabled: autoGain, clippingRisk: validation.clippingRisk },
      };
      const saved = await savePreset(finalPreset);
      const appPresetSync = await reloadPresets();
      let liveApply: unknown = { applied: false, skipped: true };

      if (applyNow) {
        if (!confirmed) {
          liveApply = {
            applied: false,
            needsConfirm: true,
            message:
              "Preset was saved but not applied. Pass confirmed:true only when the user explicitly asked to hear it now.",
          };
        } else if (target === "luxsin-x8") {
          liveApply = await applyPresetToX8(saved, true);
        } else {
          const res = await applyPreset(saved.id, true);
          if (res.online) {
            const requestAccepted = res.data?.ok === true;
            const httpError = res.data === undefined ? res.error : undefined;
            const verification = await verifyAuralinkLiveRequest(
              requestAccepted,
              saved.id,
              res.data?.requestedRenderGeneration
            );
            liveApply = {
              target: "auralink",
              applied: verification.audible,
              requestAccepted,
              audible: verification.audible,
              needsConfirm: Boolean(res.data?.needsConfirm),
              appMessage: res.data?.message,
              appError: httpError,
              verification,
              message: httpError
                ? `${verification.message} ${httpError}`
                : verification.message,
            };
          } else {
            liveApply = {
              target: "auralink",
              applied: false,
              requestAccepted: false,
              audible: false,
              offline: true,
              message: res.error,
            };
          }
        }
      }

      return jsonResult({
        saved: true,
        preset: saved,
        validation,
        appPresetSync: appPresetSync.online
          ? {
              online: true,
              reloaded: appPresetSync.data?.ok === true,
              presetCount: appPresetSync.data?.presetCount,
              message: appPresetSync.data?.message,
            }
          : {
              online: false,
              reloaded: false,
              message:
                "Preset was written to disk. The running app did not refresh its library because its ControlServer is offline or older than this endpoint.",
              detail: appPresetSync.error,
            },
        liveApply,
        note: applyNow
          ? "Preset written to the shared library and live audition was requested."
          : "Preset written to the shared library. Call apply_eq_preset or use applyNow:true to put it on live audio.",
      });
    }
  );

  server.registerTool(
    "audition_eq_preset",
    {
      title: "Audition EQ preset without saving",
      description:
        "Applies an unsaved EQ preset to the running Auralink app for live listening. Use this for preference experiments. " +
        "It validates before auditioning, does NOT write to the preset library, and requires confirmed:true for live audio changes.",
      inputSchema: {
        name: z.string().min(1).describe("Human-readable audition name, e.g. 'HD600 - Warmer Audition'."),
        id: z
          .string()
          .optional()
          .describe("Optional transient id. Omit for a fresh auto-generated audition id."),
        headphone: z
          .string()
          .optional()
          .describe("Target headphone display name or slug, e.g. 'Sennheiser HD600'."),
        goal: z
          .string()
          .optional()
          .describe("Free-text tuning intent, e.g. 'warmer and more fun without saving yet'."),
        preampDb: z
          .number()
          .min(PREAMP_MIN)
          .max(PREAMP_MAX)
          .default(0)
          .describe("Manual preamp in dB (-24…0). Default 0 preserves perceived dynamics during audition."),
        autoGain: z
          .boolean()
          .default(false)
          .describe("When true, apply validator-suggested preamp. Default false keeps audition level unchanged."),
        bands: z
          .array(bandSpecSchema)
          .min(1)
          .max(20)
          .describe("Band moves. Prefer 3-8 meaningful bands."),
        tags: z.array(z.string()).default([]).describe("Optional tags for the transient preset."),
        target: targetSchema,
        ...correctionInputSchema,
        confirmed: z
          .boolean()
          .default(false)
          .describe("Set true only when the user explicitly asked to hear this live-audio change."),
      },
      annotations: {
        readOnlyHint: false,
        destructiveHint: true,
        idempotentHint: false,
        openWorldHint: true,
      },
    },
    async ({
      name,
      id,
      headphone,
      goal,
      preampDb,
      autoGain,
      bands,
      tags,
      target,
      correctionRole,
      baselinePresetId,
      correctionSource,
      sourceConfidence,
      correctionStrength,
      targetCurveId,
      targetBlend,
      preferenceBandIndexes,
      measuredCorrection,
      confirmed,
    }) => {
      if (!confirmed) {
        return jsonResult({
          auditioned: false,
          needsConfirm: true,
          message:
            "Live audition was not started. Pass confirmed:true only when the user explicitly asked to hear this change.",
        });
      }

      const rules = await loadSafetyRules();
      const builtBands = bandsFromSpecs(
        bands.map((b) => ({
          index: b.index,
          type: b.type as EQPreset["bands"][number]["type"],
          frequencyHz: b.frequencyHz,
          gainDb: b.gainDb,
          q: b.q,
          channel: b.channel as EQPreset["bands"][number]["channel"],
          enabled: b.enabled,
        }))
      );

      const presetId =
        id && id.trim().length > 0
          ? id.trim()
          : `audition_ai_${Date.now().toString(36)}`;

      const draft: EQPreset = normalizePreset({
        id: presetId,
        name,
        headphone,
        goal,
        preampDb,
        bands: builtBands,
        safety: { autoGainEnabled: autoGain, clippingRisk: "low" },
        createdBy: "ai",
        version: 1,
        tags: ["audition", ...tags],
        createdAt: "",
        updatedAt: "",
        correction: correctionMetadataFromInput({
          correctionRole,
          baselinePresetId,
          correctionSource,
          sourceConfidence,
          correctionStrength,
          targetCurveId,
          targetBlend,
          preferenceBandIndexes,
          measuredCorrection,
          tags: ["audition", ...tags],
        }),
      });

      const validation = validatePreset(
        draft,
        rules,
        48_000,
        target === "luxsin-x8" ? "standard_iir" : "all"
      );
      if (!validation.ok) {
        return jsonResult({
          auditioned: false,
          reason: "Validation failed; preset was not auditioned.",
          validation,
        });
      }

      const finalPreset: EQPreset = {
        ...draft,
        preampDb: autoGain ? validation.suggestedPreampDb : draft.preampDb,
        safety: { autoGainEnabled: autoGain, clippingRisk: validation.clippingRisk },
      };

      if (target === "luxsin-x8") {
        const x8 = await applyPresetToX8(finalPreset, true);
        return jsonResult({
          auditioned: x8.applied === true,
          online: x8.online !== false,
          target,
          saved: false,
          preset: finalPreset,
          validation,
          x8,
          nextStep:
            "If the user likes this sound, keep the X8 entry. If not, delete or replace that X8 entry before further listening.",
        });
      }

      const res = await auditionPreset(finalPreset, true);
      if (!res.online) {
        return jsonResult({
          auditioned: false,
          online: false,
          preset: finalPreset,
          validation,
          message: res.error,
          hint: "Open or rebuild the Auralink app, then retry audition_eq_preset.",
        });
      }

      const requestAccepted = res.data?.ok === true;
      const verification = await verifyAuralinkLiveRequest(
        requestAccepted,
        finalPreset.id,
        res.data?.requestedRenderGeneration
      );
      return jsonResult({
        auditioned: verification.audible,
        requestAccepted,
        audible: verification.audible,
        online: true,
        target: "auralink",
        saved: false,
        preset: finalPreset,
        validation,
        app: res.data,
        verification,
        message: verification.message,
        nextStep: verification.audible
          ? "If the user likes this sound, call save_current_preset with a descriptive name. Otherwise revise and audition another transient preset."
          : "Do not ask for a sound judgment yet: the request was not verified as audible. Resolve routing/EQ/renderer state first.",
      });
    }
  );

  // get_autoeq_correction — measured parametric correction from AutoEq (read).

  // register_headphone_baseline — profile + baseline preset into the user's collection.
  server.registerTool(
    "register_headphone_baseline",
    {
      title: "Register headphone baseline into your collection",
      description:
        "One-shot Auralink registration: upsert a headphone profile and save its baseline preset into " +
        "the user's own collection, plus the working preset library the running app loads. AutoEq lookup " +
        "when bands are omitted; pass bands + type when AutoEq has no hit (squig.link, Super* Review, " +
        "IEF 2025, …). Does not commit and does not write Luxsin X8. Do not create scripts/ for this. " +
        "X8 is a separate hardware target via apply_eq_preset/create_eq_preset.",
      inputSchema: {
        headphone: z
          .string()
          .min(1)
          .describe("Model to register, e.g. 'Austrian Audio Hi-X60' or 'HD600'."),
        brand: z.string().optional().describe("Optional brand override when AutoEq name is ambiguous."),
        model: z.string().optional().describe("Optional model override."),
        type: z
          .enum(HEADPHONE_TYPES as [string, ...string[]])
          .optional()
          .describe("Form factor override. Inferred from AutoEq path/source when omitted."),
        source: z
          .string()
          .optional()
          .describe("Preferred AutoEq measurement source, e.g. 'oratory1990' or 'crinacle'."),
        provenance: z
          .string()
          .optional()
          .describe("Profile source string for explicit (non-AutoEq) bands, e.g. a squig.link URL."),
        credibility: z
          .enum(CREDIBILITIES as [string, ...string[]])
          .optional()
          .describe("Trust level for explicit bands. Default estimated. AutoEq path is always measured."),
        targetCurveId: z
          .string()
          .default("harman-neutral")
          .describe("Target curve id stored on the profile/preset. Default harman-neutral."),
        bands: z
          .array(bandSpecSchema)
          .optional()
          .describe("Explicit baseline PEQ bands. When provided, AutoEq is skipped. Requires type."),
        preferenceBands: z
          .array(bandSpecSchema)
          .default([])
          .describe("Optional subjective bands layered after the baseline bands (e.g. sub-bass shelf)."),
        preferenceLabel: z
          .string()
          .optional()
          .describe("Short label for preference layer, e.g. 'Sub-Bass+'. Used in preset name."),
        preampDb: z
          .number()
          .min(PREAMP_MIN)
          .max(PREAMP_MAX)
          .optional()
          .describe("Override preamp. AutoEq path uses AutoEq preamp; explicit path derives from max boost if omitted."),
        signature: z.string().optional().describe("Optional one-line tonal signature override."),
        correctionNotes: z.array(z.string()).optional().describe("Optional correction notes override/extension."),
        harshRegionsHz: z.array(frequencyRangeSchema).optional(),
        refreshAutoEq: z.boolean().default(false).describe("Force re-download of AutoEq correction."),
      },
      annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: false },
    },
    async (args) => {
      try {
        const result = await registerHeadphoneBaseline({
          headphone: args.headphone,
          brand: args.brand,
          model: args.model,
          type: args.type as HeadphoneProfile["type"] | undefined,
          source: args.source,
          provenance: args.provenance,
          credibility: args.credibility as HeadphoneProfile["credibility"] | undefined,
          targetCurveId: args.targetCurveId,
          bands: args.bands as RegisterHeadphoneBaselineInput["bands"],
          preferenceBands: args.preferenceBands as RegisterHeadphoneBaselineInput["preferenceBands"],
          preferenceLabel: args.preferenceLabel,
          preampDb: args.preampDb,
          signature: args.signature,
          correctionNotes: args.correctionNotes,
          harshRegionsHz: args.harshRegionsHz,
          refreshAutoEq: args.refreshAutoEq,
        });
        return jsonResult(result);
      } catch (err) {
        return errorResult(
          `register_headphone_baseline failed: ${err instanceof Error ? err.message : String(err)}`
        );
      }
    }
  );

  server.registerTool(
    "get_autoeq_correction",
    {
      title: "Get AutoEq measured correction",
      description:
        "Looks a headphone/IEM up in the AutoEq project's published results (oratory1990, crinacle, " +
        "Rtings, …) and returns its MEASURED parametric correction toward the Harman target: preamp + " +
        "bands in Auralink's vocabulary, with source/rig provenance. Use this BEFORE designing bands " +
        "from prose — measured data beats inference. Results are cached on disk, so repeat lookups " +
        "work offline; pass refresh:true to force a re-download.",
      inputSchema: {
        headphone: z
          .string()
          .min(1)
          .describe("Model to look up, e.g. 'HD600', 'Sennheiser HD 650', 'Moondrop Aria'. Brand optional — fuzzy matched."),
        source: z
          .string()
          .optional()
          .describe("Preferred measurement source, e.g. 'oratory1990' or 'crinacle'. Default: most credible available."),
        refresh: z
          .boolean()
          .default(false)
          .describe("Force re-download of the AutoEq index/correction instead of using the local cache."),
      },
      annotations: { readOnlyHint: true, destructiveHint: false, openWorldHint: true },
    },
    async ({ headphone, source, refresh }) => {
      try {
        const lookup = await getAutoEqCorrection({ headphone, source, refresh });
        if (!lookup.found || !lookup.correction) {
          return jsonResult({
            found: false,
            headphone,
            suggestions: lookup.suggestions,
            hint:
              lookup.suggestions.length > 0
                ? "No exact match. The suggestions are index names that share a token with the query — retry with one of them."
                : "Nothing in the AutoEq index matches. Fall back to the headphone profile's correction notes and target curves.",
          });
        }
        const c = lookup.correction;
        return jsonResult({
          found: true,
          correction: {
            name: c.name,
            source: c.source,
            rig: c.rig ?? null,
            preampDb: c.preampDb,
            bandCount: c.bands.length,
            bands: c.bands,
            provenance: c.url,
            measuredCorrection: c.measuredCorrection ?? null,
            measuredFIRAvailable: c.measuredCorrection !== undefined,
            conversionNotes: c.conversionNotes,
          },
          alternates: lookup.alternates,
          usage:
            "These bands are a measured correction toward the Harman target. Use them as the baseline for " +
            "create_eq_preset (keep preampDb as given, autoGain:false — AutoEq already computed the headroom). " +
            "For Auralink software EQ, copy measuredCorrection exactly so Measured FIR can reproduce the dense curve. " +
            "Keep the parametric bands as the IIR/Luxsin fallback, tag the source (e.g. 'autoeq', '" +
            c.source +
            "'), and list only added subjective bands in preferenceBandIndexes.",
        });
      } catch (err) {
        return errorResult(
          `AutoEq lookup failed: ${err instanceof Error ? err.message : String(err)}. ` +
            "If the network is down, only previously cached models are available."
        );
      }
    }
  );

  // get_response_curve — computed magnitude response for verification (read).
  server.registerTool(
    "get_response_curve",
    {
      title: "Get response curve",
      description:
        "Computes the combined magnitude response (dB vs Hz, 20 Hz–20 kHz log grid) of a preset — by id " +
        "or from inline bands — including preamp. Use this AFTER designing bands to verify the curve does " +
        "what the user asked before auditioning, and to explain the tuning. Optionally diffs against a " +
        "second preset. Works fully offline.",
      inputSchema: {
        id: z.string().optional().describe("Existing preset id to evaluate (loaded from disk)."),
        bands: z
          .array(bandSpecSchema)
          .max(20)
          .optional()
          .describe("Inline bands to evaluate (alternative to 'id')."),
        preampDb: z
          .number()
          .min(PREAMP_MIN)
          .max(PREAMP_MAX)
          .optional()
          .describe("Preamp to assume for inline bands. Default 0."),
        points: z
          .number()
          .int()
          .min(16)
          .max(256)
          .default(61)
          .describe("Number of log-spaced sample points."),
        renderMode: z
          .enum(["standard_iir", "hq_fir"])
          .default("standard_iir")
          .describe("Response renderer: standard_iir or measured hq_fir when the preset carries eligible measured data."),
        compareToId: z
          .string()
          .optional()
          .describe("Optional second preset id; the response also includes (this − other) per point."),
      },
      annotations: { readOnlyHint: true, destructiveHint: false, openWorldHint: false },
    },
    async ({ id, bands, preampDb, points, renderMode, compareToId }) => {
      let preset: EQPreset | null = null;
      if (id && id.trim().length > 0) {
        preset = await getPreset(id.trim());
        if (!preset) return errorResult(`No preset with id '${id}'.`);
      } else if (bands && bands.length > 0) {
        preset = normalizePreset({
          id: "preset_curve_tmp",
          name: "Curve",
          preampDb: preampDb ?? 0,
          bands: bandsFromSpecs(
            bands.map((b) => ({
              index: b.index,
              type: b.type as EQPreset["bands"][number]["type"],
              frequencyHz: b.frequencyHz,
              gainDb: b.gainDb,
              q: b.q,
              channel: b.channel as EQPreset["bands"][number]["channel"],
              enabled: b.enabled,
            }))
          ),
          safety: { autoGainEnabled: false, clippingRisk: "low" },
          createdBy: "ai",
          version: 1,
          tags: [],
          createdAt: "",
          updatedAt: "",
        });
      } else {
        return errorResult("Provide either a preset 'id' or an inline 'bands' array.");
      }

      const firEligibility = measuredFIREligibility(preset);
      const resolvedRenderMode = renderMode === "hq_fir" && firEligibility.eligible
        ? "hq_fir"
        : "standard_iir";
      const freqs = logFrequencies(points);
      const curve = responseCurve(preset, freqs, 48_000, resolvedRenderMode);
      const round = (x: number, p: number) => Math.round(x * p) / p;
      const pointsOut = curve.map((pt) => ({
        hz: round(pt.frequencyHz, 10),
        db: round(pt.magnitudeDb, 100),
      }));

      // Summary the AI can sanity-check at a glance.
      let peak = pointsOut[0];
      let dip = pointsOut[0];
      for (const pt of pointsOut) {
        if (pt.db > peak.db) peak = pt;
        if (pt.db < dip.db) dip = pt;
      }
      const avgIn = (lo: number, hi: number) => {
        const inBand = pointsOut.filter((pt) => pt.hz >= lo && pt.hz <= hi);
        if (inBand.length === 0) return 0;
        return round(inBand.reduce((sum, pt) => sum + pt.db, 0) / inBand.length, 100);
      };

      let comparison: unknown;
      if (compareToId && compareToId.trim().length > 0) {
        const other = await getPreset(compareToId.trim());
        if (!other) return errorResult(`No preset with id '${compareToId}' to compare against.`);
        const otherResolvedMode = renderMode === "hq_fir" && measuredFIREligibility(other).eligible
          ? "hq_fir"
          : "standard_iir";
        const otherCurve = responseCurve(other, freqs, 48_000, otherResolvedMode);
        comparison = {
          otherPresetId: other.id,
          otherPresetName: other.name,
          otherResolvedRenderMode: otherResolvedMode,
          deltaDb: curve.map((pt, i) => ({
            hz: round(pt.frequencyHz, 10),
            db: round(pt.magnitudeDb - otherCurve[i].magnitudeDb, 100),
          })),
        };
      }

      return jsonResult({
        presetId: preset.id,
        presetName: preset.name,
        preampDb: preset.preampDb,
        activeBands: preset.bands.filter((b) => b.enabled).length,
        requestedRenderMode: renderMode,
        resolvedRenderMode,
        renderMode: resolvedRenderMode,
        measuredFIRAvailable: firEligibility.eligible,
        measuredFIRRejectionReason: firEligibility.reason ?? null,
        rendererQualityValidated: resolvedRenderMode === "standard_iir",
        responseKind: resolvedRenderMode === "hq_fir"
          ? "measured_target_preview_not_realized_kernel"
          : "renderer_response",
        responseNote: resolvedRenderMode === "hq_fir"
          ? "This offline curve previews the eligible measured target. The running app independently synthesizes and quality-gates the sample-rate-specific FIR before activation."
          : null,
        summary: {
          peak,
          dip,
          averages: {
            subBass20to60: avgIn(20, 60),
            bass60to250: avgIn(60, 250),
            mids250to2k: avgIn(250, 2_000),
            presence2kTo6k: avgIn(2_000, 6_000),
            treble6kTo20k: avgIn(6_000, 20_000),
          },
        },
        curve: pointsOut,
        comparison,
      });
    }
  );

  // 8. validate_eq_preset — offline safety + clipping check (read, no write).
  server.registerTool(
    "validate_eq_preset",
    {
      title: "Validate EQ preset",
      description:
        "Validates an EQ preset against the safety rules and estimates clipping risk WITHOUT touching " +
        "the library or live audio. Works fully offline (the DSP magnitude + safety math is ported from " +
        "the app). Provide either an existing preset 'id' or an inline list of 'bands'.",
      inputSchema: {
        id: z
          .string()
          .optional()
          .describe("Validate an existing preset by id (loaded from disk)."),
        preampDb: z
          .number()
          .min(PREAMP_MIN)
          .max(PREAMP_MAX)
          .optional()
          .describe("Preamp to assume when validating inline bands (-24…0). Default 0."),
        autoGain: z
          .boolean()
          .default(false)
          .describe("Whether auto-preamp is assumed on for the clipping estimate. Default false preserves level/dynamics."),
        bands: z
          .array(bandSpecSchema)
          .max(20)
          .optional()
          .describe("Inline bands to validate (alternative to 'id')."),
        target: targetSchema.describe("Validation backend. Luxsin X8 validates PEQ only."),
      },
      annotations: { readOnlyHint: true, destructiveHint: false, openWorldHint: false },
    },
    async ({ id, preampDb, autoGain, bands, target }) => {
      const rules = await loadSafetyRules();
      let preset: EQPreset | null = null;

      if (id && id.trim().length > 0) {
        preset = await getPreset(id.trim());
        if (!preset) {
          return errorResult(`No preset with id '${id}' to validate.`);
        }
      } else if (bands && bands.length > 0) {
        const builtBands = bandsFromSpecs(
          bands.map((b) => ({
            index: b.index,
            type: b.type as EQPreset["bands"][number]["type"],
            frequencyHz: b.frequencyHz,
            gainDb: b.gainDb,
            q: b.q,
            channel: b.channel as EQPreset["bands"][number]["channel"],
            enabled: b.enabled,
          }))
        );
        preset = normalizePreset({
          id: "preset_validate_tmp",
          name: "Validation",
          preampDb: preampDb ?? 0,
          bands: builtBands,
          safety: { autoGainEnabled: autoGain, clippingRisk: "low" },
          createdBy: "ai",
          version: 1,
          tags: [],
          createdAt: "",
          updatedAt: "",
        });
      } else {
        return errorResult("Provide either a preset 'id' or an inline 'bands' array to validate.");
      }

      const validation = validatePreset(
        preset,
        rules,
        48_000,
        target === "luxsin-x8" ? "standard_iir" : "all"
      );
      return jsonResult({ validation, evaluatedOffline: true, target });
    }
  );

  server.registerTool(
    "route_system_audio",
    {
      title: "Route system audio",
      description:
        "Sets macOS system output to the virtual capture device so Mac sound actually passes through Auralink EQ.",
      inputSchema: {
        confirmed: z
          .boolean()
          .default(false)
          .describe("Set true only when the user explicitly asked for this live-audio change."),
      },
      annotations: {
        readOnlyHint: false,
        destructiveHint: true,
        idempotentHint: true,
        openWorldHint: true,
      },
    },
    async ({ confirmed }) => {
      if (!confirmed) {
        return jsonResult({
          online: true,
          routed: false,
          needsConfirm: true,
          message:
            "System audio was not routed. Pass confirmed:true only when the user explicitly asked to hear through Auralink.",
        });
      }
      const res = await routeSystemAudio(true);
      return jsonResult({
        online: res.online,
        routed: res.data?.ok === true,
        needsConfirm: res.data?.needsConfirm === true,
        message: res.online
          ? res.data?.message ??
            (res.data?.ok === true
            ? "Mac system audio is routed through Auralink."
            : "The app responded, but system audio was not routed.")
          : res.error,
      });
    }
  );

  server.registerTool(
    "restore_system_audio",
    {
      title: "Restore system audio",
      description:
        "Restores macOS system output from the virtual capture device back to a real output device.",
      inputSchema: {
        confirmed: z
          .boolean()
          .default(false)
          .describe("Set true only when the user explicitly asked for this live-audio change."),
      },
      annotations: {
        readOnlyHint: false,
        destructiveHint: true,
        idempotentHint: true,
        openWorldHint: true,
      },
    },
    async ({ confirmed }) => {
      if (!confirmed) {
        return jsonResult({
          online: true,
          restored: false,
          needsConfirm: true,
          message:
            "System audio was not restored. Pass confirmed:true only when the user explicitly asked to leave Auralink.",
        });
      }
      const res = await restoreSystemAudio(true);
      return jsonResult({
        online: res.online,
        restored: res.data?.ok === true,
        needsConfirm: res.data?.needsConfirm === true,
        message: res.online
          ? res.data?.message ??
            (res.data?.ok === true
            ? "Mac system audio output was restored."
            : "The app responded, but system audio was not restored.")
          : res.error,
      });
    }
  );

  server.registerTool(
    "stop_audio_routing",
    {
      title: "Stop audio routing",
      description:
        "Stops Auralink's live capture/render routing engine. Use when the user wants to stop processing or remove the macOS microphone/capture indicator.",
      inputSchema: {
        confirmed: z
          .boolean()
          .default(false)
          .describe("Set true only when the user explicitly asked for this live-audio change."),
      },
      annotations: {
        readOnlyHint: false,
        destructiveHint: true,
        idempotentHint: true,
        openWorldHint: true,
      },
    },
    async ({ confirmed }) => {
      if (!confirmed) {
        return jsonResult({
          online: true,
          stopped: false,
          needsConfirm: true,
          message:
            "Audio routing was not stopped. Pass confirmed:true only when the user explicitly asked to stop processing.",
        });
      }
      const res = await stopRouting(true);
      return jsonResult({
        online: res.online,
        stopped: res.data?.ok === true,
        needsConfirm: res.data?.needsConfirm === true,
        message: res.online
          ? res.data?.message ??
            (res.data?.ok === true
              ? "Auralink audio routing stopped."
              : "The app responded, but audio routing is still active.")
          : res.error,
      });
    }
  );

  server.registerTool(
    "save_current_preset",
    {
      title: "Save current preset",
      description:
        "Saves the currently loaded/auditioned preset in the running Auralink app. Use this when the user says " +
        "they like the audition or asks to save/keep it. This writes to the preset library but does not change sound.",
      inputSchema: {
        name: z
          .string()
          .optional()
          .describe("Optional final preset name. Use a descriptive model + goal name."),
        id: z
          .string()
          .optional()
          .describe("Optional final id. Usually omit so the current audition id is kept."),
        tags: z.array(z.string()).default([]).describe("Optional tags to add, e.g. liked, user-approved."),
        confirmed: z
          .boolean()
          .default(false)
          .describe("Set true when the user explicitly asked to save this preset."),
      },
      annotations: {
        readOnlyHint: false,
        destructiveHint: false,
        idempotentHint: false,
        openWorldHint: true,
      },
    },
    async ({ name, id, tags, confirmed }) => {
      if (!confirmed) {
        return jsonResult({
          saved: false,
          needsConfirm: true,
          message:
            "Preset was not saved. Pass confirmed:true only when the user asked to keep this audition.",
        });
      }
      const res = await saveCurrentPreset({ name, id, tags, confirmed: true });
      if (!res.online) {
        return jsonResult({
          saved: false,
          online: false,
          message: res.error,
          hint: "Open or rebuild the Auralink app, then retry save_current_preset.",
        });
      }
      if (res.data?.needsConfirm === true) {
        return jsonResult({
          saved: false,
          online: true,
          needsConfirm: true,
          message: res.data.message ?? "The app requires confirmation before saving a preset.",
        });
      }
      if (!res.data || res.data.ok === false) {
        return jsonResult({
          saved: false,
          online: true,
          message: res.error ?? res.data?.message ?? "The app returned no saved preset.",
        });
      }
      return jsonResult({
        saved: true,
        online: true,
        preset: res.data,
        note: "Current audition saved to the shared preset library.",
      });
    }
  );

  // 9. apply_eq_preset — DESTRUCTIVE: changes live audio via the app.
  server.registerTool(
    "apply_eq_preset",
    {
      title: "Apply EQ preset",
      description:
        "DESTRUCTIVE: applies a saved preset to the LIVE system audio through the running Auralink app. " +
        "Honors the app's permission mode — it may return needsConfirm:true, meaning the user must " +
        "approve in the menubar. Requires the app to be running; fails gracefully if it is offline.",
      inputSchema: {
        id: z.string().min(1).describe("Id of an existing preset to apply. Use list_presets to find ids."),
        target: targetSchema,
        confirmed: z
          .boolean()
          .default(false)
          .describe("Set true when the user explicitly confirmed this live-audio change."),
      },
      annotations: {
        readOnlyHint: false,
        destructiveHint: true,
        idempotentHint: true,
        openWorldHint: true,
      },
    },
    async ({ id, target, confirmed }) => {
      // Confirm the preset exists in the library before asking any target to apply it.
      const onDisk = await getPreset(id);
      if (!onDisk) {
        return errorResult(`No preset with id '${id}' in the library; cannot apply.`);
      }

      if (target === "luxsin-x8") {
        const x8 = await applyPresetToX8(onDisk, confirmed);
        return jsonResult({
          target,
          online: x8.online !== false,
          applied: x8.applied === true,
          needsConfirm: x8.needsConfirm === true,
          presetId: id,
          presetName: onDisk.name,
          x8,
          message:
            x8.needsConfirm === true
              ? "The X8 entry was previewed but not written/selected. Pass confirmed:true only when the user explicitly asked to hear it."
              : x8.applied === true
                ? `Wrote and selected '${onDisk.name}' on the Luxsin X8.`
                : (x8.message ?? "The X8 target did not apply the preset."),
        });
      }

      const res = await applyPreset(id, confirmed);
      if (!res.online) {
        return jsonResult({
          applied: false,
          online: false,
          message: res.error,
          hint: "Open the Auralink app, then retry apply_eq_preset.",
        });
      }
      const body = res.data ?? { ok: false };
      const httpError = res.data === undefined ? res.error : undefined;
      const requestAccepted = body.ok === true;
      const verification = requestAccepted
        ? await verifyAuralinkLiveRequest(true, id, body.requestedRenderGeneration)
        : undefined;
      return jsonResult({
        target: "auralink",
        online: true,
        applied: verification?.audible ?? false,
        requestAccepted,
        audible: verification?.audible ?? false,
        needsConfirm: body.needsConfirm === true,
        presetId: id,
        presetName: onDisk.name,
        verification,
        appMessage: body.message,
        appError: httpError,
        message:
          body.needsConfirm === true
            ? "The app requires the user to confirm this change in the menubar (permission mode)."
            : verification?.message ?? (body.message ?? httpError ?? "The app declined to accept the preset request."),
      });
    }
  );

  // 10. rollback_preset — DESTRUCTIVE: revert live audio via the app.
  server.registerTool(
    "rollback_preset",
    {
      title: "Rollback preset",
      description:
        "DESTRUCTIVE: reverts the live system audio to the previously applied preset through the running " +
        "Auralink app. Requires the app to be running; fails gracefully if it is offline.",
      inputSchema: {
        confirmed: z
          .boolean()
          .default(false)
          .describe("Set true only when the user explicitly asked to revert live audio."),
      },
      annotations: {
        readOnlyHint: false,
        destructiveHint: true,
        idempotentHint: false,
        openWorldHint: true,
      },
    },
    async ({ confirmed }) => {
      if (!confirmed) {
        return jsonResult({
          rolledBack: false,
          needsConfirm: true,
          message:
            "Live audio was not rolled back. Pass confirmed:true only when the user explicitly asked to revert.",
        });
      }
      const res = await rollbackPreset(true);
      if (!res.online) {
        return jsonResult({
          rolledBack: false,
          online: false,
          message: res.error,
          hint: "Open the Auralink app, then retry rollback_preset.",
        });
      }
      const body = res.data ?? { ok: false };
      const httpError = res.data === undefined ? res.error : undefined;
      const rollbackTarget = acceptedRollbackTarget(body);
      const hasRollbackTarget = rollbackTarget !== undefined;
      const requestAccepted = rollbackTarget !== undefined;
      const verification = requestAccepted
        ? await verifyAuralinkLiveRequest(
            true,
            rollbackTarget,
            body.requestedRenderGeneration
          )
        : undefined;
      return jsonResult({
        online: true,
        rolledBack: verification?.audible ?? false,
        requestAccepted,
        audible: verification?.audible ?? false,
        presetId: body.presetId,
        presetName: body.presetName,
        verification,
        appMessage: body.message,
        appError: httpError,
        message: verification?.message
          ?? (body.ok === true && !hasRollbackTarget
            ? "The app returned no rollback target identity; no rollback is verified."
            : (body.message ?? httpError ?? "Nothing to roll back.")),
      });
    }
  );
}
