/**
 * Local filesystem access for the MCP server.
 *
 * Presets live in the SAME directory the app uses
 * (`~/Library/Application Support/Auralink/presets`, override with
 * `AURALINK_PRESETS_DIR`) so the AI and the app see one shared library. Knowledge
 * data (headphone profiles / target curves / safety rules) is read from
 * `AURALINK_DATA_DIR` (default the bundled `mcp-server/data`), where the app's
 * core-knowledge module copies identical JSON so the server works standalone.
 *
 * Shared git-tracked library lives in the repo `library/` folder
 * (`AURALINK_LIBRARY_DIR` override): per-file headphones and shared presets.
 * Writes dual-write to Application Support (live app) and `library/` (git).
 *
 * Everything degrades gracefully: a missing knowledge file yields an empty list
 * (or the built-in default `SafetyRules`), and a malformed preset file is skipped
 * rather than crashing the server.
 */

import { promises as fs } from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

import {
  EQPreset,
  HeadphoneProfile,
  TargetCurve,
  SafetyRules,
  DEFAULT_SAFETY_RULES,
  EQBand,
  BAND_COUNT,
  clamp,
  FREQ_MIN,
  FREQ_MAX,
  GAIN_MIN,
  GAIN_MAX,
  Q_MIN,
  Q_MAX,
  PREAMP_MIN,
  PREAMP_MAX,
  BandType,
  BandChannel,
} from "./types.js";

// MARK: - Directory resolution

const moduleDir = path.dirname(fileURLToPath(import.meta.url)); // dist/

/** ~/Library/Application Support/Auralink/presets unless overridden. */
export function presetsDir(): string {
  const override = process.env.AURALINK_PRESETS_DIR;
  if (override && override.trim().length > 0) return override;
  return path.join(
    os.homedir(),
    "Library",
    "Application Support",
    "Auralink",
    "presets"
  );
}

/** ~/Library/Application Support/Auralink/revisions unless overridden. */
export function revisionsDir(): string {
  const override = process.env.AURALINK_REVISIONS_DIR;
  if (override && override.trim().length > 0) return override;
  return path.join(
    os.homedir(),
    "Library",
    "Application Support",
    "Auralink",
    "revisions"
  );
}

/** The bundled `mcp-server/data` directory unless `AURALINK_DATA_DIR` is set. */
export function dataDir(): string {
  const override = process.env.AURALINK_DATA_DIR;
  if (override && override.trim().length > 0) return override;
  // dist/ → mcp-server/ → data/
  return path.resolve(moduleDir, "..", "data");
}

/** User-editable knowledge data shared with the app. */
export function userDataDir(): string {
  const override = process.env.AURALINK_USER_DATA_DIR;
  if (override && override.trim().length > 0) return override;
  return path.join(
    os.homedir(),
    "Library",
    "Application Support",
    "Auralink",
    "data"
  );
}

/**
 * Git-tracked shared library root (`<repo>/library` by default).
 * Override with `AURALINK_LIBRARY_DIR`.
 */
export function libraryDir(): string {
  const override = process.env.AURALINK_LIBRARY_DIR;
  if (override && override.trim().length > 0) return override.trim();
  // dist/ → mcp-server/ → repo root → library/
  return path.resolve(moduleDir, "..", "..", "library");
}

/**
 * Runtime mirror of the shared library under Application Support so the
 * installed app (which cannot see the git checkout) still loads per-file
 * profiles. Override with `AURALINK_RUNTIME_LIBRARY_DIR`.
 */
export function runtimeLibraryDir(): string {
  const override = process.env.AURALINK_RUNTIME_LIBRARY_DIR;
  if (override && override.trim().length > 0) return override.trim();
  return path.join(
    os.homedir(),
    "Library",
    "Application Support",
    "Auralink",
    "library"
  );
}

export function runtimeLibraryHeadphonesDir(): string {
  return path.join(runtimeLibraryDir(), "headphones");
}

export function runtimeLibraryPresetsDir(): string {
  return path.join(runtimeLibraryDir(), "presets");
}

export function libraryHeadphonesDir(): string {
  return path.join(libraryDir(), "headphones");
}

export function libraryPresetsDir(): string {
  return path.join(libraryDir(), "presets");
}

function libraryHeadphonePath(id: string): string {
  return path.join(libraryHeadphonesDir(), `${sanitizeId(id)}.json`);
}

function libraryPresetPath(id: string): string {
  return path.join(libraryPresetsDir(), `${sanitizeId(id)}.json`);
}

/** True when a preset should be mirrored into the git-tracked library. */
export function isSharedLibraryPreset(preset: EQPreset): boolean {
  const id = (preset.id ?? "").toLowerCase();
  const tags = (preset.tags ?? []).map((t) => t.toLowerCase());
  if (id.startsWith("audition_") || id.startsWith("live_audition_")) return false;
  if (tags.includes("audition") || tags.includes("local-only")) return false;
  if (id.startsWith("ai_")) return true;
  if (tags.some((t) => ["baseline", "harman-neutral", "measured-fir", "autoeq", "crinacle-ief-2025", "library"].includes(t))) {
    return true;
  }
  if (preset.createdBy === "ai" && tags.includes("baseline")) return true;
  return false;
}

