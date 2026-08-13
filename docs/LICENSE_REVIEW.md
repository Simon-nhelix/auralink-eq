# Source license review

Review date: 2026-07-19

This review covers the `0.1.0-alpha` public source snapshot. It is a practical
release check, not legal advice, and does not approve distribution of signed
application binaries or third-party installers.

## Result

No known license incompatibility blocks publication of this source snapshot
under Apache-2.0. The conclusion assumes the maintainer has authority to
license the original Auralink source, documentation, icon, and UI screenshots.

## Reviewed scope

- Auralink source and documentation use Apache-2.0 with `LICENSE`, `NOTICE`,
  and contribution terms in `CONTRIBUTING.md`.
- The Swift package has no third-party SwiftPM dependencies. Apple SDK
  frameworks are referenced from the host development platform and are not
  copied into this repository.
- `mcp-server/package-lock.json` resolves 95 Node packages: 84 MIT, 7 ISC,
  2 BSD-3-Clause, 1 BSD-2-Clause, and 1 Apache-2.0. No package has an
  undeclared, copyleft, source-available, or proprietary license in the lock
  file. `npm run license:check` enforces this reviewed set in CI.
- Two Sennheiser HD 600 fixtures are exact copies of AutoEq's published
  `oratory1990` results at reviewed revision
  `7ae0f56d53074872b028649617a22bbb4232feb7`. AutoEq is MIT-licensed; its full
  license text is included at `third_party/licenses/AutoEq-LICENSE` and the
  measurement provenance is recorded in `THIRD_PARTY_NOTICES.md`.
- No headphone profiles or baseline presets are bundled. That data moved out of
  this repository into user-owned collection directories
  (`docs/DATA_COLLECTION.md`), which removes measurement-derived content from the
  distributed source entirely and narrows the publication boundary accordingly.
  What remains under `Sources/AuralinkCore/Resources/data` is `target-curves.json`
  and `safety-rules.json`: project-authored band hints and engineering limits. The
  IEF target-curve entry records two factual filter parameters from the attributed
  public article and does not redistribute its graphs, article text, or dataset.
  A user's own collection is their content to license; nothing in it ships here.
- The Auralink icon and UI screenshots contain project artwork and UI only;
  they do not embed third-party logos or photographs.
- BlackHole is referenced as a separately installed audio driver. Its GPL-3.0
  source, installer, branding, and binaries are not included, linked, modified,
  or redistributed by this source snapshot.

## Publication boundary

Before distributing binaries, installers, a vendored `node_modules`, copied
measurement databases, new fonts, or replacement artwork, perform a new review
and include every required license and attribution in the distributed bundle.
