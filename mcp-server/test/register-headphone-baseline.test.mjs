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
  process.env.AURALINK_REVISIONS_DIR = path.join(tmp, "revisions");
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

test("registration with preferences saves a pure baseline and a separate linked tuning", async () => {
  await withTempEnv(async ({ registerHeadphoneBaseline }, { collection }) => {
    const result = await registerHeadphoneBaseline({
      headphone: "Example IEM", type: "iem", bands: explicitBands,
      preferenceBands: [{ index: 1, type: "low_shelf", frequencyHz: 80, gainDb: 2 }],
    });
    assert.equal(result.ok, true);
    const baseline = JSON.parse(await fs.readFile(result.written.baseline, "utf8"));
    const tuning = JSON.parse(await fs.readFile(result.written.preset, "utf8"));
    assert.notEqual(baseline.id, tuning.id);
    assert.equal(baseline.correction.role, "baseline");
    assert.deepEqual(baseline.correction.preferenceBandIndexes, []);
    assert.equal(baseline.bands.filter(b => b.enabled).length, 2);
    assert.equal(tuning.correction.role, "combined");
    assert.equal(tuning.correction.baselinePresetId, baseline.id);
    assert.deepEqual(tuning.correction.preferenceBandIndexes, [3]);
    assert.deepEqual(tuning.bands.slice(0, 2), baseline.bands.slice(0, 2));
    assert.equal((await fs.readdir(path.join(collection, "presets"))).length, 2);

    const original = await fs.readFile(result.written.baseline, "utf8");
    const second = await registerHeadphoneBaseline({
      headphone: "Example IEM", type: "iem", bands: [{ frequencyHz: 500, gainDb: 1 }],
      preferenceLabel: "Vocal", preferenceBands: [{ frequencyHz: 2500, gainDb: -1 }],
    });
    assert.equal(second.baselineReused, true);
    assert.notEqual(second.preset.id, tuning.id);
    assert.equal(await fs.readFile(result.written.baseline, "utf8"), original);
    assert.deepEqual(second.baseline.bands, baseline.bands);
  });
});

test("too many preference bands fail before writing a partial registration", async () => {
  await withTempEnv(async ({ registerHeadphoneBaseline }, { collection, presets }) => {
    await assert.rejects(registerHeadphoneBaseline({
      headphone: "Full Can", type: "open_back",
      bands: Array.from({ length: 20 }, (_, i) => ({ frequencyHz: 100 + i * 100, gainDb: -1 })),
      preferenceBands: [{ frequencyHz: 80, gainDb: 1 }],
    }), /baseline bands cannot be replaced or dropped/);
    assert.deepEqual(await fs.readdir(path.join(collection, "headphones")), []);
    assert.deepEqual(await fs.readdir(path.join(collection, "presets")), []);
    assert.deepEqual(await fs.readdir(presets), []);
  });
});

test("AutoEq registration preserves measured FIR in both baseline and preference copy", async () => {
  const { parseGraphicEQ, parseParametricEQ } = await import("../dist/autoeq.js");
  const peq = parseParametricEQ(await fs.readFile(path.join(here, "fixtures", "sennheiser-hd600-parametric-eq.txt"), "utf8"));
  const measuredCorrection = parseGraphicEQ(
    await fs.readFile(path.join(here, "fixtures", "sennheiser-hd600-graphic-eq.txt"), "utf8"),
    peq.preampDb,
    { measurementId: "hd600", source: "oratory1990", provenanceURL: "https://example.test/hd600" }
  );
  await withTempEnv(async ({ registerHeadphoneBaseline }) => {
    const result = await registerHeadphoneBaseline({
      headphone: "Sennheiser HD 600", preferenceBands: [{ frequencyHz: 2000, gainDb: -1 }],
    }, {
      getAutoEqCorrection: async () => ({ found: true, suggestions: [], alternates: [], correction: {
        name: "Sennheiser HD 600", source: "oratory1990", url: "https://example.test/hd600",
        ...peq, measuredCorrection,
      } }),
    });
    assert.equal(result.ok, true);
    const tuning = JSON.parse(await fs.readFile(result.written.preset, "utf8"));
    assert.deepEqual(result.baseline.correction.measuredCorrection, measuredCorrection);
    assert.deepEqual(tuning.correction.measuredCorrection, JSON.parse(JSON.stringify(measuredCorrection)));
    assert.deepEqual(tuning.correction.preferenceBandIndexes, [11]);
    assert.equal(result.baseline.preampDb, peq.preampDb);
  });
});

test("legacy mixed baseline id is preserved while a separate pure baseline is registered", async () => {
  await withTempEnv(async ({ registerHeadphoneBaseline }) => {
    const store = await import("../dist/store.js");
    const first = await registerHeadphoneBaseline({ headphone: "Legacy Can", type: "iem", bands: explicitBands });
    const legacy = await store.savePreset({
      ...first.baseline, correction: { ...first.baseline.correction, role: "combined", preferenceBandIndexes: [2] },
    });
    await store.addPresetToCollection(legacy.id);
    const next = await registerHeadphoneBaseline({ headphone: "Legacy Can", type: "iem", bands: explicitBands });
    assert.equal(next.ok, true);
    assert.notEqual(next.baseline.id, legacy.id);
    assert.deepEqual(await store.getPreset(legacy.id), legacy);
    assert.equal(next.baseline.correction.role, "baseline");
    const repeat = await registerHeadphoneBaseline({ headphone: "Legacy Can", type: "iem", bands: explicitBands });
    assert.equal(repeat.baseline.id, next.baseline.id);
    assert.equal(repeat.baselineReused, true);
  });
});

test("registration respects sparse baseline slots without dropping auto-assigned bands", async () => {
  await withTempEnv(async ({ registerHeadphoneBaseline }) => {
    const result = await registerHeadphoneBaseline({
      headphone: "Sparse Can", type: "iem",
      bands: [{ frequencyHz: 100, gainDb: -1 }, { index: 1, frequencyHz: 200, gainDb: -2 }],
      preferenceBands: [{ index: 1, frequencyHz: 300, gainDb: -3 }],
    });
    assert.equal(result.ok, true);
    assert.equal(result.baseline.bands[0].frequencyHz, 200);
    assert.equal(result.baseline.bands[1].frequencyHz, 100);
    assert.deepEqual(result.preset.preferenceBandIndexes, [3]);
  });
});

test("AutoEq results cannot silently be relabeled as another target", async () => {
  await withTempEnv(async ({ registerHeadphoneBaseline }, { collection }) => {
    await assert.rejects(registerHeadphoneBaseline({
      headphone: "Sennheiser HD 600", targetCurveId: "crinacle-ief-2025",
    }), /AutoEq supplies Harman/);
    assert.deepEqual(await fs.readdir(path.join(collection, "presets")), []);
  });
});
