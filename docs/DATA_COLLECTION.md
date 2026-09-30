# Your headphone collection

**Auralink ships no headphone database.** No profiles, no baseline presets, nothing
about how any particular can should sound. On a fresh install the headphone list is
empty, and that is the intended state.

## Why

The profiles and presets that used to ship with this app were one person's work:
measurements they trusted, corrections they preferred, and tuning decisions made
against their ears and their gear. Bundling that into the app presented it as
factory truth. It isn't. Someone else's hearing, room, source chain, and taste
produce different answers, and an app that hands you 36 opinionated profiles on
first launch is quietly telling you they are correct.

So the data left. What remains in the app is machinery — the DSP, the validator,
the target curves the tuning engine refers to by id, and the safety limits. The
collection is yours.

This also removes a whole class of confusion that came with the old design: the
same headphone data used to exist in three places at once (the app repository, a
bundled aggregate, and a runtime mirror), kept in sync by hand. There is now one
source of truth for headphone data, and you own it.

## Where it lives

Default: `~/auralink-collection`

```
~/auralink-collection/
  manifest.json      # schemaVersion + collection name
  headphones/        # one HeadphoneProfile per model, {id}.json
  presets/           # curated presets you chose to keep, {id}.json
```

Override the location in either of two ways, checked in this order:

1. `AURALINK_COLLECTION_DIR=/path/to/collection`
2. The `AuralinkCollectionDirectory` user default:
   `defaults write com.auralink.eq AuralinkCollectionDirectory /path/to/collection`

Relative paths are rejected. A menubar app is launched by Launch Services from an
arbitrary working directory, so a relative root would resolve somewhere different
every run.

The default deliberately avoids `~/Documents`. That folder is TCC-protected, and an
ad-hoc signed build loses the access grant on every rebuild — which would look
exactly like your collection disappearing.

## It is meant to be a git repository

Nothing about the collection is Auralink-specific plumbing: it is a directory of
JSON files. Put it under version control and push it wherever you like.

```bash
cd ~/auralink-collection
git init && git add . && git commit -m "Import Auralink collection"
git remote add origin <your-remote>
git push -u origin main
```

To use an existing collection on a new machine, clone it to the default path (or
point `AURALINK_COLLECTION_DIR` at wherever you cloned it) and restart the app.
Both halves are picked up: profiles appear in the headphone list and curated
presets appear in the preset library.

A `.gitignore` excluding `audition_*.json` and `live_audition_*.json` is created for
you. Keep it — auditions are transient machine-local experiments.

## What stays machine-local

`~/Library/Application Support/Auralink/` keeps everything that is about *this
machine* rather than about your taste, and none of it belongs in a shared
collection:

| Path | Contents |
|---|---|
| `presets/` | The working preset library the engine loads, including auditions |
| `revisions/` | Per-preset version history |
| `data/` | Target curves and safety rules, seeded from the app bundle |
| `autoeq-cache/` | Cached AutoEq lookups |
| `data/user-tuning-preferences.json` | AI taste memory from your audition feedback |
| `control-token` | Local API bearer token — never commit or share this |

## Building a collection from nothing

You do not need a shipped database, because public measurements are a network call
away. Name a model to your AI assistant and `register_headphone_baseline` looks it
up in the [AutoEq](https://github.com/jaakkopasanen/AutoEq) project's published
results (oratory1990, crinacle, Rtings, and others), converts the correction into
Auralink's band vocabulary, and writes the profile plus its measured baseline into
your collection.

When AutoEq has no entry — squig.link graphs, Super\* Review, a manufacturer curve —
pass explicit `bands` plus `type`, `provenance`, and `credibility` instead. The
profile records where the numbers came from, so a later reader can tell a measured
baseline from an estimate.

Lookups are cached, so a model you have already registered still resolves offline.
A model you have never looked up needs the network once.

## Automatic tuning registration

Registering a headphone saves its profile and pure baseline in the collection and
working library. Optional preference bands produce a separate tuning. Subsequent
MCP requests through `create_preference_tuning` or `create_eq_preset` automatically
save the requested tuning to both locations; no separate save request is needed.
App permission modes still apply. A tuning request authorizes its associated save,
while live application remains a separate action.

Use `list_presets` to find a tuning and `delete_preset` to delete it from both
locations and remove its revision history. Deleting a preference does not delete
its baseline. Deleting a baseline does not cascade: saved preferences contain the
complete correction and remain usable, although their baseline reference is then
missing. The tool reports live fallback separately when deleting the current preset.

Explicitly unsaved trials use `audition_eq_preset`. App-created working presets can
still be promoted with **Add to My Collection** or `add_preset_to_collection`.
`remove_preset_from_collection` removes only the collection entry and keeps the
working copy.

## Migrating from a pre-split install

If you used Auralink when it still shipped a database, your data is in the old
locations and the app will say so on launch. Run:

```bash
node scripts/migrate-collection.mjs --dry-run   # see what would move
node scripts/migrate-collection.mjs             # copy it
```

The script gathers profiles and shared presets from the repository's old `library/`
directory, the Application Support mirror, and the legacy aggregate
`headphone-profiles.json`, then writes them into your collection. It **only
copies** — the old locations are left untouched, so a mistaken run costs nothing.

It never overwrites a record already in your collection. When the same id exists
with different content, the record is reported as a conflict and skipped; delete
the destination file and re-run if you want the legacy copy to win. Records with
filesystem-unsafe ids are skipped with a warning, and a corrupt `manifest.json`
is reported and preserved rather than replaced.

Presets in your working library that were never part of the shared set stay
machine-local. The script reports how many, and you promote the ones you want.

One data fix is applied during migration: profiles referring to the target curve
`crinacle-ief-neutral` are rewritten to `crinacle-ief-2025`. That id never existed
in `target-curves.json`, so the suggested-target tag was being silently dropped in
the UI.

## Schema versioning

`manifest.json` carries a `schemaVersion`. The app compares it against what the
build understands and warns when a collection was written by a newer Auralink, so a
partially-loading collection reports itself instead of looking like missing data.
The app never overwrites a manifest you already have.
