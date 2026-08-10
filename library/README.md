# Auralink shared library (git-tracked)

This directory is the **shared source of truth** for headphone knowledge and
baseline EQ presets that should live in git.

```
library/
  headphones/   # one HeadphoneProfile JSON per model (`{id}.json`)
  presets/      # shared baseline / measured presets (`{id}.json`)
```

## Why

Runtime state still lives under `~/Library/Application Support/Auralink/` so the
app can keep personal auditions, routing, and machine-local files. Shared
profiles used to be rewritten into a single `headphone-profiles.json` seed and
manually re-synced into git. That made MCP registration easy but git history
painful.

Now:

1. MCP tools write shared profiles/presets into `library/` (per file).
2. The same write mirrors into Application Support so the running app sees them.
3. Git commits are just `library/` diffs — append-only and reviewable.
4. Bundled seed JSON under `mcp-server/data` and `Sources/.../Resources/data`
   can be regenerated from `library/headphones` when shipping a build.

## MCP

- `register_headphone_baseline` — measured AutoEq lookup → profile + preset +
  optional Luxsin X8 import-only write, all dual-written to `library/`.
- Profile upsert / preset create also dual-write shared entries into `library/`.

Override root with `AURALINK_LIBRARY_DIR` if needed (defaults to this folder
relative to the repo / `mcp-server` package).

## Do not commit

- Audition presets (`audition_*`, `live_audition_*`)
- Control tokens, device caches, personal preference logs
- Anything under Application Support that is machine-local
