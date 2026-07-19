/**
 * EQ target abstraction — lets the Auralink MCP server drive more than one EQ
 * backend. The default target is the Auralink macOS software EQ
 * (`http://127.0.0.1:8765`); an additional `luxsin-x8` target can talk to a
 * Luxsin X8 DAC/headphone amp on the LAN whose PEQ lives in a per-headphone
 * database on the device.
 *
 * Nothing here is wired into the MCP tool surface yet (see `mcp-server/src/index.ts`);
 * this module is the migration target. Adding the `target` parameter to the
 * apply/audition tools is a separate, deliberate step.
 */
import type { BandType, EQBand, AudioState } from "../types.js";
import type { ControlResult } from "../control.js";

export type TargetId = "auralink" | "luxsin-x8";

/** What a given EQ backend can express. Used to clamp/transform band lists. */
export interface EqTargetCapabilities {
  /** Maximum number of parametric bands the target accepts. */
  maxBands: number;
  /** Filter shapes the target understands, in the Auralink vocabulary. */
  shapes: ReadonlySet<BandType>;
  /** Whether the target has a hardware/global preamp control. */
  preamp: boolean;
  /**
   * True when the target stores EQ per-headphone in an on-device database
   * (Luxsin X8). False for a single live preset (Auralink software EQ).
   */
  perHeadphoneDb: boolean;
}

/** A tuning to apply, described in backend-agnostic Auralink terms. */
export interface ApplyTuningRequest {
  /** Headphone identity, when the target is per-headphone. */
  headphone?: string;
  brand?: string;
  model?: string;
  /** Form factor for per-headphone targets, e.g. "over-ear" / "in-ear". */
  form?: string;
  /** Free-text tuning intent. */
  goal?: string;
  /**
   * Measurement target / rig provenance, e.g.
   * "crinacle EARS + 711 Harman over-ear 2018". Passed through to targets that
   * record it (X8 `target` field).
   */
  targetCurve?: string;
  /** Global preamp in dB (usually negative). */
  preampDb: number;
  /** Auralink-vocabulary bands (up to 20). */
  bands: EQBand[];
}

export interface ApplyTuningResult {
  ok: boolean;
  /** Honors the target's permission mode (e.g. Auralink needs in-app confirm). */
  needsConfirm?: boolean;
  /** Target-specific reference (X8 peq entry index, Auralink preset id, …). */
  ref?: string;
  /** Bands actually applied, after clamping/selection. */
  appliedBands: EQBand[];
  /** Human-readable transformations (e.g. "trimmed 20→10 bands"). */
  notes?: string[];
}

/**
 * Implemented by every EQ backend. Methods are the union needed by the
 * apply/audition/rollback tools; routing primitives (routeSystemAudio, …) are
 * Auralink-only and intentionally NOT on this interface.
 */
export interface EqTarget {
  readonly id: TargetId;
  readonly capabilities: EqTargetCapabilities;
  getState(): Promise<ControlResult<AudioState>>;
  applyTuning(req: ApplyTuningRequest, confirmed: boolean): Promise<ControlResult<ApplyTuningResult>>;
  rollback(): Promise<ControlResult<{ ok: boolean }>>;
}
