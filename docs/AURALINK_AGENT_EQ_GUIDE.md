# Auralink Agent EQ Guide

This is the operational guide an AI agent should read before controlling Auralink EQ through MCP. It is derived from `docs/auralink_eq_mcp_tuning_knowledge_base.docx`, then adapted to Auralink's actual product workflow:

- Auralink is not the AI. Auralink is the local audio engine, validator, preset library, headphone knowledge base, and live audition/apply endpoint.
- The AI agent reads links, measurements, reviews, user notes, and current app state, then emits explicit parametric EQ bands. When AutoEq supplies dense `GraphicEQ` data, the agent also forwards the returned `measuredCorrection` payload unchanged.
- The app validates and plays the result. The user decides what deserves to be saved.

## Product Workflow

### Add A Headphone Or Earphone

Use this when the user says things like "이 모델 추가해줘", gives a review/measurement link, or provides specs/notes for a new model.

1. **Call `get_autoeq_correction` with the model name first.** A hit returns the measured parametric correction toward Harman and, when published, a validated dense `GraphicEQ` payload (oratory1990/crinacle/… with provenance). Use the exact bands + AutoEq preamp as the Standard IIR baseline. For the Auralink software target, also copy `measuredCorrection` unchanged into the saved/auditioned preset so Measured FIR can reproduce the dense curve.
2. Read the source and extract brand, model, form factor, tonal signature, correction notes, likely harsh regions, and evidence quality.
3. Create or update the headphone profile with `upsert_headphone_profile` (mention the AutoEq source in `source` when one was found, credibility `measured`).
4. Set `suggestedTargetCurveId` to `harman-neutral` unless the evidence clearly points elsewhere.
5. Create a saved model baseline preset with `create_eq_preset`, including the returned `measuredCorrection` for the Auralink software target when available.
6. Name the baseline clearly, for example `Sennheiser HD600 - AutoEq (oratory1990)` or `TimeEar NH60 - Harman Baseline` when no measurement exists.
7. Use tags: `ai`, `baseline`, profile id, and evidence type such as `autoeq`, `measured`, `community`, or `estimated`.
8. If the source contains a long subtitle, translation artifact, or alias, keep the visible `brand` and `model` clean. Put aliases and caveats in `source` or notes only.

Baseline presets are allowed to be saved immediately because they define the model's starting point.

### Start With The Tuning Brief

