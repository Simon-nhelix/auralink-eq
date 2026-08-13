/**
 * AutoEq integration — measured headphone corrections.
 *
 * The AutoEq project (github.com/jaakkopasanen/AutoEq) publishes parametric EQ
 * corrections toward the Harman target computed from real measurements
 * (oratory1990, crinacle, Rtings, …). This module looks a headphone up in the
 * published results index and returns both the PEQ fallback and, when present,
 * the dense GraphicEQ magnitude curve used by Auralink's measured FIR renderer,
 * so the AI client can build a measured baseline instead of guessing from prose.
 *
 * Network etiquette: everything is cached on disk
 * (`~/Library/Application Support/Auralink/autoeq-cache`). The ~850 KB results
 * index refreshes weekly; individual corrections are kept for 30 days. When the
 * network is down, stale cache is served rather than failing.
 */

import { promises as fs } from "fs";
import * as path from "path";
import * as os from "os";
import { createHash } from "crypto";

import {
  BandType,
  MeasuredCorrectionPayload,
  FREQ_MIN,
  FREQ_MAX,
  GAIN_MIN,
  GAIN_MAX,
  Q_MIN,
  Q_MAX,
  PREAMP_MIN,
  PREAMP_MAX,
} from "./types.js";

const AUTOEQ_RAW_BASE = "https://raw.githubusercontent.com/jaakkopasanen/AutoEq/master/results";
const FETCH_TIMEOUT_MS = 20_000;
const INDEX_TTL_MS = 7 * 24 * 60 * 60 * 1000;       // a week
const CORRECTION_TTL_MS = 30 * 24 * 60 * 60 * 1000; // a month

// MARK: - Types

/** One row of the AutoEq results index. */
export interface AutoEqEntry {
  /** Display name as measured, e.g. "Sennheiser HD 600". */
  name: string;
  /** URL-encoded path below `results/`, e.g. "oratory1990/over-ear/Sennheiser%20HD%20600". */
  encodedRelPath: string;
  /** Measurement source, e.g. "oratory1990". */
  source: string;
  /** Measurement rig when listed, e.g. "GRAS 43AG-7". */
  rig?: string;
}

export interface AutoEqBand {
  type: BandType;
  frequencyHz: number;
  gainDb: number;
  q: number;
}

export interface AutoEqCorrection {
  name: string;
  source: string;
  rig?: string;
  /** AutoEq's own preamp for this correction, clamped to Auralink's range. */
  preampDb: number;
  bands: AutoEqBand[];
  /** Where the parametric file was fetched from (provenance). */
  url: string;
  /** Dense measured correction for Auralink's software FIR renderer, when published. */
  measuredCorrection?: MeasuredCorrectionPayload;
  /** Anything that had to be clamped/dropped while converting. */
  conversionNotes: string[];
}

export interface AutoEqLookup {
  found: boolean;
  correction?: AutoEqCorrection;
  /** Other measurements of (roughly) the same model, best first. */
  alternates: Array<{ name: string; source: string; rig?: string }>;
  /** When nothing matched: closest index names to help the AI re-query. */
  suggestions: string[];
}

// MARK: - Cache locations

/** ~/Library/Application Support/Auralink/autoeq-cache unless overridden. */
function cacheDir(): string {
  const override = process.env.AURALINK_AUTOEQ_CACHE_DIR;
  if (override && override.trim().length > 0) return override.trim();
  return path.join(os.homedir(), "Library", "Application Support", "Auralink", "autoeq-cache");
}

async function ensureCacheDir(): Promise<string> {
  const dir = cacheDir();
  await fs.mkdir(dir, { recursive: true });
  return dir;
}

async function readCacheFile(name: string, ttlMs: number): Promise<string | null> {
  try {
    const file = path.join(cacheDir(), name);
    const stat = await fs.stat(file);
    if (Date.now() - stat.mtimeMs > ttlMs) return null;
    return await fs.readFile(file, "utf-8");
  } catch {
    return null;
  }
}

/** Reads a cache file even when expired (network-down fallback). */
async function readCacheFileStale(name: string): Promise<string | null> {
  try {
    return await fs.readFile(path.join(cacheDir(), name), "utf-8");
  } catch {
    return null;
  }
}

