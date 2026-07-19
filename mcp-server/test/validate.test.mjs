import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

import { responseCurve, validatePreset } from "../dist/validate.js";
import { DEFAULT_SAFETY_RULES } from "../dist/types.js";

const fixtureUrl = new URL("../../Tests/Fixtures/response-parity.json", import.meta.url);

test("responseCurve matches the shared Swift parity fixture", async () => {
  const fixture = JSON.parse(await readFile(fixtureUrl, "utf8"));
  const curve = responseCurve(fixture.preset, fixture.frequenciesHz, fixture.sampleRate);

  assert.equal(curve.length, fixture.expectedDb.length);
  for (let i = 0; i < curve.length; i += 1) {
    const actual = curve[i].magnitudeDb;
    const expected = fixture.expectedDb[i];
    const delta = Math.abs(actual - expected);
    assert.ok(
      delta <= fixture.toleranceDb,
      `response drift at ${fixture.frequenciesHz[i]} Hz: expected ${expected}, got ${actual}`
    );
  }
});

test("notch center uses the same finite dB floor as Swift", async () => {
  const fixture = JSON.parse(await readFile(fixtureUrl, "utf8"));
  const notchIndex = fixture.frequenciesHz.indexOf(6200);
  assert.notEqual(notchIndex, -1);

  const curve = responseCurve(fixture.preset, fixture.frequenciesHz, fixture.sampleRate);
  assert.ok(curve[notchIndex].magnitudeDb > -200);
  assert.ok(curve[notchIndex].magnitudeDb < -170);
});

test("validation reports low-bass, narrow-treble, and headroom warnings", () => {
  const preset = {
    id: "risky",
    name: "Risky",
    headphone: "Test",
    goal: "Validation warning coverage",
    preampDb: 0,
    bands: [
      { index: 1, type: "low_shelf", frequencyHz: 50, gainDb: 4.5, q: 0.7, channel: "stereo", enabled: true },
      { index: 2, type: "bell", frequencyHz: 7000, gainDb: 3.0, q: 5.0, channel: "stereo", enabled: true },
    ],
    safety: { autoGainEnabled: false, clippingRisk: "low" },
    createdBy: "ai",
    version: 1,
    tags: [],
    createdAt: "",
    updatedAt: "",
  };

  const result = validatePreset(preset, DEFAULT_SAFETY_RULES);
  const messages = result.issues.map((issue) => issue.message).join("\n");

  assert.equal(result.ok, true);
  assert.match(messages, /below 80 Hz/);
  assert.match(messages, /narrow boosted treble/);
  assert.match(messages, /Estimated peak/);
});
