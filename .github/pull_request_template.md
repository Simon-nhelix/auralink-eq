## Summary

Describe the user-visible change and why it is needed.

## Verification

- [ ] `swift test`
- [ ] `cd mcp-server && npm test`
- [ ] `cd mcp-server && npm audit --omit=dev --audit-level=high`
- [ ] Bundled Swift/MCP JSON data remain identical, if touched
- [ ] Manual audio or hardware verification described below, if applicable

## Safety and compatibility

- [ ] No control token, personal preset, signing material, device identifier, or absolute home path is included
- [ ] Realtime audio callbacks still avoid allocation, locks, file I/O, and logging
- [ ] New network, permission, or on-disk behavior is documented

Manual verification and remaining risks:
