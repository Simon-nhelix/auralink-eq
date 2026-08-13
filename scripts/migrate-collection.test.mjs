import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { promises as fs } from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const script = path.join(repoRoot, "scripts", "migrate-collection.mjs");

/**
 * End-to-end tests for scripts/migrate-collection.mjs.
 *
 * Each test runs the real CLI as a subprocess against a scratch HOME, covering
 * the paths the review flagged: silent clobbering, invalid IDs as paths, and
 * corrupt-manifest replacement.
 */

async function makeHome() {
  const home = await fs.mkdtemp(path.join(os.tmpdir(), "auralink-migrate-test-"));
  const support = path.join(home, "Library", "Application Support", "Auralink");
  await fs.mkdir(path.join(support, "library", "headphones"), { recursive: true });
  await fs.mkdir(path.join(support, "library", "presets"), { recursive: true });
  await fs.mkdir(path.join(support, "data"), { recursive: true });
  return { home, support };
}

function profile(id, overrides = {}) {
  return {
    id,
    brand: "Test",
    model: id,
    type: "open_back",
    signature: "sig",
    correctionNotes: [],
    harshRegionsHz: [],
    source: "fixture",
    credibility: "estimated",
    ...overrides,
  };
}

function preset(id, overrides = {}) {
  return {
    id,
    name: id,
    preampDb: 0,
    bands: [],
    safety: { autoGainEnabled: false, clippingRisk: "low" },
    createdBy: "ai",
    version: 1,
    tags: [],
    createdAt: "",
    updatedAt: "",
    ...overrides,
  };
}

async function writeJson(file, value) {
  await fs.mkdir(path.dirname(file), { recursive: true });
  await fs.writeFile(file, JSON.stringify(value), "utf8");
}

function runMigration(home, args = [], extraEnv = {}) {
  return spawnSync(process.execPath, [script, ...args], {
    encoding: "utf8",
    env: { ...process.env, HOME: home, ...extraEnv },
  });
}

test("first migration copies profiles and presets, writes manifest + gitignore", async () => {
  const { home, support } = await makeHome();
  try {
    await writeJson(path.join(support, "library", "headphones", "hd600.json"), profile("hd600"));
    await writeJson(path.join(support, "library", "presets", "preset_shared.json"), preset("preset_shared"));

    const result = runMigration(home);
    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /Copied 1 profiles and 1 presets/);

    const collection = path.join(home, "auralink-collection");
    const migrated = JSON.parse(
      await fs.readFile(path.join(collection, "headphones", "hd600.json"), "utf8")
    );
    assert.equal(migrated.id, "hd600");
    await fs.access(path.join(collection, "presets", "preset_shared.json"));
    const manifest = JSON.parse(await fs.readFile(path.join(collection, "manifest.json"), "utf8"));
    assert.equal(manifest.schemaVersion, 1);
    await fs.access(path.join(collection, ".gitignore"));
  } finally {
    await fs.rm(home, { recursive: true, force: true });
  }
});

test("repeat migration is idempotent and never clobbers destination edits", async () => {
  const { home, support } = await makeHome();
  try {
    await writeJson(path.join(support, "library", "headphones", "foo.json"), profile("foo"));
    const collection = path.join(home, "auralink-collection");

    assert.equal(runMigration(home).status, 0);

    // User edits the destination record.
    const destFile = path.join(collection, "headphones", "foo.json");
    await writeJson(destFile, profile("foo", { brand: "Edited", credibility: "measured" }));

    const second = runMigration(home);
    assert.equal(second.status, 0, second.stderr);
    assert.match(second.stderr, /Conflict: 'foo'/);
    assert.match(second.stdout, /1 conflict\(s\) detected/);
    assert.match(second.stdout, /Copied 0 profiles/);

    // The edit survived.
    const kept = JSON.parse(await fs.readFile(destFile, "utf8"));
    assert.equal(kept.brand, "Edited");
    assert.equal(kept.credibility, "measured");
  } finally {
    await fs.rm(home, { recursive: true, force: true });
  }
});

