# Third-party notices

Auralink EQ is licensed under Apache-2.0. The following projects and data are
not relicensed by Auralink EQ; their original terms continue to apply.

## Included source dependencies and fixtures

### AutoEq

The MCP integration reads public equalization results from the
[AutoEq repository](https://github.com/jaakkopasanen/AutoEq). The HD600
ParametricEQ and GraphicEQ files under `mcp-server/test/fixtures/` are retained
as deterministic test fixtures derived from those published results.

- Copyright: Jaakko Pasanen and AutoEq contributors
- License: MIT
- Upstream license: <https://github.com/jaakkopasanen/AutoEq/blob/master/LICENSE>
- Included license text: `third_party/licenses/AutoEq-LICENSE`
- Reviewed upstream revision: `7ae0f56d53074872b028649617a22bbb4232feb7`
- Measurement provenance for the fixture: AutoEq `oratory1990` results for the
  Sennheiser HD 600

AutoEq aggregates measurements from multiple upstream measurement sources.
Auralink records the selected source and result URL with fetched corrections;
users remain responsible for complying with terms that apply to their use of
those upstream measurements.

### Headphone and preference-target references

The bundled headphone profiles are short editorial summaries, not copies of
third-party measurement databases. Their `source` fields identify the
manufacturer or measurement communities that informed the summary. Runtime
AutoEq corrections keep their exact upstream source and result URL.

The advisory `Crinacle IEF Preference 2025` hint is based on the filter
parameters described in [The New 2025 IEF Target](https://crinacle.com/2025/02/05/the-new-2025-ief-target/).
It is a small preference-direction template, not a redistributed target dataset.

### Model Context Protocol TypeScript SDK

- Package: `@modelcontextprotocol/sdk@1.29.0`
- License: MIT
- Package copyright notice: Copyright (c) 2024 Anthropic, PBC
- Source: <https://github.com/modelcontextprotocol/typescript-sdk>

The upstream project later began a licensing transition. The resolved npm
package used here declares MIT and includes the MIT license text in its
published tarball; this notice describes that resolved package, not the current
default branch.

### Zod

- Package: `zod@3.25.76`
- License: MIT
- Source: <https://github.com/colinhacks/zod>

The source repository does not vendor `node_modules`. Direct development
dependencies are TypeScript 5.9.3 (Apache-2.0) and `@types/node` 22.19.20
(MIT). Transitive Node dependency names, resolved versions, integrity hashes,
and declared licenses are recorded in `mcp-server/package-lock.json`. The
lockfile's declared licenses are checked in CI against a review-required
allowlist.

## Algorithmic references

The biquad implementation uses the published equations in Robert
Bristow-Johnson's [Audio EQ Cookbook](https://www.w3.org/TR/audio-eq-cookbook/)
as a mathematical reference. No third-party implementation is vendored.

## Project artwork and screenshots

The Auralink icon under `assets/` and Auralink UI screenshots under `design/`
are project artwork released with Auralink EQ under Apache-2.0. Product and
target names visible in examples are descriptive references; the images do not
include third-party logos or imply endorsement.

## Referenced but not distributed

### BlackHole

Auralink can use the separately installed BlackHole audio loopback driver. This
repository does not contain, build, modify, or distribute BlackHole.

- Project: <https://github.com/ExistentialAudio/BlackHole>
- License: GPL-3.0 for the upstream open-source project; upstream also documents
  separate licensing for non-GPL projects that redistribute or customize it.

Product names and trademarks belong to their respective owners. References to
headphone models, targets, measurement sources, and hardware are descriptive
and do not imply endorsement.
