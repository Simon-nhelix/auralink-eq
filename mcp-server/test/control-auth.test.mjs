import assert from "node:assert/strict";
import { promises as fs } from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";

import {
  controlTokenFilePath,
  normalizeControlToken,
  resolveControlToken,
} from "../dist/control.js";

test("control token resolution prefers an explicit environment capability", async () => {
  const token = "a".repeat(64);
  assert.equal(await resolveControlToken({ AURALINK_CONTROL_TOKEN: token }), token);
});

test("control token resolution reads the shared Application Support file", async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "auralink-control-auth-"));
  try {
    const token = "b".repeat(64);
    const tokenFile = path.join(root, "control-token");
    await fs.writeFile(tokenFile, `${token}\n`, "utf8");
    await fs.chmod(tokenFile, 0o600);
    assert.equal(
      await resolveControlToken({ AURALINK_CONTROL_TOKEN_FILE: tokenFile }),
      token
    );
  } finally {
    await fs.rm(root, { recursive: true, force: true });
  }
});

test("control token resolution rejects group-readable files", async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "auralink-control-auth-"));
  try {
    const tokenFile = path.join(root, "control-token");
    await fs.writeFile(tokenFile, `${"e".repeat(64)}\n`, { mode: 0o644 });
    await assert.rejects(
      resolveControlToken({ AURALINK_CONTROL_TOKEN_FILE: tokenFile }),
      /missing or insecure/
    );
  } finally {
    await fs.rm(root, { recursive: true, force: true });
  }
});

test("control token validation rejects short and unsafe values", () => {
  assert.equal(normalizeControlToken("short"), undefined);
  assert.equal(normalizeControlToken(`${"c".repeat(40)} with-space`), undefined);
  assert.equal(normalizeControlToken("d".repeat(32)), "d".repeat(32));
});

test("default control token path follows the selected home directory", () => {
  assert.equal(
    controlTokenFilePath({ HOME: "/tmp/auralink-home" }),
    "/tmp/auralink-home/Library/Application Support/Auralink/control-token"
  );
});