async function writeLibraryHeadphone(profile: HeadphoneProfile): Promise<void> {
  const payload = stableStringify(profile);
  await ensureDir(libraryHeadphonesDir());
  await fs.writeFile(libraryHeadphonePath(profile.id), payload, "utf8");
  // Runtime mirror for the installed app.
  await ensureDir(runtimeLibraryHeadphonesDir());
  await fs.writeFile(
    path.join(runtimeLibraryHeadphonesDir(), `${sanitizeId(profile.id)}.json`),
    payload,
    "utf8"
  );
}

async function removeLibraryHeadphone(id: string): Promise<void> {
  try {
    await fs.unlink(libraryHeadphonePath(id));
  } catch {
    /* ignore missing */
  }
  try {
    await fs.unlink(path.join(runtimeLibraryHeadphonesDir(), `${sanitizeId(id)}.json`));
  } catch {
    /* ignore missing */
  }
}

async function writeLibraryPreset(preset: EQPreset): Promise<void> {
  if (!isSharedLibraryPreset(preset)) return;
  const payload = stableStringify(preset);
  await ensureDir(libraryPresetsDir());
  await fs.writeFile(libraryPresetPath(preset.id), payload, "utf8");
  await ensureDir(runtimeLibraryPresetsDir());
  await fs.writeFile(
    path.join(runtimeLibraryPresetsDir(), `${sanitizeId(preset.id)}.json`),
    payload,
    "utf8"
  );
}

async function removeLibraryPreset(id: string): Promise<void> {
  try {
    await fs.unlink(libraryPresetPath(id));
  } catch {
    /* ignore missing */
  }
  try {
    await fs.unlink(path.join(runtimeLibraryPresetsDir(), `${sanitizeId(id)}.json`));
  } catch {
    /* ignore missing */
  }
}

async function loadHeadphoneProfilesFromLibraryDir(dir: string): Promise<HeadphoneProfile[]> {
  let entries: string[];
  try {
    entries = await fs.readdir(dir);
  } catch {
    return [];
  }
  const out: HeadphoneProfile[] = [];
  for (const entry of entries) {
    if (!entry.toLowerCase().endsWith(".json")) continue;
    const parsed = await readJson<HeadphoneProfile>(path.join(dir, entry));
    if (parsed && typeof parsed.id === "string" && typeof parsed.brand === "string") {
      out.push(parsed);
    }
  }
  return out;
}

async function loadHeadphoneProfilesFromLibrary(): Promise<HeadphoneProfile[]> {
  return loadHeadphoneProfilesFromLibraryDir(libraryHeadphonesDir());
}

/** Rebuild bundled aggregate seed files from library/headphones (best-effort). */
export async function rebuildBundledHeadphoneSeed(): Promise<{ count: number; paths: string[] }> {
  const profiles = (await loadHeadphoneProfilesFromLibrary())
    .map(normalizeProfile)
    .filter((p) => p.id.length > 0)
    .sort((a, b) => `${a.brand} ${a.model}`.localeCompare(`${b.brand} ${b.model}`));
  const paths = [
    path.resolve(moduleDir, "..", "data", "headphone-profiles.json"),
    path.resolve(moduleDir, "..", "..", "Sources", "AuralinkCore", "Resources", "data", "headphone-profiles.json"),
  ];
  const written: string[] = [];
  for (const p of paths) {
    try {
      await ensureDir(path.dirname(p));
      await fs.writeFile(p, stableStringify(profiles), "utf8");
      written.push(p);
    } catch {
      /* optional path may not exist in published package layouts */
    }
  }
  return { count: profiles.length, paths: written };
}

async function ensureDir(dir: string): Promise<void> {
  await fs.mkdir(dir, { recursive: true });
}

// MARK: - Band / preset normalization (mirrors EQBand.clamped + EQPreset.normalized)

/** Default log-spread band frequencies — mirrors `EQBand.emptyBand`. */
const DEFAULT_BAND_FREQS = [
  32, 48, 72, 110, 160, 240, 350, 520, 760, 1100, 1600, 2400, 3500, 5000, 7000,
  9000, 11000, 13000, 16000, 19000,
];

/** A flat, disabled band for an empty slot. Mirrors `EQBand.emptyBand`. */
function emptyBand(index: number): EQBand {
  const freq =
    index >= 1 && index <= BAND_COUNT ? DEFAULT_BAND_FREQS[index - 1] : 1000;
  return {
    index,
    type: "bell",
    frequencyHz: freq,
    gainDb: 0,
    q: 1.0,
    channel: "stereo",
    enabled: false,
  };
}

