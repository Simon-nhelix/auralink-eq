import assert from "node:assert/strict";
import test from "node:test";

import {
  acceptedRollbackTarget,
  evaluateAuralinkLiveRequest,
  pollAuralinkLiveVerification,
} from "../dist/live-verification.js";

const activeState = {
  eqEnabled: true,
  hqCorrectionMode: true,
  hqCorrectionRequested: true,
  requestedRenderGeneration: 7,
  committedRenderGeneration: 7,
  currentPresetId: "expected",
  routingActive: true,
  systemOutputRoutedToAuralink: true,
};

test("rollback requires an explicit successful target identity", () => {
  assert.equal(acceptedRollbackTarget({ ok: false }), undefined);
  assert.equal(acceptedRollbackTarget({ ok: true }), undefined);
  assert.equal(acceptedRollbackTarget({ ok: true, presetId: "" }), undefined);
  assert.equal(acceptedRollbackTarget({ ok: true, presetId: "target" }), "target");
});

test("control acceptance alone never claims an audible change", () => {
  assert.equal(evaluateAuralinkLiveRequest(true, undefined, "expected").audible, false);
  assert.equal(evaluateAuralinkLiveRequest(false, activeState, "expected").audible, false);
});

test("live verification requires routed path, EQ, preset, and renderer commit", () => {
  const cases = [
    { ...activeState, routingActive: false },
    { ...activeState, systemOutputRoutedToAuralink: false },
    { ...activeState, eqEnabled: false },
    { ...activeState, currentPresetId: "other" },
    { ...activeState, hqCorrectionMode: false, hqCorrectionRequested: true },
    { ...activeState, hqCorrectionMode: true, hqCorrectionRequested: false },
    { ...activeState, requestedRenderGeneration: 8, committedRenderGeneration: 7 },
    { ...activeState, requestedRenderGeneration: undefined, committedRenderGeneration: undefined },
  ];
  for (const state of cases) {
    assert.equal(evaluateAuralinkLiveRequest(true, state, "expected", 7).audible, false);
  }
});

test("live verification reports audible only after exact committed state", () => {
  const measured = evaluateAuralinkLiveRequest(true, activeState, "expected", 7);
  assert.equal(measured.audible, true);
  assert.equal(measured.rendererCommitted, true);
  assert.equal(measured.currentPresetMatches, true);

  const standard = evaluateAuralinkLiveRequest(
    true,
    { ...activeState, hqCorrectionMode: false, hqCorrectionRequested: false },
    "expected",
    7
  );
  assert.equal(standard.audible, true);
  assert.equal(standard.rendererCommitted, true);

  const newerRequest = evaluateAuralinkLiveRequest(
    true,
    { ...activeState, requestedRenderGeneration: 8, committedRenderGeneration: 8 },
    "expected",
    7
  );
  assert.equal(newerRequest.audible, false, "a different accepted request cannot verify this one");
});

test("poll retries through transient commit lag until the exact commit lands", async () => {
  const staleTick = { ...activeState, committedRenderGeneration: 6 };
  const states = [staleTick, activeState];
  let reads = 0;
  const result = await pollAuralinkLiveVerification(
    true,
    async () => states[Math.min(reads++, states.length - 1)],
    "expected",
    7,
    { sleep: async () => {} }
  );
  assert.equal(result.audible, true);
  assert.equal(reads, 2, "one stale telemetry tick should trigger exactly one retry");
});

test("poll retries a lagging preset identity as the same transient class", async () => {
  const staleTick = { ...activeState, currentPresetId: "previous" };
  const states = [staleTick, activeState];
  let reads = 0;
  const result = await pollAuralinkLiveVerification(
    true,
    async () => states[Math.min(reads++, states.length - 1)],
    "expected",
    7,
    { sleep: async () => {} }
  );
  assert.equal(result.audible, true);
  assert.equal(reads, 2);
});

test("poll never retries stable routing/EQ/bypass failures", async () => {
  for (const state of [
    { ...activeState, routingActive: false },
    { ...activeState, systemOutputRoutedToAuralink: false },
    { ...activeState, eqEnabled: false },
  ]) {
    let reads = 0;
    const result = await pollAuralinkLiveVerification(
      true,
      async () => {
        reads += 1;
        return state;
      },
      "expected",
      7,
      { sleep: async () => {} }
    );
    assert.equal(result.audible, false);
    assert.equal(reads, 1, "stable user/device state must return on the first read");
  }
});

test("poll stays bounded when the commit never lands", async () => {
  let reads = 0;
  const result = await pollAuralinkLiveVerification(
    true,
    async () => {
      reads += 1;
      return { ...activeState, committedRenderGeneration: 6 };
    },
    "expected",
    7,
    { maxAttempts: 3, sleep: async () => {} }
  );
  assert.equal(result.audible, false);
  assert.equal(reads, 3);
});

test("poll does not read state at all for a rejected request", async () => {
  let reads = 0;
  const result = await pollAuralinkLiveVerification(
    false,
    async () => {
      reads += 1;
      return activeState;
    },
    "expected",
    7,
    { sleep: async () => {} }
  );
  assert.equal(result.audible, false);
  assert.equal(result.stateVerified, false);
  assert.equal(reads, 0, "a rejected request has no committed state to wait for");
});
