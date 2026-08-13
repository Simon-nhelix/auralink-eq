# Auralink EQ — Setup

This guide gets Auralink EQ processing your system audio end to end, then wires
the MCP server into Claude Desktop so an AI can drive it.

There are two halves:

1. **System-audio routing** (BlackHole) — required for any sound to be EQ'd.
2. **AI control** (the MCP server) — optional, for natural-language tuning.

---

## Part 1 — System-audio routing with BlackHole

macOS has no built-in way to feed the whole system mix into another app, so we
use the free **BlackHole** virtual audio driver. The idea: macOS plays into
BlackHole, Auralink captures from BlackHole, applies the EQ, and plays the
result to your real headphones/DAC.

```
   macOS audio ──► BlackHole (virtual) ──► Auralink (EQ) ──► your headphones 🎧
```

### Step 1 — Install BlackHole (2 channels)

```bash
brew install blackhole-2ch
```

If you don't use Homebrew, download the installer from
<https://existential.audio/blackhole/>. After installing, a device named
**"BlackHole 2ch"** appears in *Audio MIDI Setup* and in System Settings →
Sound.

> A logout/login (or reboot) is sometimes needed before macOS lists the new
> device.

### Step 2 — Send system audio into BlackHole

Pick **one** of these. Option B is recommended because you keep hearing audio
through your normal speakers/headphones outside of Auralink while you set
things up.

**Option A — quick (output straight to BlackHole):**
System Settings → Sound → Output → choose **BlackHole 2ch**. All system audio
now flows into BlackHole. You will hear nothing until Auralink is running and
routing to your real output (Step 4).

**Option B — Multi-Output Device (recommended):**

1. Open **Audio MIDI Setup** (`/Applications/Utilities/Audio MIDI Setup.app`).
2. Click **+** (bottom-left) → **Create Multi-Output Device**.
3. In the new device, check **both** *BlackHole 2ch* and your real output
   (e.g. *External Headphones* / your DAC). Keep your real device's clock as
   the primary (master) and enable **Drift Correction** on BlackHole.
4. System Settings → Sound → Output → choose the **Multi-Output Device**.

This duplicates the system audio to both BlackHole (for Auralink to capture)
and your real output.

### Step 3 — Build and launch Auralink

```bash
# from the repo root
scripts/bundle-app.sh
open "build/Auralink EQ.app"
```

Auralink opens the full editor window and also shows a waveform icon in the
menubar. Click the menubar icon to open the compact popover.

### Step 4 — Pick your real output in Auralink