/** Clamp one band into legal ranges. Mirrors `EQBand.clamped`. */
function clampBand(band: EQBand): EQBand {
  return {
    ...band,
    frequencyHz: clamp(band.frequencyHz, FREQ_MIN, FREQ_MAX),
    gainDb: clamp(band.gainDb, GAIN_MIN, GAIN_MAX),
    q: clamp(band.q, Q_MIN, Q_MAX),
  };
}

function normalizeMeasuredCorrection(
  payload: NonNullable<NonNullable<EQPreset["correction"]>["measuredCorrection"]>
): NonNullable<NonNullable<EQPreset["correction"]>["measuredCorrection"]> {
  // Never sort/clamp/deduplicate/truncate/re-hash measured points here. A bad
  // payload must remain ineligible rather than silently becoming a new curve
  // under the caller's old content hash.
  return {
    ...payload,
    measurementId: payload.measurementId.trim(),
    sourceFormat: payload.sourceFormat.trim(),
    source: payload.source.trim(),
    rig: payload.rig?.trim(),
    provenanceURL: payload.provenanceURL.trim(),
    contentHash: payload.contentHash.trim().toLowerCase(),
    channel: payload.channel.trim(),
    phaseData: payload.phaseData.trim(),
    points: payload.points.map((point) => ({ ...point })),
  };
}

/**
 * Force a preset to exactly 20 indexed, clamped bands and clamp the preamp.
 * Mirrors `EQPreset.normalized`.
 */
export function normalizePreset(preset: EQPreset): EQPreset {
  const byIndex = new Map<number, EQBand>();
  for (const b of preset.bands) byIndex.set(b.index, clampBand(b));
  const full: EQBand[] = [];
  for (let i = 1; i <= BAND_COUNT; i++) {
    full.push(byIndex.get(i) ?? emptyBand(i));
  }
  const correction = preset.correction
    ? {
        ...preset.correction,
        correctionStrength: clamp(preset.correction.correctionStrength, 0, 1),
        targetBlend: clamp(preset.correction.targetBlend, 0, 1),
        preferenceBandIndexes: [...new Set(preset.correction.preferenceBandIndexes ?? [])]
          .filter((index) => Number.isInteger(index) && index >= 1 && index <= BAND_COUNT)
          .sort((a, b) => a - b),
        measuredCorrection: preset.correction.measuredCorrection
          ? normalizeMeasuredCorrection(preset.correction.measuredCorrection)
          : undefined,
      }
    : undefined;
  return {
    ...preset,
    bands: full,
    preampDb: clamp(preset.preampDb, PREAMP_MIN, PREAMP_MAX),
    correction,
  };
}

// MARK: - JSON helpers

async function readJson<T>(file: string): Promise<T | null> {
  try {
    const text = await fs.readFile(file, "utf8");
    return JSON.parse(text) as T;
  } catch {
    return null;
  }
}

async function readTextIfExists(file: string): Promise<string | null> {
  try {
    return await fs.readFile(file, "utf8");
  } catch {
    return null;
  }
}

/**
 * Pretty JSON with sorted keys + ISO dates, matching the app's
 * `JSONEncoder(.prettyPrinted, .sortedKeys, .iso8601)` so files round-trip
 * cleanly between the app and the MCP server.
 */
function stableStringify(value: unknown): string {
  const seen = new WeakSet<object>();
  const sortKeys = (v: unknown): unknown => {
    if (v === null || typeof v !== "object") return v;
    if (Array.isArray(v)) return v.map(sortKeys);
    const obj = v as Record<string, unknown>;
    if (seen.has(obj)) return obj;
    seen.add(obj);
    const out: Record<string, unknown> = {};
    for (const key of Object.keys(obj).sort()) {
      const child = obj[key];
      if (child === undefined) continue; // omit undefined optionals
      out[key] = sortKeys(child);
    }
    return out;
  };
  return JSON.stringify(sortKeys(value), null, 2);
}

function presetFilePath(id: string): string {
  return path.join(presetsDir(), `${sanitizeId(id)}.json`);
}

/** Keep ids filesystem-safe; preset ids are slugs/uuids so this is defensive. */
function sanitizeId(id: string): string {
  return id.replace(/[^A-Za-z0-9._-]/g, "_");
}

// MARK: - Preset CRUD

/**
 * Load every valid preset on disk (newest-updated first). Malformed files are
 * skipped. Each preset is normalized so callers always see 20 clamped bands.
 */
export async function loadAllPresets(): Promise<EQPreset[]> {
  const dir = presetsDir();
  let entries: string[];
  try {
    entries = await fs.readdir(dir);
  } catch {
    return []; // directory doesn't exist yet (app not run) → empty library
  }
  const presets: EQPreset[] = [];
  for (const entry of entries) {
    if (!entry.toLowerCase().endsWith(".json")) continue;
    const parsed = await readJson<EQPreset>(path.join(dir, entry));
    if (parsed && typeof parsed.id === "string" && Array.isArray(parsed.bands)) {
      presets.push(normalizePreset(parsed));
    }
  }
  presets.sort((a, b) => (b.updatedAt ?? "").localeCompare(a.updatedAt ?? ""));
  return presets;
}

