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
    const mod = await import(path.join(dist, "register-headphone-baseline.js"));
    const offline = async () => ({ online: false, error: "test" });
    const registerHeadphoneBaseline = (input, deps = {}) =>
      mod.registerHeadphoneBaseline(input, {
        reloadKnowledge: offline,
        reloadPresets: offline,
        ...deps,
      });
    await fn({ registerHeadphoneBaseline }, { tmp, library, runtimeLibrary, userData, presets, data });
  } finally {
    process.env = prev;
    await fs.rm(tmp, { recursive: true, force: true });
  }
}

const explicitBands = [
  { type: "low_shelf", frequencyHz: 51, gainDb: -2.7, q: 0.75 },
  { type: "bell", frequencyHz: 159, gainDb: -1.2, q: 1.26 },
];

test("explicit bands dual-write library JSON only (no seed, no x8)", async () => {
  await withTempEnv(async ({ registerHeadphoneBaseline }, { library, data }) => {
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
    assert.equal(result.seed?.skipped, true);
    assert.match(result.written.headphone, /symphonium-audio-zenith\.json$/);
    assert.match(result.written.preset, /ai_symphonium-audio-zenith_crinacle-ief-2025\.json$/);

    const hp = JSON.parse(await fs.readFile(result.written.headphone, "utf8"));
    const preset = JSON.parse(await fs.readFile(result.written.preset, "utf8"));
    assert.equal(hp.id, "symphonium-audio-zenith");
    assert.equal(hp.credibility, "measured");
    assert.equal(hp.suggestedTargetCurveId, "crinacle-ief-2025");
    assert.equal(preset.preampDb, -4.5);
    assert.equal(preset.bands.filter((b) => b.enabled).length, 2);

    const libEntries = await fs.readdir(path.join(library, "headphones"));
    assert.deepEqual(libEntries, ["symphonium-audio-zenith.json"]);
    const seed = await fs.readFile(path.join(data, "headphone-profiles.json"), "utf8");
    assert.equal(seed.trim(), "[]");
  });
});

test("explicit bands without type fail closed", async () => {
  await withTempEnv(async ({ registerHeadphoneBaseline }, { library }) => {
    const result = await registerHeadphoneBaseline({
      headphone: "Mystery Can",
      bands: explicitBands,
    });
    assert.equal(result.ok, false);
    assert.equal(result.reason, "type_required");
    const leftover = await fs.readdir(path.join(library, "headphones"));
    assert.deepEqual(leftover, []);
  });
});

test("AutoEq miss without bands returns autoeq_not_found", async () => {
  await withTempEnv(async ({ registerHeadphoneBaseline }, { library }) => {
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
    const leftover = await fs.readdir(path.join(library, "headphones"));
    assert.deepEqual(leftover, []);
  });
});

test("AutoEq path does not write seed or x8 by default", async () => {
  await withTempEnv(async ({ registerHeadphoneBaseline }, { data }) => {
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
    assert.equal(result.seed.skipped, true);
    assert.equal(result.preset.id, "ai_sennheiser-hd-600_harman-neutral");
    const seed = await fs.readFile(path.join(data, "headphone-profiles.json"), "utf8");
    assert.equal(seed.trim(), "[]");
  });
});
