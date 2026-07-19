import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

import {
  responseCurve,
  responseCurveForChannel,
  validatePreset,
} from "../dist/validate.js";
import { DEFAULT_SAFETY_RULES } from "../dist/types.js";

const fixtureUrl = new URL("../../Tests/Fixtures/channel-response-parity.json", import.meta.url);

async function loadFixture() {
  return JSON.parse(await readFile(fixtureUrl, "utf8"));
}

test("opposed left and right bands remain independent", async () => {
  const fixture = await loadFixture();
  const frequencies = [fixture.centerHz];
  const left = responseCurveForChannel(fixture.preset, frequencies, fixture.sampleRate, "left");
  const right = responseCurveForChannel(fixture.preset, frequencies, fixture.sampleRate, "right");
  const folded = responseCurve(fixture.preset, frequencies, fixture.sampleRate);

  assert.ok(Math.abs(left[0].magnitudeDb - fixture.expected.leftDb) <= fixture.toleranceDb);
  assert.ok(Math.abs(right[0].magnitudeDb - fixture.expected.rightDb) <= fixture.toleranceDb);
  assert.ok(
    Math.abs(folded[0].magnitudeDb - fixture.expected.legacyFoldedDb) <= fixture.toleranceDb
  );
});

test("channel response includes preamp and only routed bands", async () => {
  const fixture = await loadFixture();
  const preset = { ...fixture.preset, preampDb: -3 };
  const frequencies = [fixture.centerHz];
  const left = responseCurveForChannel(preset, frequencies, fixture.sampleRate, "left");
  const right = responseCurveForChannel(preset, frequencies, fixture.sampleRate, "right");

  assert.ok(Math.abs(left[0].magnitudeDb - (fixture.expected.leftDb - 3)) <= fixture.toleranceDb);
  assert.ok(Math.abs(right[0].magnitudeDb - (fixture.expected.rightDb - 3)) <= fixture.toleranceDb);
});

test("stereo band contributes to both output channels", async () => {
  const fixture = await loadFixture();
  const preset = {
    ...fixture.preset,
    bands: [
      {
        index: 10,
        type: "bell",
        frequencyHz: fixture.centerHz,
        gainDb: 6,
        q: 1,
        channel: "stereo",
        enabled: true,
      },
    ],
  };
  const frequencies = [fixture.centerHz];
  const left = responseCurveForChannel(preset, frequencies, fixture.sampleRate, "left");
  const right = responseCurveForChannel(preset, frequencies, fixture.sampleRate, "right");

  assert.ok(Math.abs(left[0].magnitudeDb - 6) <= fixture.toleranceDb);
  assert.ok(Math.abs(right[0].magnitudeDb - 6) <= fixture.toleranceDb);
});

test("validator uses the maximum actual channel peak", async () => {
  const fixture = await loadFixture();
  const result = validatePreset(fixture.preset, DEFAULT_SAFETY_RULES, fixture.sampleRate);

  assert.equal(result.estimatedPeakGainDb, fixture.expected.validatorPeakDb);
  assert.equal(result.suggestedPreampDb, fixture.expected.suggestedPreampDb);
  assert.equal(result.clippingRisk, "high");
  assert.ok(result.issues.some((issue) => /Combined response boost peaks/.test(issue.message)));
});

test("shelf validation labels the existing parameter as Q", async () => {
  const fixture = await loadFixture();
  const preset = {
    ...fixture.preset,
    bands: [
      {
        index: 1,
        type: "low_shelf",
        frequencyHz: 100,
        gainDb: 3,
        q: 11,
        channel: "stereo",
        enabled: true,
      },
    ],
  };
  const result = validatePreset(preset, DEFAULT_SAFETY_RULES, fixture.sampleRate);
  const qIssue = result.issues.find((issue) => issue.bandIndex === 1 && issue.severity === "error");

  assert.ok(qIssue);
  assert.match(qIssue.message, /Q 11\.00/);
  assert.doesNotMatch(qIssue.message, /slope/i);
});
