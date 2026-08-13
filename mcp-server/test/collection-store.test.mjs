import assert from "node:assert/strict";
import { promises as fs } from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const dist = path.resolve(here, "..", "dist");

/**
 * Runs `fn` against a scratch collection + working preset directory.
 *
 * The collection is the user's own directory (a git checkout in practice) and the
 * working preset dir is machine-local, so these tests care mostly about which of
 * the two a write lands in.
 */
async function withTempEnv(fn) {
  const tmp = await fs.mkdtemp(path.join(os.tmpdir(), "auralink-collection-"));
  const collection = path.join(tmp, "collection");
  const userData = path.join(tmp, "user-data");
  const presets = path.join(tmp, "presets");
  const data = path.join(tmp, "bundled-data");
  await fs.mkdir(path.join(collection, "headphones"), { recursive: true });
  await fs.mkdir(path.join(collection, "presets"), { recursive: true });
  await fs.mkdir(userData, { recursive: true });
  await fs.mkdir(presets, { recursive: true });
  await fs.mkdir(data, { recursive: true });

  const prev = { ...process.env };
  delete process.env.AURALINK_LIBRARY_DIR;
  process.env.AURALINK_COLLECTION_DIR = collection;
  process.env.AURALINK_USER_DATA_DIR = userData;
  process.env.AURALINK_PRESETS_DIR = presets;
  process.env.AURALINK_DATA_DIR = data;

  try {
    // Dynamic import after env is set (store resolves dirs at call time).
    const store = await import(path.join(dist, "store.js"));
    await fn(store, { tmp, collection, userData, presets, data });
  } finally {
    process.env = prev;
    await fs.rm(tmp, { recursive: true, force: true });
  }
}

function samplePreset(store, overrides = {}) {
  const bands = store.bandsFromSpecs([
    { type: "low_shelf", frequencyHz: 105, gainDb: 2, q: 0.7 },
  ]);
  return store.normalizePreset({
    id: "preset_sample",
    name: "Sample",
    goal: "unit test",
    preampDb: -2,
    bands,
    safety: { autoGainEnabled: false, clippingRisk: "low" },
    createdBy: "ai",
    version: 1,
    tags: ["ai"],
    createdAt: "",
    updatedAt: "",
    ...overrides,
  });
}

test("collection root resolution honors AURALINK_COLLECTION_DIR", async () => {
  await withTempEnv(async (store, { collection }) => {
    assert.equal(path.resolve(store.collectionDir()), path.resolve(collection));
    assert.equal(store.collectionHeadphonesDir(), path.join(collection, "headphones"));
    assert.equal(store.collectionPresetsDir(), path.join(collection, "presets"));
    assert.equal(store.collectionManifestPath(), path.join(collection, "manifest.json"));
  });
});

test("saveHeadphoneProfile writes one file into the collection", async () => {
  await withTempEnv(async (store, { collection, userData }) => {
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

    const file = path.join(collection, "headphones", "test-can-one.json");
    assert.equal(JSON.parse(await fs.readFile(file, "utf8")).id, "test-can-one");

    // No aggregate rewrite: the per-file collection is the whole story now.
    await assert.rejects(fs.access(path.join(userData, "headphone-profiles.json")));

    const loaded = await store.loadHeadphoneProfiles();
    assert.equal(loaded.length, 1);
    assert.equal(loaded[0].id, "test-can-one");
  });
});

test("deleting a profile removes the file, with no tombstone left behind", async () => {
  await withTempEnv(async (store, { collection, userData }) => {
    await store.saveHeadphoneProfile({
      id: "test-can-two",
      brand: "Test",
      model: "Can Two",
      type: "iem",
      signature: "test",
      correctionNotes: [],
      harshRegionsHz: [],
      source: "unit test",
      credibility: "estimated",
    });

    const deleted = await store.deleteHeadphoneProfile("test-can-two");
    assert.equal(deleted.id, "test-can-two");
    await assert.rejects(fs.access(path.join(collection, "headphones", "test-can-two.json")));
    await assert.rejects(fs.access(path.join(userData, "deleted-headphone-profiles.json")));
    assert.deepEqual(await store.loadHeadphoneProfiles(), []);
  });
});

test("bundled data dir is no longer a headphone profile source", async () => {
  await withTempEnv(async (store, { data }) => {
    await fs.writeFile(
      path.join(data, "headphone-profiles.json"),
      JSON.stringify([
        {
          id: "shipped-can",
          brand: "Shipped",
          model: "Can",
          type: "open_back",
          signature: "should not appear",
          correctionNotes: [],
          harshRegionsHz: [],
          source: "bundle",
          credibility: "estimated",
        },
      ])
    );
    assert.deepEqual(await store.loadHeadphoneProfiles(), []);
  });
});

