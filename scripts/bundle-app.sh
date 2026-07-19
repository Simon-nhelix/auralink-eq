#!/usr/bin/env bash
#
# bundle-app.sh — build a release binary and assemble a runnable
# "Auralink EQ.app" macOS application bundle.
#
# What this does, in order:
#   1. `swift build -c release` in the repo root.
#   2. Create build/Auralink EQ.app/Contents/{MacOS,Resources}.
#   3. Copy the built `AuralinkApp` binary into Contents/MacOS.
#   4. Copy the SwiftPM-generated AuralinkCore resource bundle next to it
#      (the app loads bundled JSON via Bundle.module).
#   5. Copy the app icon and setup guide into Contents/Resources.
#   6. Generate Contents/Info.plist (regular app with menubar extra, mic usage,
#      bundle id, min OS).
#   7. Ad-hoc codesign the whole bundle so Gatekeeper lets it run locally.
#   8. Print how to run it and the next setup steps.
#
# This is a workflow script, so it must be deterministic: no UUID()/Date()
# baked into the bundle, no network calls.
set -euo pipefail

# --- Locations -------------------------------------------------------------
# Resolve the repo root from this script's location so the build works no
# matter where it is invoked from.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

APP_NAME="Auralink EQ"
EXECUTABLE="AuralinkApp"
BUNDLE_ID="com.auralink.eq"
MIN_MACOS="14.0"
ICON_FILE="AuralinkAppIcon.icns"
APP_VERSION="0.1.0"
RELEASE_CHANNEL="alpha"

BUILD_DIR="${REPO_ROOT}/build"
APP_DIR="${BUILD_DIR}/${APP_NAME}.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
APP_ICON="${REPO_ROOT}/assets/AppIcon/${ICON_FILE}"
SETUP_GUIDE="${REPO_ROOT}/docs/SETUP.md"

# --- 1. Build --------------------------------------------------------------
echo "==> Building ${EXECUTABLE} (release)…"
swift build -c release --package-path "${REPO_ROOT}"

# Ask SwiftPM where it put the release products rather than guessing the
# arch-specific path (works on Apple Silicon and Intel alike).
RELEASE_BIN_DIR="$(swift build -c release --package-path "${REPO_ROOT}" --show-bin-path)"
BUILT_BINARY="${RELEASE_BIN_DIR}/${EXECUTABLE}"

if [[ ! -x "${BUILT_BINARY}" ]]; then
    echo "error: built binary not found at ${BUILT_BINARY}" >&2
    exit 1
fi

# --- 2. Assemble the bundle skeleton --------------------------------------
echo "==> Assembling ${APP_NAME}.app…"
rm -rf "${APP_DIR}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"

# --- 3. Copy the executable -----------------------------------------------
cp "${BUILT_BINARY}" "${MACOS_DIR}/${EXECUTABLE}"
chmod +x "${MACOS_DIR}/${EXECUTABLE}"