In the Auralink menubar popover (or the full editor's top bar):

1. Confirm Auralink detected the virtual capture device (it auto-selects the
   first device whose name contains *BlackHole* / *Auralink* / *Loopback*). If
   it didn't, you'll see a **"Set up system audio"** notice — recheck Step 2.
2. Set **Output device** to your real headphones / DAC (the device you actually
   listen on). Auralink captures from BlackHole and plays the EQ'd audio here.
3. Toggle **EQ On**. Play some audio — you should hear it, now equalized.

> If you used **Option A** and route Auralink's output back to a device that is
> *also* feeding BlackHole, you'll create a feedback loop. Output to a real
> physical device only.

### Step 5 — Grant the microphone permission

On first launch (or the first time the routing engine starts), macOS prompts
for **microphone** access. Approve it. Audio *input* — which is how Auralink
captures the BlackHole stream — is gated behind the microphone privacy
permission, even though no real mic is involved. (The reason is spelled out in
the app's `NSMicrophoneUsageDescription`.)

If you missed the prompt: System Settings → Privacy & Security → Microphone →
enable **Auralink EQ**, then restart the app.

---

## Part 2 — AI control via the MCP server

The MCP server lets Claude (Desktop) read Auralink's live state and create /
validate / apply tunings. It is a Node + TypeScript process using stdio
transport. It shares the same on-disk preset directory and knowledge data as
the app, and talks to the running app's control server at
`http://127.0.0.1:8765` for live state and apply/rollback. If the app is
offline, read and validate tools still work offline.

The ControlServer requires a random user-only bearer token. Auralink creates it
at `~/Library/Application Support/Auralink/control-token` on first launch, and
the MCP server reads it automatically. Do not copy the token into this config.

### Step 1 — Build the MCP server

```bash
cd mcp-server
npm ci
npm run build
```

This produces the runnable server (e.g. `mcp-server/dist/index.js`). You can
sanity-check it with `npm start`.

### Step 2 — Register it in Claude Desktop

Edit Claude Desktop's config file:

```
~/Library/Application Support/Claude/claude_desktop_config.json
```

Add (or merge) an `auralink-eq` entry under `mcpServers`. Use **absolute
paths**:

```json
{
  "mcpServers": {
    "auralink-eq": {
      "command": "node",
      "args": ["/ABSOLUTE/PATH/TO/auralink-eq/mcp-server/dist/index.js"],
      "env": {
        "AURALINK_DATA_DIR": "/ABSOLUTE/PATH/TO/auralink-eq/mcp-server/data"
      }
    }
  }
}
```

- `AURALINK_CONTROL_URL` — where the app's control server listens (default
  `http://127.0.0.1:8765`). Override only if you changed the port.
- `AURALINK_CONTROL_TOKEN_FILE` — shared token file path. The default matches
  the app; override only for an isolated development environment.
- `AURALINK_CONTROL_TOKEN` — explicit token override. Avoid it in persistent
  client configs; never commit its value.
- `AURALINK_PRESETS_DIR` — the shared preset directory. Defaults to the same
  Application Support location the app uses, so you normally don't need to set
  it; expand `~` to an absolute path if your environment doesn't.
- `AURALINK_DATA_DIR` — the bundled knowledge data (target curves, safety rules).
  The repo ships an identical copy under `mcp-server/data`.
- `AURALINK_COLLECTION_DIR` — your headphone profiles and curated presets. Defaults
  to `~/auralink-collection` for both the app and the server, so you normally don't
  need to set it. Set it only if you keep your collection elsewhere, and set it for
  both. See [DATA_COLLECTION.md](DATA_COLLECTION.md).

### Step 3 — Restart Claude Desktop and verify

Quit and reopen Claude Desktop. The `auralink-eq` tools should appear. Try:

> "What's my current audio state?" → calls `get_current_audio_state`.
> "Make my HD600 punchier for rock but keep vocals clear and avoid harsh
> treble." → builds a validated preset; applying it respects Auralink's
> permission mode and (unless you're in full-control) asks first.

If state tools report the app is offline, make sure **Auralink EQ is running**
(its control server only listens while the app is up). Read-only and validation
tools work regardless.

### Optional — Pi coding agent

This repo also ships a project-local Pi extension at
`.pi/extensions/auralink-mcp.ts`. Pi does not have built-in MCP, so the extension
starts `mcp-server/dist/index.js`, discovers the Auralink MCP tools, and exposes
them in Pi under their original names (`get_agent_eq_guide`,
`upsert_headphone_profile`, `audition_eq_preset`, etc.).

After building the server, trust the project-local extension if Pi asks, then
start/reload Pi from the repo root and run:

```text
/auralink-mcp
```

Use `/auralink-mcp refresh` after rebuilding the MCP server. The bridge only
starts/stops the Node MCP process; it does **not** restart the Auralink EQ app or
interrupt audio. Live-audio tools still require explicit user confirmation.

---

## Troubleshooting

- **No "Set up system audio" cleared / no capture device:** BlackHole isn't
  installed or visible yet — reinstall and reboot, then recheck Step 2.
- **No sound at all:** your system output is BlackHole (Option A) but Auralink
  isn't routing to a real device, or EQ is off. Verify Step 4.
- **Echo / feedback / distortion:** Auralink is outputting to a device that
  also feeds BlackHole. Output to a real physical device only, and prefer a
  Multi-Output Device (Option B).
- **Microphone prompt never appeared:** enable Auralink EQ under System
  Settings → Privacy & Security → Microphone, then restart the app.
- **Clipping indicator is red:** lower the pre-amp (the validator suggests an
  auto pre-amp) or enable Safe Mode, which forces the preamp/clip guard.
- **MCP tools missing in Claude:** check the JSON path is absolute and valid
  (a trailing comma breaks the file), then fully restart Claude Desktop.