async function writeCacheFile(name: string, content: string): Promise<void> {
  const dir = await ensureCacheDir();
  // Atomic: a crash mid-write must not leave a truncated cache behind —
  // readers tolerate a missing file (re-download) but a half-written JSON
  // would poison every offline fallback until the TTL expires.
  const target = path.join(dir, name);
  const temp = path.join(
    dir,
    `.tmp-${process.pid}-${Date.now()}-${Math.random().toString(36).slice(2)}`
  );
  try {
    await fs.writeFile(temp, content, "utf-8");
    await fs.rename(temp, target);
  } catch (error) {
    await fs.rm(temp, { force: true }).catch(() => {});
    throw error;
  }
}

// MARK: - Fetch

async function fetchText(url: string): Promise<string> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), FETCH_TIMEOUT_MS);
  try {
    const res = await fetch(url, { signal: controller.signal });
    if (!res.ok) {
      throw new Error(`AutoEq fetch failed: ${res.status} ${res.statusText} for ${url}`);
    }
    return await res.text();
  } finally {
    clearTimeout(timer);
  }
}

// MARK: - Index

/**
 * Parses one index line of the form
 * `- [Name](./Source/rig%20form/Name) by Source on Rig`.
 * The URL part can contain unencoded parentheses (e.g. "(ANC Off)"), so the
 * link target is extracted with balanced-paren scanning, not a regex.
 */
function parseIndexLine(line: string): AutoEqEntry | null {
  const trimmed = line.trim();
  if (!trimmed.startsWith("- [")) return null;
  const nameEnd = trimmed.indexOf("](");
  if (nameEnd < 0) return null;
  const name = trimmed.slice(3, nameEnd).trim();
  if (name.length === 0) return null;

  let depth = 1;
  let i = nameEnd + 2;
  const urlStart = i;
  while (i < trimmed.length && depth > 0) {
    const ch = trimmed[i];
    if (ch === "(") depth++;
    else if (ch === ")") depth--;
    if (depth > 0) i++;
  }
  if (depth !== 0) return null;
  let target = trimmed.slice(urlStart, i);
  if (target.startsWith("./")) target = target.slice(2);
  target = target.replace(/\/+$/, "");
  if (target.length === 0) return null;

  const remainder = trimmed.slice(i + 1).trim();
  const byMatch = /^by\s+(.+?)(?:\s+on\s+(.+))?$/.exec(remainder);

  // The first path segment is the source directory; prefer the human-readable
  // "by …" suffix when present.
  const firstSegment = decodeURIComponent(target.split("/")[0] ?? "");
  return {
    name,
    encodedRelPath: target,
    source: byMatch?.[1]?.trim() || firstSegment || "unknown",
    rig: byMatch?.[2]?.trim(),
  };
}

function parseIndex(markdown: string): AutoEqEntry[] {
  const out: AutoEqEntry[] = [];
  for (const line of markdown.split("\n")) {
    const entry = parseIndexLine(line);
    if (entry) out.push(entry);
  }
  return out;
}

/** Loads the results index, from cache when fresh, network otherwise. */
export async function loadIndex(refresh = false): Promise<AutoEqEntry[]> {
  if (!refresh) {
    const cached = await readCacheFile("index.md", INDEX_TTL_MS);
    if (cached) return parseIndex(cached);
  }
  try {
    const fetched = await fetchText(`${AUTOEQ_RAW_BASE}/INDEX.md`);
    await writeCacheFile("index.md", fetched);
    return parseIndex(fetched);
  } catch (err) {
    // Network down / GitHub unreachable: stale cache beats nothing.
    const stale = await readCacheFileStale("index.md");
    if (stale) return parseIndex(stale);
    throw err;
  }
}

// MARK: - Matching

/** Lowercased alphanumerics only: "Sennheiser HD 600" → "sennheiserhd600". */
function normalizeName(s: string): string {
  return s.toLowerCase().replace(/[^a-z0-9]/g, "");
}

/** Higher = more trusted measurement source. */
function sourcePriority(source: string): number {
  const s = source.toLowerCase();
  if (s.includes("oratory1990")) return 100;
  if (s.includes("crinacle")) return 90;
  if (s.includes("rtings")) return 70;
  if (s.includes("innerfidelity")) return 60;
  if (s.includes("hypethesonics")) return 55;
  if (s.includes("headphone.com")) return 50;
  return 35;
}

