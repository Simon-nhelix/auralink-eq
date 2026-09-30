import assert from "node:assert/strict";
import { promises as fs } from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { z } from "zod";

import { registerTools } from "../dist/register-tools.js";
import * as store from "../dist/store.js";

const writes = [
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
    return JSON.parse(result.content[0].text);
  };
  try {
    await store.savePreset({
      id: "preset_test", name: "Original", preampDb: -2,
      bands: store.bandsFromSpecs([{ frequencyHz: 1000, gainDb: -1 }]),
      safety: { autoGainEnabled: false, clippingRisk: "low" },
      createdBy: "user", version: 1, tags: [], createdAt: "", updatedAt: "",
    });
    await store.addPresetToCollection("preset_test");
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
    assert.equal((await invoke("list_presets", {})).count, 1);
    const validation = await invoke("validate_eq_preset", { id: "preset_test" });
    assert.equal(validation.validation.ok, true);
    assert.deepEqual(requests, []);
  });
});
