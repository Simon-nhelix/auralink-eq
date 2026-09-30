import assert from "node:assert/strict";
import test from "node:test";
import os from "node:os";
import path from "node:path";
import { LuxsinClient, isLuxsinState } from "../dist/targets/luxsin/client.js";
import { LuxsinX8Target, buildX8Change, mapState } from "../dist/targets/luxsin/adapter.js";
import { luxsinDecode, luxsinEncode } from "../dist/targets/luxsin/codec.js";
import { applyPresetToX8 } from "../dist/helpers.js";
import { bandsFromSpecs } from "../dist/store.js";

const bands = bandsFromSpecs([{ frequencyHz: 120, gainDb: -2 }]);
const preset = {
  id: "test_tuning", name: "Test tuning", headphone: "Test Can", preampDb: -2, bands,
  safety: { autoGainEnabled: false, clippingRisk: "low" }, createdBy: "ai",
  version: 1, tags: [], createdAt: "", updatedAt: "",
};
const typeNames = ["LOW_PASS", "HIGH_PASS", "BPF", "NOTCH", "PEAKING", "LOW_SHELF", "HIGH_SHELF", "APF"];
function stored(payload) {
  return { ...payload, filters: JSON.stringify(payload.filters.map(f => ({ ...f, type: typeNames[f.type] }))) };
}
const original = stored(buildX8Change({ headphone: "Original", preampDb: -1, bands }).payload);

async function withDevice(options, body) {
  const previousFetch = globalThis.fetch;
  const previousEnv = { ...process.env };
  process.env.AURALINK_COLLECTION_DIR = path.join(os.tmpdir(), "auralink-nonexistent-luxsin-test-collection");
  process.env.AURALINK_DATA_DIR = path.join(os.tmpdir(), "auralink-nonexistent-luxsin-test-data");
  const state = { device: options.model ?? "Luxsin-X8", mac: "test-mac", peqSelect: 0, peqEnable: 1, dsp_enable: 1, audio_enable: 1, audioFormat: "PCM 44.1kHz", ...options.state };
  let peq = [structuredClone(original)];
  const requests = [];
  let inflight = 0;
  let maxInflight = 0;
  globalThis.fetch = async (url, init = {}) => {
    const u = new URL(url);
    const action = u.searchParams.get("action");
    requests.push({ action, method: init.method ?? "GET" });
    inflight++;
    maxInflight = Math.max(maxInflight, inflight);
    try {
      if (options.delay) await new Promise(resolve => setTimeout(resolve, options.delay));
      if (init.method === "POST") {
        if (options.postFails) throw new Error("ack lost");
        const data = JSON.parse(luxsinDecode(new URLSearchParams(init.body).get("data")));
        if (data.peqChange && !options.ignoreWrite) {
          peq = [stored(data.peqChange), ...peq.filter(e => e.name !== data.peqChange.name)];
        }
        if (data.peqRemove && !options.ignoreDelete) peq = peq.filter(e => !data.peqRemove.includes(e.name));
        if (options.postFailsAfterWrite) throw new Error("ack lost after write");
        return new Response("Settings updated");
      }
      if (action === "setting") {
        if (options.settingFails) throw new Error("setting ack lost");
        if (!options.ignoreSelect) state.peqSelect = Number(u.searchParams.get("peqSelect"));
        return new Response("Settings updated");
      }
      const data = action === "syncPeq" ? (options.badDb ? {} : { peq }) : state;
      return new Response(luxsinEncode(JSON.stringify(data)));
    } finally { inflight--; }
  };
  const client = new LuxsinClient({ baseUrl: "http://luxsin-test.invalid", model: options.clientModel, minGapMs: 0, autoDiscover: false });
  const device = new LuxsinX8Target(client);
  try { await body({ device, client, state, requests, entries: () => peq, maxInflight: () => maxInflight }); }
  finally { globalThis.fetch = previousFetch; process.env = previousEnv; }
}

test("Luxsin stores, reads back, restores previous selection and activates the requested entry", async () => {
  await withDevice({}, async ({ device, state, entries }) => {
    const imported = await applyPresetToX8(preset, true, { select: false, device });
    assert.equal(imported.written, true);
    assert.equal(imported.applied, false);
    assert.equal(entries()[state.peqSelect].name, "Original");
    const result = await applyPresetToX8(preset, true, { device });
    assert.equal(result.written, true);
    assert.equal(result.selected, true);
    assert.equal(result.processing, true);
    assert.equal(result.applied, true);
    assert.equal(entries()[state.peqSelect].name, preset.name);
  });
});

test("HTTP success with ignored EQ never reports success or selects a missing entry", async () => {
  await withDevice({ ignoreWrite: true }, async ({ device, requests }) => {
    const result = await applyPresetToX8(preset, true, { device });
    assert.equal(result.written, false);
    assert.equal(result.applied, false);
    assert.equal(requests.some(r => r.action === "setting"), false);
    assert.match(result.message, /stored EQ did not match/);
  });
});

test("ignored selection and bypassed DSP cannot produce applied:true", async () => {
  await withDevice({}, async ({ device, state }) => {
    state.dsp_enable = 0;
    const result = await applyPresetToX8(preset, true, { device });
    assert.equal(result.written, true);
    assert.equal(result.selected, true);
    assert.equal(result.applied, false);
  });
  await withDevice({ ignoreSelect: true }, async ({ device }) => {
    // Import reorders the database and restoration is also ignored: fail closed.
    const result = await applyPresetToX8(preset, true, { device });
    assert.equal(result.applied, false);
  });
});

