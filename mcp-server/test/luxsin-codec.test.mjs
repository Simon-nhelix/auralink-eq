import assert from "node:assert/strict";
import test from "node:test";

import { luxsinEncode, luxsinDecode } from "../dist/targets/luxsin/codec.js";
import { encodeFormBody } from "../dist/targets/luxsin/client.js";

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

test("encodeFormBody percent-encodes '+' so the device does not read it as a space", () => {
  // Standard base64 '8' maps to scrambled '+', so any payload whose standard
  // base64 contains '8' produces a form-unsafe body.
  const payload = { peqChange: { name: "\u00ff\u00ff" } };
  const raw = luxsinEncode(JSON.stringify(payload));
  assert.ok(raw.includes("+"), "fixture must produce a '+' in the encoded body");

  const body = encodeFormBody(payload);
  assert.ok(!body.slice("data=".length).includes("+"));

  // An x-www-form-urlencoded parser turns '+' into a space before decoding.
  const asParsed = decodeURIComponent(body.slice("data=".length).replace(/\+/g, " "));
  assert.equal(asParsed, raw);
  assert.deepEqual(JSON.parse(luxsinDecode(asParsed)), payload);
});

test("encodeFormBody survives the round trip for a realistic peqChange", () => {
  const payload = {
    peqChange: {
      name: "TimeEar TEA-99 – Harman Neutral Open Earbud X8",
      brand: "TimeEar",
      model: "TEA-99",
      form: "in-ear",
      target: "harman-neutral (community/review-derived, no measurement)",
      filters: [
        { type: 5, fc: 55, gain: 4.5, q: 0.7 },
        { type: 6, fc: 10000, gain: 1.5, q: 0.7 },
      ],
      autoPre: 0,
      preamp: -5,
      canDel: 1,
    },
  };
  const body = encodeFormBody(payload);
  const asParsed = decodeURIComponent(body.slice("data=".length).replace(/\+/g, " "));
  assert.deepEqual(JSON.parse(luxsinDecode(asParsed)), payload);
});
