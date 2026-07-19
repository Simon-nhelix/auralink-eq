import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { mkdtemp, readFile, rm, utimes, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

import {
  getCorrection,
  parseGraphicEQ,
  parseParametricEQ,
} from "../dist/autoeq.js";
import {
  measuredFIREligibility,
  responseCurve,
  validatePreset,
} from "../dist/validate.js";
import { DEFAULT_SAFETY_RULES } from "../dist/types.js";

const here = path.dirname(fileURLToPath(import.meta.url));
const parametricFixture = await readFile(
  path.join(here, "fixtures", "sennheiser-hd600-parametric-eq.txt"),
  "utf8"
);
const graphicFixture = await readFile(
  path.join(here, "fixtures", "sennheiser-hd600-graphic-eq.txt"),
  "utf8"
);

const metadata = {
  measurementId: "autoeq-hd600-oratory1990",
  source: "oratory1990",
  provenanceURL:
    "https://raw.githubusercontent.com/jaakkopasanen/AutoEq/master/results/oratory1990/over-ear/Sennheiser%20HD%20600/Sennheiser%20HD%20600%20GraphicEQ.txt",
};

test("HD600 GraphicEQ becomes a deterministic correction-only FIR payload", () => {
  const peq = parseParametricEQ(parametricFixture);
  const payload = parseGraphicEQ(graphicFixture, peq.preampDb, metadata);
  const again = parseGraphicEQ(graphicFixture.replaceAll("; ", ";\r\n"), peq.preampDb, metadata);

  assert.equal(peq.preampDb, -6.3);
  assert.equal(peq.bands.length, 10);
  assert.equal(payload.schemaVersion, 1);
  assert.equal(payload.sourceFormat, "autoeq_graphic_eq");
  assert.equal(payload.phaseData, "magnitude_only");
  assert.equal(payload.points.length, 127);
  assert.equal(payload.points[0].frequencyHz, 20);
  assert.ok(Math.abs(payload.points[0].gainDb - 6.1) < 1e-12);
  assert.equal(payload.usableLowHz, 40);
  assert.equal(payload.usableHighHz, 10_000);
  assert.equal(
    payload.contentHash,
    "3aefca2da9f0720dd64d53e46ff880a76a36c6cfa5af4a3a7b717af925f06c23"
  );
  assert.equal(again.contentHash, payload.contentHash);
  assert.deepEqual(again.points, payload.points);
});

test("measured response uses GraphicEQ baseline and applies preference bands only once", () => {
  const peq = parseParametricEQ(parametricFixture);
  const measuredCorrection = parseGraphicEQ(graphicFixture, peq.preampDb, metadata);
  const peqBands = peq.bands.map((band, index) => ({
    ...band,
    index: index + 1,
    channel: "stereo",
    enabled: true,
  }));
  const preference = {
    index: 11,
    type: "bell",
    frequencyHz: 1_000,
    gainDb: 1.5,
    q: 1,
    channel: "stereo",
    enabled: true,
  };
  const empty = Array.from({ length: 9 }, (_, offset) => ({
    index: offset + 12,
    type: "bell",
    frequencyHz: 2_000 + offset * 100,
    gainDb: 0,
    q: 1,
    channel: "stereo",
    enabled: false,
  }));
  const preset = {
    id: "hd600-measured",
    name: "HD600 Measured",
    preampDb: peq.preampDb,
    bands: [...peqBands, preference, ...empty],
    safety: { autoGainEnabled: false, clippingRisk: "low" },
    createdBy: "ai",
    version: 1,
    tags: [],
    createdAt: new Date(0).toISOString(),
    updatedAt: new Date(0).toISOString(),
    correction: {
      role: "combined",
      source: "AutoEq/oratory1990",
      sourceConfidence: "measured",
      correctionStrength: 1,
      targetBlend: 1,
      preferenceBandIndexes: [11],
      measuredCorrection,
    },
  };

  const frequencies = [100, 1_000, 8_000];
  const standard = responseCurve(preset, frequencies, 48_000, "standard_iir");
  const measured = responseCurve(preset, frequencies, 48_000, "hq_fir");
  assert.ok(measured.some((point, index) => Math.abs(point.magnitudeDb - standard[index].magnitudeDb) > 0.1));
  const measuredWithoutPreference = {
    ...preset,
    bands: preset.bands.map((band) => band.index === 11 ? { ...band, enabled: false } : band),
  };
  const baselineAt1k = responseCurve(measuredWithoutPreference, [1_000], 48_000, "hq_fir")[0].magnitudeDb;
  assert.ok(Math.abs((measured[1].magnitudeDb - baselineAt1k) - 1.5) < 0.05);
  const validation = validatePreset(preset, DEFAULT_SAFETY_RULES);
  assert.equal(validation.ok, true);
  assert.ok(validation.estimatedPeakGainDb >= 0);
});

test("Luxsin PEQ validation is unchanged by Auralink measured metadata", () => {
  const peq = parseParametricEQ(parametricFixture);
  const measuredCorrection = parseGraphicEQ(graphicFixture, peq.preampDb, metadata);
  const active = peq.bands.map((band, index) => ({
    ...band,
    index: index + 1,
    channel: "stereo",
    enabled: true,
  }));
  const disabled = Array.from({ length: 10 }, (_, offset) => ({
    index: offset + 11,
    type: "bell",
    frequencyHz: 11_000 + offset * 500,
    gainDb: 0,
    q: 1,
    channel: "stereo",
    enabled: false,
  }));
  const base = {
    id: "x8-isolation",
    name: "X8 isolation",
    preampDb: peq.preampDb,
    bands: [...active, ...disabled],
    safety: { autoGainEnabled: true, clippingRisk: "low" },
    createdBy: "ai",
    version: 1,
    tags: [],
    createdAt: new Date(0).toISOString(),
    updatedAt: new Date(0).toISOString(),
  };
  const measured = {
    ...base,
    correction: {
      role: "baseline",
      source: "AutoEq/oratory1990",
      sourceConfidence: "measured",
      correctionStrength: 1,
      targetBlend: 1,
      preferenceBandIndexes: [],
      measuredCorrection,
    },
  };
  const peqOnly = validatePreset(base, DEFAULT_SAFETY_RULES, 48_000, "standard_iir");
  const x8Measured = validatePreset(measured, DEFAULT_SAFETY_RULES, 48_000, "standard_iir");
  assert.deepEqual(x8Measured, peqOnly);
});

test("measured payload hash mismatch fails closed", () => {
  const peq = parseParametricEQ(parametricFixture);
  const measuredCorrection = parseGraphicEQ(graphicFixture, peq.preampDb, metadata);
  const preset = {
    id: "bad-hash",
    name: "Bad hash",
    preampDb: 0,
    bands: [],
    safety: { autoGainEnabled: false, clippingRisk: "low" },
    createdBy: "ai",
    version: 1,
    tags: [],
    createdAt: "",
    updatedAt: "",
    correction: {
      role: "baseline",
      sourceConfidence: "measured",
      correctionStrength: 1,
      targetBlend: 1,
      preferenceBandIndexes: [],
      measuredCorrection: { ...measuredCorrection, contentHash: "0".repeat(64) },
    },
  };
  assert.equal(measuredFIREligibility(preset).reason, "content_hash_mismatch");
  assert.equal(validatePreset(preset, DEFAULT_SAFETY_RULES).ok, false);
});

test("AutoEq cache handles fresh, stale, missing, corrupt, and refresh paths", async () => {
  const originalCacheDir = process.env.AURALINK_AUTOEQ_CACHE_DIR;
  const originalFetch = globalThis.fetch;
  const entryPath = "oratory1990/over-ear/Sennheiser%20HD%20600";
  const hash = createHash("sha1").update(entryPath).digest("hex").slice(0, 16);
  const index = `- [Sennheiser HD 600](./${entryPath}) by oratory1990 on GRAS 43AG-7\n`;

  async function makeCache() {
    const directory = await mkdtemp(path.join(os.tmpdir(), "auralink-autoeq-test-"));
    process.env.AURALINK_AUTOEQ_CACHE_DIR = directory;
    await writeFile(path.join(directory, "index.md"), index);
    await writeFile(path.join(directory, `correction-${hash}.txt`), parametricFixture);
    return directory;
  }

  try {
    let directory = await makeCache();
    await writeFile(path.join(directory, `graphic-${hash}.txt`), graphicFixture);
    globalThis.fetch = async () => { throw new Error("fresh cache should avoid network"); };
    let result = await getCorrection({ headphone: "HD600" });
    assert.equal(result.correction?.measuredCorrection?.points.length, 127);
    await rm(directory, { recursive: true, force: true });

    directory = await makeCache();
    await writeFile(path.join(directory, `graphic-${hash}.txt`), graphicFixture);
    const staleDate = new Date(Date.now() - 40 * 24 * 60 * 60 * 1_000);
    await Promise.all([
      "index.md",
      `correction-${hash}.txt`,
      `graphic-${hash}.txt`,
    ].map((name) => utimes(path.join(directory, name), staleDate, staleDate)));
    globalThis.fetch = async () => { throw new Error("offline"); };
    result = await getCorrection({ headphone: "HD600" });
    assert.equal(result.found, true);
    assert.equal(result.correction?.measuredCorrection?.contentHash.length, 64);
    await rm(directory, { recursive: true, force: true });

    directory = await makeCache();
    globalThis.fetch = async () => new Response("missing", { status: 404 });
    result = await getCorrection({ headphone: "HD600" });
    assert.equal(result.correction?.measuredCorrection, undefined);
    assert.match(result.correction?.conversionNotes.at(-1) ?? "", /Measured FIR data unavailable/);
    await rm(directory, { recursive: true, force: true });

    directory = await makeCache();
    await writeFile(path.join(directory, `graphic-${hash}.txt`), "not GraphicEQ");
    globalThis.fetch = async () => { throw new Error("corrupt cache should be reported"); };
    result = await getCorrection({ headphone: "HD600" });
    assert.equal(result.correction?.measuredCorrection, undefined);
    assert.match(result.correction?.conversionNotes.at(-1) ?? "", /GraphicEQ/);
    await rm(directory, { recursive: true, force: true });

    directory = await makeCache();
    await writeFile(path.join(directory, `graphic-${hash}.txt`), "not GraphicEQ");
    globalThis.fetch = async (url) => {
      const value = String(url);
      if (value.endsWith("INDEX.md")) return new Response(index, { status: 200 });
      if (value.includes("ParametricEQ.txt")) return new Response(parametricFixture, { status: 200 });
      if (value.includes("GraphicEQ.txt")) return new Response(graphicFixture, { status: 200 });
      return new Response("missing", { status: 404 });
    };
    result = await getCorrection({ headphone: "HD600", refresh: true });
    assert.equal(result.correction?.measuredCorrection?.points.length, 127);
    await rm(directory, { recursive: true, force: true });
  } finally {
    globalThis.fetch = originalFetch;
    if (originalCacheDir === undefined) delete process.env.AURALINK_AUTOEQ_CACHE_DIR;
    else process.env.AURALINK_AUTOEQ_CACHE_DIR = originalCacheDir;
  }
});

test("GraphicEQ parser rejects malformed, unordered, and under-covered input", () => {
  assert.throws(
    () => parseGraphicEQ("20 0; 40 0", -1, metadata),
    /GraphicEQ:/
  );
  assert.throws(
    () => parseGraphicEQ("GraphicEQ: 20 0; nope; 10000 0", -1, metadata),
    /Malformed/
  );
  const unordered = Array.from({ length: 16 }, (_, index) => {
    const frequency = index === 8 ? 100 : 20 + index * 20;
    return `${frequency} 0`;
  }).join("; ");
  assert.throws(
    () => parseGraphicEQ(`GraphicEQ: ${unordered}`, -1, metadata),
    /strictly increasing/
  );
  const shortCoverage = Array.from({ length: 16 }, (_, index) => `${100 + index * 100} 0`).join("; ");
  assert.throws(
    () => parseGraphicEQ(`GraphicEQ: ${shortCoverage}`, -1, metadata),
    /does not cover/
  );
});
