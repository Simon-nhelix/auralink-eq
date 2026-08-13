#!/usr/bin/env node
/**
 * One-time migration into a user-owned Auralink collection.
 *
 * Auralink used to ship a headphone database and keep it in three places at once:
 * the repo's `library/`, a runtime mirror under Application Support, and an
 * aggregate `headphone-profiles.json`. Profiles and curated presets now live in a
 * single directory the user owns — typically a git checkout — and the app ships
 * none of them.
 *
 * This script gathers whatever the old layout left behind and copies it into that
 * directory. It only ever COPIES: nothing is deleted or rewritten in place, so a
 * mistaken run costs nothing but disk.
 *
 * Usage:
 *   node scripts/migrate-collection.mjs             # copy into the collection
 *   node scripts/migrate-collection.mjs --dry-run   # report only
 *   AURALINK_COLLECTION_DIR=/path node scripts/migrate-collection.mjs
 */

import { promises as fs } from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const support = path.join(os.homedir(), "Library", "Application Support", "Auralink");
const dryRun = process.argv.includes("--dry-run");

/** Same resolution order the app and MCP server use (env → defaults → home). */
function collectionDir() {
  const override =
    process.env.AURALINK_COLLECTION_DIR ?? process.env.AURALINK_LIBRARY_DIR;
  if (override && override.trim().length > 0) {
    const trimmed = override.trim();
    const expanded = trimmed.startsWith("~")
      ? path.join(os.homedir(), trimmed.slice(1))
      : trimmed;
    // Reject relative paths — they would follow the process CWD.
    if (path.isAbsolute(expanded)) return expanded;
    console.warn(`Ignoring relative collection path: ${trimmed}`);
  }
  return path.join(os.homedir(), "auralink-collection");
}

/** Validates that an ID is safe for filesystem use (mirrors app/MCP contract). */
function isValidRecordId(id) {
  if (typeof id !== "string") return false;
  const trimmed = id.trim();
  if (!trimmed || trimmed.length > 128) return false;
  if (trimmed === "." || trimmed === "..") return false;
  if (trimmed.includes("..")) return false;
  if (trimmed.startsWith("-") || trimmed.startsWith(".")) return false;
  if (trimmed.endsWith(".") || trimmed.endsWith("-")) return false;
  return /^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(trimmed);
}

/** Writes a file atomically (write to temp, then rename). */
async function atomicWriteFile(filePath, content, encoding = "utf8") {
  const dir = path.dirname(filePath);
  const tempPath = path.join(dir, `.tmp-${Date.now()}-${Math.random().toString(36).slice(2)}`);
  await fs.writeFile(tempPath, content, encoding);
  await fs.rename(tempPath, filePath);
}

/** Curve id that only ever existed in profile data, never in `target-curves.json`. */
const CURVE_ID_FIXES = { "crinacle-ief-neutral": "crinacle-ief-2025" };

const COLLECTION_GITIGNORE = `# Machine-local Auralink state must never enter a shared collection.
audition_*.json
live_audition_*.json
.DS_Store
`;

async function readJsonFile(file) {
  try {
    return JSON.parse(await fs.readFile(file, "utf8"));
  } catch {
    return null;
  }
}

async function readJsonDir(dir) {
  let entries;
  try {
    entries = await fs.readdir(dir);
  } catch {
    return [];
  }
  const out = [];
  for (const entry of entries) {
    if (!entry.toLowerCase().endsWith(".json")) continue;
    const parsed = await readJsonFile(path.join(dir, entry));
    if (parsed && typeof parsed.id === "string" && parsed.id.length > 0) {
      if (isValidRecordId(parsed.id)) {
        out.push(parsed);
      } else {
        console.warn(`Skipping record with invalid ID '${parsed.id}' in ${dir}/${entry}`);
      }
    }
  }
  return out;
}

function stableStringify(value) {
  return `${JSON.stringify(value, Object.keys(flatten(value)).sort(), 2)}\n`;
}

/** Collects every key in the object graph so `JSON.stringify` can sort them. */
function flatten(value, into = {}) {
  if (Array.isArray(value)) {
    for (const item of value) flatten(item, into);
  } else if (value && typeof value === "object") {
    for (const [key, nested] of Object.entries(value)) {
      into[key] = true;
      flatten(nested, into);
    }
  }
  return into;
}

