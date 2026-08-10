#!/usr/bin/env bash
# Mirror git library/ into Application Support so the installed app loads it.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DEST="${HOME}/Library/Application Support/Auralink/library"
mkdir -p "${DEST}/headphones" "${DEST}/presets"
rsync -a --delete "${REPO_ROOT}/library/headphones/" "${DEST}/headphones/"
rsync -a "${REPO_ROOT}/library/presets/" "${DEST}/presets/"
echo "Synced library → ${DEST}"
echo "  headphones: $(ls "${DEST}/headphones" | wc -l | tr -d ' ')"
echo "  presets:    $(ls "${DEST}/presets" | wc -l | tr -d ' ')"
