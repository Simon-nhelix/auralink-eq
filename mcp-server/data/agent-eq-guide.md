# Auralink Agent EQ Guide

Auralink is the local audio engine, preset store, validator, and live apply endpoint. It is not an AI model. The AI client reads evidence, decides explicit EQ bands, then uses Auralink tools to validate, audition, save, and apply.

## Default Workflow

1. Read `get_agent_eq_guide` and `get_current_audio_state` before changing sound.
2. **Measured data first.** When the user names a model, call `get_autoeq_correction` before designing anything. A hit returns the AutoEq parametric correction computed from real measurements (oratory1990, crinacle, …) — use those exact bands and AutoEq's preamp as the baseline, record the source in tags (e.g. `autoeq`, `oratory1990`). Only design bands from prose when no measurement exists.
3. If the user provides headphone or earphone data and says to add it, call `register_headphone_baseline`. AutoEq models: pass the name. Non-AutoEq (squig.link, Super* Review, manufacturer graph): pass `bands` + `type` + `provenance` + `credibility`. The tool writes the profile and its baseline preset into the user's own collection. Do not write `scripts/`, do not commit, and do not use this tool for Luxsin X8.
   - **Auralink ships no headphone database.** An empty headphone list on a fresh install is expected, not a defect: the collection belongs to the user. Look models up with `get_autoeq_correction` rather than assuming data should already be there.
   - Nothing else enters the collection on its own. Call `add_preset_to_collection` only when the user asks to keep or share a preset; auditions and experiments stay machine-local.
4. Use Harman Neutral as the default baseline target unless the user, evidence, or measurement source clearly says otherwise.
5. **Verify before audition.** After designing or editing bands, call `get_response_curve` and check the combined curve matches the stated intent (shelf where intended, no accidental ripple, sane preamp headroom).
6. For later preference changes, audition first. Do not save every experiment. Save only when the user says it is good, wants to keep it, or asks to save.
7. If the user explicitly asks to hear a change now, audition/apply with `confirmed:true`. Never claim live sound changed unless the app reports `routingActive` and `systemOutputRoutedToAuralink`.

## Preset Policy

- Model baseline: saved preset. Name it `<Brand> <Model> - Harman Baseline` or another clear model baseline name.
- Preference tuning: audition-only first. Examples: warmer, more exciting, smoother treble, more vocal, less bass.
- Save-on-like: when the user says "좋아", "맘에 들어", "저장해줘", or equivalent, save the currently auditioned preset with a descriptive name and tags.
- Default audition level policy: preserve volume and dynamics. Use `preampDb:0` and `autoGain:false` unless the user asks for protected/safe mode or the EQ has extreme boosts.
- The clipping meter and user's ears are feedback. Warnings are useful, but small positive boosts are acceptable for quick listening tests.

## Link/Data Ingestion

- If a measurement graph exists, use it as primary evidence and set credibility to `measured` or `community`.
- If only review text/specs exist, infer carefully, set credibility to `estimated`, and keep the baseline conservative.
- Store source URLs and caveats in the headphone profile `source` field.
- Add `harshRegionsHz` only when the review/graph suggests likely fatigue or peaks.

## Output Shape The AI Should Produce

For "add this model":
- `headphoneProfile`: brand, model, type, signature, correctionNotes, harshRegionsHz, suggestedTargetCurveId:`harman-neutral`, source, credibility.
- `baselinePreset`: explicit bands, headphone display name, goal, tags including `ai`, `baseline`, `harman-neutral`, and the profile id.

For "tune this sound":
- `auditionPreset`: explicit bands, headphone display name, goal, `preampDb:0`, `autoGain:false`, tags including `ai` and `audition`.
- `rationale`: short explanation of audible intent and any risk/caveat.

## Band Design Defaults

- Measured AutoEq baselines: use the bands as returned (often 10) with AutoEq's own preamp and `autoGain:false` — the headroom is already computed. Layer preference moves on top as extra bands instead of editing the measured ones.
- Prefer 3-8 meaningful parametric moves for preference changes over filling all 20 bands.
- Use broad shelves for tonal balance and narrower bell filters for peaks.
- Start with +/-1 to 2 dB moves for subjective preference. **If the user says the change is too subtle or they can't hear it, scale the existing moves up (+/-3 to 4 dB) instead of adding more tiny bands.** An EQ the user can't hear is a failed tuning, not a safe one.
- For earbuds/open designs with limited bass, be realistic: a low shelf can add body, but cannot create sealed sub-bass.
- Use cuts around harsh regions before adding treble elsewhere.