interface ScoredEntry {
  entry: AutoEqEntry;
  score: number;
}

/**
 * Scores every index entry whose normalized name contains the whole normalized
 * query (so "HD600" finds "Sennheiser HD 600"). Exact-name matches and trusted
 * sources rank first; long suffixes ("(ANC On)", "(sample B)") rank lower.
 */
function scoreEntries(query: string, entries: AutoEqEntry[]): ScoredEntry[] {
  const q = normalizeName(query);
  if (q.length === 0) return [];

  const scored: ScoredEntry[] = [];
  for (const entry of entries) {
    const n = normalizeName(entry.name);
    if (!n.includes(q)) continue;
    const extra = n.length - q.length;
    const closeness = n === q ? 60 : Math.max(0, 40 - extra);
    scored.push({ entry, score: sourcePriority(entry.source) + closeness });
  }
  scored.sort((a, b) => b.score - a.score || a.entry.name.localeCompare(b.entry.name));
  return scored;
}

/** Loose suggestions when nothing contains the full query: any-token matches. */
function suggestNames(query: string, entries: AutoEqEntry[], limit: number): string[] {
  const tokens = query
    .split(/\s+/)
    .map(normalizeName)
    .filter((t) => t.length >= 2);
  if (tokens.length === 0) return [];
  const seen = new Set<string>();
  for (const entry of entries) {
    const n = normalizeName(entry.name);
    if (tokens.some((t) => n.includes(t))) {
      seen.add(entry.name);
      if (seen.size >= limit) break;
    }
  }
  return [...seen];
}

// MARK: - Parametric EQ parsing

const FILTER_LINE =
  /^Filter\s+\d+\s*:\s*(ON|OFF)\s+(PK|PEQ|LSC|LS|HSC|HS)\s+Fc\s+([\d.]+)\s*Hz\s+Gain\s+(-?[\d.]+)\s*dB(?:\s+Q\s+([\d.]+))?/i;

function bandTypeFor(token: string): BandType | null {
  switch (token.toUpperCase()) {
    case "PK":
    case "PEQ":
      return "bell";
    case "LSC":
    case "LS":
      return "low_shelf";
    case "HSC":
    case "HS":
      return "high_shelf";
    default:
      return null;
  }
}

function clamp(value: number, lo: number, hi: number): number {
  return Math.min(hi, Math.max(lo, value));
}

/** Parses an AutoEq `… ParametricEQ.txt` into Auralink band specs. */
export function parseParametricEQ(text: string): {
  preampDb: number;
  bands: AutoEqBand[];
  conversionNotes: string[];
} {
  const notes: string[] = [];
  const bands: AutoEqBand[] = [];

  const preampMatch = /^Preamp:\s*(-?[\d.]+)\s*dB/m.exec(text);
  let preampDb = preampMatch ? parseFloat(preampMatch[1]) : 0;
  if (preampDb > PREAMP_MAX || preampDb < PREAMP_MIN) {
    notes.push(
      `AutoEq preamp ${preampDb.toFixed(1)} dB clamped to Auralink's ${PREAMP_MIN}…${PREAMP_MAX} dB range.`
    );
    preampDb = clamp(preampDb, PREAMP_MIN, PREAMP_MAX);
  }

  for (const line of text.split("\n")) {
    const m = FILTER_LINE.exec(line.trim());
    if (!m) continue;
    if (m[1].toUpperCase() === "OFF") continue;
    const type = bandTypeFor(m[2]);
    if (!type) continue;

    let frequencyHz = parseFloat(m[3]);
    let gainDb = parseFloat(m[4]);
    let q = m[5] !== undefined ? parseFloat(m[5]) : 0.707;
    if (!Number.isFinite(frequencyHz) || !Number.isFinite(gainDb) || !Number.isFinite(q)) continue;

    if (frequencyHz < FREQ_MIN || frequencyHz > FREQ_MAX) {
      notes.push(`Filter at ${frequencyHz.toFixed(0)} Hz clamped into ${FREQ_MIN}–${FREQ_MAX} Hz.`);
      frequencyHz = clamp(frequencyHz, FREQ_MIN, FREQ_MAX);
    }
    if (gainDb < GAIN_MIN || gainDb > GAIN_MAX) {
      notes.push(`Gain ${gainDb.toFixed(1)} dB clamped into ${GAIN_MIN}…${GAIN_MAX} dB.`);
      gainDb = clamp(gainDb, GAIN_MIN, GAIN_MAX);
    }
    if (q < Q_MIN || q > Q_MAX) {
      notes.push(`Q ${q.toFixed(2)} clamped into ${Q_MIN}–${Q_MAX}.`);
      q = clamp(q, Q_MIN, Q_MAX);
    }
    bands.push({ type, frequencyHz, gainDb, q });
  }

  if (bands.length > 20) {
    notes.push(`AutoEq produced ${bands.length} filters; the 20 largest by |gain| were kept.`);
    bands.sort((a, b) => Math.abs(b.gainDb) - Math.abs(a.gainDb));
    bands.length = 20;
  }
  bands.sort((a, b) => a.frequencyHz - b.frequencyHz);

  return { preampDb, bands, conversionNotes: notes };
}

