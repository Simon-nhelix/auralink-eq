import assert from "node:assert/strict";
import { promises as fs } from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const dist = path.resolve(here, "..", "dist");

async function withTempEnv(fn) {
  const tmp = await fs.mkdtemp(path.join(os.tmpdir(), "auralink-register-"));
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
    const mod = await import(path.join(dist, "register-headphone-baseline.js"));
    const offline = async () => ({ online: false, error: "test" });
    const registerHeadphoneBaseline = (input, deps = {}) =>
      mod.registerHeadphoneBaseline(input, {
        reloadKnowledge: offline,
        reloadPresets: offline,
        ...deps,
      });
    await fn({ registerHeadphoneBaseline }, { tmp, collection, userData, presets, data });
  } finally {
    process.env = prev;
    await fs.rm(tmp, { recursive: true, force: true });
  }
}

const explicitBands = [
  { type: "low_shelf", frequencyHz: 51, gainDb: -2.7, q: 0.75 },
  { type: "bell", frequencyHz: 159, gainDb: -1.2, q: 1.26 },
];

test("explicit bands write profile + baseline into the collection (no x8)", async () => {
  await withTempEnv(async ({ registerHeadphoneBaseline }, { collection, presets }) => {
    const result = await registerHeadphoneBaseline({
      headphone: "Symphonium Audio Zenith",
      brand: "Symphonium Audio",
      model: "Zenith",
      type: "iem",
      targetCurveId: "crinacle-ief-2025",
      bands: explicitBands,
      provenance: "Super* Review clone-IEC711, squig.link, 2026-05-21",
      credibility: "measured",
      preampDb: -4.5,
      signature: "sub-bass-forward 4BA IEM",
    });

    assert.equal(result.ok, true);
    assert.equal("x8" in result, false);
    assert.equal(result.collectionDir, collection);
    assert.equal(result.preset.inCollection, true);
    assert.match(result.written.headphone, /symphonium-audio-zenith\.json$/);
    assert.match(result.written.preset, /ai_symphonium-audio-zenith_crinacle-ief-2025\.json$/);

    const hp = JSON.parse(await fs.readFile(result.written.headphone, "utf8"));
    const preset = JSON.parse(await fs.readFile(result.written.preset, "utf8"));
    assert.equal(hp.id, "symphonium-audio-zenith");
    assert.equal(hp.credibility, "measured");
    assert.equal(hp.suggestedTargetCurveId, "crinacle-ief-2025");
    assert.equal(preset.preampDb, -4.5);
    assert.equal(preset.bands.filter((b) => b.enabled).length, 2);

    // Both halves land where they belong: profile + baseline in the collection,
    // and a working copy so the running app can load it.
    assert.deepEqual(await fs.readdir(path.join(collection, "headphones")), [
      "symphonium-audio-zenith.json",
    ]);
    await fs.access(
      path.join(presets, "ai_symphonium-audio-zenith_crinacle-ief-2025.json")
    );
  });
});

test("registration never writes back into the app's bundled data", async () => {
  await withTempEnv(async ({ registerHeadphoneBaseline }, { data }) => {
    const before = await fs.readdir(data);
    await registerHeadphoneBaseline({
      headphone: "Symphonium Audio Zenith",
      type: "iem",
      bands: explicitBands,
      credibility: "measured",
    });
    assert.deepEqual(await fs.readdir(data), before);
  });
});

test("explicit bands without type fail closed", async () => {
  await withTempEnv(async ({ registerHeadphoneBaseline }, { collection }) => {
    const result = await registerHeadphoneBaseline({
      headphone: "Mystery Can",
      bands: explicitBands,
    });
    assert.equal(result.ok, false);
    assert.equal(result.reason, "type_required");
    assert.deepEqual(await fs.readdir(path.join(collection, "headphones")), []);
  });
});

test("AutoEq miss without bands returns autoeq_not_found", async () => {
  await withTempEnv(async ({ registerHeadphoneBaseline }, { collection }) => {
    const result = await registerHeadphoneBaseline(
      { headphone: "Not A Real Headphone" },
      {
        getAutoEqCorrection: async () => ({
          found: false,
          suggestions: ["Sennheiser HD 600"],
          alternates: [],
        }),
      }
    );
    assert.equal(result.ok, false);
    assert.equal(result.reason, "autoeq_not_found");
    assert.deepEqual(result.suggestions, ["Sennheiser HD 600"]);
    assert.deepEqual(await fs.readdir(path.join(collection, "headphones")), []);
  });
});

test("AutoEq path lands in the collection without touching x8", async () => {
  await withTempEnv(async ({ registerHeadphoneBaseline }, { collection }) => {
    const result = await registerHeadphoneBaseline(
      {
        headphone: "Sennheiser HD 600",
        brand: "Sennheiser",
        model: "HD 600",
        type: "open_back",
      },
      {
        getAutoEqCorrection: async () => ({
          found: true,
          suggestions: [],
          alternates: [],
          correction: {
            name: "Sennheiser HD 600",
            source: "oratory1990",
            preampDb: -6.2,
            bands: [{ type: "bell", frequencyHz: 105, gainDb: -1.2, q: 0.7 }],
            url: "https://example.test/hd600",
            conversionNotes: [],
          },
        }),
      }
    );
    assert.equal(result.ok, true);
    assert.equal("x8" in result, false);
    assert.equal(result.preset.id, "ai_sennheiser-hd-600_harman-neutral");
    assert.equal(result.preset.inCollection, true);
    await fs.access(
      path.join(collection, "presets", "ai_sennheiser-hd-600_harman-neutral.json")
    );
  });
});

test("validation failure leaves no orphan profile in the collection", async () => {
  await withTempEnv(async ({ registerHeadphoneBaseline }, { collection, presets }) => {
    // An invalid measuredCorrection payload (bad content hash) produces a
    // validation error. Before the fix, the profile was written BEFORE this
    // validation ran, leaving an orphan profile with no baseline preset.
    const result = await registerHeadphoneBaseline(
      {
        headphone: "Broken FIR Can",
        brand: "Broken",
        model: "FIR Can",
        type: "open_back",
      },
      {
        getAutoEqCorrection: async () => ({
          found: true,
          suggestions: [],
          alternates: [],
          correction: {
            name: "Broken FIR Can",
            source: "oratory1990",
            preampDb: -3,
            bands: [{ type: "bell", frequencyHz: 105, gainDb: -1.2, q: 0.7 }],
            url: "https://example.test/broken",
            conversionNotes: [],
            measuredCorrection: {
              schemaVersion: 1,
              measurementId: "broken",
              sourceFormat: "autoeq_graphic_eq",
              source: "oratory1990",
              provenanceURL: "https://example.test/broken",
              sourcePreampDb: -3,
              contentHash: "0".repeat(64), // invalid: does not match computed hash
              channel: "stereo",
              phaseData: "magnitude_only",
              usableLowHz: 20,
              usableHighHz: 20000,
              points: Array.from({ length: 20 }, (_, i) => ({
                frequencyHz: 20 * Math.pow(1000, i / 19),
                gainDb: 0,
              })),
            },
          },
        }),
      }
    );
    assert.equal(result.ok, false);
    assert.equal(result.reason, "validation_failed");
    // The critical assertion: no orphan profile and no preset on disk.
    assert.deepEqual(await fs.readdir(path.join(collection, "headphones")), []);
    assert.deepEqual(await fs.readdir(path.join(collection, "presets")), []);
    assert.deepEqual(await fs.readdir(presets), []);
  });
});