/** Read one preset by id, or null if it doesn't exist / is malformed. */
export async function getPreset(id: string): Promise<EQPreset | null> {
  const parsed = await readJson<EQPreset>(presetFilePath(id));
  if (!parsed || typeof parsed.id !== "string" || !Array.isArray(parsed.bands)) {
    return null;
  }
  return normalizePreset(parsed);
}

/**
 * Persist a preset, bumping its version if it already existed and stamping
 * `updatedAt` (and `createdAt` for brand-new presets). Returns the saved preset.
 * The on-disk shape matches the Swift encoder so the app reads it without fuss.
 */
export async function savePreset(preset: EQPreset): Promise<EQPreset> {
  await ensureDir(presetsDir());
  const now = new Date().toISOString();
  const existing = await getPreset(preset.id);

  const normalized = normalizePreset(preset);
  const saved: EQPreset = {
    ...normalized,
    version: existing ? existing.version + 1 : Math.max(1, normalized.version),
    createdAt:
      existing?.createdAt && existing.createdAt.length > 0
        ? existing.createdAt
        : normalized.createdAt && normalized.createdAt.length > 0
          ? normalized.createdAt
          : now,
    updatedAt: now,
  };

  await fs.writeFile(presetFilePath(saved.id), stableStringify(saved), "utf8");
  await writeLibraryPreset(saved);
  return saved;
}

/** Delete one preset and its revision folder. Returns the deleted preset, or null. */
export async function deletePreset(id: string): Promise<EQPreset | null> {
  const preset = await getPreset(id);
  if (!preset) return null;
  try {
    await fs.unlink(presetFilePath(id));
  } catch {
    /* ignore missing file after the successful read */
  }
  await removeLibraryPreset(id);
  try {
    await fs.rm(path.join(revisionsDir(), sanitizeId(id)), {
      recursive: true,
      force: true,
    });
  } catch {
    /* ignore revision cleanup failures */
  }
  return preset;
}

/** True if a preset with this id exists on disk. */
export async function presetExists(id: string): Promise<boolean> {
  try {
    await fs.access(presetFilePath(id));
    return true;
  } catch {
    return false;
  }
}

// MARK: - Knowledge data

async function loadHeadphoneProfilesFrom(dir: string): Promise<HeadphoneProfile[]> {
  const data = await readJson<HeadphoneProfile[]>(
    path.join(dir, "headphone-profiles.json")
  );
  return Array.isArray(data) ? data : [];
}

async function loadDeletedHeadphoneProfileIds(): Promise<Set<string>> {
  const ids = await readJson<string[]>(
    path.join(userDataDir(), "deleted-headphone-profiles.json")
  );
  return new Set(
    Array.isArray(ids)
      ? ids.map((id) => sanitizeId(String(id).trim().toLowerCase())).filter(Boolean)
      : []
  );
}

async function saveDeletedHeadphoneProfileIds(ids: Set<string>): Promise<void> {
  await ensureDir(userDataDir());
  await fs.writeFile(
    path.join(userDataDir(), "deleted-headphone-profiles.json"),
    stableStringify([...ids].sort()),
    "utf8"
  );
}

function uniqueDirs(dirs: string[]): string[] {
  const seen = new Set<string>();
  const out: string[] = [];
  for (const dir of dirs) {
    const resolved = path.resolve(dir);
    if (seen.has(resolved)) continue;
    seen.add(resolved);
    out.push(resolved);
  }
  return out;
}

function normalizeProfile(profile: HeadphoneProfile): HeadphoneProfile {
  return {
    id: sanitizeId(profile.id.trim().toLowerCase()),
    brand: profile.brand.trim(),
    model: profile.model.trim(),
    type: profile.type,
    signature: profile.signature.trim(),
    correctionNotes: profile.correctionNotes.map((note) => note.trim()).filter(Boolean),
    harshRegionsHz: profile.harshRegionsHz
      .map((range) => ({
        lowHz: Math.max(20, Math.min(range.lowHz, range.highHz)),
        highHz: Math.min(20_000, Math.max(range.lowHz, range.highHz)),
      }))
      .filter((range) => range.highHz > range.lowHz),
    suggestedTargetCurveId: profile.suggestedTargetCurveId?.trim() || undefined,
    source: profile.source.trim(),
    credibility: profile.credibility,
  };
}

