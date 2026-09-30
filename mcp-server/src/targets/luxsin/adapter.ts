/**
 * Luxsin X8 EQ target adapter.
 *
 * Translates Auralink-vocabulary tunings (20 parametric bands, bell/shelf/pass/
 * notch) into Luxsin X8 headphone-DB entries (10 bands, PEAKING/LOW_SHELF/…)
 * and exposes them through the backend-agnostic {@link EqTarget} interface.
 *
 * Pure transformation logic (band mapping, compatibility checks, entry building) is
 * exported and unit-tested; only {@link LuxsinX8Target} talks to the device.
 *
 * Nothing here changes live audio unless `confirmed` is set, and activation
 * (selecting an entry) is a separate explicit step on purpose.
 */
import type { BandType, EQBand, AudioState } from "../../types.js";
import type { ControlResult } from "../../control.js";
import type {
  ApplyTuningRequest,
  ApplyTuningResult,
  EqTarget,
  EqTargetCapabilities,
} from "../types.js";
import {
  LuxsinClient,
  type X8DeviceState,
  type X8Filter,
  type X8PeqChange,
  type X8PeqDb,
  type X8WireFilter,
} from "./client.js";

/** Auralink filter shape → X8 filter type string (device's READ format). */
const BAND_TYPE_TO_X8: Record<BandType, string> = {
  bell: "PEAKING",
  low_shelf: "LOW_SHELF",
  high_shelf: "HIGH_SHELF",
  low_pass: "LOW_PASS",
  high_pass: "HIGH_PASS",
  notch: "NOTCH",
};

/** Auralink filter shape → X8 numeric type code (device's WRITE format).
 *  Verified verbatim from the controller's x(): LPF=0,HPF=1,BPF=2,NOTCH=3,
 *  PEAKING=4,LSHELF=5,HSHELF=6,APF=7. */
const BAND_TYPE_TO_X8_CODE: Record<BandType, number> = {
  bell: 4,
  low_shelf: 5,
  high_shelf: 6,
  notch: 3,
  low_pass: 0,
  high_pass: 1,
};

/** Shapes that are structural and always preserved when trimming bands. */
const STRUCTURAL_TYPES: ReadonlySet<BandType> = new Set([
  "low_shelf",
  "high_shelf",
  "notch",
  "low_pass",
  "high_pass",
]);

const X8_MAX_BANDS = 10;
const NEUTRAL_PAD_FREQUENCIES = [31.5, 63, 125, 250, 500, 1000, 2000, 4000, 8000, 16000];

export const X8_CAPABILITIES: EqTargetCapabilities = {
  maxBands: X8_MAX_BANDS,
  shapes: new Set<BandType>(["bell", "low_shelf", "high_shelf", "low_pass", "high_pass", "notch"]),
  preamp: true,
  perHeadphoneDb: true,
};

/** Convert one Auralink band to an X8 filter. */
export function bandToX8Filter(band: EQBand): X8Filter {
  return {
    type: BAND_TYPE_TO_X8[band.type] ?? "PEAKING",
    fc: round(band.frequencyHz, 2),
    gain: round(band.gainDb, 2),
    q: round(band.q, 2),
  };
}

/**
 * Select at most `maxBands` bands for the X8.
 *
 * Strategy: drop disabled bands; always keep structural shapes (shelves, notch,
 * pass filters — they define the overall contour/surgical fixes); rank bells by
 * impact (|gain|, broader-first on ties) and keep the top ones that fit. If
 * structural bands alone exceed the limit, the lowest-impact are trimmed last.
 * Returns a lossy suggestion for offline analysis only; device writes do NOT use
 * this helper and reject over-limit presets instead.
 */
