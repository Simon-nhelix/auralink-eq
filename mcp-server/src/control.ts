/**
 * Thin client for the Auralink app's ControlServer (a localhost HTTP server,
 * default `http://127.0.0.1:8765`, override with `AURALINK_CONTROL_URL`).
 *
 * Live state and any destructive action (apply / rollback) go through here. When
 * the app is offline every call resolves to `{ online: false, … }` instead of
 * throwing, so read tools can still serve cached/disk data and the AI gets a
 * clear "the app isn't running" signal rather than a stack trace.
 *
 * Endpoints (per BUILD_SPEC §APP control):
 *   GET  /state     → AudioState
 *   GET  /devices   → OutputDevice[]
 *   GET  /presets   → EQPreset[]
 *   GET  /preset?id=… → EQPreset
 *   POST /apply     { id, confirmed? } → { ok, needsConfirm }
 *   POST /audition-preset { preset, confirmed? } → { ok, needsConfirm, saved:false }
 *   POST /save-current-preset { name?, id?, tags?, confirmed? } → saved EQPreset or { ok, needsConfirm }
 *   POST /rollback  { confirmed? } → { ok, needsConfirm, … }
 *   POST /preset    EQPreset | { preset, confirmed? } → saved EQPreset or { ok, needsConfirm }
 *   POST /validate  EQPreset    → ValidationResult
 *   POST /reload-presets { confirmed? } → { ok, needsConfirm, presetCount }
 *   POST /reload-knowledge { confirmed? } → { ok, needsConfirm, profileCount, targetCurveCount }
 *   POST /route-system-audio { confirmed? } → { ok, needsConfirm }
 *   POST /restore-system-audio { confirmed? } → { ok, needsConfirm }
 *   POST /stop-routing { confirmed? } → { ok, needsConfirm }
 */

import { promises as fs } from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

import { AudioState, EQPreset, OutputDevice } from "./types.js";

/** Result wrapper that never throws on a network/offline error. */
export interface ControlResult<T> {
  /** True when the app responded; false when it's unreachable. */
  online: boolean;
  /** Parsed JSON body on success, otherwise undefined. */
  data?: T;
  /** Human-readable explanation when `online` is false or the call failed. */
  error?: string;
  /** HTTP status code when a response was received. */
  status?: number;
}

const DEFAULT_CONTROL_URL = "http://127.0.0.1:8765";
const REQUEST_TIMEOUT_MS = 4000;
const MIN_CONTROL_TOKEN_LENGTH = 32;

export function controlTokenFilePath(environment: NodeJS.ProcessEnv = process.env): string {
  const override = environment.AURALINK_CONTROL_TOKEN_FILE?.trim();
  if (override) return path.resolve(expandHome(override, environment));
  const home = environment.HOME?.trim() || os.homedir();
  return path.join(home, "Library", "Application Support", "Auralink", "control-token");
}

export function normalizeControlToken(raw: string | undefined): string | undefined {
  const token = raw?.trim();
  if (!token || token.length < MIN_CONTROL_TOKEN_LENGTH || !/^[A-Za-z0-9._~-]+$/.test(token)) {
    return undefined;
  }
  return token;
}

export async function resolveControlToken(
  environment: NodeJS.ProcessEnv = process.env
): Promise<string> {
  const explicit = normalizeControlToken(environment.AURALINK_CONTROL_TOKEN);
  if (explicit) return explicit;

  const tokenFile = controlTokenFilePath(environment);
  let raw: string;
  try {
    const [contents, attributes] = await Promise.all([
      fs.readFile(tokenFile, "utf8"),
      fs.stat(tokenFile),
    ]);
    if ((attributes.mode & 0o077) !== 0) {
      throw new Error("control token file must not be accessible by group or other users");
    }
    raw = contents;
  } catch {
    throw new Error(
      `control token is missing or insecure at ${tokenFile}; launch Auralink EQ first`
    );
  }
  const token = normalizeControlToken(raw);
  if (!token) throw new Error(`control token at ${tokenFile} is invalid`);
  return token;
}

function expandHome(value: string, environment: NodeJS.ProcessEnv): string {
  if (value === "~") return environment.HOME?.trim() || os.homedir();
  if (value.startsWith("~/")) {
    return path.join(environment.HOME?.trim() || os.homedir(), value.slice(2));
  }
  return value;
}

/** Base URL of the app's ControlServer (no trailing slash). */
export function controlBaseUrl(): string {
  const override = process.env.AURALINK_CONTROL_URL;
  const raw = override && override.trim().length > 0 ? override.trim() : DEFAULT_CONTROL_URL;
  return raw.replace(/\/+$/, "");
}

/**
 * Perform one request against the ControlServer, swallowing connection errors
 * into a `{ online: false }` result. Uses an AbortController timeout so a hung
 * app can't wedge the MCP server.
 */
