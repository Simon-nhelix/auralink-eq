# Contributing to Auralink EQ

Thanks for helping improve Auralink EQ. The project is in alpha, so small,
well-tested changes with a clearly stated user impact are easiest to review.

## Development setup

Requirements:

- macOS 14 or newer
- Swift 6 toolchain / Xcode command-line tools
- Node.js 18 or newer for the MCP server
- BlackHole 2ch only when testing live system-audio routing

Run the verification suites before opening a pull request:

```bash
swift test

cd mcp-server
npm ci
npm test
npm audit --omit=dev --audit-level=high
```

## Pull requests

- Keep DSP and wire-format changes covered by deterministic tests.
- Preserve realtime callback constraints: no allocation, locks, file I/O, or
  logging on the audio render/capture paths.
- Update both Swift and MCP copies when changing bundled knowledge data; CI
  checks that the JSON files stay identical.
- Document new network access, local-device discovery, permissions, or on-disk
  data in `SECURITY.md` and the setup documentation.
- Never commit personal presets, device diagnostics, control tokens, signing
  material, absolute home-directory paths, or AI-client configuration files.
- Note when manual hardware or listening verification was performed; automated
  tests do not establish subjective sound quality.

Restarting the app can interrupt live audio. Ask before stopping a running app
in a shared development session, and restore routing through the UI afterwards.

By contributing, you agree that your contribution is licensed under the
Apache License 2.0 as described in `LICENSE`.