/** All headphone profiles: bundled seed + git library + user Application Support. */
export async function loadHeadphoneProfiles(): Promise<HeadphoneProfile[]> {
  const byId = new Map<string, HeadphoneProfile>();
  const deletedIds = await loadDeletedHeadphoneProfileIds();
  // Order: bundled defaults → git library → user runtime (later wins).
  for (const dir of uniqueDirs([
    dataDir(),
    libraryHeadphonesDir(),
    runtimeLibraryHeadphonesDir(),
    userDataDir(),
  ])) {
    // library dirs are folders of per-file profiles, not a single JSON.
    if (
      path.resolve(dir) === path.resolve(libraryHeadphonesDir()) ||
      path.resolve(dir) === path.resolve(runtimeLibraryHeadphonesDir())
    ) {
      const profiles =
        path.resolve(dir) === path.resolve(libraryHeadphonesDir())
          ? await loadHeadphoneProfilesFromLibrary()
          : await loadHeadphoneProfilesFromLibraryDir(dir);
      for (const profile of profiles) {
        const normalized = normalizeProfile(profile);
        if (normalized.id.length > 0) byId.set(normalized.id, normalized);
      }
      continue;
    }
    for (const profile of await loadHeadphoneProfilesFrom(dir)) {
      const normalized = normalizeProfile(profile);
      if (normalized.id.length > 0) byId.set(normalized.id, normalized);
    }
  }
  for (const id of deletedIds) byId.delete(id);
  return [...byId.values()].sort((a, b) =>
    `${a.brand} ${a.model}`.localeCompare(`${b.brand} ${b.model}`)
  );
}

/** Create or update one user headphone profile. */
export async function saveHeadphoneProfile(
  profile: HeadphoneProfile
): Promise<HeadphoneProfile> {
  const normalized = normalizeProfile(profile);
  await ensureDir(userDataDir());
  const deletedIds = await loadDeletedHeadphoneProfileIds();
  deletedIds.delete(normalized.id);
  await saveDeletedHeadphoneProfileIds(deletedIds);

  const current = await loadHeadphoneProfiles();
  const merged = new Map<string, HeadphoneProfile>();
  for (const item of current) merged.set(item.id, item);
  merged.set(normalized.id, normalized);

  const sorted = [...merged.values()].sort((a, b) =>
    `${a.brand} ${a.model}`.localeCompare(`${b.brand} ${b.model}`)
  );
  await fs.writeFile(
    path.join(userDataDir(), "headphone-profiles.json"),
    stableStringify(sorted),
    "utf8"
  );
  // Dual-write shared profile into git-tracked library (per-file).
  await writeLibraryHeadphone(normalized);
  return normalized;
}

/** Delete/hide one headphone profile. Returns the visible profile before deletion, or null. */
export async function deleteHeadphoneProfile(
  id: string
): Promise<HeadphoneProfile | null> {
  const normalizedId = sanitizeId(id.trim().toLowerCase());
  if (normalizedId.length === 0) return null;

  const existing = (await loadHeadphoneProfiles()).find((p) => p.id === normalizedId) ?? null;
  if (!existing) return null;

  await ensureDir(userDataDir());

  const userProfiles = await loadHeadphoneProfilesFrom(userDataDir());
  const keptUserProfiles = userProfiles
    .map(normalizeProfile)
    .filter((profile) => profile.id !== normalizedId)
    .sort((a, b) => `${a.brand} ${a.model}`.localeCompare(`${b.brand} ${b.model}`));
  await fs.writeFile(
    path.join(userDataDir(), "headphone-profiles.json"),
    stableStringify(keptUserProfiles),
    "utf8"
  );

  const deletedIds = await loadDeletedHeadphoneProfileIds();
  deletedIds.add(normalizedId);
  await saveDeletedHeadphoneProfileIds(deletedIds);
  await removeLibraryHeadphone(normalizedId);
  return existing;
}

/** One headphone profile by id, or null. */
export async function getHeadphoneProfile(
  id: string
): Promise<HeadphoneProfile | null> {
  const all = await loadHeadphoneProfiles();
  return all.find((p) => p.id === id) ?? null;
}

/**
 * Fuzzy headphone lookup. Mirrors `KnowledgeBase.profileMatching`: matches when
 * the slug, brand, model, or "brand model" display name contains the query
 * (case-insensitive), or vice versa.
 */
export async function matchHeadphoneProfile(
  query: string
): Promise<HeadphoneProfile | null> {
  const all = await loadHeadphoneProfiles();
  const needle = query.trim().toLowerCase();
  if (needle.length === 0) return null;

  // Exact slug first.
  const exact = all.find((p) => p.id.toLowerCase() === needle);
  if (exact) return exact;

  for (const p of all) {
    const haystacks = [
      p.id,
      p.brand,
      p.model,
      `${p.brand} ${p.model}`,
    ].map((s) => s.toLowerCase());
    if (haystacks.some((h) => h.includes(needle) || needle.includes(h))) {
      return p;
    }
  }
  return null;
}

/** All target curves, or [] if absent/malformed. */
export async function loadTargetCurves(): Promise<TargetCurve[]> {
  const data = await readJson<TargetCurve[]>(
    path.join(dataDir(), "target-curves.json")
  );
  return Array.isArray(data) ? data : [];
}

/** One target curve by id, or null. */
export async function getTargetCurve(id: string): Promise<TargetCurve | null> {
  const all = await loadTargetCurves();
  return all.find((c) => c.id === id) ?? null;
}

