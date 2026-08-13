# Auralink EQ — MCP Server

A local [Model Context Protocol](https://modelcontextprotocol.io) server that lets an
AI client (Claude Desktop, etc.) read the live audio state of the **Auralink EQ**
macOS app and generate / validate / apply per-headphone EQ tunings in natural
language.

It speaks two backends:

- **Filesystem** — reads and writes the *same* working preset library the app uses
  (`~/Library/Application Support/Auralink/presets`), reads the user's own headphone
  profiles and curated presets from their collection (`~/auralink-collection` by
  default), and reads bundled target curves and safety rules from `./data`. No
  headphone data ships; see `../docs/DATA_COLLECTION.md`.
- **App ControlServer** — a localhost HTTP API the running app exposes
  (`http://127.0.0.1:8765`) for live state and any change to live audio. It
  requires the user-only bearer token created by the app on first launch.

Read tools and `validate_eq_preset` work fully **offline** — the EQ DSP magnitude
math and the safety/clipping validation are ported from the app's Swift
`Biquad` / `FrequencyResponse` / `PresetValidator` so the AI can reason about a
tuning without the app running. Live-state, routing, audition, apply, and
rollback tools require the app.

## What it exposes

### Tools (28)

| Tool | Kind | Notes |
| --- | --- | --- |
| `get_current_audio_state` | read | Live `AudioState` from the app; offline notice if it isn't running. |
| `get_agent_eq_guide` | read | Canonical measured-first agent workflow. |
| `get_tuning_guidance` | read | Safety and tuning guidance for a request. |
| `get_tuning_brief` | read | Current preset, baseline, profile, preferences, and recommended starting point. |
| `record_tuning_feedback` | write | Records explicit listening feedback locally. |
| `get_user_tuning_preferences` | read | Summarizes locally stored feedback. |
| `list_output_devices` | read | Output devices from the app (requires app). |
| `list_headphone_profiles` | read | All profiles in the user's collection (offline). Empty on a fresh install. |
| `get_headphone_profile` | read | One profile by slug id (offline). |
| `upsert_headphone_profile` | write | Validates and saves a profile into the user's collection. |
| `delete_headphone_profile` | write | Deletes a profile from the collection. |
| `list_presets` | read | Working library + collection presets, flagged with `inCollection` (offline). |
| `get_preset` | read | One full preset by id (offline). |
| `add_preset_to_collection` | write | Copies a preset into the user's collection. Ask first. |
| `remove_preset_from_collection` | write | Drops a collection entry, keeping the working copy. |
| `delete_preset` | write | Deletes a local preset and refreshes the app when online. |
| `create_eq_preset` | write | **Validates before writing**; applies auto-preamp; never touches live audio. |
| `audition_eq_preset` | **live** | Applies an unsaved, validated preset temporarily after confirmation. |
| `get_autoeq_correction` | network read | Fetches/caches measured AutoEq PEQ and GraphicEQ data with provenance. |
| `get_response_curve` | read | Computes the combined left/right response before auditioning. |
| `validate_eq_preset` | read | Offline safety + clipping check for an id or inline bands. |
| `route_system_audio` | **destructive** | Routes macOS output through Auralink. |
| `restore_system_audio` | **destructive** | Restores the previous physical output. |
| `stop_audio_routing` | **destructive** | Stops the capture/render path. |
| `save_current_preset` | write | Saves the current loaded or auditioned state. |
| `apply_eq_preset` | **destructive** | Applies a preset to live audio via the app; honors permission mode. |
| `rollback_preset` | **destructive** | Reverts live audio to the previous preset via the app. |

Live and destructive tools are explicitly annotated in their MCP metadata.
`create_eq_preset` always runs the validator first and refuses to write a preset
that produces a validation **error**.

### Resources (5)

- `eq://current-state` — live `AudioState` (or an offline notice).
- `eq://presets` — the full shared preset library.
- `eq://headphones/{id}` — one headphone profile by slug (templated; lists + autocompletes ids).
- `eq://target-curves` — all genre/purpose tuning templates.
- `eq://safety-rules` — the guardrails used by validation.

### Prompts (3)

- `create_headphone_tuning` — guided end-to-end tuning for a headphone + goal.
- `reduce_harshness` — tame fatiguing 5–9 kHz / upper-mid energy.
- `make_genre_tuning` — build a preset shaped for a genre / use-case.

## Build

Requires Node 18+ (developed against Node 24).

```bash
cd mcp-server
npm ci
npm run build      # tsc → dist/
```

Other scripts:

```bash
npm start          # node dist/index.js  (stdio transport)
npm run dev        # tsc -w  (rebuild on change)
```

## Configuration (environment variables)

| Variable | Default | Purpose |
| --- | --- | --- |
| `AURALINK_PRESETS_DIR` | `~/Library/Application Support/Auralink/presets` | Working preset library (read/write). |
| `AURALINK_COLLECTION_DIR` | `~/auralink-collection` | The user's own headphone profiles and curated presets. Must match the app's setting. `AURALINK_LIBRARY_DIR` is accepted as the pre-split name. |
| `AURALINK_DATA_DIR` | `./data` (next to this package) | Bundled target curves and safety rules. |
| `AURALINK_CONTROL_URL` | `http://127.0.0.1:8765` | Base URL of the app's ControlServer. |
| `AURALINK_CONTROL_TOKEN_FILE` | `~/Library/Application Support/Auralink/control-token` | Shared capability file created by the app. |
| `AURALINK_CONTROL_TOKEN` | unset | Explicit bearer capability for controlled development environments. |

All variables are optional — the defaults match the app's conventions. Launch
the app once before using live tools so it can create the private control token.
Do not paste that token into MCP configuration or commit it. If a knowledge
file is missing, the relevant list comes back empty and `safety-rules` falls back
to the built-in defaults. If the app is offline, live-state and destructive tools
return a clear `online: false` notice instead of failing.

## Wire into Claude Desktop

1. Launch Auralink EQ once so the private local control token exists.
2. Build the server (`npm ci && npm run build`).
3. Open Claude Desktop's config:
   `~/Library/Application Support/Claude/claude_desktop_config.json`
4. Merge the `auralink` entry from [`claude_desktop_config.json`](./claude_desktop_config.json)
   in this folder — using the **absolute** path to this repo's `dist/index.js`:

   ```json
   {
     "mcpServers": {
       "auralink": {
         "command": "node",
        "args": ["/ABSOLUTE/PATH/TO/auralink-eq/mcp-server/dist/index.js"]
       }
     }
   }
   ```

5. Restart Claude Desktop. The `auralink` server should appear with its tools,
   resources, and prompts.
6. For live state and applying tunings, launch the **Auralink EQ** app first so
   its ControlServer is listening on port 8765.

## Notes

- stdio is the JSON-RPC channel; the server logs only to **stderr**, so stdout
  stays clean for the protocol.
- The on-disk preset JSON matches the app's `JSONEncoder` output (camelCase
  fields, snake_case enum values, ISO-8601 dates, sorted keys), so presets the AI
  creates load directly in the app and vice versa.