test("identical destination content is skipped silently on re-run", async () => {
  const { home, support } = await makeHome();
  try {
    await writeJson(path.join(support, "library", "headphones", "same.json"), profile("same"));
    assert.equal(runMigration(home).status, 0);

    const second = runMigration(home);
    assert.equal(second.status, 0, second.stderr);
    assert.doesNotMatch(second.stderr, /Conflict/);
    assert.match(second.stdout, /Copied 0 profiles and 0 presets/);
  } finally {
    await fs.rm(home, { recursive: true, force: true });
  }
});

test("records with path-traversal ids are skipped, not written outside the collection", async () => {
  const { home, support } = await makeHome();
  try {
    await writeJson(
      path.join(support, "library", "headphones", "evil.json"),
      profile("../escape")
    );

    const result = runMigration(home);
    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stderr, /invalid ID '\.\.\/escape'/);

    const collection = path.join(home, "auralink-collection");
    assert.equal(
      await fs.readFile(path.join(collection, "escape.json"), "utf8").catch(() => null),
      null
    );
    // Nothing escaped to the collection root or above.
    const rootEntries = await fs.readdir(collection).catch(() => []);
    assert.ok(!rootEntries.includes("escape.json"));
  } finally {
    await fs.rm(home, { recursive: true, force: true });
  }
});

test("a corrupt manifest is preserved and reported, never replaced", async () => {
  const { home, support } = await makeHome();
  try {
    await writeJson(path.join(support, "library", "headphones", "hd600.json"), profile("hd600"));
    const collection = path.join(home, "auralink-collection");
    await fs.mkdir(collection, { recursive: true });
    const manifestPath = path.join(collection, "manifest.json");
    await fs.writeFile(manifestPath, "{ broken json", "utf8");

    const result = runMigration(home);
    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /manifest\.json exists but is not valid JSON/);
    assert.equal(await fs.readFile(manifestPath, "utf8"), "{ broken json");
  } finally {
    await fs.rm(home, { recursive: true, force: true });
  }
});

test("aggregate-only legacy data migrates too", async () => {
  const { home, support } = await makeHome();
  try {
    await writeJson(path.join(support, "data", "headphone-profiles.json"), [profile("agg-only")]);

    const result = runMigration(home);
    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /Copied 1 profiles/);
    const migrated = JSON.parse(
      await fs.readFile(path.join(home, "auralink-collection", "headphones", "agg-only.json"), "utf8")
    );
    assert.equal(migrated.id, "agg-only");
  } finally {
    await fs.rm(home, { recursive: true, force: true });
  }
});

test("machine-local audition presets are not migrated", async () => {
  const { home, support } = await makeHome();
  try {
    await writeJson(
      path.join(support, "library", "presets", "audition_scratch.json"),
      preset("audition_scratch")
    );
    await writeJson(
      path.join(support, "library", "presets", "preset_keep.json"),
      preset("preset_keep")
    );

    const result = runMigration(home);
    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /Copied 0 profiles and 1 presets/);
    const presetsDir = path.join(home, "auralink-collection", "presets");
    assert.deepEqual(await fs.readdir(presetsDir), ["preset_keep.json"]);
  } finally {
    await fs.rm(home, { recursive: true, force: true });
  }
});

test("nothing to migrate reports cleanly", async () => {
  const { home } = await makeHome();
  try {
    const result = runMigration(home);
    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /Nothing to migrate/);
  } finally {
    await fs.rm(home, { recursive: true, force: true });
  }
});

test("a relative AURALINK_COLLECTION_DIR is rejected in favor of the default", async () => {
  const { home, support } = await makeHome();
  try {
    await writeJson(path.join(support, "library", "headphones", "hd600.json"), profile("hd600"));

    const result = runMigration(home, [], { AURALINK_COLLECTION_DIR: "relative/path" });
    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stderr, /Ignoring relative collection path/);
    // Fell back to ~/auralink-collection.
    await fs.access(path.join(home, "auralink-collection", "headphones", "hd600.json"));
  } finally {
    await fs.rm(home, { recursive: true, force: true });
  }
});