export function selectBandsForX8(
  bands: EQBand[],
  maxBands = X8_MAX_BANDS,
): { kept: EQBand[]; dropped: EQBand[]; notes: string[] } {
  const notes: string[] = [];
  const disabled = bands.filter((b) => !b.enabled);
  const enabled = bands.filter((b) => b.enabled);
  if (disabled.length) notes.push(`dropped ${disabled.length} disabled band(s)`);

  const structural = enabled.filter((b) => STRUCTURAL_TYPES.has(b.type));
  const bells = enabled
    .filter((b) => !STRUCTURAL_TYPES.has(b.type))
    .sort(byImpactDesc);

  const bellBudget = Math.max(0, maxBands - structural.length);
  const keptBells = bells.slice(0, bellBudget);
  const droppedBells = bells.slice(bellBudget);

  let keptStructural = structural;
  let droppedStructural: EQBand[] = [];
  if (structural.length > maxBands) {
    // Pathological case: more structural bands than the limit. Trim by impact.
    const ranked = [...structural].sort(byImpactDesc);
    keptStructural = ranked.slice(0, maxBands);
    droppedStructural = ranked.slice(maxBands);
  }

  const dropped = [...disabled, ...droppedBells, ...droppedStructural];
  const keptCount = keptStructural.length + keptBells.length;
  if (dropped.length > 0) {
    notes.push(
      `trimmed ${bands.length}→${keptCount} bands; dropped: ` +
        dropped
          .map((b) => `${b.type}@${b.frequencyHz}Hz(${b.gainDb >= 0 ? "+" : ""}${b.gainDb}dB)`)
          .join(", "),
    );
  }

  const kept = [...keptStructural, ...keptBells].sort((a, b) => a.frequencyHz - b.frequencyHz);
  return { kept, dropped, notes };
}

/** Pad a write payload to exactly 10 filters with transparent PEAKING 0dB bands.
 *  Never let the X8 auto-pad: it fills empty slots as LOW_PASS@0Hz, which can
 *  mute the DSP path if that runtime filter set is loaded. */
export function padX8WireFilters(filters: X8WireFilter[], maxBands = X8_MAX_BANDS): { filters: X8WireFilter[]; padded: number } {
  const out = filters.slice(0, maxBands);
  const padded = Math.max(0, maxBands - out.length);
  for (let i = out.length; i < maxBands; i++) {
    out.push({ type: BAND_TYPE_TO_X8_CODE.bell, fc: NEUTRAL_PAD_FREQUENCIES[i] ?? 1000, gain: 0, q: 1 });
  }
  return { filters: out, padded };
}

/** Build the X8 `peqChange` payload (name-keyed upsert) from a tuning request.
 *  Filters use numeric type codes (write format) and are always padded to 10
 *  safe filters before being sent. */
export function buildX8Change(req: ApplyTuningRequest, maxBands = X8_MAX_BANDS): {
  payload: X8PeqChange;
  appliedBands: EQBand[];
  notes: string[];
} {
  const enabled = req.bands.filter((b) => b.enabled);
  if (enabled.length > maxBands) throw new Error(`Luxsin supports ${maxBands} bands; this tuning has ${enabled.length}. Create a hardware-specific tuning; no bands were dropped.`);
  if (enabled.some((b) => b.channel !== "stereo")) throw new Error("Luxsin PEQ cannot represent left/right-only bands; create a stereo tuning first.");
  if (!Number.isFinite(req.preampDb) || req.preampDb < -24 || req.preampDb > 0) throw new Error("Invalid Luxsin preamp (-24…0 dB required).");
  if (enabled.some((b) => !(b.type in BAND_TYPE_TO_X8_CODE) ||
      !Number.isFinite(b.frequencyHz) || b.frequencyHz < 20 || b.frequencyHz > 20000 ||
      !Number.isFinite(b.gainDb) || b.gainDb < -18 || b.gainDb > 18 ||
      !Number.isFinite(b.q) || b.q < 0.1 || b.q > 10)) throw new Error("Invalid Luxsin filter parameters.");
  const kept = [...enabled].sort((a, b) => a.frequencyHz - b.frequencyHz);
  const notes: string[] = [];
  const rawFilters = kept.map((b) => ({
    type: BAND_TYPE_TO_X8_CODE[b.type] ?? 4,
    fc: round(b.frequencyHz, 2),
    gain: round(b.gainDb, 2),
    q: round(b.q, 2),
  }));
  const { filters, padded } = padX8WireFilters(rawFilters, maxBands);
  if (padded > 0) notes.push(`padded ${rawFilters.length}→${maxBands} with neutral PEAKING 0dB filters`);
  // brand/model are REQUIRED by the device to create a new entry (a bare
  // {name,filters,...} only edits). Derive from the headphone string if needed.
  const { brand, model } = splitHeadphone(req.headphone, req.brand, req.model);
  const name = (req.headphone ?? `${brand} ${model}`.trim()).trim();
  const payload: X8PeqChange = {
    name,
    brand,
    model,
    filters,
    autoPre: 0,
    preamp: round(req.preampDb, 2),
    canDel: 1,
  };
  if (req.form) payload.form = req.form;
  if (req.targetCurve) payload.target = req.targetCurve;
  return { payload, appliedBands: kept, notes };
}

