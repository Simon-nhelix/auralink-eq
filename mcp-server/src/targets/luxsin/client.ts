/**
 * Luxsin X8 local REST client.
 *
 * Every control path funnels through `http://<ip>/dev/info.cgi` with an `action`
 * query parameter. Responses are JSON encoded with the custom-alphabet base64
 * codec (see ./codec.ts). Writes POST `data=<encoded-json>` to the same CGI.
 *
 * The X8's embedded web server is fragile under burst/concurrent load. This
 * client is deliberately polite and also resilient to DHCP changes: it tries
 * the configured/cached URL first, then discovers the X8 on the local LAN and
 * updates its cache before retrying.
 */
import { execFile } from "node:child_process";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { homedir, networkInterfaces } from "node:os";
import { dirname, join } from "node:path";
import { promisify } from "node:util";

import { luxsinDecode, luxsinEncode } from "./codec.js";

const execFileAsync = promisify(execFile);

const DEFAULT_BASE_URL = "http://192.168.1.2";
const READ_TIMEOUT_MS = 12000;
const DISCOVERY_TIMEOUT_MS = 700;
const MIN_GAP_MS = 150; // min spacing between requests to the device
const RETRY_BACKOFF_MS = 600;
const DISCOVERY_CONCURRENCY = 16;
const CACHE_PATH = join(homedir(), "Library", "Application Support", "Auralink", "mcp", "luxsin-x8.json");

export interface X8Filter {
  type: string; // "PEAKING" | "LOW_SHELF" | "HIGH_SHELF" | "NOTCH" | "LOW_PASS" | "HIGH_PASS" | "BPF" | "APF"
  fc: number; // center/cutoff Hz
  gain: number; // dB
  q: number;
}

export interface X8HeadphoneEntry {
  name: string;
  brand: string;
  model: string;
  form?: string; // "over-ear" | "in-ear" | …
  target?: string; // measurement target/rig provenance
  preamp: number;
  canDel: number; // 1 | 0
  autoPre?: number; // 1 | 0
  /** JSON-encoded string of X8Filter[]. Stored serialized on the device. */
  filters: string;
}

export interface X8PeqDb {
  peq: X8HeadphoneEntry[];
}

/** Wire filter for WRITES — type is a numeric code (LPF=0,HPF=1,BPF=2,NOTCH=3,PEAKING=4,LSHELF=5,HSHELF=6,APF=7). */
export interface X8WireFilter {
  type: number;
  fc: number;
  gain: number;
  q: number;
}

/** peqChange payload — name-keyed upsert. To CREATE a new entry the device
 *  requires brand+model (the controller's add flow also sends form+target);
 *  a bare {name,filters,...} only edits an existing entry and silently no-ops
 *  when the name is new. */
export interface X8PeqChange {
  name: string;
  brand: string;
  model: string;
  form?: string;
  target?: string;
  filters: X8WireFilter[];
  autoPre: number;
  preamp: number;
  canDel: number;
}

/** Device-wide state from ?action=syncData. Only the fields we care about. */
export interface X8DeviceState {
  device?: string;
  audioFormat?: string;
  volume?: number;
  input?: number;
  output?: number;
  dsp_enable?: number;
  peqEnable?: number;
  peqSelect?: number; // index of the active headphone entry
  effect_enable?: number;
  crossfeed_enable?: number;
  dacImpedance?: number;
  mac?: string;
  version?: number;
  [key: string]: unknown;
}

export interface LuxsinDiscoveryOptions {
  preferredBaseUrl?: string;
  includeSubnetSweep?: boolean;
  timeoutMs?: number;
  concurrency?: number;
}

export interface LuxsinClientOptions {
  baseUrl?: string;
  /** Override the min inter-request gap (ms). Default 150. */
  minGapMs?: number;
  /** Auto-discover a changed X8 IP when the configured/cached URL fails. Default true. */
  autoDiscover?: boolean;
  discovery?: Omit<LuxsinDiscoveryOptions, "preferredBaseUrl">;
}

export class LuxsinClient {
  private currentBaseUrl: string;
  private readonly minGapMs: number;
  private readonly autoDiscover: boolean;
  private readonly discovery: Omit<LuxsinDiscoveryOptions, "preferredBaseUrl">;
  private lastRequestAt = 0;

  constructor(opts: LuxsinClientOptions = {}) {
    const env = process.env.X8_URL?.trim();
    this.currentBaseUrl = normalizeBaseUrl(opts.baseUrl ?? env ?? DEFAULT_BASE_URL);
    this.minGapMs = opts.minGapMs ?? MIN_GAP_MS;
    this.autoDiscover = opts.autoDiscover ?? true;
    this.discovery = opts.discovery ?? {};
  }

  get baseUrl(): string {
    return this.currentBaseUrl;
  }

