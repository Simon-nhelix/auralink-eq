import assert from "node:assert/strict";
import { promises as fs } from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { z } from "zod";

import { registerTools } from "../dist/register-tools.js";
import * as store from "../dist/store.js";

const writes = [
  ["create_preference_tuning", { baselinePresetId: "baseline_test", name: "Warm", bands: [{ frequencyHz: 80, gainDb: 1 }] }, "saved"],
  ["create_eq_preset", { id: "preset_test", name: "Edited", bands: [{ frequencyHz: 1000, gainDb: -2 }] }, "saved"],
  ["delete_preset", { id: "preset_test" }, "deleted"],
  ["add_preset_to_collection", { id: "preset_test" }, "added"],
  ["remove_preset_from_collection", { id: "preset_test" }, "removed"],
  ["upsert_headphone_profile", { id: "test-can", brand: "Test", model: "Can", signature: "Edited", source: "test" }, "saved"],
  ["delete_headphone_profile", { id: "test-can" }, "deleted"],
  ["register_headphone_baseline", { headphone: "New Can", type: "iem", bands: [{ frequencyHz: 1000, gainDb: -2 }] }, "ok"],
  ["record_tuning_feedback", { sentiment: "liked", feedbackText: "test" }, "recorded"],
];

async function snapshot(directory) {
  const files = {};
  for (const entry of await fs.readdir(directory, { withFileTypes: true })) {
    const file = path.join(directory, entry.name);
    files[entry.name] = entry.isDirectory()
      ? await snapshot(file)
      : await fs.readFile(file, "utf8");
  }
  return files;
}

async function withFixture(stateResponse, body) {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "auralink-write-permission-"));
  const previousEnv = { ...process.env };
  const previousFetch = globalThis.fetch;
  const requests = [];
  process.env.AURALINK_PRESETS_DIR = path.join(root, "presets");
  process.env.AURALINK_REVISIONS_DIR = path.join(root, "revisions");
  process.env.AURALINK_COLLECTION_DIR = path.join(root, "collection");
  process.env.AURALINK_USER_DATA_DIR = path.join(root, "data");
  process.env.AURALINK_DATA_DIR = path.join(root, "bundled-data");
  process.env.AURALINK_CONTROL_TOKEN = "test-capability-000000000000000000000000";
  process.env.AURALINK_CONTROL_URL = "http://permission-test.invalid";
  globalThis.fetch = async (url) => {
    const endpoint = new URL(url).pathname;
    requests.push(endpoint);
    if (endpoint === "/state") return stateResponse();
    return new Response(JSON.stringify({ ok: true }), { status: 200 });
  };
  const tools = new Map();
  registerTools({ registerTool(name, config, handler) { tools.set(name, { config, handler }); } });
  const invoke = async (name, input) => {
    const { config, handler } = tools.get(name);
    const result = await handler(z.object(config.inputSchema).parse(input));
    return result.isError ? { isError: true, message: result.content[0].text } : JSON.parse(result.content[0].text);
  };
  try {
    await store.savePreset({
      id: "preset_test", name: "Original", preampDb: -2,
      bands: store.bandsFromSpecs([{ frequencyHz: 1000, gainDb: -1 }]),
      safety: { autoGainEnabled: false, clippingRisk: "low" },
      createdBy: "user", version: 1, tags: [], createdAt: "", updatedAt: "",
    });
    await store.addPresetToCollection("preset_test");
    await store.savePreset({
      ...(await store.getPreset("preset_test")), id: "baseline_test", headphone: "Test Can",
      tags: ["baseline", "harman-neutral"],
      correction: { role: "baseline", correctionStrength: 1, targetBlend: 1,
        sourceConfidence: "measured", preferenceBandIndexes: [], targetCurveId: "harman-neutral" },
    });
    await store.addPresetToCollection("baseline_test");
    await store.saveHeadphoneProfile({
      id: "test-can", brand: "Test", model: "Can", type: "iem",
      signature: "Original", source: "test", credibility: "estimated",
      correctionNotes: [], harshRegionsHz: [],
    });
    await body({ invoke, root, requests });
  } finally {
    globalThis.fetch = previousFetch;
    process.env = previousEnv;
    await fs.rm(root, { recursive: true, force: true });
  }
}