/** Derive brand/model for the device's create operation. Explicit fields win;
 *  otherwise split "Sennheiser HD600" → {Sennheiser, HD600}. */
function splitHeadphone(headphone: string | undefined, brand?: string, model?: string): { brand: string; model: string } {
  if (brand && model) return { brand: brand.trim(), model: model.trim() };
  if (!headphone) return { brand: "Unknown", model: "Unknown" };
  const idx = headphone.indexOf(" ");
  if (idx === -1) return { brand: headphone.trim(), model: headphone.trim() };
  return { brand: (brand ?? headphone.slice(0, idx)).trim(), model: (model ?? headphone.slice(idx + 1)).trim() };
}

/** Impact ranking: bigger |gain| first, broader (lower Q) breaks ties. */
function byImpactDesc(a: EQBand, b: EQBand): number {
  const ia = Math.abs(a.gainDb);
  const ib = Math.abs(b.gainDb);
  if (ib !== ia) return ib - ia;
  return a.q - b.q; // broader first
}

function round(n: number, digits: number): number {
  const f = 10 ** digits;
  return Math.round(n * f) / f;
}

/**
 * Luxsin X8 {@link EqTarget}. Read methods are safe to call any time; writes are
 * gated on `confirmed` and never change the active headphone without an
 * explicit {@link selectHeadphone} call.
 */
export class LuxsinX8Target implements EqTarget {
  readonly id: "luxsin-x8" | "luxsin-x9";
  readonly capabilities = X8_CAPABILITIES;
  readonly client: LuxsinClient;

  constructor(client?: LuxsinClient) {
    this.client = client ?? new LuxsinClient();
    this.id = this.client.model;
  }

  /** Full-fidelity device state (richer than the AudioState mapping). */
  async getX8State(): Promise<ControlResult<{ state: X8DeviceState; peq: X8PeqDb }>> {
    try {
      const state = await this.client.getDeviceInfo();
      const peq = await this.client.getPeq();
      return { online: true, status: 200, data: { state, peq } };
    } catch (err) {
      return { online: false, error: explain(err, this.client.baseUrl) };
    }
  }

  async getState(): Promise<ControlResult<AudioState>> {
    try {
      const state = await this.client.getDeviceInfo();
      const peq = await this.client.getPeq();
      return { online: true, status: 200, data: mapState(state, peq) };
    } catch (err) {
      return { online: false, error: explain(err, this.client.baseUrl) };
    }
  }

  private async currentActiveEntryName(): Promise<string | undefined> {
    const state = await this.client.getDeviceInfo();
    const db = await this.client.getPeq();
    const index = Number(state.peqSelect);
    if (db.peq.length && (!Number.isInteger(index) || !db.peq[index])) {
      throw new Error("Cannot establish the active Luxsin entry before mutation.");
    }
    return db.peq[index]?.name;
  }

  private async restoreActiveEntryByName(name?: string): Promise<string | undefined> {
    if (!name) return undefined;
    const state = await this.client.getDeviceInfo();
    const db = await this.client.getPeq();
    const current = db.peq[Number(state.peqSelect ?? 0)]?.name;
    if (current === name) return undefined;
    const index = db.peq.findIndex((e) => e.name === name);
    if (index < 0) throw new Error(`Could not restore active X8 entry "${name}" (not found)`);
    await this.client.setSetting("peqSelect", index);
    const restored = await this.client.getDeviceInfo();
    const restoredDb = await this.client.getPeq();
    if (restoredDb.peq[Number(restored.peqSelect)]?.name !== name) throw new Error("Previous Luxsin entry was not restored on read-back.");
    return `restored active X8 entry "${name}" after DB mutation`;
  }

  private mutationQueue: Promise<unknown> = Promise.resolve();

  private mutate<T>(operation: () => Promise<T>): Promise<T> {
    const run = this.mutationQueue.then(() => this.client.withPinnedDevice(operation));
    this.mutationQueue = run.catch(() => {});
    return run;
  }

