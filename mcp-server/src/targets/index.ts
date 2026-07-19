/**
 * EQ target registry.
 *
 * The Auralink MCP server's default EQ backend is the macOS software EQ served
 * by the app at `http://127.0.0.1:8765` (see ../control.ts). This module adds
 * the ability to address additional backends, currently the Luxsin X8 DAC/headphone
 * amp on the LAN.
 *
 * Status: the X8 target is fully implemented and validated. The `auralink` id
 * still resolves to `undefined` here on purpose — the existing tool surface in
 * ../index.ts calls ../control.ts directly, and routing it through EqTarget is a
 * deliberate migration step (adding a `target` parameter to the apply/audition
 * tools) kept separate so this module can land with zero impact on live audio.
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
  if (id === "luxsin-x8") return createX8Target();
  return undefined;
}
