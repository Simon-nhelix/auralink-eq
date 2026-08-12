#!/usr/bin/env node
/**
 * Fix Aune AC55 dual registration:
 * - Auralink software: profile aune-ac55 + preset ai_aune-ac55_harman-mid
 * - Luxsin X8 hardware: applyTuning import-only (no selectHeadphone)
 */
import { copyFileSync, mkdirSync, readFileSync, writeFileSync, existsSync, unlinkSync } from "node:fs";
import { dirname, join } from "node:path";
import { homedir } from "node:os";
import { fileURLToPath, pathToFileURL } from "node:url";

const HOME = homedir();
const REPO = join(HOME, "Documents/ai_eq");
const SUPPORT = join(HOME, "Library/Application Support/Auralink");
const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));

const hpSrc = join(REPO, "library/headphones/aune-ac55.json");
const presetSrc = join(REPO, "library/presets/ai_aune-ac55_harman-mid.json");

function mustReadJson(p) {
  if (!existsSync(p)) throw new Error(`missing ${p}`);
  return JSON.parse(readFileSync(p, "utf8"));
}

function writeJson(p, obj) {
  mkdirSync(dirname(p), { recursive: true });
  writeFileSync(p, JSON.stringify(obj, null, 2) + "\n", "utf8");
  console.log("wrote", p);
}

function rmIfPresent(p) {
  if (existsSync(p)) {
    unlinkSync(p);
    console.log("deleted", p);
    return true;
  }
  console.log("absent (ok)", p);
  return false;
}

function syncCopies() {
  const hp = mustReadJson(hpSrc);
  const preset = mustReadJson(presetSrc);

  // Ensure repo files match expected values (idempotent patch)
  hp.credibility = "estimated";
  hp.id = "aune-ac55";
  hp.brand = "Aune";
  hp.model = "AC55";
  writeJson(hpSrc, hp);

  preset.id = "ai_aune-ac55_harman-mid";
  preset.preampDb = -3.5;
  preset.tags = ["ai", "aune-ac55", "harman-mid", "estimated", "open-clip-on"];
  preset.name = "Aune AC55 – Harman mid (estimated)";
  preset.goal = "Harman-leaning mild-bass open clip-on mid-ground; estimated FR (no AutoEq/Squig/Crinacle).";
  preset.updatedAt = new Date().toISOString().replace(/\.\d{3}Z$/, "Z");
  if (!Array.isArray(preset.bands) || preset.bands.length !== 20) {
    throw new Error(`preset must be 20 bands, got ${preset.bands?.length}`);
  }
  writeJson(presetSrc, preset);

  const hpTargets = [
    join(SUPPORT, "library/headphones/aune-ac55.json"),
  ];
  const presetTargets = [
    join(SUPPORT, "presets/ai_aune-ac55_harman-mid.json"),
    join(SUPPORT, "library/presets/ai_aune-ac55_harman-mid.json"),
  ];
  for (const t of hpTargets) {
    mkdirSync(dirname(t), { recursive: true });
    copyFileSync(hpSrc, t);
    console.log("copied", t);
  }
  for (const t of presetTargets) {
    mkdirSync(dirname(t), { recursive: true });
    copyFileSync(presetSrc, t);
    console.log("copied", t);
  }

  // headphone-profiles.json list upsert
  const profilesPath = join(SUPPORT, "data/headphone-profiles.json");
  const profiles = mustReadJson(profilesPath);
  if (!Array.isArray(profiles)) throw new Error("headphone-profiles.json is not a list");
  const idx = profiles.findIndex((p) => p && p.id === "aune-ac55");
  if (idx >= 0) profiles[idx] = hp;
  else profiles.push(hp);
  writeJson(profilesPath, profiles);
  console.log("headphone-profiles.json aune-ac55 index:", idx >= 0 ? idx : profiles.length - 1);

  // Delete misleading X8-named Auralink aliases
  for (const p of [
    join(SUPPORT, "presets/preset_aune_ac55_harman_mid_x8.json"),
    join(SUPPORT, "library/presets/preset_aune_ac55_harman_mid_x8.json"),
    join(REPO, "library/presets/preset_aune_ac55_harman_mid_x8.json"),
  ]) {
    rmIfPresent(p);
  }

  return { hp, preset };
}

