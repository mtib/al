#!/usr/bin/env bash
# One-time setup: install cmake if missing, pre-download the GGML model.
set -euo pipefail

cd "$(dirname "$0")"

if ! command -v cmake >/dev/null 2>&1; then
    echo "Installing cmake via Homebrew..."
    brew install cmake
fi

mkdir -p models
MODEL="ggml-large-v3-turbo-q5_0.bin"
URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/${MODEL}"

if [[ -s "models/${MODEL}" ]]; then
    echo "✓ ${MODEL} already cached"
else
    echo "→ downloading ${MODEL} (~570 MB)"
    curl -L --fail --progress-bar -o "models/${MODEL}.partial" "${URL}"
    mv "models/${MODEL}.partial" "models/${MODEL}"
fi

echo "✓ dev-setup complete."