const state = (permissionMode) => () => new Response(JSON.stringify({ permissionMode }), { status: 200 });

for (const [label, response, confirmed, reason] of [
  ["read-only", state("read_only"), false, "read_only"],
  ["read-only even with confirmation", state("read_only"), true, "read_only"],
  ["ask-before-write without confirmation", state("ask_before_write"), false, "confirmation_required"],
  ["offline even with confirmation", () => { throw new Error("offline"); }, true, "permission_unavailable"],
  ["authentication failure", () => new Response("unauthorized", { status: 401 }), true, "permission_unavailable"],
  ["missing permission mode", state(undefined), true, "permission_unavailable"],
  ["unknown permission mode", state("future_mode"), true, "permission_unavailable"],
]) {
  test(`${label} prevents every library write without changing any files`, async () => {
    await withFixture(response, async ({ invoke, root, requests }) => {
      const before = await snapshot(root);
      for (const [name, input] of writes) {
        requests.length = 0;
        const result = await invoke(name, { ...input, confirmed });
        assert.equal(result.ok, false, name);
        assert.equal(result.reason, reason, name);
        assert.equal(result.needsConfirm, reason === "confirmation_required", name);
        assert.deepEqual(await snapshot(root), before, name);
        assert.deepEqual(requests, ["/state"], name);
      }
    });
  });
}

for (const [mode, confirmed] of [
  ["ask_before_write", true],
  ["allow_preset_creation", false],
  ["full_control", false],
]) {
  test(`${mode} permits authorized library operations`, async () => {
    for (const [name, input, successKey] of writes) {
      await withFixture(state(mode), async ({ invoke }) => {
        const result = await invoke(name, { ...input, confirmed });
        assert.equal(result[successKey], true, `${mode}: ${name}`);
      });
    }
  });
}

test("permission is checked again after the app switches to read-only", async () => {
  let mode = "full_control";
  await withFixture(() => state(mode)(), async ({ invoke, root }) => {
    assert.equal((await invoke(writes[0][0], writes[0][1])).saved, true);
    mode = "read_only";
    const before = await snapshot(root);
    const result = await invoke(writes[0][0], { ...writes[0][1], confirmed: true });
    assert.equal(result.reason, "read_only");
    assert.deepEqual(await snapshot(root), before);
  });
});

test("read-only also blocks create-and-apply before writing or contacting a live target", async () => {
  await withFixture(state("read_only"), async ({ invoke, root, requests }) => {
    const before = await snapshot(root);
    const result = await invoke("create_eq_preset", { ...writes[0][1], applyNow: true, confirmed: true });
    assert.equal(result.reason, "read_only");
    assert.deepEqual(requests, ["/state"]);
    assert.deepEqual(await snapshot(root), before);
  });
});

test("offline reads and validation remain available", async () => {
  await withFixture(() => { throw new Error("offline"); }, async ({ invoke, requests }) => {
    assert.equal((await invoke("list_presets", {})).count, 2);
    const validation = await invoke("validate_eq_preset", { id: "preset_test" });
    assert.equal(validation.validation.ok, true);
    assert.deepEqual(requests, []);
  });
});


test("preference create, revise and delete preserves baseline and removes every tuning copy", async () => {
  await withFixture(state("allow_preset_creation"), async ({ invoke }) => {
    const before = await store.getPreset("baseline_test");
    const created = await invoke("create_preference_tuning", {
      baselinePresetId: before.id, name: "Warm", bands: [{ index: 1, frequencyHz: 80, gainDb: 1 }],
    });
    assert.equal(created.saved, true);
    assert.equal(created.inCollection, true);
    assert.deepEqual(created.preset.bands[0], before.bands[0]);
    assert.deepEqual(created.preset.correction.preferenceBandIndexes, [2]);
    assert.equal(created.preset.preampDb, before.preampDb - 1);
    const brief = await invoke("get_tuning_brief", { headphone: "Test Can" });
    assert.equal(brief.recommendation.startFromPresetId, before.id);
    const revised = await invoke("create_preference_tuning", {
      baselinePresetId: before.id, id: created.preset.id, name: "Warm revised",
      bands: [{ frequencyHz: 80, gainDb: 2 }],
    });
    assert.equal(revised.preset.version, 2);
    assert.deepEqual(await store.getPreset(before.id), before);
    assert.equal((await invoke("delete_preset", { id: created.preset.id })).deleted, true);
    assert.equal(await store.getPreset(created.preset.id), null);
    assert.equal((await store.collectionPresetIds()).includes(created.preset.id), false);
    await assert.rejects(fs.access(path.join(store.revisionsDir(), created.preset.id)));
    assert.deepEqual(await store.getPreset(before.id), before);
    assert.equal((await invoke("delete_preset", { id: created.preset.id })).deleted, false);
  });
});

