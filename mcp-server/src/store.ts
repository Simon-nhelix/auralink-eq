/**
 * Local filesystem access for the MCP server.
 *
 * Two roots, mirroring `AuralinkPaths` on the Swift side:
 *
 * - The **working preset directory** the app loads from
 *   (`~/Library/Application Support/Auralink/presets`, override with
 *   `AURALINK_PRESETS_DIR`) so the AI and the app see one live library. Target
 *   curves and safety rules come from `AURALINK_DATA_DIR` (default the bundled
 *   `mcp-server/data`), where the app's core-knowledge module copies identical
 *   JSON so the server works standalone.
 * - The **user's collection** (`~/auralink-collection`, override with
 *   `AURALINK_COLLECTION_DIR`): per-file headphone profiles and curated presets,
 *   typically a git checkout the user owns. This is the only source of headphone
 *   profiles — Auralink ships none, because a shipped database would impose one
 *   person's taste on every user.
 *
 * Writes into the collection are deliberate: profiles go there because the user
 * registered them, and presets only via `addPresetToCollection`. Nothing
 * accumulates in the user's repository as a side effect.
 *
 * Everything degrades gracefully: a missing knowledge file yields an empty list
 * (or the built-in default `SafetyRules`), and a malformed preset file is skipped
 * rather than crashing the server.
 */

import { promises as fs } from "node:fs";
import { execSync } from "node:child_process";
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

// MARK: - ID validation (mirrors Swift CollectionRecordID)

const ID_MAX_LENGTH = 128;

/**
 * Validates that `id` is safe for filesystem use.
 * Mirrors Swift `CollectionRecordID.isValid`.
 */
export function isValidRecordId(id: string): boolean {
  const trimmed = id.trim();
  if (!trimmed || trimmed.length > ID_MAX_LENGTH) return false;
  if (trimmed === "." || trimmed === "..") return false;
  if (trimmed.includes("..")) return false;
  if (trimmed.startsWith("-") || trimmed.startsWith(".")) return false;
  if (trimmed.endsWith(".") || trimmed.endsWith("-")) return false;
  // Must start with alphanumeric, then allow alphanumeric + ._-
  return /^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(trimmed);
}

/**
 * Returns the ID if valid, null otherwise.
 * Mirrors Swift `CollectionRecordID.parse`.
 */
export function parseRecordId(id: string): string | null {
  return isValidRecordId(id) ? id.trim() : null;
}

/**
 * Returns the ID if valid, throws otherwise.
 * Mirrors Swift `CollectionRecordID.require`.
 */
export function requireRecordId(id: string): string {
  const parsed = parseRecordId(id);
  if (parsed === null) {
    throw new Error(
      `Invalid collection record ID: '${id}'. IDs must start with a letter or number, ` +
        `contain only letters, numbers, dots, underscores, and dashes, and be at most ${ID_MAX_LENGTH} characters.`
    );
  }
  return parsed;
}

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
 * Expands `~` to the user's home directory.
 * Mirrors Swift `configuredCollectionPath`'s tilde expansion.
 */
function expandTilde(p: string): string {
  if (p === "~") return os.homedir();
  if (p.startsWith("~/")) return path.join(os.homedir(), p.slice(2));
  return p;
}

/**
 * Normalizes a configured collection path: trims, expands `~`, rejects empty
 * values and relative paths (a relative collection root would follow the
 * process CWD).
 * Mirrors Swift `AuralinkPaths.configuredCollectionPath`.
 */
function normalizeCollectionPath(raw: string | undefined): string | null {
  if (!raw) return null;
  const trimmed = raw.trim();
  if (!trimmed) return null;
  const expanded = expandTilde(trimmed);
  if (!path.isAbsolute(expanded)) return null;
  return expanded;
}

