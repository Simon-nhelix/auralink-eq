import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";

export function registerPrompts(server: McpServer): void {
  // MARK: - Prompts (3) — exact names from BUILD_SPEC

  // create_headphone_tuning — full guided tuning workflow.
  server.registerPrompt(
    "create_headphone_tuning",
    {
      title: "Create headphone tuning",
      description:
        "Guide the assistant through synthesizing a safe, validated EQ preset for a specific headphone " +
        "and goal, then optionally applying it.",
      argsSchema: {
        headphone: z
          .string()
          .describe("Headphone display name or slug, e.g. 'Sennheiser HD600'."),
        goal: z
          .string()
          .describe("Desired sound, e.g. 'warm and relaxed for late-night listening'."),
        preference: z
          .string()
          .optional()
          .describe("Extra preference, e.g. 'keep vocals clear, a bit more sub-bass'."),
      },
    },
    ({ headphone, goal, preference }) => ({
      messages: [
        {
          role: "user",
          content: {
            type: "text",
            text:
              `Create an EQ tuning for the ${headphone} with this goal: "${goal}".` +
              (preference ? ` Additional preference: "${preference}".` : "") +
              `\n\nSteps:\n` +
              `1. Call get_tuning_guidance with headphone="${headphone}" and goal="${goal}". Treat Auralink as an audio engine, not an AI model.\n` +
              `2. Call get_headphone_profile to read the ${headphone}'s signature, correction notes, and harsh regions.\n` +
              `3. Read eq://target-curves and eq://safety-rules to choose a sensible starting direction and stay within limits.\n` +
              `4. Design a small set of explicit parametric bands yourself (favor gentle cuts of harsh regions over large boosts).\n` +
              `5. Call create_eq_preset with those bands (it validates before writing). If validation fails, revise and retry.\n` +
              `6. Summarize the changes and their rationale, report the clipping risk, and ask whether to apply_eq_preset.`,
          },
        },
      ],
    })
  );

  // reduce_harshness — targeted de-essing / 5–9 kHz tame.
  server.registerPrompt(
    "reduce_harshness",
    {
      title: "Reduce harshness",
      description:
        "Guide the assistant to tame fatiguing upper-mid/treble harshness on the current or a named preset.",
      argsSchema: {
        preset_id: z
          .string()
          .optional()
          .describe("Preset id to start from. Omit to use the currently applied preset."),
        amount_db: z
          .string()
          .optional()
          .describe("Roughly how much to cut, in dB (e.g. '3'). Keep it gentle."),
      },
    },
    ({ preset_id, amount_db }) => ({
      messages: [
        {
          role: "user",
          content: {
            type: "text",
            text:
              `Reduce harshness` +
              (preset_id ? ` on preset '${preset_id}'` : ` on the currently applied preset (read get_current_audio_state to find it)`) +
              `.\n\nSteps:\n` +
              `1. Load the starting preset with get_preset.\n` +
              `2. If a headphone is set, read its harsh regions via get_headphone_profile; otherwise target the common 5–9 kHz range.\n` +
              `3. Add gentle bell cuts (around ${amount_db ?? "2–3"} dB, moderate Q) in the harsh regions; do not add boosts.\n` +
              `4. Call validate_eq_preset to confirm it's safe, then create_eq_preset to save a new version.\n` +
              `5. Report the cuts you made and ask whether to apply_eq_preset.`,
          },
        },
      ],
    })
  );

  // make_genre_tuning — apply a target curve for a genre.
  server.registerPrompt(
    "make_genre_tuning",
    {
      title: "Make genre tuning",
      description:
        "Guide the assistant to build an EQ preset shaped for a music genre or use-case, scaled to a headphone.",
      argsSchema: {
        genre: z
          .string()
          .describe("Genre or use-case, e.g. 'rock', 'vocal-focus', 'fps-footstep', 'late-night'."),
        headphone: z
          .string()
          .optional()
          .describe("Optional headphone to scale the tuning to, by name or slug."),
      },
    },
    ({ genre, headphone }) => ({
      messages: [
        {
          role: "user",
          content: {
            type: "text",
            text:
              `Build an EQ preset for ${genre}` +
              (headphone ? ` tuned to the ${headphone}` : ``) +
              `.\n\nSteps:\n` +
              `1. Read eq://target-curves and pick the curve whose id/category best matches "${genre}"; use its band hints as a starting point.\n` +
              (headphone
                ? `2. Call get_headphone_profile for the ${headphone} and adjust the hints to its signature and harsh regions. ` +
                  `If no profile exists, call get_autoeq_correction and register_headphone_baseline to create a measured baseline first (fresh installs ship no headphone database); if AutoEq has no match either, keep the tuning generic and say so.\n`
                : `2. (No headphone given — keep the tuning generic but conservative.)\n`) +
              `3. Read eq://safety-rules and keep every move within the limits.\n` +
              `4. Call create_eq_preset (it validates before writing). Name it clearly, e.g. "${headphone ? headphone + " – " : ""}${genre}".\n` +
              `5. Summarize the tuning and clipping risk, then ask whether to apply_eq_preset.`,
          },
        },
      ],
    })
  );
}