# --- 4. Copy the AuralinkCore resource bundle into Contents/Resources ------
# SwiftPM emits a bundle named "<Package>_<Target>.bundle"
# (e.g. Auralink_AuralinkCore.bundle). For an executable target, the generated
# Bundle.module accessor resolves it via Bundle.main.resourceURL — i.e. it must
# live in Contents/Resources, NOT Contents/MacOS (codesign also rejects a
# nested bundle placed inside MacOS).
CORE_BUNDLE=""
for candidate in "${RELEASE_BIN_DIR}"/*AuralinkCore*.bundle; do
    if [[ -d "${candidate}" ]]; then
        CORE_BUNDLE="${candidate}"
        break
    fi
done

if [[ -n "${CORE_BUNDLE}" ]]; then
    cp -R "${CORE_BUNDLE}" "${RESOURCES_DIR}/"
    echo "    bundled resources: $(basename "${CORE_BUNDLE}")"
else
    echo "    warning: no AuralinkCore_*.bundle found; the app will fall back" >&2
    echo "             to seeding knowledge data from ${HOME}/Library/Application Support/Auralink/data" >&2
fi

# --- 5. Copy the app icon ---------------------------------------------------
if [[ -f "${APP_ICON}" ]]; then
    cp "${APP_ICON}" "${RESOURCES_DIR}/${ICON_FILE}"
    echo "    app icon: ${ICON_FILE}"
else
    echo "    warning: app icon not found at ${APP_ICON}; macOS will use the default icon" >&2
fi

if [[ -f "${SETUP_GUIDE}" ]]; then
    cp "${SETUP_GUIDE}" "${RESOURCES_DIR}/SETUP.md"
    echo "    setup guide: SETUP.md"
else
    echo "    warning: setup guide not found at ${SETUP_GUIDE}" >&2
fi

# --- 6. Generate Info.plist -----------------------------------------------
# NSMicrophoneUsageDescription is required because system-audio capture goes
# through an input device, which macOS gates behind the microphone privacy
# permission. The app does not start capture at launch; permission is requested
# only when live routing is explicitly started.
#
# LSEnvironment / SWIFT_IS_CURRENT_EXECUTOR_LEGACY_MODE_OVERRIDE=legacy:
# macOS 26 DesignLibrary/SwiftUI executor-check crash mitigation (Swift
# #87097/#89197) — system-compiled framework code hands the concurrency
# runtime a bogus SerialExecutorRef during backgrounded layout passes.
# "legacy" selects the pre-Swift-6, non-asserting isCurrentExecutor behavior
# process-wide. Belt-and-braces alongside AppModel's UI publish gate. Note it
# only applies to LaunchServices launches (open / Finder), not swift-run.
#
# CAUTION: this heredoc is UNQUOTED so ${VARS} expand — which means $(...)
# and backticks inside it EXECUTE. Keep prose comments up here, not in the
# XML (a backticked command in an XML comment once launched a stray debug
# app from inside the bundling run).
cat > "${CONTENTS_DIR}/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key>
    <string>${EXECUTABLE}</string>
    <key>CFBundleIconFile</key>
    <string>${ICON_FILE}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleShortVersionString</key>
    <string>${APP_VERSION}</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>AuralinkReleaseChannel</key>
    <string>${RELEASE_CHANNEL}</string>
    <key>LSMinimumSystemVersion</key>
    <string>${MIN_MACOS}</string>
    <key>LSUIElement</key>
    <false/>
    <key>LSEnvironment</key>
    <dict>
        <key>SWIFT_IS_CURRENT_EXECUTOR_LEGACY_MODE_OVERRIDE</key>
        <string>legacy</string>
    </dict>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Auralink EQ captures system audio through a virtual loopback input device (such as BlackHole) so it can apply equalization before sending sound to your headphones. macOS classifies this audio input as microphone access.</string>
</dict>
</plist>
PLIST

# Fail the build before signing if privacy metadata or the macOS 26 runtime
# mitigation is ever removed accidentally. Missing microphone usage text makes
# TCC terminate the app with SIGABRT as soon as live capture requests access.
echo "==> Validating bundle metadata…"
/usr/bin/plutil -lint "${CONTENTS_DIR}/Info.plist" >/dev/null
# Tolerate a missing key here (2>/dev/null || true) so the checks below can
# emit their friendly, specific error instead of `set -e` aborting on a raw
# PlistBuddy failure.
PLIST_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${CONTENTS_DIR}/Info.plist" 2>/dev/null || true)"
MIC_USAGE="$(/usr/libexec/PlistBuddy -c 'Print :NSMicrophoneUsageDescription' "${CONTENTS_DIR}/Info.plist" 2>/dev/null || true)"
EXECUTOR_MODE="$(/usr/libexec/PlistBuddy -c 'Print :LSEnvironment:SWIFT_IS_CURRENT_EXECUTOR_LEGACY_MODE_OVERRIDE' "${CONTENTS_DIR}/Info.plist" 2>/dev/null || true)"
if [[ "${PLIST_BUNDLE_ID}" != "${BUNDLE_ID}" ]]; then
    echo "error: unexpected bundle identifier: ${PLIST_BUNDLE_ID}" >&2
    exit 1
fi
if [[ -z "${MIC_USAGE//[[:space:]]/}" ]]; then
    echo "error: NSMicrophoneUsageDescription must be a non-empty string" >&2
    exit 1
fi
if [[ "${EXECUTOR_MODE}" != "legacy" ]]; then
    echo "error: missing macOS 26 executor-check mitigation in LSEnvironment" >&2
    exit 1
fi

# A minimal PkgInfo keeps Launch Services happy for a classic .app.
printf 'APPL????' > "${CONTENTS_DIR}/PkgInfo"

# --- 7. Codesign (inside-out) -----------------------------------------------
# Prefer a stable local identity ("Auralink Dev Signing", create one with
# scripts/setup-dev-signing.sh; override via $AURALINK_SIGN_IDENTITY): a stable
# identity keeps the TCC microphone grant across rebuilds. Ad-hoc ("-s -")
# otherwise — that re-prompts for the mic permission on every rebuild.
# NOTE: the SwiftPM resource bundle has no Info.plist, so it is NOT a code
# bundle — it is sealed as plain resources by the app signature. We therefore
# do NOT sign it directly (codesign would reject it) and do NOT use --deep
# (which would try to). Sign the executable, then the app wrapper.
SIGN_IDENTITY="${AURALINK_SIGN_IDENTITY:-Auralink Dev Signing}"
# Sign by the identity's SHA-1 hash, not its name: the trust-setup flow leaves
# both the identity and a bare trusted copy of its certificate in the keychain,
# and codesign refuses a name that matches more than one entry ("ambiguous").
SIGN_ID="$(security find-identity -v -p codesigning 2>/dev/null \
  | awk -v id="${SIGN_IDENTITY}" '$0 ~ id { print $2; exit }')"
if [ -n "${SIGN_ID}" ]; then
  echo "==> Codesigning with identity: ${SIGN_IDENTITY} (${SIGN_ID})"
else
  SIGN_ID="-"
  echo "==> Ad-hoc codesigning (no stable identity; run scripts/setup-dev-signing.sh once to fix the permission re-prompts)…"
fi
codesign -s "${SIGN_ID}" --force --timestamp=none "${MACOS_DIR}/${EXECUTABLE}"
codesign -s "${SIGN_ID}" --force --timestamp=none "${APP_DIR}"
codesign --verify --strict "${APP_DIR}" && echo "    signature verified."

# --- 8. Next steps ---------------------------------------------------------
cat <<NEXT

==> Done.

Built bundle:
    ${APP_DIR}

Run it:
    open "${APP_DIR}"
  or directly (to see stdout/logs):
    "${MACOS_DIR}/${EXECUTABLE}"

The app opens a normal editor window and also shows a waveform icon in the
menubar. Launching it does not start audio capture or change your Mac output.

Next steps:
  1. Set up system-audio routing (BlackHole). See docs/SETUP.md.
  2. Pick your real output device inside Auralink so processed audio reaches
     your headphones.
  3. Click Start System EQ only when you are ready to grant microphone
     permission and route system sound through Auralink.
  4. Wire the MCP server into an AI client so it can read state and create/apply
     tunings. See docs/SETUP.md and README.md.

To install it for everyday use, drag the .app into /Applications:
    cp -R "${APP_DIR}" /Applications/
NEXT