/**
 * The user's own headphone/preset collection root (`~/auralink-collection` by
 * default). Override with `AURALINK_COLLECTION_DIR`; `AURALINK_LIBRARY_DIR` is
 * accepted as the pre-split name so existing configs keep working.
 *
 * Resolution order matches Swift `AuralinkPaths.collectionDirectory`:
 * 1. `AURALINK_COLLECTION_DIR` / `AURALINK_LIBRARY_DIR` environment variable
 * 2. macOS `defaults read com.auralink.eq AuralinkCollectionDirectory` (when
 *    available and env is unset)
 * 3. `~/auralink-collection`
 *
 * Deliberately not under `~/Documents`: that folder is TCC-protected and an
 * ad-hoc signed build loses the grant on every rebuild.
 */
export function collectionDir(): string {
  // 1. Environment override
  const envOverride =
    process.env.AURALINK_COLLECTION_DIR ?? process.env.AURALINK_LIBRARY_DIR;
  const fromEnv = normalizeCollectionPath(envOverride);
  if (fromEnv) return fromEnv;

  // 2. macOS UserDefaults (only when env is unset and on macOS).
  //    Memoized: spawning `defaults` on every call would be wasteful.
  if (process.platform === "darwin") {
    if (cachedDefaultsCollectionDir === undefined) {
      cachedDefaultsCollectionDir = readDefaultsCollectionDir();
    }
    if (cachedDefaultsCollectionDir) return cachedDefaultsCollectionDir;
  }

  // 3. Default
  return path.join(os.homedir(), "auralink-collection");
}

/** undefined = not yet read; null = read but unset/invalid. */
let cachedDefaultsCollectionDir: string | null | undefined;

function readDefaultsCollectionDir(): string | null {
  try {
    const result = execSync(
      "defaults read com.auralink.eq AuralinkCollectionDirectory 2>/dev/null || true",
      { encoding: "utf8", stdio: ["pipe", "pipe", "pipe"] }
    ).trim();
    return normalizeCollectionPath(result);
  } catch {
    // defaults command not available or failed — fall through to default
    return null;
  }
}

export function collectionHeadphonesDir(): string {
  return path.join(collectionDir(), "headphones");
}

export function collectionPresetsDir(): string {
  return path.join(collectionDir(), "presets");
}

export function collectionManifestPath(): string {
  return path.join(collectionDir(), "manifest.json");
}

function collectionHeadphonePath(id: string): string {
  const safeID = requireRecordId(id);
  return path.join(collectionHeadphonesDir(), `${safeID}.json`);
}

function collectionPresetPath(id: string): string {
  const safeID = requireRecordId(id);
  return path.join(collectionPresetsDir(), `${safeID}.json`);
}

async function writeCollectionHeadphone(profile: HeadphoneProfile): Promise<void> {
  await ensureDir(collectionHeadphonesDir());
  await atomicWriteFile(collectionHeadphonePath(profile.id), stableStringify(profile));
}

async function removeCollectionHeadphone(id: string): Promise<boolean> {
  return unlinkUnlessMissing(collectionHeadphonePath(id));
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
    // Defensive: skip records missing required fields rather than crashing.
    if (
      parsed &&
      typeof parsed.id === "string" &&
      typeof parsed.brand === "string" &&
      typeof parsed.model === "string" &&
      typeof parsed.type === "string" &&
      typeof parsed.signature === "string" &&
      Array.isArray(parsed.correctionNotes) &&
      Array.isArray(parsed.harshRegionsHz) &&
      typeof parsed.source === "string" &&
      typeof parsed.credibility === "string"
    ) {
      out.push(parsed);
    }
  }
  return out;
}

async function ensureDir(dir: string): Promise<void> {
  await fs.mkdir(dir, { recursive: true });
}

/**
 * Writes a file atomically: temp file in the same directory, then rename.
 * A crash mid-write can never leave a truncated JSON at the real path —
 * readers see either the old file or the new one, never a half-written mix.
 */
async function atomicWriteFile(filePath: string, content: string): Promise<void> {
  const dir = path.dirname(filePath);
  const tempPath = path.join(
    dir,
    `.tmp-${process.pid}-${Date.now()}-${Math.random().toString(36).slice(2)}`
  );
  try {
    await fs.writeFile(tempPath, content, "utf8");
    await fs.rename(tempPath, filePath);
  } catch (error) {
    await fs.rm(tempPath, { force: true }).catch(() => {});
    throw error;
  }
}

