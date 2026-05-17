#!/usr/bin/env bash
# Download sherpa-onnx pre-built dylibs, Silero VAD model, and Moonshine ASR model.
# Idempotent: skips downloads when sentinel files already exist.
set -euo pipefail
cd "$(dirname "$0")/.."

SHERPA_VERSION="${SHERPA_VERSION:-1.12.20}"
SHERPA_PKG="sherpa-onnx-v${SHERPA_VERSION}-osx-universal2-shared"
SHERPA_URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/v${SHERPA_VERSION}/${SHERPA_PKG}.tar.bz2"
PREFIX="build/sherpa-prefix"
MODEL_DIR="build/sherpa-models"

# --- sherpa-onnx libs ---
if [[ ! -f "${PREFIX}/lib/libsherpa-onnx-c-api.dylib" ]]; then
    echo "→ downloading sherpa-onnx v${SHERPA_VERSION}…"
    mkdir -p build/tmp
    curl -fSL "$SHERPA_URL" | tar xj -C build/tmp
    mkdir -p "${PREFIX}"
    cp -r "build/tmp/${SHERPA_PKG}/include" "${PREFIX}/"
    cp -r "build/tmp/${SHERPA_PKG}/lib"     "${PREFIX}/"
    rm -rf build/tmp
    echo "✓ sherpa-onnx libs at ${PREFIX}/"
else
    echo "✓ sherpa-onnx libs already present (pass --force to re-download)"
fi

# --- Silero VAD model ---
mkdir -p "${MODEL_DIR}"
if [[ ! -f "${MODEL_DIR}/silero_vad.onnx" ]]; then
    echo "→ downloading silero_vad.onnx…"
    curl -fSL "https://github.com/snakers4/silero-vad/raw/master/src/silero_vad/data/silero_vad.onnx" \
         -o "${MODEL_DIR}/silero_vad.onnx"
    echo "✓ silero_vad.onnx ($(du -sh "${MODEL_DIR}/silero_vad.onnx" | cut -f1))"
else
    echo "✓ silero_vad.onnx already present"
fi

# --- Moonshine base en int8 ---
MOONSHINE_DIR="${MODEL_DIR}/sherpa-onnx-moonshine-base-en-int8"
if [[ ! -d "${MOONSHINE_DIR}" ]]; then
    echo "→ downloading moonshine-base-en-int8…"
    curl -fSL "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-moonshine-base-en-int8.tar.bz2" \
         | tar xj -C "${MODEL_DIR}"
    echo "✓ moonshine-base-en-int8 ($(du -sh "${MOONSHINE_DIR}" | cut -f1))"
else
    echo "✓ moonshine-base-en-int8 already present"
fi

# --- Patch CSherpa forwarding header ---
mkdir -p Sources/CSherpa/include
cat > Sources/CSherpa/include/c-api.h <<'HEADER'
// Auto-generated forwarding header — re-created by tools/download-sherpa.sh
// Do not edit manually.
#include "../../build/sherpa-prefix/include/sherpa-onnx/c-api/c-api.h"
HEADER

echo "✓ CSherpa/include/c-api.h updated"
echo "✓ download-sherpa.sh complete"