  async applyTuning(req: ApplyTuningRequest, confirmed: boolean): Promise<ControlResult<ApplyTuningResult>> {
    if (!confirmed) return this.performApply(req, false);
    try { return await this.mutate(() => this.performApply(req, true)); }
    catch (err) { return { online: false, error: explain(err, this.client.baseUrl) }; }
  }

  /** Serialize write, read-back and selection as one operation. */
  async applyAndSelect(req: ApplyTuningRequest, confirmed: boolean): Promise<{
    write: ControlResult<ApplyTuningResult>;
    select?: ControlResult<{ ok: boolean; index?: number; processing?: boolean }>;
  }> {
    if (!confirmed) return { write: await this.performApply(req, false) };
    try {
      return await this.mutate(async () => {
        const write = await this.performApply(req, true);
        const select = write.data?.ok && write.data.ref ? await this.performSelect(write.data.ref) : undefined;
        return { write, select };
      });
    } catch (err) { return { write: { online: false, error: explain(err, this.client.baseUrl) } }; }
  }

  private async performApply(req: ApplyTuningRequest, confirmed: boolean): Promise<ControlResult<ApplyTuningResult>> {
    const { payload, appliedBands, notes } = buildX8Change(req, this.capabilities.maxBands);

    if (!confirmed) {
      // Preview only — never write to the device without explicit confirmation.
      return {
        online: true,
        status: 200,
        data: {
          ok: false,
          needsConfirm: true,
          ref: payload.name,
          appliedBands,
          notes: ["preview only — pass confirmed:true to write to the X8 headphone DB", ...notes],
        },
      };
    }

    try {
      const previousActive = await this.currentActiveEntryName();
      const existing = (await this.client.getPeq()).peq.filter((e) => e.name === payload.name);
      if (existing.length > 1 || existing.some((e) => e.canDel !== 1)) {
        return { online: true, data: { ok: false, appliedBands, notes }, error: "Luxsin entry name is ambiguous or protected. Choose another tuning name." };
      }
      let verified = false;
      let restoreNote: string | undefined;
      try {
        await this.client.peqChange(payload);
        const entries = (await this.client.getPeq()).peq.filter((e) => e.name === payload.name);
        verified = entries.length === 1 && entryMatchesPayload(entries[0], payload);
      } finally {
        // Even a lost acknowledgement may follow a successful DB mutation.
        restoreNote = await this.restoreActiveEntryByName(previousActive);
      }
      return {
        online: true,
        status: 200,
        data: { ok: verified, ref: payload.name, appliedBands, notes: restoreNote ? [...notes, restoreNote] : notes },
        ...(!verified ? { error: "Device acknowledged the request but stored EQ did not match. Not selecting the entry." } : {}),
      };
    } catch (err) {
      return { online: false, error: explain(err, this.client.baseUrl) };
    }
  }

  /** Delete only the named inactive entry; never let deletion switch live sound. */
  async deleteHeadphone(name: string, confirmed = false): Promise<ControlResult<{ ok: boolean; needsConfirm?: boolean }>> {
    if (!confirmed) return { online: true, data: { ok: false, needsConfirm: true } };
    try {
      return await this.mutate(async () => {
        const previousActive = await this.currentActiveEntryName();
        if (previousActive === name) return { online: true, data: { ok: false }, error: "Select another entry before deleting the active Luxsin preset." };
        const before = await this.client.getPeq();
        const entries = before.peq.filter((e) => e.name === name);
        if (entries.length === 0) return { online: true, data: { ok: true } };
        if (entries.length !== 1 || entries[0].canDel !== 1) return { online: true, data: { ok: false }, error: "Entry is ambiguous or protected; not deleted." };
        try { await this.client.peqRemove(name); }
        finally { await this.restoreActiveEntryByName(previousActive); }
        const after = await this.client.getPeq();
        const ok = !after.peq.some((e) => e.name === name);
        return { online: true, data: { ok }, ...(!ok ? { error: "Deletion was not confirmed by device read-back." } : {}) };
      });
    } catch (err) {
      return { online: false, error: explain(err, this.client.baseUrl) };
    }
  }

  async rollback(): Promise<ControlResult<{ ok: boolean }>> {
    // The X8 has no exposed "previous preset" concept; rolling back means
    // re-selecting a different headphone entry, which is a deliberate choice.
    return {
      online: true,
      status: 200,
      data: { ok: false },
      error: "X8 target has no live rollback; use selectHeadphone(name) to switch entries.",
    };
  }