/**
 * Deletes a file, tolerating "already gone" but surfacing real failures.
 * - Returns: true when a file was removed, false when it did not exist.
 * - Throws: on any other error (permissions, I/O) — a silent "success" would
 *   leave the record in place while the caller reports it deleted.
 */
async function unlinkUnlessMissing(filePath: string): Promise<boolean> {
  try {
    await fs.unlink(filePath);
    return true;
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return false;
    throw error;
  }
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
  const safeID = requireRecordId(id);
  return path.join(presetsDir(), `${safeID}.json`);
}

// MARK: - Preset CRUD

/** Every valid preset in one directory, keyed by id. Malformed files are skipped. */
async function loadPresetsFromDir(dir: string): Promise<Map<string, EQPreset>> {
  const byId = new Map<string, EQPreset>();
  let entries: string[];
  try {
    entries = await fs.readdir(dir);
  } catch {
    return byId; // directory doesn't exist yet → nothing to load
  }
  for (const entry of entries) {
    if (!entry.toLowerCase().endsWith(".json")) continue;
    const parsed = await readJson<EQPreset>(path.join(dir, entry));
    if (parsed && typeof parsed.id === "string" && Array.isArray(parsed.bands)) {
      byId.set(parsed.id, normalizePreset(parsed));
    }
  }
  return byId;
}

/**
 * Load every valid preset from the working directory and the user's collection
 * (newest-updated first). On an id collision the working copy wins, matching
 * `PresetStore.loadAll` on the Swift side.
 */
export async function loadAllPresets(): Promise<EQPreset[]> {
  const fromCollection = await loadPresetsFromDir(collectionPresetsDir());
  const fromWorking = await loadPresetsFromDir(presetsDir());
  const byId = new Map([...fromCollection, ...fromWorking]);
  return [...byId.values()].sort((a, b) =>
    (b.updatedAt ?? "").localeCompare(a.updatedAt ?? "")
  );
}

/** Ids currently present in the user's collection. */
export async function collectionPresetIds(): Promise<string[]> {
  return [...(await loadPresetsFromDir(collectionPresetsDir())).keys()].sort();
}

/**
 * Read one preset by id from the working directory, falling back to the user's
 * collection. Null if neither has it or the file is malformed.
 */
export async function getPreset(id: string): Promise<EQPreset | null> {
  for (const file of [presetFilePath(id), collectionPresetPath(id)]) {
    const parsed = await readJson<EQPreset>(file);
    if (parsed && typeof parsed.id === "string" && Array.isArray(parsed.bands)) {
      return normalizePreset(parsed);
    }
  }
  return null;
}

/**
 * Copy a preset into the user's collection. The only path that writes presets
 * there, so nothing lands in the user's repository without them asking.
 */
export async function addPresetToCollection(id: string): Promise<EQPreset | null> {
  const preset = await getPreset(id);
  if (!preset) return null;
  await ensureDir(collectionPresetsDir());
  await atomicWriteFile(collectionPresetPath(preset.id), stableStringify(preset));
  return preset;
}

/** Remove a preset from the collection, leaving the working copy alone. */
export async function removePresetFromCollection(id: string): Promise<boolean> {
  return unlinkUnlessMissing(collectionPresetPath(id));
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

  // Working directory only. Getting into the user's collection takes an explicit
  // `addPresetToCollection`.
  await atomicWriteFile(presetFilePath(saved.id), stableStringify(saved));
  return saved;
}

/** Delete one preset and its revision folder. Returns the deleted preset, or null. */
export async function deletePreset(id: string): Promise<EQPreset | null> {
  const preset = await getPreset(id);
  if (!preset) return null;
  await unlinkUnlessMissing(presetFilePath(id));
  // Drop the collection copy too, otherwise the preset reappears on next load
  // and the delete reads as having failed.
  await removePresetFromCollection(id);
  // Revision cleanup is best-effort but real failures are surfaced: fs.rm with
  // force:true already tolerates a missing folder, so a rejection here means a
  // genuine I/O problem the caller should hear about.
  await fs.rm(path.join(revisionsDir(), requireRecordId(id)), {
    recursive: true,
    force: true,
  });
  return preset;
}