test("savePreset writes only the working copy, never the collection", async () => {
  await withTempEnv(async (store, { collection, presets }) => {
    const saved = await store.savePreset(
      samplePreset(store, {
        id: "ai_test-can-one_harman-neutral",
        tags: ["ai", "baseline", "harman-neutral"],
      })
    );
    assert.equal(saved.id, "ai_test-can-one_harman-neutral");

    await fs.access(path.join(presets, "ai_test-can-one_harman-neutral.json"));
    // An `ai_`/baseline id used to be auto-mirrored by a tag heuristic. It must not be.
    await assert.rejects(
      fs.access(path.join(collection, "presets", "ai_test-can-one_harman-neutral.json"))
    );
    assert.deepEqual(await store.collectionPresetIds(), []);
  });
});

test("addPresetToCollection is the only way in, and is reversible", async () => {
  await withTempEnv(async (store, { collection, presets }) => {
    await store.savePreset(samplePreset(store, { id: "preset_promote" }));

    const added = await store.addPresetToCollection("preset_promote");
    assert.equal(added.id, "preset_promote");
    await fs.access(path.join(collection, "presets", "preset_promote.json"));
    assert.deepEqual(await store.collectionPresetIds(), ["preset_promote"]);

    assert.equal(await store.removePresetFromCollection("preset_promote"), true);
    assert.deepEqual(await store.collectionPresetIds(), []);
    // The working copy survives leaving the collection.
    await fs.access(path.join(presets, "preset_promote.json"));
  });
});

test("addPresetToCollection reports a miss instead of writing junk", async () => {
  await withTempEnv(async (store, { collection }) => {
    assert.equal(await store.addPresetToCollection("preset_missing"), null);
    assert.equal(await store.removePresetFromCollection("preset_missing"), false);
    assert.deepEqual(await fs.readdir(path.join(collection, "presets")), []);
  });
});

test("collection-only presets are visible to loadAllPresets and getPreset", async () => {
  await withTempEnv(async (store, { collection }) => {
    // Simulates a fresh `git clone` of someone's collection.
    await fs.writeFile(
      path.join(collection, "presets", "preset_cloned.json"),
      JSON.stringify(samplePreset(store, { id: "preset_cloned", name: "Cloned" }))
    );

    const all = await store.loadAllPresets();
    assert.equal(all.some((p) => p.id === "preset_cloned"), true);
    assert.equal((await store.getPreset("preset_cloned")).name, "Cloned");
    assert.equal(await store.presetExists("preset_cloned"), true);
  });
});

test("the working copy shadows the collection on an id collision", async () => {
  await withTempEnv(async (store, { collection }) => {
    await fs.writeFile(
      path.join(collection, "presets", "preset_shared.json"),
      JSON.stringify(samplePreset(store, { id: "preset_shared", name: "Collection Version" }))
    );
    await store.savePreset(samplePreset(store, { id: "preset_shared", name: "Local Edit" }));

    const matches = (await store.loadAllPresets()).filter((p) => p.id === "preset_shared");
    assert.equal(matches.length, 1);
    assert.equal(matches[0].name, "Local Edit");
  });
});

test("deletePreset clears the collection copy so the delete sticks", async () => {
  await withTempEnv(async (store, { collection }) => {
    await store.savePreset(samplePreset(store, { id: "preset_gone" }));
    await store.addPresetToCollection("preset_gone");

    const deleted = await store.deletePreset("preset_gone");
    assert.equal(deleted.id, "preset_gone");
    await assert.rejects(fs.access(path.join(collection, "presets", "preset_gone.json")));
    assert.equal(await store.getPreset("preset_gone"), null);
    assert.equal((await store.loadAllPresets()).some((p) => p.id === "preset_gone"), false);
  });
});

test("a missing collection directory is tolerated, not fatal", async () => {
  await withTempEnv(async (store, { tmp }) => {
    process.env.AURALINK_COLLECTION_DIR = path.join(tmp, "not-cloned-yet");
    assert.deepEqual(await store.loadHeadphoneProfiles(), []);
    assert.deepEqual(await store.collectionPresetIds(), []);
    assert.deepEqual(await store.loadAllPresets(), []);
  });
});

test("AURALINK_LIBRARY_DIR still resolves as the pre-split name", async () => {
  await withTempEnv(async (store, { tmp }) => {
    const legacy = path.join(tmp, "legacy-library");
    delete process.env.AURALINK_COLLECTION_DIR;
    process.env.AURALINK_LIBRARY_DIR = legacy;
    assert.equal(path.resolve(store.collectionDir()), path.resolve(legacy));
  });
});
