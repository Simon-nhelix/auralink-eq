import assert from "node:assert/strict";
import test from "node:test";

import { bandToX8Filter, selectBandsForX8, buildX8Change } from "../dist/targets/luxsin/adapter.js";

/** Helper: build an Auralink EQBand. */
function band(i, type, frequencyHz, gainDb, q = 1.0, enabled = true) {
  return { index: i, type, frequencyHz, gainDb, q, channel: "stereo", enabled };
}

test("bandToX8Filter maps every Auralink shape to the X8 vocabulary", () => {
  const cases = [
    ["bell", "PEAKING"],
    ["low_shelf", "LOW_SHELF"],
    ["high_shelf", "HIGH_SHELF"],
    ["low_pass", "LOW_PASS"],
    ["high_pass", "HIGH_PASS"],
    ["notch", "NOTCH"],
  ];
  for (const [a8, x8] of cases) {
    const f = bandToX8Filter(band(1, a8, 1000, -2.5, 0.7));
    assert.equal(f.type, x8);
    assert.equal(f.fc, 1000);
    assert.equal(f.gain, -2.5);
    assert.equal(f.q, 0.7);
  }
});

test("selectBandsForX8 keeps everything when under the limit", () => {
  const bands = [band(1, "low_shelf", 80, 3), band(2, "bell", 1000, -2), band(3, "high_shelf", 8000, -1)];
  const { kept, dropped, notes } = selectBandsForX8(bands);
  assert.equal(kept.length, 3);
  assert.equal(dropped.length, 0);
  assert.equal(notes.length, 0);
});

test("selectBandsForX8 drops disabled bands first", () => {
  const bands = [
    band(1, "bell", 100, 5),
    band(2, "bell", 200, 4, 1, false), // disabled
  ];
  const { kept, dropped } = selectBandsForX8(bands);
  assert.equal(kept.length, 1);
  assert.equal(kept[0].frequencyHz, 100);
  assert.equal(dropped.length, 1);
});

test("selectBandsForX8 trims 20→10, preserving shelves and highest-impact bells", () => {
  // 2 structural shelves + 18 bells with varying gains.
  const bands = [
    band(1, "low_shelf", 60, 4),
    band(2, "high_shelf", 9000, -3),
    ...Array.from({ length: 18 }, (_, k) => band(k + 3, "bell", 100 + k * 500, (k - 9))), // gains -9..+8
  ];
  const { kept, dropped } = selectBandsForX8(bands, 10);
  assert.equal(kept.length, 10, "exactly maxBands kept");
  assert.equal(dropped.length, 10, "the rest dropped");

  // both shelves preserved
  const shelfTypes = kept.filter((b) => b.type === "low_shelf" || b.type === "high_shelf").map((b) => b.type);
  assert.deepEqual([...new Set(shelfTypes)].sort(), ["high_shelf", "low_shelf"]);

  // kept bells are the 8 highest |gain|: |k-9| for k=0..17 → max |gain| are at the ends.
  // gains: k0=-9,k1=-8,...,k8=-1,k9=0,k10=1,...,k17=8. Top 8 by |gain|: -9,-8,-8? compute set.
  const keptBellGains = kept.filter((b) => b.type === "bell").map((b) => b.gainDb).sort((a, b) => a - b);
  assert.equal(keptBellGains.length, 8);
  // The 8 largest |gain| bells: -9,-8,-7,-6,-7? Let's assert by checking the smallest |gain| dropped is <= smallest |gain| kept.
  const keptMinAbs = Math.min(...keptBellGains.map(Math.abs));
  const droppedBellGains = dropped.filter((b) => b.type === "bell").map((b) => b.gainDb);
  const droppedMaxAbs = Math.max(...droppedBellGains.map(Math.abs));
  assert.ok(keptMinAbs >= droppedMaxAbs, "every kept bell has |gain| >= every dropped bell");
});

test("buildX8Change produces a peqChange payload with numeric filter type codes", () => {
  const { payload, appliedBands, notes } = buildX8Change({
    headphone: "Sennheiser HD600",
    form: "over-ear",
    targetCurve: "crinacle EARS + 711 Harman over-ear 2018",
    preampDb: -1.2,
    bands: [band(1, "low_shelf", 80, 3), band(2, "bell", 1000, -2), band(3, "notch", 6000, -8, 4)],
  });
  // name + write-side fields only
  assert.equal(payload.name, "Sennheiser HD600");
  assert.equal(payload.autoPre, 0);
  assert.equal(payload.preamp, -1.2);
  assert.equal(payload.canDel, 1);
  assert.ok(Array.isArray(payload.filters), "filters is an array (not a JSON string) on the write path");
  assert.equal(payload.filters.length, 10, "X8 write payload is always padded to exactly 10 filters");
  // numeric type codes for the real filters: low_shelf=5, bell=4, notch=3
  assert.deepEqual(payload.filters.slice(0, 3).map((f) => f.type), [5, 4, 3]);
  assert.equal(payload.filters[0].fc, 80);
  // padding filters are transparent PEAKING 0dB, never LOW_PASS@0.
  for (const f of payload.filters.slice(3)) {
    assert.equal(f.type, 4);
    assert.equal(f.gain, 0);
    assert.equal(f.q, 1);
    assert.notEqual(f.fc, 0);
  }
  assert.equal(appliedBands.length, 3);
  assert.equal(notes.some((n) => n.includes("padded 3→10")), true);
});
