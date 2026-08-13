import { McpServer, ResourceTemplate } from "@modelcontextprotocol/sdk/server/mcp.js";

import {
  loadAllPresets,
  getHeadphoneProfile,
  loadHeadphoneProfiles,
  loadAgentEQGuide,
  loadTargetCurves,
  loadSafetyRules,
} from "./store.js";
import { getState } from "./control.js";
import { tuningGuidePayload } from "./helpers.js";

const MIME_JSON = "application/json";
const MIME_MARKDOWN = "text/markdown";

export function registerResources(server: McpServer): void {
  // MARK: - Resources

  // eq://agent-guide — agent-facing operational EQ guide.
  server.registerResource(
    "agent-guide",
    "eq://agent-guide",
    {
      title: "Agent EQ guide",
      description:
        "Operational workflow for AI agents: add model baselines, audition preference tunings, and save only liked variations.",
      mimeType: MIME_MARKDOWN,
    },
    async (uri) => {
      const guide = await loadAgentEQGuide();
      return {
        contents: [{ uri: uri.href, mimeType: MIME_MARKDOWN, text: guide.content }],
      };
    }
  );

  // eq://tuning-guide — contract for AI clients designing EQ for Auralink.
  server.registerResource(
    "tuning-guide",
    "eq://tuning-guide",
    {
      title: "Tuning guide",
      description:
        "Workflow, safety guardrails, and band-design hints for AI clients. Auralink itself has no AI model.",
      mimeType: MIME_JSON,
    },
    async (uri) => {
      const guide = await tuningGuidePayload({ includeLiveState: true });
      return {
        contents: [{ uri: uri.href, mimeType: MIME_JSON, text: JSON.stringify(guide, null, 2) }],
      };
    }
  );

  // eq://current-state — live AudioState (or an offline notice).
  server.registerResource(
    "current-state",
    "eq://current-state",
    {
      title: "Current audio state",
      description: "Live snapshot of the Auralink audio engine (AudioState). Falls back to an offline notice.",
      mimeType: MIME_JSON,
    },
    async (uri) => {
      const res = await getState();
      const payload = res.online
        ? { online: true, state: res.data }
        : { online: false, message: res.error };
      return {
        contents: [{ uri: uri.href, mimeType: MIME_JSON, text: JSON.stringify(payload, null, 2) }],
      };
    }
  );

  // eq://presets — the full shared preset library.
  server.registerResource(
    "presets",
    "eq://presets",
    {
      title: "Preset library",
      description: "All saved EQ presets in the shared library (read from disk).",
      mimeType: MIME_JSON,
    },
    async (uri) => {
      const presets = await loadAllPresets();
      return {
        contents: [
          {
            uri: uri.href,
            mimeType: MIME_JSON,
            text: JSON.stringify({ count: presets.length, presets }, null, 2),
          },
        ],
      };
    }
  );

  // eq://headphones/{id} — one headphone profile by slug (templated resource).
  server.registerResource(
    "headphones",
    new ResourceTemplate("eq://headphones/{id}", {
      // Enumerate every profile so clients can browse them.
      list: async () => {
        const profiles = await loadHeadphoneProfiles();
        return {
          resources: profiles.map((p) => ({
            uri: `eq://headphones/${p.id}`,
            name: p.id,
            title: `${p.brand} ${p.model}`,
            description: p.signature,
            mimeType: MIME_JSON,
          })),
        };
      },
      complete: {
        // Autocomplete profile ids by prefix.
        id: async (value) => {
          const profiles = await loadHeadphoneProfiles();
          const v = value.toLowerCase();
          return profiles.map((p) => p.id).filter((slug) => slug.toLowerCase().startsWith(v));
        },
      },
    }),
    {
      title: "Headphone profile",
      description: "Tonal-balance profile for a single headphone, addressed by its slug id.",
      mimeType: MIME_JSON,
    },
    async (uri, variables) => {
      const rawId = variables.id;
      const id = Array.isArray(rawId) ? rawId[0] : rawId;
      const profile = id ? await getHeadphoneProfile(String(id)) : null;
      const payload = profile ?? { error: `No headphone profile with id '${String(id)}'.` };
      return {
        contents: [{ uri: uri.href, mimeType: MIME_JSON, text: JSON.stringify(payload, null, 2) }],
      };
    }
  );

  // eq://target-curves — all target curves.
  server.registerResource(
    "target-curves",
    "eq://target-curves",
    {
      title: "Target curves",
      description: "Genre/purpose tuning templates the AI uses as starting targets.",
      mimeType: MIME_JSON,
    },
    async (uri) => {
      const curves = await loadTargetCurves();
      return {
        contents: [
          {
            uri: uri.href,
            mimeType: MIME_JSON,
            text: JSON.stringify({ count: curves.length, targetCurves: curves }, null, 2),
          },
        ],
      };
    }
  );

  // eq://safety-rules — the guardrails (from disk or built-in defaults).
  server.registerResource(
    "safety-rules",
    "eq://safety-rules",
    {
      title: "Safety rules",
      description: "The guardrails every preset is validated against (gain/Q-or-slope limits, headroom, auto-preamp).",
      mimeType: MIME_JSON,
    },
    async (uri) => {
      const rules = await loadSafetyRules();
      return {
        contents: [{ uri: uri.href, mimeType: MIME_JSON, text: JSON.stringify(rules, null, 2) }],
      };
    }
  );
}