async function request<T>(
  pathAndQuery: string,
  init?: RequestInit
): Promise<ControlResult<T>> {
  const url = `${controlBaseUrl()}${pathAndQuery}`;
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), REQUEST_TIMEOUT_MS);
  try {
    let controlToken: string;
    try {
      controlToken = await resolveControlToken();
    } catch (err) {
      const reason = err instanceof Error ? err.message : String(err);
      return {
        online: false,
        error: `Control token is unavailable (${reason}). Launch Auralink EQ first.`,
      };
    }
    const isPost = init?.method?.toUpperCase() === "POST";
    const res = await fetch(url, {
      ...init,
      signal: controller.signal,
      headers: {
        Accept: "application/json",
        Authorization: `Bearer ${controlToken}`,
        ...(isPost ? { "Content-Type": "application/json" } : {}),
        ...(init?.headers ?? {}),
      },
    });

    if (!res.ok) {
      let body = "";
      try {
        body = await res.text();
      } catch {
        /* ignore */
      }
      return {
        online: true,
        status: res.status,
        error: `ControlServer returned ${res.status} ${res.statusText}${body ? `: ${body}` : ""}`,
      };
    }

    // Some POSTs may return an empty body; tolerate that.
    const text = await res.text();
    if (text.length === 0) {
      return { online: true, status: res.status, data: undefined as T };
    }
    try {
      return { online: true, status: res.status, data: JSON.parse(text) as T };
    } catch {
      return {
        online: true,
        status: res.status,
        error: "malformed response body",
      };
    }
  } catch (err) {
    const reason = err instanceof Error ? err.message : String(err);
    return {
      online: false,
      error: `Auralink app is not reachable at ${controlBaseUrl()} (${reason}). Make sure the app is running.`,
    };
  } finally {
    clearTimeout(timer);
  }
}

// MARK: - Read endpoints

/** GET /state → live AudioState. */
export function getState(): Promise<ControlResult<AudioState>> {
  return request<AudioState>("/state");
}

/** GET /devices → output devices known to CoreAudio. */
export function getDevices(): Promise<ControlResult<OutputDevice[]>> {
  return request<OutputDevice[]>("/devices");
}

// MARK: - Write / destructive endpoints

/**
 * POST /apply { id } — apply a preset to live audio. The app honors its
 * permission mode and may answer `{ ok: false, needsConfirm: true }` when the
 * user must confirm in the menubar first.
 */
export function applyPreset(
  id: string,
  confirmed = false
): Promise<ControlResult<{
  ok: boolean;
  needsConfirm?: boolean;
  message?: string;
  requestedRenderGeneration?: number;
}>> {
  return request("/apply", {
    method: "POST",
    body: JSON.stringify({ id, confirmed }),
  });
}

function presetForWire(preset: EQPreset): EQPreset {
  const now = new Date().toISOString();
  return {
    ...preset,
    createdAt: preset.createdAt && preset.createdAt.length > 0 ? preset.createdAt : now,
    updatedAt: preset.updatedAt && preset.updatedAt.length > 0 ? preset.updatedAt : now,
  };
}

/** POST /audition-preset — apply an unsaved preset to live audio. */
export function auditionPreset(
  preset: EQPreset,
  confirmed = false
): Promise<
  ControlResult<{
    ok: boolean;
    needsConfirm?: boolean;
    saved: false;
    presetId: string;
    presetName: string;
    activeBands: number;
    clippingRisk?: string;
    requestedRenderGeneration?: number;
    message?: string;
  }>
> {
  return request("/audition-preset", {
    method: "POST",
    body: JSON.stringify({ preset: presetForWire(preset), confirmed }),
  });
}

/** POST /save-current-preset — persist the current loaded/auditioned preset. */
export function saveCurrentPreset(options: {
  name?: string;
  id?: string;
  tags?: string[];
  confirmed?: boolean;
}): Promise<ControlResult<EQPreset & { ok?: boolean; needsConfirm?: boolean; message?: string }>> {
  return request("/save-current-preset", {
    method: "POST",
    body: JSON.stringify(options),
  });
}

/** POST /reload-knowledge — make the running app re-read headphone/target data. */
export function reloadKnowledge(
  confirmed = false
): Promise<
  ControlResult<{
    ok: boolean;
    needsConfirm?: boolean;
    profileCount: number;
    targetCurveCount: number;
    message?: string;
  }>
> {
  return request("/reload-knowledge", {
    method: "POST",
    body: JSON.stringify({ confirmed }),
  });
}

/** POST /reload-presets — make the running app re-read preset files. */
export function reloadPresets(
  confirmed = false
): Promise<
  ControlResult<{ ok: boolean; needsConfirm?: boolean; presetCount: number; message?: string }>
> {
  return request("/reload-presets", {
    method: "POST",
    body: JSON.stringify({ confirmed }),
  });
}

/** POST /rollback — revert to the previously applied preset. */
export function rollbackPreset(
  confirmed = false
): Promise<
  ControlResult<{
    ok: boolean;
    needsConfirm?: boolean;
    message?: string;
    presetId?: string;
    presetName?: string;
    requestedRenderGeneration?: number;
  }>
> {
  return request("/rollback", {
    method: "POST",
    body: JSON.stringify({ confirmed }),
  });
}

/** POST /route-system-audio — set macOS output to the virtual capture device. */
export function routeSystemAudio(
  confirmed = false
): Promise<ControlResult<{ ok: boolean; needsConfirm?: boolean; message?: string }>> {
  return request("/route-system-audio", {
    method: "POST",
    body: JSON.stringify({ confirmed }),
  });
}

/** POST /restore-system-audio — restore macOS output to a real device. */
export function restoreSystemAudio(
  confirmed = false
): Promise<ControlResult<{ ok: boolean; needsConfirm?: boolean; message?: string }>> {
  return request("/restore-system-audio", {
    method: "POST",
    body: JSON.stringify({ confirmed }),
  });
}

/** POST /stop-routing — stop capture/render engines without changing saved presets. */
export function stopRouting(
  confirmed = false
): Promise<ControlResult<{ ok: boolean; needsConfirm?: boolean; message?: string }>> {
  return request("/stop-routing", {
    method: "POST",
    body: JSON.stringify({ confirmed }),
  });
}