/**
 * Merges records by id from several sources, earliest source winning.
 *
 * Each source's unique contributions are named, not just counted. The runtime
 * mirror in particular can hold leftovers from old test runs, and a bare count
 * would let one slide into the user's repository unnoticed.
 */
function mergeById(sources) {
  const byId = new Map();
  const contributions = [];
  for (const { label, records } of sources) {
    // A source is only a "supplement" once an earlier one has actually supplied
    // something. Post-split the repo library is gone, so whichever source lands
    // first is the effective primary and its entries are not surprising.
    const supplementsExisting = byId.size > 0;
    const added = [];
    for (const record of records) {
      if (byId.has(record.id)) continue;
      byId.set(record.id, record);
      added.push(record.id);
    }
    contributions.push({ label, seen: records.length, added, supplementsExisting });
  }
  return { byId, contributions };
}

function reportContributions(kind, { byId, contributions }) {
  console.log(kind);
  for (const c of contributions) {
    console.log(`  ${c.label}: ${c.seen} found, ${c.added.length} new`);
    if (c.supplementsExisting && c.added.length > 0) {
      for (const id of c.added) console.log(`      + ${id}  <- only here; review it`);
    }
  }
  console.log(`  -> ${byId.size} total\n`);
}

/** Rewrites curve ids that never had a matching target curve definition. */
function applyCurveIdFixes(record) {
  const fixes = [];
  const fixed = structuredClone(record);
  const replacement = CURVE_ID_FIXES[fixed.suggestedTargetCurveId];
  if (replacement) {
    fixes.push(`${fixed.id}: suggestedTargetCurveId ${fixed.suggestedTargetCurveId} -> ${replacement}`);
    fixed.suggestedTargetCurveId = replacement;
  }
  const currentTarget = fixed.correction?.targetCurveId;
  const correctionReplacement = CURVE_ID_FIXES[currentTarget];
  if (correctionReplacement) {
    fixes.push(`${fixed.id}: correction.targetCurveId ${currentTarget} -> ${correctionReplacement}`);
    fixed.correction.targetCurveId = correctionReplacement;
  }
  return { fixed, fixes };
}

function isMachineLocalPreset(preset) {
  const id = (preset.id ?? "").toLowerCase();
  return id.startsWith("audition_") || id.startsWith("live_audition_");
}

async function writeRecords(byId, destination, { fixCurveIds }) {
  const fixes = [];
  let written = 0;
  const conflicts = [];
  if (!dryRun) await fs.mkdir(destination, { recursive: true });

  for (const record of byId.values()) {
    let payload = record;
    if (fixCurveIds) {
      const result = applyCurveIdFixes(record);
      payload = result.fixed;
      fixes.push(...result.fixes);
    }

    const destPath = path.join(destination, `${payload.id}.json`);

    // No-clobber: check if destination already has this record.
    const existing = await readJsonFile(destPath);
    if (existing) {
      const existingJson = JSON.stringify(existing, Object.keys(flatten(existing)).sort());
      const payloadJson = JSON.stringify(payload, Object.keys(flatten(payload)).sort());
      if (existingJson !== payloadJson) {
        conflicts.push(payload.id);
        console.warn(`Conflict: '${payload.id}' already exists in destination with different content`);
        continue;
      }
      // Same content — skip silently (idempotent).
      continue;
    }

    if (!dryRun) {
      await atomicWriteFile(destPath, stableStringify(payload), "utf8");
    }
    written += 1;
  }
  return { written, fixes, conflicts };
}

