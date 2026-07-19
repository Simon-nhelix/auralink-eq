import { AudioState } from "./types.js";

export interface AuralinkLiveVerification {
  requestAccepted: boolean;
  audible: boolean;
  stateVerified: boolean;
  routingActive?: boolean;
  systemOutputRoutedToAuralink?: boolean;
  eqEnabled?: boolean;
  currentPresetMatches?: boolean;
  hqCorrectionRequested?: boolean;
  hqCorrectionMode?: boolean;
  rendererCommitted?: boolean;
  expectedRenderGeneration?: number;
  requestedRenderGeneration?: number;
  committedRenderGeneration?: number;
  message: string;
}

export function acceptedRollbackTarget(body: {
  ok?: boolean;
  presetId?: string;
}): string | undefined {
  return body.ok === true && typeof body.presetId === "string" && body.presetId.length > 0
    ? body.presetId
    : undefined;
}

/** Pure post-request truth check. Control acceptance alone is never audible. */
export function evaluateAuralinkLiveRequest(
  requestAccepted: boolean,
  state: AudioState | undefined,
  expectedPresetId?: string,
  expectedRenderGeneration?: number
): AuralinkLiveVerification {
  if (!requestAccepted) {
    return {
      requestAccepted: false,
      audible: false,
      stateVerified: false,
      message: "The app did not accept the live-audio request.",
    };
  }
  if (!state) {
    return {
      requestAccepted: true,
      audible: false,
      stateVerified: false,
      message: "The app accepted the request, but post-change live state could not be verified.",
    };
  }
  const routingAudible = state.routingActive && state.systemOutputRoutedToAuralink;
  const currentPresetMatches = expectedPresetId === undefined || state.currentPresetId === expectedPresetId;
  const requestedFIR = state.hqCorrectionRequested ?? state.hqCorrectionMode;
  const generationCommitted = expectedRenderGeneration !== undefined
    && state.requestedRenderGeneration === expectedRenderGeneration
    && state.committedRenderGeneration === expectedRenderGeneration;
  const rendererCommitted = requestedFIR === state.hqCorrectionMode && generationCommitted;
  const audible = routingAudible && state.eqEnabled && currentPresetMatches && rendererCommitted;
  let message: string;
  if (!routingAudible) {
    message = "The app accepted the request, but Auralink is not the active routed system-audio path; no audible change is verified.";
  } else if (!state.eqEnabled) {
    message = "The app accepted and selected the preset, but EQ is bypassed; no audible EQ change is verified.";
  } else if (!currentPresetMatches) {
    message = "The app accepted the request, but the expected preset is not yet reported as current.";
  } else if (!rendererCommitted) {
    message = "The app accepted the request and routing is active, but the exact requested DSP generation has not yet committed at an audio callback boundary.";
  } else {
    message = "Post-change state verifies the expected preset on an active routed EQ path with the requested renderer committed.";
  }
  return {
    requestAccepted: true,
    audible,
    stateVerified: true,
    routingActive: state.routingActive,
    systemOutputRoutedToAuralink: state.systemOutputRoutedToAuralink,
    eqEnabled: state.eqEnabled,
    currentPresetMatches,
    hqCorrectionRequested: requestedFIR,
    hqCorrectionMode: state.hqCorrectionMode,
    rendererCommitted,
    expectedRenderGeneration,
    requestedRenderGeneration: state.requestedRenderGeneration,
    committedRenderGeneration: state.committedRenderGeneration,
    message,
  };
}

export interface AuralinkLivePollOptions {
  /** Total state reads including the first one. Default 3. */
  maxAttempts?: number;
  /** Delay between reads. Default 75 ms (the app publishes telemetry ~10 Hz). */
  delayMs?: number;
  /** Injectable for tests. */
  sleep?: (ms: number) => Promise<void>;
}

const defaultSleep = (ms: number): Promise<void> =>
  new Promise<void>((resolve) => setTimeout(resolve, ms));

/**
 * Bounded-poll wrapper around the pure truth check. The app commits a
 * requested DSP generation at the next audio-callback boundary and coalesces
 * telemetry on a ~10 Hz tick, so one immediate /state read can lag an accepted
 * request and report a false negative. Only callback/tick-transient mismatches
 * (preset identity or committed generation while the routed EQ path is up) are
 * retried; routing-off / EQ-bypassed / unreadable-state outcomes are stable
 * user or device state and return on the first read.
 */
export async function pollAuralinkLiveVerification(
  requestAccepted: boolean,
  readState: () => Promise<AudioState | undefined>,
  expectedPresetId?: string,
  expectedRenderGeneration?: number,
  options: AuralinkLivePollOptions = {}
): Promise<AuralinkLiveVerification> {
  const maxAttempts = Math.max(1, Math.floor(options.maxAttempts ?? 3));
  const delayMs = Math.max(0, options.delayMs ?? 75);
  const sleep = options.sleep ?? defaultSleep;
  if (!requestAccepted) {
    // A rejected request has no committed state to wait for; keep the pure
    // fast path and avoid a pointless state read.
    return evaluateAuralinkLiveRequest(
      false,
      undefined,
      expectedPresetId,
      expectedRenderGeneration
    );
  }
  let last: AuralinkLiveVerification | undefined;
  for (let attempt = 0; attempt < maxAttempts; attempt += 1) {
    const state = await readState();
    last = evaluateAuralinkLiveRequest(
      requestAccepted,
      state,
      expectedPresetId,
      expectedRenderGeneration
    );
    if (last.audible) return last;
    const transientCommitLag =
      last.requestAccepted &&
      last.stateVerified &&
      last.routingActive === true &&
      last.systemOutputRoutedToAuralink === true &&
      last.eqEnabled === true &&
      (last.currentPresetMatches === false || last.rendererCommitted === false);
    if (!transientCommitLag || attempt + 1 >= maxAttempts) return last;
    await sleep(delayMs);
  }
  // maxAttempts >= 1 guarantees `last` was assigned in the loop above.
  return last as AuralinkLiveVerification;
}
