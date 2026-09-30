# Luxsin tuning support and verification

Reviewed on 2026-09-30. Auralink's AI client creates explicit PEQ settings and
sends them to the hardware; it does not invoke Luxsin's own AI service.

## Model support

| Target | Implemented | Verification limits |
| --- | --- | --- |
| `luxsin-x8` | State reads, verified PEQ storage and selection, inactive preset deletion | Existing X8 protocol plus simulated-device regression tests. The configured device was unreachable during this review; these changes have not been tested on live hardware. |
| `luxsin-x9` | Experimental state and preset reads with explicit `X9_URL`; local tuning preparation | Shared CGI read protocol is an inference, not a confirmed X9 integration. Device writes remain disabled pending firmware-specific verification. |
| Other Luxsin models | Not enabled | Add models only after identifying their API, filter limits and device identity. AI branding alone does not establish protocol compatibility. |

Use `list_eq_targets` to discover these limits through normal MCP operation.
Existing `target:"luxsin-x8"` calls remain supported. X9 requests never fall back
to X8 discovery or to Auralink software audio.

## Findings corrected in this review

- The old apply result could report success after an HTTP acknowledgement even
  when storage or selection failed. The adapter now reads back the exact entry,
  all filters, preamp, auto-preamp setting and selected name. `applied:true` also
  requires the device to report DSP and PEQ processing enabled. This does not
  measure physical audibility or subjective sound quality.
- Hardware writes previously discarded bands above the 10-band limit and lost
  left/right-only routing. They now reject both cases. Create a separate stereo
  hardware tuning with at most 10 active bands, preserving the original preset.
  Unused slots still use transparent PEAKING filters to avoid unsafe auto-padding.
- Request spacing did not prevent concurrent requests from overlapping. Complete
  requests and write/read-back/select transactions are now serialized.
- Failed writes were retried, including mutating GET requests. They are now sent
  once because a lost acknowledgement may follow a successful device change.
  Active-entry restoration is attempted even after a failed acknowledgement.
  A failed verification is not proof that nothing was written: inspect device
  state before retrying.
- Explicit device addresses now disable automatic discovery by default. Mutations
  stay bound to the initially verified address/model and MAC when available.
- Malformed PEQ responses no longer look like an empty library. Model identity is
  matched exactly, and 44.1 kHz status is no longer truncated to 44 kHz.

## Preset lifecycle

Keep the device baseline and preference variations as separate local presets.
Validate the intended hardware preset with `validate_eq_preset` and
`target:"luxsin-x8"` before applying. Measured FIR data stays in the portable local
preset; Luxsin hardware receives its compatible PEQ bands only.

`delete_preset` deletes the local working/collection copies. For the hardware
database, use `delete_luxsin_preset` with the exact entry name after the user's
deletion request. Active or protected entries are refused. Removal is read back
and the previous active name is restored if the database order changes.

The device may defer persistent settings storage; immediate read-back proves the
reported current state, not survival across a power cycle. No firmware upgrade,
audio setting change, or hardware preset write was performed during this review.

## Evidence and next verification

Luxsin's [official X8 API release](https://forum.zidoo.tv/index.php?threads/luxsin-x8-api-now-available.103689/)
links to its [firmware-derived API notes](https://am.luxsinaudio.com/ota/202607/x8/4d2ab/README.md).
These confirm the custom Base64 alphabet, CGI reads, numeric filter codes and
PEQ structure. They also state that POST handlers are firmware-dependent and
should be verified against a device build. The existing `data=` form field is
retained: the notes say the field name is not checked by that source.

The [official X9 product page](https://luxsinaudio.com/products/luxsin-x9)
and [personal EQ instructions](https://luxsinaudio.com/pages/add-personal-eq-into-x9)
confirm web control and user EQ. They do not establish compatibility with every
X8 write command. The [X8 firmware history](https://luxsinaudio.com/pages/download-for-x8)
also documents deferred settings persistence and Web UI PEQ fixes.

Before enabling X9 writes, capture its firmware version and read-only state/PEQ
shape, verify documented filter limits and write semantics, and test a disposable
inactive entry with read-back and cleanup on an explicitly authorized device.
Confirm existing selection, enable flags and presets survive the operation.