/** Safety rules from disk, or the built-in defaults if the file is absent. */
export async function loadSafetyRules(): Promise<SafetyRules> {
  const data = await readJson<SafetyRules>(
    path.join(dataDir(), "safety-rules.json")
  );
  if (
    data &&
    typeof data.maxBoostDb === "number" &&
    typeof data.targetHeadroomDb === "number"
  ) {
    return data;
  }
  return DEFAULT_SAFETY_RULES;
}

// MARK: - User tuning preferences (AI taste-memory; not read by the app)

/** Sentiment of a single piece of tuning feedback. */
export type TuningSentiment = "liked" | "disliked" | "mixed";

/** Recognized perceived-issue buckets, mirroring the descriptor rules in the agent guide. */
export const PERCEIVED_ISSUES = [
  "too_bright",
  "too_dark",
  "too_bassy",
  "not_enough_bass",
  "harsh",
  "sibilant",
  "muddy",
  "boomy",
  "thin",
  "nasal",
  "boxy",
  "too_much_change",
  "not_enough_change",
  "good_balance",
  "other",
] as const;
export type PerceivedIssue = (typeof PERCEIVED_ISSUES)[number];

/** One recorded reaction to a tuning. The raw log; aggregates are derived at read time. */
export interface TuningFeedbackEntry {
  id: string;
  createdAt: string;
  /** Display name or slug, e.g. 'Sennheiser HD600'. null/omitted = global feedback. */
  headphone?: string;
  /** Transient audition id or saved preset id that was reacted to, if any. */
  presetId?: string;
  presetName?: string;
  sentiment: TuningSentiment;
  perceivedIssue?: PerceivedIssue;
  /** What the tuning was attempting, e.g. 'warmer'. */
  goal?: string;
  /** The user's own words, if any. */
  feedbackText?: string;
  /** Freeform preference markers the AI infers, e.g. 'less-treble-bite'. */
  tags?: string[];
  /** Snapshot of the bands that were auditioned (only meaningful fields). */
  bands?: Array<{ type: BandType; frequencyHz: number; gainDb: number; q: number }>;
}

/** The on-disk shape: just a newest-first log, capped to keep it tidy. */
export interface UserTuningPreferences {
  entries: TuningFeedbackEntry[];
}

const PREFS_FILE = "user-tuning-preferences.json";
const MAX_PREF_ENTRIES = 500;

function prefsFilePath(): string {
  return path.join(userDataDir(), PREFS_FILE);
}

/** Load the preference log (empty list if absent/malformed). */
export async function loadUserTuningPreferences(): Promise<UserTuningPreferences> {
  const data = await readJson<UserTuningPreferences>(prefsFilePath());
  if (data && Array.isArray(data.entries)) return data;
  return { entries: [] };
}

/** Prepend a feedback entry (newest first), cap the log, persist, and return the new state. */
export async function appendTuningFeedback(
  entry: TuningFeedbackEntry
): Promise<UserTuningPreferences> {
  await ensureDir(userDataDir());
  const current = await loadUserTuningPreferences();
  const entries = [entry, ...current.entries].slice(0, MAX_PREF_ENTRIES);
  const prefs: UserTuningPreferences = { entries };
  await fs.writeFile(prefsFilePath(), stableStringify(prefs), "utf8");
  return prefs;
}

/** Delete one feedback entry by id. Returns the removed entry, or null. */
export async function deleteTuningFeedback(
  id: string
): Promise<TuningFeedbackEntry | null> {
  const current = await loadUserTuningPreferences();
  const idx = current.entries.findIndex((e) => e.id === id);
  if (idx < 0) return null;
  const [removed] = current.entries.splice(idx, 1);
  await ensureDir(userDataDir());
  await fs.writeFile(
    prefsFilePath(),
    stableStringify({ entries: current.entries }),
    "utf8"
  );
  return removed;
}

export interface PreferenceCount {
  count: number;
}

/** Aggregated, AI-facing view of the feedback log for one scope (global or a headphone). */
export interface TuningPreferenceSummary {
  scope: "global" | "headphone";
  headphone: string | null;
  totalEntries: number;
  sentimentCounts: { liked: number; disliked: number; mixed: number };
  topDislikedIssues: Array<{ issue: PerceivedIssue; count: number }>;
  topLikedIssues: Array<{ issue: PerceivedIssue; count: number }>;
  likedGoals: Array<{ goal: string; count: number }>;
  dislikedGoals: Array<{ goal: string; count: number }>;
  tagFrequency: Array<{ tag: string; count: number }>;
  derivedNotes: string[];
  recent: TuningFeedbackEntry[];
}

function sortedCounters(
  counter: Map<string, number>,
  limit: number
): Array<{ key: string; count: number }> {
  return [...counter.entries()]
    .map(([key, count]) => ({ key, count }))
    .sort((a, b) => b.count - a.count || a.key.localeCompare(b.key))
    .slice(0, limit);
}

/**
 * Derive an aggregated preference summary from the feedback log, optionally
 * scoped to one headphone (fuzzy match on the entry's headphone field).
 * Pure function — safe to unit-test offline.
 */