  /** GET ?action=syncData → full device state. Auto-discovers if IP changed. */
  async getDeviceInfo(): Promise<X8DeviceState> {
    const state = await this.getJson<X8DeviceState>("?action=syncData");
    if (!isLuxsinState(state)) throw new Error(`Response at ${this.baseUrl} is not a Luxsin X8`);
    return state;
  }

  /** GET ?action=syncPeq → the on-device headphone EQ database. */
  async getPeq(): Promise<X8PeqDb> {
    const db = await this.getJson<X8PeqDb>("?action=syncPeq");
    return db && Array.isArray(db.peq) ? db : { peq: [] };
  }

  /** POST {peqChange:{...}} — upsert a headphone entry by name. */
  async peqChange(payload: X8PeqChange): Promise<{ ok: true }> {
    await this.ensureReachable();
    const body = encodeFormBody({ peqChange: payload });
    await this.request({ method: "POST", path: "", body });
    return { ok: true };
  }

  /** POST {peqRemove:[name]} — delete a headphone entry by name. */
  async peqRemove(name: string): Promise<{ ok: true }> {
    await this.ensureReachable();
    const body = encodeFormBody({ peqRemove: [name] });
    await this.request({ method: "POST", path: "", body });
    return { ok: true };
  }

  /** GET ?action=setting&<key>=<val> — write a single setting. */
  async setSetting(key: string, value: string | number): Promise<{ ok: true }> {
    await this.ensureReachable();
    await this.request({ method: "GET", path: `?action=setting&${key}=${encodeURIComponent(String(value))}` });
    return { ok: true };
  }

  /** Force discovery now and switch this client to the discovered URL. */
  async rediscover(): Promise<string | undefined> {
    return this.discoverAndSwitch();
  }

  // ---- internals ----

  private async ensureReachable(): Promise<void> {
    await this.getDeviceInfo();
  }

  private async getJson<T = unknown>(path: string): Promise<T> {
    try {
      return await this.getJsonOnce<T>(path);
    } catch (err) {
      if (!this.autoDiscover) throw err;
      const found = await this.discoverAndSwitch();
      if (!found) throw err;
      return await this.getJsonOnce<T>(path);
    }
  }

  private async getJsonOnce<T = unknown>(path: string): Promise<T> {
    const text = await this.request({ method: "GET", path });
    return JSON.parse(luxsinDecode(text.trim())) as T;
  }

  private async discoverAndSwitch(): Promise<string | undefined> {
    const found = await discoverLuxsinX8BaseUrl({
      preferredBaseUrl: this.currentBaseUrl,
      ...this.discovery,
    });
    if (found) this.currentBaseUrl = normalizeBaseUrl(found);
    return found;
  }

  private async request(req: { method: string; path: string; body?: string }): Promise<string> {
    await this.gate();
    const url = `${this.currentBaseUrl}/dev/info.cgi${req.path}`;
    const doFetch = (): Promise<string> => this.fetchOnce(url, req);
    try {
      return await doFetch();
    } catch (err) {
      await sleep(RETRY_BACKOFF_MS);
      return await doFetch();
    }
  }

  private async fetchOnce(url: string, req: { method: string; body?: string }): Promise<string> {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), READ_TIMEOUT_MS);
    try {
      const headers: Record<string, string> = {};
      if (req.body !== undefined) headers["Content-Type"] = "application/x-www-form-urlencoded; charset=UTF-8";
      const res = await fetch(url, {
        method: req.method,
        headers,
        body: req.body,
        signal: controller.signal,
        keepalive: false,
      });
      if (!res.ok) throw new Error(`X8 HTTP ${res.status} for ${url}`);
      // Writes return a plain "<html><body>Settings updated</body></html>" ack;
      // reads return the scrambled-base64 payload. Caller decides how to parse.
      return await res.text();
    } finally {
      clearTimeout(timer);
    }
  }

  private async gate(): Promise<void> {
    const elapsed = Date.now() - this.lastRequestAt;
    if (elapsed < this.minGapMs) await sleep(this.minGapMs - elapsed);
    this.lastRequestAt = Date.now();
  }
}

export async function discoverLuxsinX8BaseUrl(options: LuxsinDiscoveryOptions = {}): Promise<string | undefined> {
  const candidates = await discoveryCandidates(options);
  const timeoutMs = options.timeoutMs ?? DISCOVERY_TIMEOUT_MS;
  const concurrency = options.concurrency ?? DISCOVERY_CONCURRENCY;
  for (let i = 0; i < candidates.length; i += concurrency) {
    const batch = candidates.slice(i, i + concurrency);
    const hits = await Promise.all(batch.map(async (baseUrl) => (await probeLuxsinBaseUrl(baseUrl, timeoutMs)) ? baseUrl : undefined));
    const found = hits.find((x): x is string => Boolean(x));
    if (found) {
      await writeCachedBaseUrl(found);
      return found;
    }
  }
  return undefined;
}

