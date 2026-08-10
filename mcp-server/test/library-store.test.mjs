import assert from "node:assert/strict";
import { promises as fs } from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const dist = path.resolve(here, "..", "dist");

async function withTempEnv(fn) {
  const tmp = await fs.mkdtemp(path.join(os.tmpdir(), "auralink-library-"));
  const library = path.join(tmp, "library");
  const runtimeLibrary = path.join(tmp, "runtime-library");
  const userData = path.join(tmp, "user-data");
  const presets = path.join(tmp, "presets");
  const data = path.join(tmp, "bundled-data");
  await fs.mkdir(path.join(library, "headphones"), { recursive: true });
  await fs.mkdir(path.join(library, "presets"), { recursive: true });
  await fs.mkdir(path.join(runtimeLibrary, "headphones"), { recursive: true });
  await fs.mkdir(path.join(runtimeLibrary, "presets"), { recursive: true });
  await fs.mkdir(userData, { recursive: true });
  await fs.mkdir(presets, { recursive: true });
  await fs.mkdir(data, { recursive: true });
  await fs.writeFile(path.join(data, "headphone-profiles.json"), "[]\n");

  const prev = { ...process.env };
  process.env.AURALINK_LIBRARY_DIR = library;
  process.env.AURALINK_RUNTIME_LIBRARY_DIR = runtimeLibrary;
  process.env.AURALINK_USER_DATA_DIR = userData;
  process.env.AURALINK_PRESETS_DIR = presets;
  process.env.AURALINK_DATA_DIR = data;

  try {
    // Dynamic import after env is set (store resolves dirs at call time).
    const store = await import(path.join(dist, "store.js"));
    await fn(store, { tmp, library, runtimeLibrary, userData, presets, data });
  } finally {
    process.env = prev;
    await fs.rm(tmp, { recursive: true, force: true });
  }
}

test("saveHeadphoneProfile dual-writes per-file library entry", async () => {
  await withTempEnv(async (store, { library, runtimeLibrary, userData }) => {
    const saved = await store.saveHeadphoneProfile({
      id: "test-can-one",
      brand: "Test",
      model: "Can One",
      type: "open_back",
      signature: "neutral test can",
      correctionNotes: ["none"],
      harshRegionsHz: [],
      suggestedTargetCurveId: "harman-neutral",
      source: "unit test",
      credibility: "estimated",
    });
    assert.equal(saved.id, "test-can-one");

    const libFile = path.join(library, "headphones", "test-can-one.json");
    const runtimeFile = path.join(runtimeLibrary, "headphones", "test-can-one.json");
    const userFile = path.join(userData, "headphone-profiles.json");
    const libRaw = JSON.parse(await fs.readFile(libFile, "utf8"));
    const runtimeRaw = JSON.parse(await fs.readFile(runtimeFile, "utf8"));
    const userRaw = JSON.parse(await fs.readFile(userFile, "utf8"));
    assert.equal(libRaw.id, "test-can-one");
    assert.equal(runtimeRaw.id, "test-can-one");
    assert.equal(userRaw.length, 1);
    assert.equal(userRaw[0].id, "test-can-one");

    const loaded = await store.loadHeadphoneProfiles();
    assert.equal(loaded.some((p) => p.id === "test-can-one"), true);
  });
});

test("savePreset dual-writes shared ai_ presets into library", async () => {
  await withTempEnv(async (store, { library, presets }) => {
    const bands = store.bandsFromSpecs([
      { type: "low_shelf", frequencyHz: 105, gainDb: 2, q: 0.7 },
    ]);
    const saved = await store.savePreset(
      store.normalizePreset({
        id: "ai_test-can-one_harman-neutral",
        name: "Test Can One – Harman Neutral",
        headphone: "Test Can One",
        goal: "unit test baseline",
        preampDb: -2,
        bands,
        safety: { autoGainEnabled: false, clippingRisk: "low" },
        createdBy: "ai",
        version: 1,
        tags: ["ai", "baseline", "harman-neutral", "library"],
        createdAt: "",
        updatedAt: "",
      })
    );
    assert.equal(store.isSharedLibraryPreset(saved), true);
    const libFile = path.join(library, "presets", "ai_test-can-one_harman-neutral.json");
    const runtimeFile = path.join(presets, "ai_test-can-one_harman-neutral.json");
    await fs.access(libFile);
    await fs.access(runtimeFile);
  });
});

test("audition presets are not mirrored into library", async () => {
  await withTempEnv(async (store, { library, presets }) => {
    const bands = store.bandsFromSpecs([
      { type: "bell", frequencyHz: 1000, gainDb: 1, q: 1 },
    ]);
    const saved = await store.savePreset(
      store.normalizePreset({
        id: "audition_ai_tmp123",
        name: "tmp audition",
        preampDb: 0,
        bands,
        safety: { autoGainEnabled: false, clippingRisk: "low" },
        createdBy: "ai",
        version: 1,
        tags: ["ai", "audition"],
        createdAt: "",
        updatedAt: "",
      })
    );
    assert.equal(store.isSharedLibraryPreset(saved), false);
    await fs.access(path.join(presets, "audition_ai_tmp123.json"));
    await assert.rejects(fs.access(path.join(library, "presets", "audition_ai_tmp123.json")));
  });
});
