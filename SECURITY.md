# Security policy

## Supported versions

Auralink EQ is currently an alpha project. Security fixes are applied to the
latest `main` branch and the newest `0.1.x` prerelease only.

## Reporting a vulnerability

Please do not include exploit details, control tokens, device identifiers, or
audio-path diagnostics in a public issue. Use GitHub's private vulnerability
reporting feature from the repository's **Security** tab. If private reporting
is not yet enabled, open a minimal issue asking the maintainer for a private
contact channel without disclosing the vulnerability.

Useful reports include the affected commit, macOS and Node versions, expected
security boundary, minimal reproduction, and impact. Remove personal device
names and preset contents unless they are essential to the report.

## Local control boundary

The app's HTTP ControlServer binds to the loopback interface only. It also
requires a random bearer capability stored at:

`~/Library/Application Support/Auralink/control-token`

The file is created with user-only permissions. Do not paste the token into
issues, logs, shell history, MCP configuration, or repository files. The MCP
server reads it directly. `AURALINK_CONTROL_TOKEN` and
`AURALINK_CONTROL_TOKEN_FILE` exist for controlled development environments;
never commit their values.

Browser-originated requests are rejected, CORS is not enabled, and ControlServer
write requests require JSON. Binding to loopback and token authentication do not
protect a machine whose user account is already compromised.

MCP tools that edit library files query the authenticated app state before
writing. Read Only cannot be overridden by a client confirmation; Ask Before
Write requires `confirmed:true`. If the app's permission mode cannot be verified
(offline, authentication failure, or unsupported response), no library files are
changed. This policy covers presets, headphone profiles, collection membership,
and tuning feedback; read-tool cache maintenance is separate.

## Network behavior

- The Swift app processes audio locally and does not upload audio.
- A packaged app with an update public key checks public GitHub release metadata
  automatically at most once a day, unless disabled in the update window.
  Archives and detached signatures are downloaded only when the user chooses
  installation. No audio, control token, preset or device data is sent.
- The MCP server can fetch public AutoEq result files from GitHub when that tool
  is invoked. Results are cached under the user's Auralink Application Support
  directory.
- Optional Luxsin X8 support communicates with a device on the local network and
  may scan private IPv4 addresses when device discovery is requested.
- No analytics or crash-reporting service is included.

## Update authenticity

The app pins an Ed25519 public key in its signed bundle. HTTPS downloads are
verified before extraction; the extracted app must match the release version,
bundle identifier and public key and have a valid macOS code signature. A modified
archive or signature is rejected before app replacement. The release private key
is kept in the maintainer's login keychain, separate from MiSTer FTP's key. The
GitHub account and release notes are not themselves authenticated by that key.

Ad-hoc macOS signing is the current release workflow. Update authenticity does
not imply Apple notarization. Key rotation is not supported automatically; a lost
key requires recovery or a documented manual migration to a newly signed release.

### MCP tuning persistence

A request to register a device or tune its EQ includes saving the resulting
baseline or preference preset. MCP tuning tools write both the working preset
library and the configured user collection; they do not commit or publish it.
The existing app permission mode still governs these writes. A separate user
request to hear a result is required for live application. `delete_preset`
removes working and collection copies plus revision history; it does not cascade
to other presets. Explicitly unsaved listening trials remain available.
