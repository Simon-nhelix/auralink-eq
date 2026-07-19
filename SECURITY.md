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

## Network behavior

- The Swift app processes audio locally and does not upload audio.
- The MCP server can fetch public AutoEq result files from GitHub when that tool
  is invoked. Results are cached under the user's Auralink Application Support
  directory.
- Optional Luxsin X8 support communicates with a device on the local network and
  may scan private IPv4 addresses when device discovery is requested.
- No analytics or crash-reporting service is included.