test("generic MCP creation automatically enters collection without applying live audio", async () => {
  await withFixture(state("allow_preset_creation"), async ({ invoke, requests }) => {
    const result = await invoke("create_eq_preset", {
      name: "Generic", bands: [{ frequencyHz: 800, gainDb: -1 }],
    });
    assert.equal(result.saved, true);
    assert.equal(result.inCollection, true);
    assert.ok((await store.collectionPresetIds()).includes(result.preset.id));
    assert.equal(requests.includes("/apply"), false);
    assert.equal(requests.includes("/audition-preset"), false);
  });
});

test("preference writes cannot overwrite a baseline or tune another variation as a baseline", async () => {
  await withFixture(state("full_control"), async ({ invoke }) => {
    const before = await store.getPreset("baseline_test");
    const input = { name: "Bad", bands: [{ frequencyHz: 80, gainDb: 1 }] };
    for (const [tool, args] of [
      ["create_preference_tuning", { ...input, baselinePresetId: before.id, id: before.id }],
      ["create_preference_tuning", { ...input, baselinePresetId: "preset_test" }],
      ["create_eq_preset", { ...input, id: before.id }],
    ]) {
      const result = await invoke(tool, args);
      assert.notEqual(result.saved, true);
    }
    assert.deepEqual(await store.getPreset(before.id), before);
  });
});


test("X8 compatibility is checked by offline validation before library creation", async () => {
  await withFixture(state("full_control"), async ({ invoke, root, requests }) => {
    const bands = Array.from({ length: 11 }, (_, i) => ({ frequencyHz: 100 + 100 * i, gainDb: -1 }));
    const validation = await invoke("validate_eq_preset", { target: "luxsin-x8", bands });
    assert.equal(validation.validation.ok, false);
    assert.equal(validation.readyToApply, false);
    assert.deepEqual(requests, []);
    const before = await snapshot(root);
    const created = await invoke("create_eq_preset", { name: "Too many", target: "luxsin-x8", bands });
    assert.equal(created.saved, false);
    assert.deepEqual(await snapshot(root), before);
  });
});

test("X9 apply and audition never fall back to Auralink or hardware writes", async () => {
  await withFixture(state("full_control"), async ({ invoke, requests }) => {
    const apply = await invoke("apply_eq_preset", { id: "preset_test", target: "luxsin-x9", confirmed: true });
    assert.equal(apply.applied, false);
    assert.equal(apply.x8.reason, "unverified_device_writes");
    const audition = await invoke("audition_eq_preset", {
      name: "X9 trial", target: "luxsin-x9", confirmed: true, bands: [{ frequencyHz: 100, gainDb: -1 }],
    });
    assert.equal(audition.auditioned, false);
    assert.equal(audition.x8.reason, "unverified_device_writes");
    const deletion = await invoke("delete_luxsin_preset", { name: "Original", target: "luxsin-x9", confirmed: true });
    assert.equal(deletion.deleted, false);
    assert.equal(deletion.reason, "unverified_device_writes");
    assert.deepEqual(requests, []);
  });
});

test("target capabilities are available offline with unverified model limits explicit", async () => {
  await withFixture(() => { throw new Error("offline"); }, async ({ invoke, requests }) => {
    const result = await invoke("list_eq_targets", {});
    assert.equal(result.targets["luxsin-x8"].deviceWrite, true);
    assert.equal(result.targets["luxsin-x9"].deviceWrite, false);
    assert.equal(result.targets["luxsin-x9"].maxBands, null);
    const validation = await invoke("validate_eq_preset", { id: "preset_test", target: "luxsin-x9" });
    assert.equal(validation.validation.ok, true);
    assert.equal(validation.readyToApply, false);
    assert.deepEqual(requests, []);
  });
});
