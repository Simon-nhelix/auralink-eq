# Auralink data-only headphone register

Date: 2026-08-13

## Problem

Adding a headphone currently produces extra files (one-off `scripts/register-*.mjs`, `scripts/verify-*.mjs`, bundled seed JSON) because `register_headphone_baseline` only accepts AutoEq hits and also mixes Luxsin X8 + seed rebuild into the same call. Agents then invent scripts for squig.link / Super* Review / IEF 2025 cases.

## Goal

One MCP call writes only Auralink library data. No git commit. No X8. No seed rebuild by default. No agent scripts.

## Contract

`register_headphone_baseline` remains the single add tool.

Git-visible writes:

- `library/headphones/{id}.json`
- `library/presets/{presetId}.json`

Runtime (not git): Application Support dual-write + `reload-knowledge` / `reload-presets`.

Out of scope for this tool:

- `git commit`
- Luxsin X8 (`targets`, `x8Select`, `confirmed` removed)
- bundled `headphone-profiles.json` seed ( `rebuildSeed` default `false` )
- anything under `scripts/`

X8 stays on `apply_eq_preset` / `create_eq_preset` with `target: luxsin-x8` when the user names that hardware.

## Input modes

1. **AutoEq** — no `bands`. Existing lookup. Miss → `ok:false`, `reason: autoeq_not_found`, hint to pass `bands`.
2. **Explicit** — `bands` provided. Skip AutoEq. Require `type`. `credibility` defaults to `estimated`. Profile `source` from `provenance` (else a non-AutoEq provenance string).

`preferenceBands` still layer after the baseline bands on both modes.

## Response

Always include `written.headphone` and `written.preset` absolute paths on success. Never include an `x8` field.

## Agent rules

Skill + `agent-eq-guide`: add = this tool only. Do not write `scripts/`. Do not touch bundled seeds. Do not call X8 unless the user names Luxsin X8. Commit is a later human tidy step.
