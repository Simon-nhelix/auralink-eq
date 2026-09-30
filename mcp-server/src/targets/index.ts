/**
 * EQ target registry.
 *
 * The Auralink MCP server's default EQ backend is the macOS software EQ served
 * by the app at `http://127.0.0.1:8765` (see ../control.ts). This module adds
 * the ability to address additional backends, currently the Luxsin X8 DAC/headphone
 * amp on the LAN.
 *
 * X8 is the writable hardware target. X9 is an explicitly addressed,
 * experimental read-only target; firmware write compatibility is unverified.
 */
export type {
  EqTarget,
  TargetId,
  EqTargetCapabilities,
  ApplyTuningRequest,
  ApplyTuningResult,
} from "./types.js";

export {
  LuxsinX8Target,
  X8_CAPABILITIES,
  buildX8Change,
  padX8WireFilters,
  selectBandsForX8,
  bandToX8Filter,
} from "./luxsin/adapter.js";

export { LuxsinClient } from "./luxsin/client.js";
export type {
  X8HeadphoneEntry,
  X8Filter,
  X8PeqDb,
  X8DeviceState,
  LuxsinClientOptions,
} from "./luxsin/client.js";

export { luxsinEncode, luxsinDecode } from "./luxsin/codec.js";

import type { EqTarget, TargetId } from "./types.js";
import { LuxsinClient } from "./luxsin/client.js";
import { LuxsinX8Target } from "./luxsin/adapter.js";

/** The target used when none is specified — unchanged Auralink behavior. */
export const DEFAULT_TARGET: TargetId = "auralink";

let x8Singleton: LuxsinX8Target | undefined;

/** Create (or reuse) the singleton Luxsin X8 target. */
export function createX8Target(): LuxsinX8Target {
  return (x8Singleton ??= new LuxsinX8Target());
}

/**
 * Resolve a target by id. Returns `undefined` for the legacy `auralink` path,
 * which is served directly by ../control.ts until the EqTarget migration of the
 * tool surface lands. Callers treat `undefined` as "use the existing path".
 */
export function pickTarget(id: TargetId): EqTarget | undefined {
  if (id === "luxsin-x8" || id === "luxsin-x9") return createLuxsinTarget(id);
  return undefined;
}

let x9Singleton: LuxsinX8Target | undefined;
export function createLuxsinTarget(id: "luxsin-x8" | "luxsin-x9"): LuxsinX8Target {
  if (id === "luxsin-x8") return createX8Target();
  return (x9Singleton ??= new LuxsinX8Target(new LuxsinClient({ model: "luxsin-x9", autoDiscover: false })));
}

export const LUXSIN_SUPPORT = {
  "luxsin-x8": { model: "X8", deviceRead: true, deviceWrite: true, maxBands: 10, perChannel: false, fir: false, environment: "X8_URL" },
  "luxsin-x9": { model: "X9", deviceRead: "experimental", deviceWrite: false, maxBands: null, perChannel: null, fir: false, environment: "X9_URL",
    note: "Official X9 documentation confirms custom EQ and web control. Shared-protocol read access is experimental; device writes require model/firmware verification." },
} as const;