async function main() {
  const destination = collectionDir();
  console.log(`Collection root: ${destination}`);
  console.log(dryRun ? "Mode: dry run (nothing will be written)\n" : "Mode: copy\n");

  // Profiles. The repo library was the source of truth, then the runtime mirror,
  // then the aggregate for anything registered but never mirrored.
  const aggregate = (await readJsonFile(path.join(support, "data", "headphone-profiles.json"))) ?? [];
  const profileSources = [
    { label: "repo library/headphones", records: await readJsonDir(path.join(repoRoot, "library", "headphones")) },
    { label: "Application Support library/headphones", records: await readJsonDir(path.join(support, "library", "headphones")) },
    { label: "Application Support data/headphone-profiles.json", records: Array.isArray(aggregate) ? aggregate : [] },
  ];
  const profiles = mergeById(profileSources);

  // Presets: only the ones already treated as shared. Everything else in the
  // working directory stays machine-local until the user promotes it explicitly.
  const presetSources = [
    { label: "repo library/presets", records: await readJsonDir(path.join(repoRoot, "library", "presets")) },
    { label: "Application Support library/presets", records: await readJsonDir(path.join(support, "library", "presets")) },
  ];
  const presets = mergeById(presetSources);
  for (const [id, preset] of [...presets.byId]) {
    if (isMachineLocalPreset(preset)) presets.byId.delete(id);
  }

  if (profileSources[0].records.length === 0 && presetSources[0].records.length === 0) {
    console.log(
      "Note: the repository's old library/ is gone, so everything below comes from the\n" +
      "legacy Application Support mirror. That mirror can hold leftovers from old test\n" +
      "runs — skim the results before committing them.\n"
    );
  }

  reportContributions("Headphone profiles", profiles);
  reportContributions("Curated presets", presets);

  if (profiles.byId.size === 0 && presets.byId.size === 0) {
    console.log("Nothing to migrate. If this is a fresh install, that is expected.");
    return;
  }

  const profileResult = await writeRecords(
    profiles.byId,
    path.join(destination, "headphones"),
    { fixCurveIds: true }
  );
  const presetResult = await writeRecords(
    presets.byId,
    path.join(destination, "presets"),
    { fixCurveIds: true }
  );

  const allConflicts = [...profileResult.conflicts, ...presetResult.conflicts];
  if (allConflicts.length > 0) {
    console.log(`\n⚠️  ${allConflicts.length} conflict(s) detected (not overwritten):`);
    for (const id of allConflicts) console.log(`  - ${id}`);
    console.log("Review these manually and delete the destination record if you want to overwrite.\n");
  }

  const fixes = [...profileResult.fixes, ...presetResult.fixes];
  if (fixes.length > 0) {
    console.log("Data fixes applied (curve ids with no matching target curve):");
    for (const fix of fixes) console.log(`  ${fix}`);
    console.log();
  }

  if (!dryRun) {
    const manifestPath = path.join(destination, "manifest.json");
    // Only write a manifest when none exists. A corrupt manifest is left
    // untouched and reported — silently replacing it would erase the schema
    // marker from a newer build (same contract as the Swift side).
    let manifestExists = false;
    try {
      await fs.access(manifestPath);
      manifestExists = true;
    } catch {
      manifestExists = false;
    }
    if (!manifestExists) {
      await atomicWriteFile(
        manifestPath,
        stableStringify({
          schemaVersion: 1,
          name: "My Auralink Collection",
          createdAt: new Date().toISOString(),
        }),
        "utf8"
      );
      console.log(`Wrote ${manifestPath}`);
    } else if (!(await readJsonFile(manifestPath))) {
      console.log(`Warning: ${manifestPath} exists but is not valid JSON — left untouched.`);
    }
    const gitignorePath = path.join(destination, ".gitignore");
    try {
      await fs.access(gitignorePath);
    } catch {
      await atomicWriteFile(gitignorePath, COLLECTION_GITIGNORE, "utf8");
      console.log(`Wrote ${gitignorePath}`);
    }
  }

  console.log(
    `\n${dryRun ? "Would copy" : "Copied"} ${profileResult.written} profiles and ${presetResult.written} presets.`
  );

  const workingPresets = await readJsonDir(path.join(support, "presets"));
  const notMigrated = workingPresets.filter(
    (p) => !presets.byId.has(p.id) && !isMachineLocalPreset(p)
  );
  if (notMigrated.length > 0) {
    console.log(
      `\n${notMigrated.length} preset(s) in the working library were left machine-local.`
    );
    console.log(
      "Nothing is promoted for you — add the ones you want to keep with the app's"
    );
    console.log('"Add to My Collection" action or the add_preset_to_collection tool.');
  }

  if (!dryRun) {
    console.log("\nNext: turn the collection into a repository and push it.");
    console.log(`  cd ${destination}`);
    console.log("  git init && git add . && git commit -m 'Import Auralink collection'");
    console.log("  git remote add origin <your-git-remote>");
    console.log("  git push -u origin main");
    console.log("\nThe old locations are untouched. Remove them once you are satisfied:");
    console.log(`  ${path.join(support, "library")}`);
    console.log(`  ${path.join(support, "data", "headphone-profiles.json")}`);
  }
}

main().catch((error) => {
  console.error(`Migration failed: ${error.message}`);
  process.exitCode = 1;
});
