# Auralink data-only headphone register Implementation Plan

> Inline execution in the requesting session. No git commit unless Simon asks.

**Goal:** `register_headphone_baseline` writes only Auralink library JSON, including non-AutoEq explicit bands, with no X8 and no default seed rebuild.

**Architecture:** Extract `registerHeadphoneBaseline()` from the MCP tool handler so tests can call it with a temp `library/` and a mocked AutoEq lookup. The tool becomes a thin Zod/MCP wrapper.

**Tech Stack:** TypeScript MCP server (`mcp-server/`), node:test, existing `store.ts` dual-write.

## Global Constraints

- No git commit from the tool or this change set unless Simon asks.
- No Luxsin X8 writes from `register_headphone_baseline`.
- `rebuildSeed` default `false`.
- Do not create `scripts/register-*.mjs` or `scripts/verify-*.mjs`.
- Measured FIR payloads stay AutoEq-only; explicit PEQ is IIR bands.

---

### Task 1: Core register function + tests

**Files:**
- Create: `mcp-server/src/register-headphone-baseline.ts`
- Create: `mcp-server/test/register-headphone-baseline.test.mjs`
- Modify: `mcp-server/src/register-tools.ts` (thin wrapper, drop X8 params, add `bands`/`provenance`/`credibility`)
- Modify: `mcp-server/data/agent-eq-guide.md`, `library/README.md`, `mcp-server/src/index.ts`, `mcp-server/src/types.ts` (CREDIBILITIES), `~/.claude/skills/auralink-add-headphone/SKILL.md`

**Produces:** `registerHeadphoneBaseline(input, deps?) → RegisterHeadphoneBaselineResult`

- [ ] Failing tests for explicit bands, missing type, AutoEq miss, no seed write
- [ ] Implement `registerHeadphoneBaseline`
- [ ] Wire MCP tool
- [ ] Update agent docs/skill
- [ ] `npm test` in `mcp-server/`