  /** Explicitly activate a headphone entry by name (changes live audio). */
  async selectHeadphone(name: string, confirmed = false): Promise<ControlResult<{ ok: boolean; index?: number; processing?: boolean; needsConfirm?: boolean }>> {
    if (!confirmed) return { online: true, data: { ok: false, needsConfirm: true } };
    try { return await this.mutate(() => this.performSelect(name)); }
    catch (err) { return { online: false, error: explain(err, this.client.baseUrl) }; }
  }

  private async performSelect(name: string): Promise<ControlResult<{ ok: boolean; index?: number; processing?: boolean }>> {
    try {
      const db = await this.client.getPeq();
      const index = db.peq.findIndex((e) => e.name === name);
      if (index === -1) return { online: true, status: 200, data: { ok: false }, error: `no X8 entry named "${name}"` };
      await this.client.setSetting("peqSelect", index);
      const state = await this.client.getDeviceInfo();
      const after = await this.client.getPeq();
      const selected = Number(state.peqSelect);
      const ok = Number.isInteger(selected) && after.peq[selected]?.name === name;
      const processing = state.dsp_enable === 1 && state.peqEnable === 1 && state.audio_enable !== 0;
      return { online: true, status: 200, data: { ok, index: selected, processing },
        ...(!ok ? { error: "Requested Luxsin entry was not selected on read-back." } : {}) };
    } catch (err) {
      return { online: false, error: explain(err, this.client.baseUrl) };
    }
  }
}

/** Verify real stored filters, not the firmware's unconditional HTTP 200 ack. */
export function entryMatchesPayload(entry: X8PeqDb["peq"][number], payload: X8PeqChange): boolean {
  try {
    const filters = JSON.parse(entry.filters) as X8Filter[];
    const typeNames = ["LOW_PASS", "HIGH_PASS", "BPF", "NOTCH", "PEAKING", "LOW_SHELF", "HIGH_SHELF", "APF"];
    const close = (a: number, b: number) => Number.isFinite(a) && Math.abs(a - b) <= 0.011;
    return entry.name === payload.name && close(entry.preamp, payload.preamp) && entry.autoPre === 0 &&
      Array.isArray(filters) && filters.length === payload.filters.length && filters.every((filter, i) => {
        const expected = payload.filters[i];
        return filter.type === typeNames[expected.type] && close(filter.fc, expected.fc) &&
          close(filter.gain, expected.gain) && close(filter.q, expected.q);
      });
  } catch { return false; }
}

/** Map X8 device state into Auralink's AudioState (best-effort, lossy). */
export function mapState(state: X8DeviceState, peq: X8PeqDb): AudioState {
  const index = Number(state.peqSelect);
  const active = Number.isInteger(index) ? peq.peq[index] : undefined;
  const sampleRate = parseSampleRate(state.audioFormat);
  return {
    eqEnabled: state.peqEnable === 1,
    safeMode: false,
    hqCorrectionMode: false,
    currentPresetName: active?.name,
    needsVirtualDevice: false,
    loopbackDriverInstalled: false,
    systemOutputRoutedToAuralink: false,
    sampleRate,
    bufferFrames: 0,
    latencyMs: 0,
    routingActive: state.dsp_enable === 1,
    clippingDetected: false,
    preClipPeakDb: -120,
    estimatedTruePeakDb: -120,
    clippingEventsTotal: 0,
    lastClippingPeakDb: -120,
    outputPeakDb: -120,
    capturePeakDb: -120,
    captureCallbacks: 0,
    renderCallbacks: 0,
    capturedFrames: 0,
    renderedFrames: 0,
    ringReadFrames: 0,
    ringAvailableFrames: 0,
    underrunsTotal: 0,
    resyncsTotal: 0,
    mcpConnected: false,
    permissionMode: "ask_before_write",
    audioInputPermission: "unknown",
  };
}

function parseSampleRate(audioFormat?: string): number {
  if (!audioFormat) return 0;
  const m = audioFormat.match(/(\d+(?:\.\d+)?)\s*kHz/i);
  return m ? parseFloat(m[1]) * 1000 : 0;
}

function explain(err: unknown, baseUrl: string): string {
  const msg = err instanceof Error ? err.message : String(err);
  return `Luxsin operation failed at ${baseUrl} (${msg}). Make sure the device is on and on the same network, check the configured hardware address. Do not switch audio targets automatically.`;
}
