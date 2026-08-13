#!/usr/bin/env node
/**
 * Auralink EQ — local MCP server (stdio transport).
 *
 * Lets an AI client (Claude Desktop, etc.) read the live audio state and the
 * shared preset library, and generate / validate / apply per-headphone EQ
 * tunings in natural language. It talks to:
 *   • the filesystem (presets + bundled knowledge data) via `store.ts`
 *   • the running app's localhost ControlServer via `control.ts`
 *
 * Read tools never require confirmation and work offline (from disk). Validation
 * runs entirely offline via the ported DSP/safety math in `validate.ts`. The two
 * destructive tools (`apply_eq_preset`, `rollback_preset`) are annotated as such
 * and POST to the app's ControlServer, degrading gracefully when it's offline.
 *
 * Tool / resource / prompt names are the exact identifiers fixed by BUILD_SPEC
 * §MCP server — do not rename them.
 */

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";

import { controlBaseUrl } from "./control.js";
import { registerPrompts } from "./register-prompts.js";
import { registerResources } from "./register-resources.js";
import { registerTools } from "./register-tools.js";

const server = new McpServer(
  {
    name: "auralink-mcp",
    version: "0.1.0-alpha.0",
  },
  {
    instructions:
      "At the START of a tuning task, call get_tuning_brief with the headphone to get the current preset, " +
      "the resolved baseline, safety limits, and a recommended starting point in one read — it prevents " +
      "missing the current state or the baseline to build on. " +
      "Auralink EQ is not an AI model. It is a local audio engine, preset library, validator, and live apply endpoint. " +
      "For natural-language tuning requests, first call get_agent_eq_guide/get_tuning_guidance and read the relevant eq:// resources, then the AI client should design explicit EQ bands. " +
      "MEASURED DATA FIRST: when the user names a headphone/IEM model, call get_autoeq_correction before inventing bands — it returns the AutoEq PEQ fallback and, when available, a dense GraphicEQ-derived measuredCorrection payload (oratory1990, crinacle, …). Preserve that payload in Auralink software presets and mark only subjective additions in preferenceBandIndexes; use PEQ alone for Luxsin X8. Only fall back to prose-derived guesses when no measurement exists. " +
      "After designing or editing bands, call get_response_curve to verify the combined curve actually matches the stated intent (bass shelf where intended, no accidental ripple) before auditioning. " +
      "When adding a new headphone/earphone model, call register_headphone_baseline (AutoEq name, or bands+type when AutoEq misses). It writes library/ JSON only — do not create scripts/, do not rebuild seed, do not commit, and do not use that tool for Luxsin X8. For later preference tuning, audition first with audition_eq_preset and save only when the user likes it or asks to save. " +
      "Audition levels: AutoEq baselines come with their own negative preamp — keep it. For small preference tweaks (≤2-3 dB boosts) preampDb:0 with autoGain:false preserves level; for bigger boost stacks enable autoGain. validate_eq_preset works offline. Only call audition_eq_preset, apply_eq_preset, or route_system_audio after the user explicitly asks for a live-audio change. " +
      "TASTE MEMORY: whenever the user reacts to an audition (liked or disliked), call record_tuning_feedback with the sentiment, a perceivedIssue, their words, and a snapshot of the auditioned bands. get_tuning_brief already surfaces the resulting taste hints; call get_user_tuning_preferences for the full history. " +
      "Never claim live sound changed from control acceptance alone. Require the tool response audible:true or state with routingActive, systemOutputRoutedToAuralink, eqEnabled, expected preset id, and matching requested/committed render generations and modes.",
  }
);

registerTools(server);
registerResources(server);
registerPrompts(server);

async function main(): Promise<void> {
  const transport = new StdioServerTransport();
  await server.connect(transport);
  // Log to stderr only — stdout is the JSON-RPC channel and must stay clean.
  process.stderr.write(
    `auralink-mcp ready (control: ${controlBaseUrl()})\n`
  );
}

main().catch((err) => {
  process.stderr.write(`auralink-mcp failed to start: ${err instanceof Error ? err.stack : String(err)}\n`);
  process.exit(1);
});
