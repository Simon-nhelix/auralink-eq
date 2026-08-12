#!/usr/bin/env node
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { join } from "node:path";
import { homedir } from "node:os";
import { pathToFileURL } from "node:url";

const HOME = homedir();
const REPO = join(HOME, "Documents/ai_eq");
const SUPPORT = join(HOME, "Library/Application Support/Auralink");
const NEW_NAME = "Aune AC55 – Harman Mid Open Clip X8";
const OLD_NAME = "Aune AC55";
const PRESET_ID = "ai_aune-ac55_harman-mid";

const { LuxsinX8Target } = await import(
  pathToFileURL(join(REPO, "mcp-server/dist/targets/index.js")).href
);

function loadPreset() {
  const p = join(SUPPORT, "presets", `${PRESET_ID}.json`);
  const fallback = join(REPO, "library/presets", `${PRESET_ID}.json`);
  const path = existsSync(p) ? p : fallback;
  return { path, preset: JSON.parse(readFileSync(path, "utf8")) };
}

function syncPresetName(preset) {
  preset.name = "Aune AC55 – Harman Mid Open Clip";
  preset.headphone = "Aune AC55";
  preset.updatedAt = new Date().toISOString().replace(/\.\d{3}Z$/, "Z");
  for (const t of [
    join(REPO, "library/presets", `${PRESET_ID}.json`),
    join(SUPPORT, "presets", `${PRESET_ID}.json`),
    join(SUPPORT, "library/presets", `${PRESET_ID}.json`),
  ]) {
    writeFileSync(t, JSON.stringify(preset, null, 2) + "\n");
    console.log("wrote", t);
  }
}

const { preset } = loadPreset();
syncPresetName(preset);

const res = await fetch("http://127.0.0.1:8791/reload-presets", { method: "POST" });
console.log("reload-presets", res.status, (await res.text()).slice(0, 200));

const x8 = new LuxsinX8Target();
const before = await x8.getX8State();
if (!before.online) {
  console.error("X8 offline", before.error);
  process.exit(2);
}
const beforeActive = before.data.peq.peq[Number(before.data.state.peqSelect ?? 0)]?.name;
console.log("BEFORE_ACTIVE", beforeActive);

const write = await x8.applyTuning({
  headphone: NEW_NAME,
  brand: "Aune",
  model: "AC55",
  form: "over-ear",
  goal: preset.goal,
  targetCurve: "harman-neutral",
  preampDb: preset.preampDb ?? -3.5,
  bands: preset.bands,
}, true);
console.log("WRITE", JSON.stringify({ online: write.online, ok: write.data?.ok, ref: write.data?.ref, notes: write.data?.notes, error: write.error }));

if (write.data?.ok) {
  const del = await x8.deleteHeadphone(OLD_NAME);
  console.log("DELETE_OLD", JSON.stringify({ online: del.online, ok: del.data?.ok, error: del.error }));
}

const after = await x8.getX8State();
const afterActive = after.data.peq.peq[Number(after.data.state.peqSelect ?? 0)]?.name;
const names = after.data.peq.peq.map((e) => e.name);
console.log("AFTER_ACTIVE", afterActive);
console.log("HAS_NEW", names.includes(NEW_NAME), "HAS_OLD", names.includes(OLD_NAME));
console.log("ACTIVE_UNCHANGED", beforeActive === afterActive);
if (!names.includes(NEW_NAME) || names.includes(OLD_NAME) || beforeActive !== afterActive) process.exit(1);