export function summarizeTuningPreferences(
  entries: TuningFeedbackEntry[],
  options: { headphoneNeedle?: string; limit?: number } = {}
): TuningPreferenceSummary {
  const limit = Math.max(0, options.limit ?? 10);
  const needle = options.headphoneNeedle?.trim().toLowerCase() ?? "";
  const scoped = needle.length > 0;
  const filtered = scoped
    ? entries.filter((e) => (e.headphone ?? "").toLowerCase().includes(needle))
    : entries;

  const sentimentCounts = { liked: 0, disliked: 0, mixed: 0 };
  const issueCounter = new Map<string, number>(); // `${sentiment}|${issue}`
  const likedGoalCounts = new Map<string, number>();
  const dislikedGoalCounts = new Map<string, number>();
  const tagFreq = new Map<string, number>();

  for (const e of filtered) {
    if (sentimentCounts[e.sentiment] !== undefined) sentimentCounts[e.sentiment]++;
    if (e.perceivedIssue) {
      const key = `${e.sentiment}|${e.perceivedIssue}`;
      issueCounter.set(key, (issueCounter.get(key) ?? 0) + 1);
    }
    const goal = e.goal?.trim().toLowerCase();
    if (goal) {
      if (e.sentiment === "liked") likedGoalCounts.set(goal, (likedGoalCounts.get(goal) ?? 0) + 1);
      else if (e.sentiment === "disliked")
        dislikedGoalCounts.set(goal, (dislikedGoalCounts.get(goal) ?? 0) + 1);
    }
    for (const t of e.tags ?? []) {
      const tk = t.trim().toLowerCase();
      if (tk) tagFreq.set(tk, (tagFreq.get(tk) ?? 0) + 1);
    }
  }

  const topIssuesFor = (sentiment: TuningSentiment) =>
    sortedCounters(issueCounter, 5)
      .filter(({ key }) => key.startsWith(`${sentiment}|`))
      .map(({ key, count }) => ({
        issue: key.slice(sentiment.length + 1) as PerceivedIssue,
        count,
      }));

  const topDislikedIssues = topIssuesFor("disliked");
  const topLikedIssues = topIssuesFor("liked");
  const likedGoals = sortedCounters(likedGoalCounts, 5).map(({ key, count }) => ({
    goal: key,
    count,
  }));
  const dislikedGoals = sortedCounters(dislikedGoalCounts, 5).map(({ key, count }) => ({
    goal: key,
    count,
  }));
  const tagFrequency = sortedCounters(tagFreq, 8).map(({ key, count }) => ({
    tag: key,
    count,
  }));

  const derivedNotes: string[] = [];
  if (filtered.length === 0) {
    derivedNotes.push("No feedback recorded yet for this scope.");
  } else {
    if (topDislikedIssues.length)
      derivedNotes.push(
        `Avoid: ${topDislikedIssues
          .map((i) => `${i.issue.replace(/_/g, " ")} (×${i.count})`)
          .join(", ")}.`
      );
    if (topLikedIssues.length)
      derivedNotes.push(
        `Generally liked: ${topLikedIssues
          .map((i) => `${i.issue.replace(/_/g, " ")} (×${i.count})`)
          .join(", ")}.`
      );
    if (likedGoals.length)
      derivedNotes.push(
        `Directions that landed well: ${likedGoals
          .map((g) => `${g.goal} (×${g.count})`)
          .join(", ")}.`
      );
    if (dislikedGoals.length)
      derivedNotes.push(
        `Directions that missed: ${dislikedGoals
          .map((g) => `${g.goal} (×${g.count})`)
          .join(", ")}.`
      );
    if (tagFrequency.length)
      derivedNotes.push(
        `Preference markers: ${tagFrequency
          .map((t) => `${t.tag} (×${t.count})`)
          .join(", ")}.`
      );
  }

  return {
    scope: scoped ? "headphone" : "global",
    headphone: scoped ? options.headphoneNeedle ?? null : null,
    totalEntries: filtered.length,
    sentimentCounts,
    topDislikedIssues,
    topLikedIssues,
    likedGoals,
    dislikedGoals,
    tagFrequency,
    derivedNotes,
    recent: filtered.slice(0, limit),
  };
}

// MARK: - Agent guide

export interface AgentEQGuide {
  source: "user" | "docs" | "bundled" | "generated";
  format: "markdown";
  path?: string;
  content: string;
}