// MARK: - GraphicEQ parsing

/** Parses an AutoEq GraphicEQ line and removes the separately applied preamp. */
export function parseGraphicEQ(
  text: string,
  sourcePreampDb: number,
  metadata: {
    measurementId: string;
    source: string;
    rig?: string;
    provenanceURL: string;
  }
): MeasuredCorrectionPayload {
  const trimmed = text.trim();
  if (!trimmed.startsWith("GraphicEQ:")) {
    throw new Error("GraphicEQ data is missing the 'GraphicEQ:' header.");
  }
  if (!Number.isFinite(sourcePreampDb)) {
    throw new Error("GraphicEQ normalization requires a finite AutoEq preamp.");
  }

  const body = trimmed.slice("GraphicEQ:".length);
  const points = body.split(";").map((part, offset) => {
    const match = /^\s*(\d+(?:\.\d+)?)\s+(-?\d+(?:\.\d+)?)\s*$/.exec(part);
    if (!match) throw new Error(`Malformed GraphicEQ point ${offset + 1}.`);
    const frequencyHz = Number(match[1]);
    const sourceGainDb = Number(match[2]);
    const gainDb = sourceGainDb - sourcePreampDb;
    if (!Number.isFinite(frequencyHz) || !Number.isFinite(gainDb)) {
      throw new Error(`GraphicEQ point ${offset + 1} is not finite.`);
    }
    if (frequencyHz < 10 || frequencyHz > 24_000 || gainDb < -24 || gainDb > 24) {
      throw new Error(`GraphicEQ point ${offset + 1} is outside Auralink's measured-correction bounds.`);
    }
    return { frequencyHz, gainDb };
  });
  if (points.length < 16 || points.length > 512) {
    throw new Error(`GraphicEQ requires 16–512 points; received ${points.length}.`);
  }
  for (let index = 1; index < points.length; index++) {
    if (points[index].frequencyHz <= points[index - 1].frequencyHz) {
      throw new Error("GraphicEQ frequencies must be strictly increasing and unique.");
    }
  }
  if (points[0].frequencyHz > 40 || points[points.length - 1].frequencyHz < 10_000) {
    throw new Error("GraphicEQ does not cover Auralink's 40 Hz–10 kHz primary correction range.");
  }

  const canonical = points
    .map((point) => `${point.frequencyHz.toFixed(6)}:${point.gainDb.toFixed(6)}`)
    .join("|");
  const contentHash = createHash("sha256").update(`1|${canonical}`).digest("hex");
  return {
    schemaVersion: 1,
    measurementId: metadata.measurementId,
    sourceFormat: "autoeq_graphic_eq",
    source: metadata.source,
    rig: metadata.rig,
    provenanceURL: metadata.provenanceURL,
    sourcePreampDb,
    contentHash,
    channel: "stereo",
    phaseData: "magnitude_only",
    usableLowHz: Math.max(40, points[0].frequencyHz),
    // AutoEq intentionally treats the >10 kHz region as uncertain/averaged.
    usableHighHz: Math.min(10_000, points[points.length - 1].frequencyHz),
    points,
  };
}

// MARK: - Correction lookup