async function reloadPresets() {
  const url = "http://127.0.0.1:8791/reload-presets";
  const res = await fetch(url, { method: "POST" });
  const text = await res.text();
  console.log("reload-presets", res.status, text.slice(0, 500));
  return { status: res.status, text };
}

async function x8Write(preset) {
  const modPath = join(REPO, "mcp-server/dist/targets/index.js");
  const { LuxsinX8Target } = await import(pathToFileURL(modPath).href);
  const target = new LuxsinX8Target(); // default http://192.168.1.2

  const bands = preset.bands;
  const req = {
    headphone: "Aune AC55",
    brand: "Aune",
    model: "AC55",
    form: "over-ear",
    targetCurve: "harman-neutral",
    preampDb: -3.5,
    bands,
  };

  const beforeState = await target.getX8State?.().catch(() => null);
  let beforeActive = null;
  try {
    // Prefer internal helper if reachable via getState mapping
    const st = await target.getState();
    beforeActive = st?.data?.currentPresetName ?? null;
    console.log("before active (mapped):", beforeActive);
    if (beforeState?.online && beforeState.data) {
      const peqSelect = beforeState.data.peqSelect;
      const peq = beforeState.data.peq ?? beforeState.data;
      console.log("before getX8State keys:", Object.keys(beforeState.data || {}));
    }
  } catch (e) {
    console.log("before state note:", String(e?.message || e));
  }

  // Resolve active entry name the same way applyTuning does, via client
  let beforeActiveName = null;
  let afterActiveName = null;
  try {
    beforeActiveName = await target.currentActiveEntryName?.();
  } catch {}
  // currentActiveEntryName may be private — fall back via client
  if (beforeActiveName == null) {
    try {
      const peq = await target.client.getPeq();
      const state = await target.client.getDeviceInfo();
      const idx = state.peqSelect;
      beforeActiveName = typeof idx === "number" ? peq.peq[idx]?.name ?? null : null;
      console.log("before peqSelect", idx, "name", beforeActiveName, "entryCount", peq.peq?.length);
    } catch (e) {
      console.log("before peq fetch failed:", String(e?.message || e));
    }
  } else {
    console.log("before active entry:", beforeActiveName);
  }

  console.log("--- preview applyTuning(confirmed=false) ---");
  const preview = await target.applyTuning(req, false);
  console.log(JSON.stringify(preview, null, 2));

  console.log("--- write applyTuning(confirmed=true) — no selectHeadphone ---");
  const written = await target.applyTuning(req, true);
  console.log(JSON.stringify(written, null, 2));

  // Verify entry + active unchanged
  const peq = await target.client.getPeq();
  const state = await target.client.getDeviceInfo();
  const idx = state.peqSelect;
  afterActiveName = typeof idx === "number" ? peq.peq[idx]?.name ?? null : null;
  const entry = peq.peq.find((e) => e.name === "Aune AC55");
  console.log("after peqSelect", idx, "name", afterActiveName);
  console.log("entry exists:", !!entry);
  if (entry) {
    const summary = {
      name: entry.name,
      brand: entry.brand,
      model: entry.model,
      form: entry.form,
      target: entry.target,
      preamp: entry.preamp,
      autoPre: entry.autoPre,
      filters: (entry.filters || []).map((f) => ({
        type: f.type,
        fc: f.fc,
        gain: f.gain,
        q: f.q,
      })),
    };
    console.log("entry summary:", JSON.stringify(summary, null, 2));
  }
  console.log("ACTIVE_BEFORE=", JSON.stringify(beforeActiveName));
  console.log("ACTIVE_AFTER=", JSON.stringify(afterActiveName));
  console.log("ACTIVE_UNCHANGED=", beforeActiveName === afterActiveName);
  return { preview, written, beforeActiveName, afterActiveName, entryExists: !!entry };
}

const { preset } = syncCopies();
await reloadPresets();
const x8 = await x8Write(preset);
console.log("DONE", JSON.stringify({
  activeBefore: x8.beforeActiveName,
  activeAfter: x8.afterActiveName,
  entryExists: x8.entryExists,
  writeOk: x8.written?.data?.ok ?? x8.written?.ok,
  ref: x8.written?.data?.ref,
  notes: x8.written?.data?.notes,
}, null, 2));