test("hardware overflow and per-channel bands are rejected without any write", async () => {
  await withDevice({}, async ({ device, requests }) => {
    for (const invalidBands of [
      bandsFromSpecs(Array.from({ length: 11 }, (_, i) => ({ frequencyHz: 100 + 100 * i, gainDb: -1 }))),
      bandsFromSpecs([{ frequencyHz: 100, gainDb: -1, channel: "left" }]),
    ]) {
      const result = await applyPresetToX8({ ...preset, bands: invalidBands }, true, { device });
      assert.equal(result.applied, false);
    }
    assert.equal(requests.some(r => r.method === "POST" || r.action === "setting"), false);
  });
});

test("unconfirmed writes, selection and deletion never contact hardware", async () => {
  await withDevice({}, async ({ device, requests }) => {
    assert.equal((await applyPresetToX8(preset, false, { device })).needsConfirm, true);
    assert.equal((await device.selectHeadphone("Original")).data.needsConfirm, true);
    assert.equal((await device.deleteHeadphone("Original")).data.needsConfirm, true);
    assert.deepEqual(requests, []);
  });
});

test("device writes are never retried after an ambiguous transport failure", async () => {
  await withDevice({ postFails: true }, async ({ device, requests }) => {
    assert.equal((await applyPresetToX8(preset, true, { device })).applied, false);
    assert.equal(requests.filter(r => r.method === "POST").length, 1);
  });
  await withDevice({ settingFails: true }, async ({ device, requests }) => {
    assert.equal((await device.selectHeadphone("Original", true)).online, false);
    assert.equal(requests.filter(r => r.action === "setting").length, 1);
  });
});

test("device client serializes complete requests even when reads overlap", async () => {
  await withDevice({ delay: 5 }, async ({ client, maxInflight }) => {
    await Promise.all([client.getDeviceInfo(), client.getPeq(), client.getDeviceInfo()]);
    assert.equal(maxInflight(), 1);
  });
});

test("device mutations do not interleave write and selection transactions", async () => {
  await withDevice({ delay: 1 }, async ({ device, entries, state }) => {
    const completed = [];
    const results = await Promise.all(["First", "Second"].map(name =>
      applyPresetToX8({ ...preset, name }, true, { device }).then(result => {
        completed.push(name);
        return result;
      })
    ));
    assert.ok(results.every(r => r.applied));
    // Async preparation may enqueue either request first. Each full transaction
    // must succeed, and the final selection belongs to the last completed one.
    assert.equal(entries()[state.peqSelect].name, completed.at(-1));
  });
});

test("deletion refuses active entries, verifies removal and preserves the active name", async () => {
  await withDevice({}, async ({ device, entries, state }) => {
    assert.equal((await device.deleteHeadphone("Original", true)).data.ok, false);
    await applyPresetToX8(preset, true, { select: false, device });
    assert.equal((await device.deleteHeadphone(preset.name, true)).data.ok, true);
    assert.equal(entries().some(e => e.name === preset.name), false);
    assert.equal(entries()[state.peqSelect].name, "Original");
  });
});

test("malformed PEQ response is an error, and exact model identity is required", async () => {
  await withDevice({ badDb: true }, async ({ client }) => {
    await assert.rejects(client.getPeq(), /Invalid Luxsin PEQ/);
  });
  assert.equal(isLuxsinState({ device: "Luxsin-X8" }), true);
  assert.equal(isLuxsinState({ device: "Luxsin-X80" }), false);
  await withDevice({ model: "Luxsin-X9" }, async ({ device, requests }) => {
    assert.equal((await applyPresetToX8(preset, true, { device })).applied, false);
    assert.equal(requests.some(r => r.method === "POST"), false);
  });
});

test("X9 reads use their own model while every write path stays disabled", async () => {
  await withDevice({ model: "Luxsin-X9", clientModel: "luxsin-x9" }, async ({ device, client, requests }) => {
    assert.equal((await device.getState()).online, true);
    await assert.rejects(client.setSetting("peqSelect", 0), /not verified/);
    await assert.rejects(client.peqRemove("Original"), /not verified/);
    const result = await applyPresetToX8(preset, true, { target: "luxsin-x9", device });
    assert.equal(result.applied, false);
    assert.equal(result.reason, "unverified_device_writes");
    assert.equal(requests.some(r => r.method === "POST" || r.action === "setting"), false);
  });
});

test("44.1 kHz hardware status does not truncate to 44 kHz", () => {
  assert.equal(mapState({ audioFormat: "PCM 44.1kHz" }, { peq: [] }).sampleRate, 44100);
});


test("lost write acknowledgement restores the original selection without replaying the write", async () => {
  await withDevice({ postFailsAfterWrite: true }, async ({ device, entries, state, requests }) => {
    const result = await applyPresetToX8(preset, true, { device });
    assert.equal(result.applied, false);
    assert.ok(entries().some(e => e.name === preset.name), "write may have succeeded despite lost ack");
    assert.equal(entries()[state.peqSelect].name, "Original");
    assert.equal(requests.filter(r => r.method === "POST").length, 1);
  });
});

test("protected hardware presets are never overwritten or deleted", async () => {
  await withDevice({}, async ({ device, entries, requests }) => {
    entries()[0].canDel = 0;
    assert.equal((await applyPresetToX8({ ...preset, name: "Original" }, true, { device })).applied, false);
    assert.equal((await device.deleteHeadphone("Original", true)).data.ok, false);
    assert.equal(requests.some(r => r.method === "POST"), false);
  });
});