/** True if a preset with this id exists in the working directory or the collection. */
export async function presetExists(id: string): Promise<boolean> {
  return (await getPreset(id)) != null;
}

// MARK: - Knowledge data

function normalizeProfile(profile: HeadphoneProfile): HeadphoneProfile {
  // Defensive: handle missing fields gracefully to prevent crashes.
  const safeId = typeof profile.id === "string" ? profile.id.trim().toLowerCase() : "";
  const brand = typeof profile.brand === "string" ? profile.brand.trim() : "";
  const model = typeof profile.model === "string" ? profile.model.trim() : "";
  const signature = typeof profile.signature === "string" ? profile.signature.trim() : "";
  const source = typeof profile.source === "string" ? profile.source.trim() : "";
  const correctionNotes = Array.isArray(profile.correctionNotes)
    ? profile.correctionNotes.map((n) => (typeof n === "string" ? n.trim() : "")).filter(Boolean)
    : [];
  const harshRegionsHz = Array.isArray(profile.harshRegionsHz)
    ? profile.harshRegionsHz
        .map((range) => {
          if (!range || typeof range.lowHz !== "number" || typeof range.highHz !== "number") {
            return null;
          }
          return {
            lowHz: Math.max(20, Math.min(range.lowHz, range.highHz)),
            highHz: Math.min(20_000, Math.max(range.lowHz, range.highHz)),
          };
        })
        .filter((r): r is NonNullable<typeof r> => r !== null)
        .filter((r) => r.highHz > r.lowHz)
    : [];

  return {
    // Invalid ids (e.g. path traversal from a hand-edited file) normalize to
    // empty so the profile is skipped at load and rejected on save — never
    // silently mangled into a colliding filename.
    id: parseRecordId(safeId) ?? "",
    brand,
    model,
    type: profile.type,
    signature,
    correctionNotes,
    harshRegionsHz,
    suggestedTargetCurveId:
      typeof profile.suggestedTargetCurveId === "string"
        ? profile.suggestedTargetCurveId.trim() || undefined
        : undefined,
    source,
    credibility: profile.credibility,
  };
}

/**
 * All headphone profiles, from the user's collection and nowhere else.
 *
 * There is no bundled seed to merge and no tombstone file to subtract: deleting
 * the file *is* the deletion, because every profile got there because the user
 * put it there.
 */
export async function loadHeadphoneProfiles(): Promise<HeadphoneProfile[]> {
  const byId = new Map<string, HeadphoneProfile>();
  for (const profile of await loadHeadphoneProfilesFromLibraryDir(collectionHeadphonesDir())) {
    const normalized = normalizeProfile(profile);
    if (normalized.id.length > 0) byId.set(normalized.id, normalized);
  }
  return [...byId.values()].sort((a, b) =>
    `${a.brand} ${a.model}`.localeCompare(`${b.brand} ${b.model}`)
  );
}

/** Create or update one headphone profile in the user's collection. */
export async function saveHeadphoneProfile(
  profile: HeadphoneProfile
): Promise<HeadphoneProfile> {
  const normalized = normalizeProfile(profile);
  await writeCollectionHeadphone(normalized);
  return normalized;
}

/** Delete one headphone profile. Returns the profile before deletion, or null. */
export async function deleteHeadphoneProfile(
  id: string
): Promise<HeadphoneProfile | null> {
  // Reject invalid ids outright instead of sanitizing them into a possibly
  // colliding filename (two distinct raw ids could map to one sanitized file).
  const normalizedId = parseRecordId(id.trim().toLowerCase());
  if (!normalizedId) return null;

  const existing = (await loadHeadphoneProfiles()).find((p) => p.id === normalizedId) ?? null;
  if (!existing) return null;

  await removeCollectionHeadphone(normalizedId);
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
  await atomicWriteFile(prefsFilePath(), stableStringify(prefs));
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
  await atomicWriteFile(
    prefsFilePath(),
    stableStringify({ entries: current.entries })
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
