import { getState } from "./control.js";
import {
  pollAuralinkLiveVerification,
  type AuralinkLiveVerification,
} from "./live-verification.js";

/** A text-only tool result carrying pretty-printed JSON (the AI parses this). */
export function jsonResult(value: unknown): { content: { type: "text"; text: string }[] } {
  return { content: [{ type: "text", text: JSON.stringify(value, null, 2) }] };
}

/** Separates control acceptance from a state-verified audible change. */
export async function verifyAuralinkLiveRequest(
  requestAccepted: boolean,
  expectedPresetId?: string,
  expectedRenderGeneration?: number
): Promise<AuralinkLiveVerification> {
  return pollAuralinkLiveVerification(
    requestAccepted,
    async () => {
      const stateResult = await getState();
      return stateResult.online ? stateResult.data : undefined;
    },
    expectedPresetId,
    expectedRenderGeneration
  );
}

/** A tool error result with a human-readable message. */
export function errorResult(
  message: string
): { content: { type: "text"; text: string }[]; isError: true } {
  return { content: [{ type: "text", text: message }], isError: true };
}
