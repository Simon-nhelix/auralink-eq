import assert from "node:assert/strict";
import test from "node:test";

import { luxsinEncode, luxsinDecode } from "../dist/targets/luxsin/codec.js";

test("luxsin codec round-trips JSON payloads", () => {
  const samples = [
    '{"peq":[{"index":0,"brand":"Sennheiser","model":"HD600","filters":"[{\\"type\\":\\"PEAKING\\",\\"fc\\":75,\\"gain\\":1.2,\\"q\\":2.38}]","preamp":-1.2,"canDel":1}]}',
    '{"filters":[],"preamp":0}',
    '{"target":"crinacle EARS + 711 Harman over-ear 2018"}',
  ];
  for (const s of samples) {
    assert.equal(luxsinDecode(luxsinEncode(s)), s);
  }
});

test("luxsin codec round-trips unicode and emoji", () => {
  const s = "안녕 세계 — Luxsin X8 codec 🎧 τ=2π";
  assert.equal(luxsinDecode(luxsinEncode(s)), s);
});

test("luxsin encode produces non-standard alphabet (not plain base64)", () => {
  // The first char of the standard alphabet 'A' must map to a different char.
  // Encode bytes that produce a leading 'A' in standard base64 (0x00 → "AA..").
  const enc = luxsinEncode("\x00\x00\x00");
  assert.notEqual(enc.charAt(0), "A");
  assert.equal(luxsinDecode(enc), "\x00\x00\x00");
});