/**
 * Build the `data=<payload>` form body for a write.
 *
 * The scrambled-base64 alphabet includes `+`, which in an
 * `application/x-www-form-urlencoded` body means a literal space. Without
 * percent-encoding the device decodes a corrupted payload and silently ignores
 * the write while still answering HTTP 200 "Settings updated".
 */
export function encodeFormBody(payload: unknown): string {
  return "data=" + encodeURIComponent(luxsinEncode(JSON.stringify(payload)));
}

async function discoveryCandidates(options: LuxsinDiscoveryOptions): Promise<string[]> {
  const raw: (string | undefined)[] = [
    options.preferredBaseUrl,
    process.env.X8_URL?.trim(),
    await readCachedBaseUrl(),
    DEFAULT_BASE_URL,
    ...(await arpBaseUrls()),
  ];
  if (options.includeSubnetSweep ?? true) raw.push(...localSubnetBaseUrls());
  const seen = new Set<string>();
  const out: string[] = [];
  for (const item of raw) {
    if (!item) continue;
    const url = normalizeBaseUrl(item);
    if (seen.has(url)) continue;
    seen.add(url);
    out.push(url);
  }
  return out;
}

async function probeLuxsinBaseUrl(baseUrl: string, timeoutMs: number): Promise<boolean> {
  const base = normalizeBaseUrl(baseUrl);
  if (await probeSyncData(base, timeoutMs)) return true;
  return await probeRootRedirect(base, timeoutMs);
}

async function probeSyncData(baseUrl: string, timeoutMs: number): Promise<boolean> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const res = await fetch(`${baseUrl}/dev/info.cgi?action=syncData`, { signal: controller.signal, redirect: "manual" });
    if (!res.ok) return false;
    const text = await res.text();
    const state = JSON.parse(luxsinDecode(text.trim())) as X8DeviceState;
    return isLuxsinState(state);
  } catch {
    return false;
  } finally {
    clearTimeout(timer);
  }
}

async function probeRootRedirect(baseUrl: string, timeoutMs: number): Promise<boolean> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const res = await fetch(`${baseUrl}/`, { signal: controller.signal, redirect: "manual" });
    const location = res.headers.get("location") ?? "";
    return /luxsinaudio\.com\/x8\/i\.html/i.test(location);
  } catch {
    return false;
  } finally {
    clearTimeout(timer);
  }
}

function isLuxsinState(value: unknown): value is X8DeviceState {
  return typeof value === "object" && value !== null && String((value as X8DeviceState).device ?? "").toLowerCase().includes("luxsin-x8");
}

async function arpBaseUrls(): Promise<string[]> {
  try {
    const { stdout } = await execFileAsync("arp", ["-a"], { timeout: 1500 });
    const matches = [...stdout.matchAll(/\((\d{1,3}(?:\.\d{1,3}){3})\)/g)].map((m) => m[1]);
    return matches.filter(isPrivateIPv4).map((ip) => `http://${ip}`);
  } catch {
    return [];
  }
}

function localSubnetBaseUrls(): string[] {
  const out: string[] = [];
  for (const entries of Object.values(networkInterfaces())) {
    for (const info of entries ?? []) {
      if (info.family !== "IPv4" || info.internal || !isPrivateIPv4(info.address)) continue;
      const parts = info.address.split(".");
      if (parts.length !== 4) continue;
      const prefix = parts.slice(0, 3).join(".");
      for (let i = 1; i <= 254; i++) {
        const ip = `${prefix}.${i}`;
        if (ip === info.address) continue;
        out.push(`http://${ip}`);
      }
    }
  }
  return out;
}

function isPrivateIPv4(ip: string): boolean {
  const p = ip.split(".").map((x) => Number(x));
  if (p.length !== 4 || p.some((x) => !Number.isInteger(x) || x < 0 || x > 255)) return false;
  return p[0] === 10 || (p[0] === 172 && p[1] >= 16 && p[1] <= 31) || (p[0] === 192 && p[1] === 168);
}

async function readCachedBaseUrl(): Promise<string | undefined> {
  try {
    const data = JSON.parse(await readFile(CACHE_PATH, "utf8")) as { baseUrl?: string };
    return data.baseUrl;
  } catch {
    return undefined;
  }
}

async function writeCachedBaseUrl(baseUrl: string): Promise<void> {
  try {
    await mkdir(dirname(CACHE_PATH), { recursive: true });
    await writeFile(CACHE_PATH, JSON.stringify({ baseUrl: normalizeBaseUrl(baseUrl), updatedAt: new Date().toISOString() }, null, 2));
  } catch {
    // Cache is best-effort only; discovery result is still valid for this run.
  }
}

function normalizeBaseUrl(input: string): string {
  const raw = input.trim();
  const withScheme = /^https?:\/\//i.test(raw) ? raw : `http://${raw}`;
  return withScheme.replace(/\/+$/, "");
}

function sleep(ms: number): Promise<void> {
  return new Promise((r) => setTimeout(r, ms));
}
