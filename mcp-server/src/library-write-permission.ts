import { z } from "zod";

import { getState, type ControlResult } from "./control.js";
import type { AudioState, PermissionMode } from "./types.js";

export const libraryWriteConfirmationSchema = z.boolean().default(false).describe(
  "Set true when the user requested registration, tuning (including automatic saving), or deletion. No separate save request is needed. " +
  "Read Only always forbids writes; Ask Before Write requires confirmation."
);

export interface LibraryWriteDenial {
  ok: false;
  written: false;
  needsConfirm: boolean;
  reason: "read_only" | "confirmation_required" | "permission_unavailable";
  permissionMode?: PermissionMode;
  message: string;
}

/** Check each disk mutation against the app's current policy before any write. */
export async function libraryWriteDenial(
  confirmed: boolean,
  state?: ControlResult<AudioState>
): Promise<LibraryWriteDenial | undefined> {
  const response = state ?? await getState();
  const mode = response.online ? response.data?.permissionMode : undefined;
  switch (mode) {
    case "read_only":
      return {
        ok: false, written: false, needsConfirm: false, reason: "read_only",
        permissionMode: mode,
        message: "The app is in Read Only mode; library writes are not allowed, even with confirmation.",
      };
    case "ask_before_write":
      if (!confirmed) {
        return {
          ok: false, written: false, needsConfirm: true, reason: "confirmation_required",
          permissionMode: mode,
          message: "No files were changed. Pass confirmed:true only when the user explicitly requested this file change.",
        };
      }
      return undefined;
    case "allow_preset_creation":
    case "full_control":
      return undefined;
    default:
      // Confirmation cannot substitute for an unavailable or unknown policy.
      return {
        ok: false, written: false, needsConfirm: false, reason: "permission_unavailable",
        message: "No files were changed because the app's write permission could not be verified. " +
          "Launch Auralink EQ and check its local control connection, then retry.",
      };
  }
}
