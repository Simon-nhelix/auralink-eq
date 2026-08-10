#!/usr/bin/env node
/**
 * One-shot migration: copy live Application Support profiles + shared presets
 * into repo library/ as per-file JSON. Also rebuild bundled seed aggregates.
 *
 * Usage (from repo root):
 *   node scripts/sync-library-from-runtime.mjs
 */
import { promises as fs } from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const libraryRoot = path.join(repoRoot, "library");
const headphonesDir = path.join(libraryRoot, "headphones");
const presetsLibDir = path.join(libraryRoot, "presets");
const support = path.join(os.homedir(), "Library", "Application Support", "Auralink");
const liveProfiles = path.join(support, "data", "headphone-profiles.json");
const livePresetsDir = path.join(support, "presets");

function stableStringify(value) {
  const sortKeys = (v) => {
    if (Array.isArray(v)) return v.map(sortKeys);
    if (v && typeof v === "object") {
      const out = {};
      for (const k of Object.keys(v).sort()) out[k] = sortKeys(v[k]);
      return out;
    }
    return v;
  };
  return JSON.stringify(sortKeys(value), null, 2) + "\n";
}

function sanitizeId(id) {
  return String(id).replace(/[^A-Za-z0-9._-]/g, "_");
}

function isSharedPreset(fileName, preset) {
  if (!fileName.endsWith(".json")) return false;
  if (fileName.startsWith("audition_")) return false;
  if (fileName.startsWith("live_audition_")) return false;
  if (fileName.startsWith("preset_ai_") && !fileName.includes("harman") && !fileName.includes("crinacle") && !fileName.includes("baseline")) {
    // keep generic ai drafts out unless tagged
  }
  const tags = preset.tags ?? [];
  if (tags.includes("audition")) return false;
  if (preset.createdBy === "ai") return true;
  if (tags.some((t) => ["baseline", "harman-neutral", "measured-fir", "autoeq", "crinacle-ief-2025"].includes(t))) return true;
  if (fileName.startsWith("ai_")) return true;
  // known shared non-ai names
  if (/autoeq|baseline|harman|crinacle|ief/i.test(fileName)) return true;
  return false;
}

async function ensureDir(dir) {
  await fs.mkdir(dir, { recursive: true });
}

async function main() {
  await ensureDir(headphonesDir);
  await ensureDir(presetsLibDir);

  const profiles = JSON.parse(await fs.readFile(liveProfiles, "utf8"));
  if (!Array.isArray(profiles)) throw new Error("live profiles not an array");

  for (const p of profiles) {
    const id = sanitizeId(p.id);
    await fs.writeFile(path.join(headphonesDir, `${id}.json`), stableStringify(p));
  }
  console.log(`wrote ${profiles.length} headphones → library/headphones`);

  let presetCount = 0;
  let entries = [];
  try {
    entries = await fs.readdir(livePresetsDir);
  } catch {
    entries = [];
  }
  for (const entry of entries) {
    if (!entry.endsWith(".json")) continue;
    const full = path.join(livePresetsDir, entry);
    const text = await fs.readFile(full, "utf8");
    let preset;
    try {
      preset = JSON.parse(text);
    } catch {
      continue;
    }
    if (!isSharedPreset(entry, preset)) continue;
    const id = sanitizeId(preset.id || entry.replace(/\.json$/i, ""));
    await fs.writeFile(path.join(presetsLibDir, `${id}.json`), stableStringify(preset));
    presetCount++;
  }
  console.log(`wrote ${presetCount} shared presets → library/presets`);

  // Rebuild bundled seed aggregates (profiles only — target curves/safety stay as-is)
  const sorted = [...profiles].sort((a, b) =>
    `${a.brand} ${a.model}`.localeCompare(`${b.brand} ${b.model}`)
  );
  // Ship a smaller seed? Keep full live set so bundle matches library.
  const seedPaths = [
    path.join(repoRoot, "mcp-server/data/headphone-profiles.json"),
    path.join(repoRoot, "Sources/AuralinkCore/Resources/data/headphone-profiles.json"),
  ];
  for (const seed of seedPaths) {
    await fs.writeFile(seed, stableStringify(sorted));
    console.log(`seed updated: ${path.relative(repoRoot, seed)} (${sorted.length})`);
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