const GENERATED_AGENT_GUIDE = `# Auralink Agent EQ Guide

Auralink is the local audio engine, preset store, validator, and live apply endpoint. It is not an AI model. The AI client must read evidence, decide explicit EQ bands, then use Auralink tools to validate, audition, save, and apply.

## Default Workflow

1. Read get_agent_eq_guide and get_current_audio_state before changing sound.
2. If the user provides headphone or earphone data and says to add it, create or update a headphone profile, then create a saved baseline preset for that model.
3. Use Harman Neutral as the default baseline target unless the user, evidence, or measurement source clearly says otherwise.
4. For later preference changes, audition first. Do not save every experiment. Save only when the user says it is good, wants to keep it, or asks to save.
5. If the user says something was added by mistake, use delete_headphone_profile or delete_preset, then re-add with a clean model name if needed.
6. If the user explicitly asks to hear a change now, audition/apply with confirmed:true. Control acceptance is not audible proof: require audible:true or active/routed/enabled state with the expected preset and matching requested/committed DSP generations.

## Preset Policy

- Model baseline: saved preset. Name it "<Brand> <Model> - Harman Baseline" or another clear model baseline name.
- Preference tuning: audition-only first. Examples: warmer, more exciting, smoother treble, more vocal, less bass.
- Save-on-like: when the user says "좋아", "맘에 들어", "저장해줘", or equivalent, save the currently auditioned preset with a descriptive name and tags.
- Delete mistakes: remove mistaken visible model names/presets instead of leaving clutter in the library.
- Default audition level policy: preserve volume and dynamics. Use preampDb:0 and autoGain:false unless the user asks for protected/safe mode or the EQ has extreme boosts.
- The clipping meter and user's ears are feedback. Warnings are useful, but small positive boosts are acceptable for quick listening tests.

## Link/Data Ingestion

- If a measurement graph exists, use it as primary evidence and set credibility to measured or community.
- If only review text/specs exist, infer carefully, set credibility to estimated, and keep the baseline conservative.
- Store source URLs and caveats in the headphone profile source field.
- Add harshRegionsHz only when the review/graph suggests likely fatigue or peaks.

## Output Shape The AI Should Produce

For "add this model":
- headphoneProfile: brand, model, type, signature, correctionNotes, harshRegionsHz, suggestedTargetCurveId:"harman-neutral", source, credibility.
- baselinePreset: explicit bands, headphone display name, goal, tags including ai, baseline, harman-neutral, and the profile id.
- Keep the visible model name clean; source aliases or translated subtitles belong in source/notes.

For "tune this sound":
- auditionPreset: explicit bands, headphone display name, goal, preampDb:0, autoGain:false, tags including ai and audition.
- rationale: short explanation of audible intent and any risk/caveat.

## Band Design Defaults

- Prefer 3-8 meaningful parametric moves over filling all 20 bands.
- Use broad shelves for tonal balance and narrower bell filters for peaks.
- Start with +/-0.5 to 2 dB moves for subjective preference, larger only when evidence or user intent supports it.
- For earbuds/open designs with limited bass, be realistic: a low shelf can add body, but cannot create sealed sub-bass.
- Use cuts around harsh regions before adding treble elsewhere.
`;

export async function loadAgentEQGuide(): Promise<AgentEQGuide> {
  const candidates: Array<{ source: AgentEQGuide["source"]; file: string }> = [
    { source: "user", file: path.join(userDataDir(), "agent-eq-guide.md") },
    { source: "docs", file: path.resolve(moduleDir, "..", "..", "docs", "AURALINK_AGENT_EQ_GUIDE.md") },
    { source: "bundled", file: path.join(dataDir(), "agent-eq-guide.md") },
  ];
  for (const candidate of candidates) {
    const content = await readTextIfExists(candidate.file);
    if (content && content.trim().length > 0) {
      return {
        source: candidate.source,
        format: "markdown",
        path: candidate.file,
        content,
      };
    }
  }
  return {
    source: "generated",
    format: "markdown",
    content: GENERATED_AGENT_GUIDE,
  };
}

// MARK: - Preset construction helpers (used by create_eq_preset)

/** A fresh 20-slot flat band array (all disabled). Mirrors `EQBand.defaultBands`. */
export function defaultBands(): EQBand[] {
  const bands: EQBand[] = [];
  for (let i = 1; i <= BAND_COUNT; i++) bands.push(emptyBand(i));
  return bands;
}

/**
 * Build a normalized 20-band array from a sparse list of partial band specs.
 * Slots not provided stay flat/disabled. Provided slots are enabled and clamped.
 */
export function bandsFromSpecs(
  specs: Array<{
    index?: number;
    type?: BandType;
    frequencyHz: number;
    gainDb?: number;
    q?: number;
    channel?: BandChannel;
    enabled?: boolean;
  }>
): EQBand[] {
  const bands = defaultBands();
  let nextAuto = 1;
  for (const spec of specs) {
    // Choose a slot: explicit index, else next free slot.
    let idx = spec.index ?? 0;
    if (idx < 1 || idx > BAND_COUNT) {
      while (nextAuto <= BAND_COUNT && bands[nextAuto - 1].enabled) nextAuto++;
      if (nextAuto > BAND_COUNT) break; // no slots left
      idx = nextAuto;
    }
    bands[idx - 1] = clampBand({
      index: idx,
      type: spec.type ?? "bell",
      frequencyHz: spec.frequencyHz,
      gainDb: spec.gainDb ?? 0,
      q: spec.q ?? 1.0,
      channel: spec.channel ?? "stereo",
      enabled: spec.enabled ?? true,
    });
  }
  return bands;
}
