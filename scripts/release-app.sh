#!/usr/bin/env bash
# Makes the universal app + signed update pair. Publishing is a separate action.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

# Idempotent: creates the Auralink-specific key once; never rotates a configured key.
swift scripts/update-signing.swift generate
swift scripts/update-signing.swift check

# Match MiSTer FTP's ad-hoc app signing by default. Ed25519 proves update origin.
AURALINK_SIGN_IDENTITY="${AURALINK_SIGN_IDENTITY:--}" scripts/bundle-app.sh --universal
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :version' Resources/Release.plist)"
ARCHIVE="${ROOT}/build/Auralink-EQ-${VERSION}.zip"
rm -f "${ARCHIVE}" "${ARCHIVE}.sig"
ditto -c -k --sequesterRsrc --keepParent "build/Auralink EQ.app" "${ARCHIVE}"
swift scripts/update-signing.swift sign "${ARCHIVE}"
echo "Release files ready:"
echo "  ${ARCHIVE}"
echo "  ${ARCHIVE}.sig"
echo "Publish both files on GitHub with tag v${VERSION}. Mark alpha/beta releases as prereleases."