Before any sound change, call **`get_tuning_brief`** with the headphone (and the user's goal). It returns one read containing: the matched headphone profile, the **currently applied preset** (with its bands + response-curve summary), the **resolved baseline preset** to build on (with its bands + curve), the key safety limits, and a concrete `recommendation` (start from the baseline, or create one if none exists). This prevents the two most common tuning mistakes: ignoring what is currently loaded, and layering preference moves on nothing instead of on the measured baseline. For workflow/guardrails/descriptor-to-frequency heuristics, also call `get_tuning_guidance`.

### Tune A Preference

Use this when the user asks for a sound change after a model/baseline exists: warmer, more exciting, smoother, less sibilant, more vocal, more bass, better rock, and similar.

1. Call `get_tuning_brief` for the headphone. If `recommendation.situation` is `has_baseline`, layer your preference moves on top of `baselinePreset.bands`; if it is `matches_but_no_baseline`, build on `bestAvailablePreset.bands` but recommend creating a measured baseline via `get_autoeq_correction`. Honor `userPreferences.derivedNotes` — avoid the things the user repeatedly dislikes and lean into what they like.
2. Create a small variation using explicit bands. Preserve the baseline's `measuredCorrection` unchanged and mark only the new subjective slots in `preferenceBandIndexes`; Measured FIR renders the dense baseline and those preference bands, not the baseline PEQ twice.
3. Audition it live with `audition_eq_preset` when the user asked to hear the change.
4. Do not save each experiment.
5. **Record the user's reaction with `record_tuning_feedback`** (sentiment + perceivedIssue + their words + a snapshot of the auditioned bands) for every audition they react to — liked or disliked. This is the taste-memory that makes future tunings converge.
6. If the user says "좋아", "맘에 들어", "저장해줘", "keep this", or equivalent, call `save_current_preset` with a descriptive name (and record a `liked` feedback entry).

Preference presets are audition-first, save-on-like, and every reaction feeds the taste-memory read back by `get_tuning_brief` and `get_user_tuning_preferences`.

### Use The Luxsin X8 Hardware Target

Use this when the user wants the EQ to live on the Luxsin X8 DAC/headphone amp instead of only in the macOS Auralink software path. This is the right path for listening from non-Mac inputs into the X8.

1. Keep the headphone/profile workflow the same: `get_autoeq_correction` first, `upsert_headphone_profile` for new or image-derived models, then design explicit Auralink-vocabulary bands.
2. Read X8 state with `get_current_audio_state` and `target:"luxsin-x8"`. If it returns `online:false`, the X8 is absent/offline; fall back to normal Auralink or tell the user the hardware target was not found. Do not treat missing X8 as an MCP failure.
3. To save a preset and put it on the X8, call `create_eq_preset` with `target:"luxsin-x8"`, `applyNow:true`, and `confirmed:true` only after the user explicitly asked to hear/test the X8 hardware change.
4. To put an already saved preset on the X8, call `apply_eq_preset` with `target:"luxsin-x8"` and `confirmed:true`.
5. `audition_eq_preset` also accepts `target:"luxsin-x8"`; unlike software audition, it writes/selects a hardware X8 entry. Use descriptive temporary names and do not spray many experiments into the X8 database.
6. The MCP server handles X8 implementation details: local IP discovery/cache, custom base64 codec, `peqChange`, numeric filter type codes, 10-band limit, safe transparent padding, and active-entry restoration. Do not call the X8 CGI endpoints directly unless debugging the adapter.
7. X8 entries support 10 bands. The target adapter trims Auralink's 20-band preset to the most important enabled bands and pads the rest with transparent `PEAKING 0 dB` filters. This prevents the firmware's unsafe `LOW_PASS@0` auto-padding. X8 remains PEQ-only; `measuredCorrection` is portable preset metadata but is not rendered by the hardware target.

### Remember The User's Taste

Taste accumulates in `~/Library/Application Support/Auralink/data/user-tuning-preferences.json` (AI-only; the app does not read it). Use `record_tuning_feedback` whenever the user reacts to a tuning, and `get_user_tuning_preferences` (optionally scoped to a headphone) to read the aggregated summary — frequent complaints, directions that landed or missed, and freeform preference markers. `get_tuning_brief` already carries a compact `userPreferences` hint, so you usually don't need a separate call at the start; reach for `get_user_tuning_preferences` when you want the full recent-entry history or the global view.

### Delete Mistakes

Use this when the user says a model, profile, or preset was added by mistake.

1. Delete mistaken headphone/earphone profiles with `delete_headphone_profile`.
2. Delete mistaken saved presets with `delete_preset`.
3. If the user corrects the model name, immediately re-add the profile under the clean display name and create a fresh baseline.
4. Keep aliases and caveats in notes/source fields; do not pollute the visible model name with every translation variant or article subtitle.

The app auto-refreshes its profile and preset lists when MCP changes the shared data on disk. If a client is connected to an older app build, use `reload-knowledge` / `reload-presets` through the app control API or restart the app.

## Live Audio Rules

- For the default `auralink` target, control acceptance is not audible proof. Never claim live sound changed unless state reports `routingActive:true`, `systemOutputRoutedToAuralink:true`, `eqEnabled:true`, the expected preset id, and matching `requestedRenderGeneration` / `committedRenderGeneration` (plus requested/active FIR mode agreement). Prefer the write tool's explicit `audible`/`verification` fields.
- For `target:"luxsin-x8"`, live sound changes on the X8 only after a confirmed `create_eq_preset`/`audition_eq_preset`/`apply_eq_preset` returns applied/selected successfully and `get_current_audio_state({target:"luxsin-x8"})` shows the expected `currentPresetName`.
- Only live-audition/apply when the user explicitly asked to hear or test it.
- For this product, the default audition policy is level-preserving: `preampDb:0`, `autoGain:false`.
- Use automatic preamp or safe mode when the user asks for protected mode, when boosts are large, or when clipping is reported and the user wants automatic guardrails.
- The clipping meter and the user's ears are feedback. Small positive boosts are acceptable for quick listening tests.

## Evidence And Confidence

- Measurement graph available: use it as primary evidence. Credibility should usually be `measured` or `community`.
- Review text only: infer conservatively. Credibility should be `estimated`.
- Manufacturer specs only: useful for form factor/impedance/driver limits, not enough for exact correction. Credibility should be `manufacturer`.
- No evidence: do not claim correction. Treat moves as preference tuning.
- Always keep source URLs and caveats in the headphone profile `source` field.

## Correction Vs Preference

Correction means compensating for known model behavior. Preference means making the sound fit the user's taste or a listening situation.

- Without measurement or credible consensus, avoid saying "exact correction".
- A model baseline may combine light correction and Harman-like target shaping.
- Later tuning should be described as a preference variation unless it is grounded in new evidence.

## Band Design Defaults

- Measured AutoEq baselines: keep the returned bands (often 10) and AutoEq's preamp as-is; layer preference moves on top as extra bands.
- Prefer 3-8 meaningful bands for preference moves over filling all 20.
- Use broad Q for tonal shaping: `0.5-1.5`.
- Use narrower Q for resonance or sibilance cuts: `2-5`.
- Avoid high-Q boosts unless there is very strong reason.
- Start with `1-2 dB` moves for subjective preference.
- If the user says the effect is too subtle, scale the existing moves up (`3-4 dB`) instead of adding more tiny bands — an inaudible EQ is a failed tuning, not a safe one.
- After designing bands, call `get_response_curve` to verify the combined curve matches the request before auditioning.
- For earbuds/open designs with limited seal, be realistic about sub-bass.

## Frequency Map

| Range | Perceptual Meaning | Agent Guidance |
| --- | --- | --- |
| 20-40 Hz | Rumble, LFE pressure | Avoid large boosts. Many headphones/earbuds cannot reproduce this cleanly. |
| 40-80 Hz | Sub-bass weight | Use broad low shelf or bell for depth. Watch clipping. |
| 80-160 Hz | Bass punch, kick impact | Rock/EDM punch often starts around 80-120 Hz. |
| 160-300 Hz | Warmth, boom, mud | Add tiny warmth or cut muddiness. This range can mask vocals. |
| 300-600 Hz | Body, boxiness | Boxy/hollow diagnosis zone. Prefer small cuts. |
| 600 Hz-1 kHz | Mid core, nasal tone | Nasal/telephone tone often lives here. |
| 1-2 kHz | Forwardness, vocal distance | Small boosts move vocals forward. Too much can shout. |
| 2-4 kHz | Presence, attack, footstep cues | Powerful but fatiguing. Avoid large default boosts. |
| 4-6 kHz | Edge, harshness, metallic attack | Main harsh/metallic cut candidate. |
| 6-8.5 kHz | Sibilance, cymbal bite | Cut for "쏜다", "치찰음", "심벌 피곤". |
| 8.5-12 kHz | Air, sparkle, detail | Add air carefully; hiss and fatigue can increase. |
| 12-20 kHz | Ultra-air/noise | Individual hearing and measurement reliability vary. Use small shelves. |

## Descriptor Rules

| User Phrase | First Suspect | Initial Move |
| --- | --- | --- |
| muddy / 탁함 | 160-350 Hz, sometimes 300-600 Hz | Bell `-1` to `-3 dB`, Q `0.8-1.4` |
| boomy / 붕붕 | 80-180 Hz or 160-300 Hz | Low shelf `-1` to `-2 dB` or bell cut |
| thin / 얇음 | 80-200 Hz low, or 2-4 kHz high | Low shelf `+1` to `+2 dB`, or presence cut |
| warm / 따뜻 | 120-300 Hz body, 4-8 kHz relaxed | Low shelf `+0.5` to `+1.5 dB`, optional treble cut |
| bright / 밝게 | 3-6 kHz or 8-12 kHz | High shelf `+1` to `+2 dB` or small 3 kHz boost |
| dark / 어두움 | Upper treble low, low-mid high | 8-10 kHz shelf `+1` to `+3 dB`, optional 250 Hz cut |
| harsh / 쏨 | 2.5-6 kHz | Bell `-1` to `-3 dB`, Q `1.2-2.5` |
| sibilant / 치찰음 | 5.5-8.5 kHz | Bell `-1` to `-4 dB`, Q `2-5` |
| vocal forward | 1.5-3 kHz, 200-400 Hz cleanup | 1.8-2.5 kHz `+1` to `+2 dB`, optional 250 Hz cut |
| airy / 공기감 | 9-14 kHz | High shelf `+1` to `+2.5 dB` |
| punchy / 펀치 | 70-130 Hz, 2-4 kHz attack | 90 Hz `+1` to `+3 dB`, optional 2.5 kHz `+1 dB` |
| relaxed / 편안함 | 2-6 kHz and upper treble | 3.5 kHz `-1 dB`, 7 kHz `-1 dB` |

## Intent Recipes

These are starting points, not final answers.

- Rock: 80-120 Hz `+1` to `+3`, 1.8-3 kHz `+1` to `+2`, 5-8 kHz `-0.5` to `-2`.
- Pop/K-pop: 90 Hz `+1` to `+2`, 2 kHz `+1`, 6-8 kHz cut if needed, 10 kHz `+1`.
- EDM/Hip-hop: 50-80 Hz `+1` to `+3`, 120 Hz `+1`, 250 Hz `-1`, 8-10 kHz `+1`.
- Jazz/Acoustic: 250 Hz `-0.5`, 1.5 kHz `+0.5`, 10 kHz `+1`; avoid big V shapes.
- Classical: minimal tonal shaping, preserve dynamics, remove only clear resonances.
- FPS: 60-120 Hz `-1` to `-3`, 2-5 kHz `+1` to `+3`, 6-8 kHz cut if fatiguing.
- Late night: 80 Hz `+1`, 10 kHz `+0.5`, 3-6 kHz `-0.5`.
- Meeting/voice: low cleanup, 250 Hz `-2`, 2.5 kHz `+1` to `+2`.

## Tool Contracts

### For Adding A Model

Use:

1. `upsert_headphone_profile`
2. `create_eq_preset`

The `create_eq_preset` baseline should use `autoGain:false` by default unless the preset has meaningful boost stacking. A saved baseline is expected.

For Luxsin X8 hardware output, pass `target:"luxsin-x8"` plus `applyNow:true` and `confirmed:true` only when the user explicitly asked to put the preset on the X8. Without `applyNow:true`, `create_eq_preset` only writes the Auralink preset library.

### For Auditioning A Variation

Use:

1. `audition_eq_preset`
2. Ask for brief feedback, or wait for the user's reaction.

For `target:"luxsin-x8"`, remember that audition writes/selects an X8 hardware entry rather than a purely transient software audition. Use it sparingly, with clear names, and replace/delete mistakes promptly.

Do not call `create_eq_preset` for every variation. That pollutes the library.

### For Saving A Liked Variation

Use:

1. `save_current_preset`

Name it based on the model and the audible goal, for example `HD600 - Warm Rock v1` or `TimeEar NH60 - Smoother Treble`.

### For Deleting A Mistake

Use:

1. `delete_headphone_profile`
2. `delete_preset`

Then re-add with the corrected name if the user intended a rename rather than a full removal.

## Output Contract For Agent Reasoning

When proposing an EQ, structure your internal result like this before calling tools:

```json
{
  "presetName": "HD600 - Warm Rock Audition",
  "intentSummary": "Add kick warmth and guitar body while keeping treble fatigue controlled.",
  "assumptions": ["No measurement data was provided.", "Using current headphone profile as the baseline."],
  "confidence": "medium",
  "target": "auralink",
  "preampDb": 0,
  "autoGain": false,
  "bands": [
    {
      "type": "low_shelf",
      "frequencyHz": 95,
      "gainDb": 1.5,
      "q": 0.7,
      "channel": "stereo",
      "enabled": true
    }
  ],
  "safetyNotes": ["No automatic attenuation for this audition; monitor clipping."],
  "savePolicy": "audition_only_until_user_likes_it"
}
```

## Hard No

- Do not invent exact correction from text-only evidence.
- Do not fill all 20 bands for a first draft.
- Do not use large high-Q boosts.
- Do not apply or audition live without an explicit user request.
- Do not tell the user sound changed if routing is bypassed for Auralink, or if X8 apply/select did not succeed for `target:"luxsin-x8"`.
- Do not save preference experiments unless the user likes them or asks to save.
- Do not keep a mistaken translated model suffix in the visible model list after the user calls it out.
- Do not send direct X8 CGI writes from an agent workflow; use MCP `target:"luxsin-x8"` so discovery, 10-band safety padding, active-entry restoration, and no-device handling are applied.
