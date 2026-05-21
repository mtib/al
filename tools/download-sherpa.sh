#!/usr/bin/env bash
# Download sherpa-onnx pre-built dylibs, Silero VAD model, and the ASR models
# used by the in-app picker:
#   * Parakeet TDT-CTC 110M (English)
#   * FastConformer CTC multilingual (EN/DE/ES/FR)
#   * Moonshine Tiny (English, lightest)
# Idempotent: skips downloads when sentinel files already exist.
# Pass --force to re-download everything.
set -euo pipefail
cd "$(dirname "$0")/.."

FORCE="${1:-}"

trap 'rm -rf build/tmp' EXIT

SHERPA_VERSION="${SHERPA_VERSION:-1.12.20}"
SHERPA_PKG="sherpa-onnx-v${SHERPA_VERSION}-osx-universal2-shared"
SHERPA_URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/v${SHERPA_VERSION}/${SHERPA_PKG}.tar.bz2"
PREFIX="build/sherpa-prefix"
MODEL_DIR="build/sherpa-models"

# --- sherpa-onnx libs ---
if [[ "$FORCE" == "--force" ]] || [[ ! -f "${PREFIX}/lib/libsherpa-onnx-c-api.dylib" ]]; then
    if [[ "$FORCE" == "--force" ]]; then
        echo "→ forcing re-download of sherpa-onnx v${SHERPA_VERSION}…"
        rm -rf "${PREFIX}" build/tmp
    else
        echo "→ downloading sherpa-onnx v${SHERPA_VERSION}…"
    fi
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
if [[ "$FORCE" == "--force" ]] || [[ ! -f "${MODEL_DIR}/silero_vad.onnx" ]]; then
    if [[ "$FORCE" == "--force" ]]; then
        echo "→ forcing re-download of silero_vad.onnx…"
        rm -f "${MODEL_DIR}/silero_vad.onnx"
    else
        echo "→ downloading silero_vad.onnx…"
    fi
    curl -fSL "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx" \
         -o "${MODEL_DIR}/silero_vad.onnx.tmp"
    mv "${MODEL_DIR}/silero_vad.onnx.tmp" "${MODEL_DIR}/silero_vad.onnx"
    echo "✓ silero_vad.onnx ($(du -sh "${MODEL_DIR}/silero_vad.onnx" | cut -f1))"
else
    echo "✓ silero_vad.onnx already present"
fi

# --- Stale model cleanup ---
# Drop obsolete model bundles so they don't get shipped into the .app.
rm -rf "${MODEL_DIR}/sherpa-onnx-moonshine-base-en-int8"

# Helper: idempotent download + extract of a sherpa-onnx asr-models tar.bz2.
# Args: <archive-stem> <human-name> <approx-size>
fetch_asr_model() {
    local stem="$1"
    local nice="$2"
    local size="$3"
    local dir="${MODEL_DIR}/${stem}"
    local staging="${MODEL_DIR}/.staging-${stem}"
    local url="https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/${stem}.tar.bz2"
    if [[ "$FORCE" == "--force" ]] || [[ ! -d "${dir}" ]]; then
        if [[ "$FORCE" == "--force" ]]; then
            echo "→ forcing re-download of ${nice} (~${size})…"
            rm -rf "${dir}"
        else
            echo "→ downloading ${nice} (~${size})…"
        fi
        rm -rf "${staging}"
        mkdir -p "${staging}"
        curl -fSL "${url}" | tar xj -C "${staging}"
        mv "${staging}/${stem}" "${dir}"
        rm -rf "${staging}"
        echo "✓ ${stem} ($(du -sh "${dir}" | cut -f1))"
    else
        echo "✓ ${stem} already present"
    fi
}

# --- Parakeet TDT-CTC 110M (English) ---
fetch_asr_model "sherpa-onnx-nemo-parakeet_tdt_ctc_110m-en-36000-int8" "parakeet-tdt-ctc-110m-en-int8" "99 MB"

# --- FastConformer CTC multilingual (EN/DE/ES/FR) ---
fetch_asr_model "sherpa-onnx-nemo-fast-conformer-ctc-en-de-es-fr-14288-int8" "fast-conformer-ctc-en-de-es-fr-int8" "98 MB"

# --- Parakeet TDT 0.6B v3 (English, heavyweight transducer) ---
fetch_asr_model "sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8" "parakeet-tdt-0.6b-v3-int8" "465 MB"

# --- Moonshine Tiny int8 (lightweight English fallback) ---
fetch_asr_model "sherpa-onnx-moonshine-tiny-en-int8" "moonshine-tiny-en-int8" "45 MB"

# --- Patch CSherpa forwarding header ---
mkdir -p Sources/CSherpa/include
cat > Sources/CSherpa/include/c-api.h <<'HEADER'
// Auto-generated forwarding header — re-created by tools/download-sherpa.sh
// Do not edit manually.
#include "../../../build/sherpa-prefix/include/sherpa-onnx/c-api/c-api.h"
HEADER

echo "✓ CSherpa/include/c-api.h updated"
echo "✓ download-sherpa.sh complete"
