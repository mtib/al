#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

OUT_DIR="${1:-build/icon}"
mkdir -p "${OUT_DIR}"

if [[ -f "${OUT_DIR}/icon.icns" ]]; then
    echo "✓ icon already rendered at ${OUT_DIR}/icon.icns"
    exit 0
fi

echo "→ rendering icon (ear SF Symbol)"
swift tools/make-icon.swift "${OUT_DIR}"
test -f "${OUT_DIR}/icon.icns" || { echo "✗ icon.icns not produced"; exit 1; }
echo "✓ icon at ${OUT_DIR}/icon.icns"
