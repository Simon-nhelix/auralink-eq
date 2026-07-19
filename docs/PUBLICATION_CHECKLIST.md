# Source publication checklist

This checklist is for the `0.1.0-alpha` source preview. It does not authorize or
describe distribution of signed app binaries.

## Before the first public push

- Publish a clean source snapshot rather than the existing private commit
  history if that history contains personal email addresses, home-directory
  paths, removed planning documents, or local operations notes.
- Configure the publishing Git identity with the maintainer's GitHub noreply
  address before creating the public initial commit.
- Run `swift test`.
- Run `cd mcp-server && npm ci && npm test`.
- Run `cd mcp-server && npm run license:check`.
- Run `cd mcp-server && npm audit --omit=dev --audit-level=high`.
- Confirm the three bundled JSON data files are identical between
  `Sources/AuralinkCore/Resources/data/` and `mcp-server/data/`.
- Search the complete public snapshot for credentials, control tokens, signing
  material, personal presets, device diagnostics, and absolute home paths.
- Confirm README status and all package/protocol versions describe the same
  prerelease.
- Confirm `docs/LICENSE_REVIEW.md`, `THIRD_PARTY_NOTICES.md`, and copied
  third-party license texts still cover every bundled fixture and asset.

## GitHub repository settings

- Default branch: `main`.
- Require the `Swift build and tests` and `MCP build, tests, and audit` checks
  before merging to `main`.
- Enable Dependabot alerts and security updates.
- Enable secret scanning and push protection when available for the repository.
- Enable private vulnerability reporting so `SECURITY.md` has a working private
  channel.
- Disable binary attachments for the initial announcement; link users to local
  build instructions only.

## First source tag

After CI passes on the public repository, tag the source snapshot
`v0.1.0-alpha.0`. Do not attach the locally signed `.app` bundle to the tag.

## After publication

- Replace any generic repository metadata with the final GitHub URL.
- Review incoming issues for accidentally posted tokens, device identifiers, or
  presets and remove sensitive content promptly.
- Keep `SECURITY.md`, third-party notices, and the network-behavior disclosure in
  sync with new integrations.