function resultFileUrl(entry: AutoEqEntry, suffix: string): string {
  const dirName = decodeURIComponent(entry.encodedRelPath.split("/").pop() ?? entry.name);
  const fileName = encodeURIComponent(`${dirName} ${suffix}`);
  // encodeURIComponent leaves ( ) ' alone; raw.githubusercontent wants them encoded.
  const safe = (s: string) =>
    s.replace(/\(/g, "%28").replace(/\)/g, "%29").replace(/'/g, "%27");
  return `${AUTOEQ_RAW_BASE}/${safe(entry.encodedRelPath)}/${safe(fileName)}`;
}

/** Raw URL of the parametric file for one index entry. */
function parametricUrl(entry: AutoEqEntry): string {
  return resultFileUrl(entry, "ParametricEQ.txt");
}

/** Raw URL of the full-resolution GraphicEQ file for one index entry. */
function graphicUrl(entry: AutoEqEntry): string {
  return resultFileUrl(entry, "GraphicEQ.txt");
}

function resultCacheHash(entry: AutoEqEntry): string {
  return createHash("sha1").update(entry.encodedRelPath).digest("hex").slice(0, 16);
}

function correctionCacheName(entry: AutoEqEntry): string {
  return `correction-${resultCacheHash(entry)}.txt`;
}

function graphicCacheName(entry: AutoEqEntry): string {
  return `graphic-${resultCacheHash(entry)}.txt`;
}

async function fetchCachedResult(
  entry: AutoEqEntry,
  refresh: boolean,
  cacheName: string,
  url: string
): Promise<string> {
  if (!refresh) {
    const cached = await readCacheFile(cacheName, CORRECTION_TTL_MS);
    if (cached) return cached;
  }
  try {
    const fetched = await fetchText(url);
    await writeCacheFile(cacheName, fetched);
    return fetched;
  } catch (err) {
    const stale = await readCacheFileStale(cacheName);
    if (stale) return stale;
    throw err;
  }
}

async function fetchParametric(entry: AutoEqEntry, refresh: boolean): Promise<string> {
  return fetchCachedResult(entry, refresh, correctionCacheName(entry), parametricUrl(entry));
}

async function fetchGraphic(entry: AutoEqEntry, refresh: boolean): Promise<string> {
  return fetchCachedResult(entry, refresh, graphicCacheName(entry), graphicUrl(entry));
}

/**
 * Looks a headphone up in AutoEq and returns its PEQ fallback plus validated
 * GraphicEQ payload (and alternate measurements). `source` filters
 * to a preferred measurement source when given.
 */
export async function getCorrection(options: {
  headphone: string;
  source?: string;
  refresh?: boolean;
  maxAlternates?: number;
}): Promise<AutoEqLookup> {
  const { headphone, source, refresh = false, maxAlternates = 5 } = options;
  const entries = await loadIndex(refresh);

  let scored = scoreEntries(headphone, entries);
  if (source && source.trim().length > 0) {
    const wanted = source.trim().toLowerCase();
    const filtered = scored.filter((s) => s.entry.source.toLowerCase().includes(wanted));
    if (filtered.length > 0) scored = filtered;
  }

  if (scored.length === 0) {
    return {
      found: false,
      alternates: [],
      suggestions: suggestNames(headphone, entries, 10),
    };
  }

  const best = scored[0].entry;
  const text = await fetchParametric(best, refresh);
  const parsed = parseParametricEQ(text);
  let measuredCorrection: MeasuredCorrectionPayload | undefined;
  const conversionNotes = [...parsed.conversionNotes];
  try {
    const graphicText = await fetchGraphic(best, refresh);
    measuredCorrection = parseGraphicEQ(graphicText, parsed.preampDb, {
      measurementId: `autoeq-${resultCacheHash(best)}`,
      source: best.source,
      rig: best.rig,
      provenanceURL: graphicUrl(best),
    });
  } catch (err) {
    conversionNotes.push(
      `Measured FIR data unavailable: ${err instanceof Error ? err.message : String(err)}`
    );
  }

  return {
    found: true,
    correction: {
      name: best.name,
      source: best.source,
      rig: best.rig,
      preampDb: parsed.preampDb,
      bands: parsed.bands,
      url: parametricUrl(best),
      measuredCorrection,
      conversionNotes,
    },
    alternates: scored.slice(1, 1 + maxAlternates).map((s) => ({
      name: s.entry.name,
      source: s.entry.source,
      rig: s.entry.rig,
    })),
    suggestions: [],
  };
}
