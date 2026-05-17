#!/usr/bin/env bash
# Build Al and wrap it into a proper .app bundle.
set -euo pipefail

cd "$(dirname "$0")"

CONFIG="${CONFIG:-release}"
APP_NAME="Al"
APP_DIR="build/${APP_NAME}.app"

./tools/build-whisper.sh

echo "→ swift build -c ${CONFIG}"
swift build -c "${CONFIG}"

BIN_PATH="$(swift build -c "${CONFIG}" --show-bin-path)/${APP_NAME}"

rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"

cp "${BIN_PATH}" "${APP_DIR}/Contents/MacOS/${APP_NAME}"
cp Info.plist "${APP_DIR}/Contents/Info.plist"

MODEL_NAME="${WHISPER_MODEL:-ggml-large-v3-turbo-q5_0.bin}"
cp "build/whisper-models/${MODEL_NAME}" "${APP_DIR}/Contents/Resources/${MODEL_NAME}"

if ./tools/make-icon.sh build/icon 2>/dev/null; then
    cp build/icon/icon.icns "${APP_DIR}/Contents/Resources/icon.icns"
fi

# Reuse LiveTranslate's signing identity env var.
# TCC grants are keyed on (cert identity, bundle ID); Al's bundle ID
# (local.mtib.al) is distinct from LiveTranslate's, so each app gets
# its own grants even when signed with the same cert.
SIGN_IDENTITY="${LIVETRANSLATE_SIGN_IDENTITY:--}"
codesign --force --deep --sign "${SIGN_IDENTITY}" "${APP_DIR}" >/dev/null
if [[ "${SIGN_IDENTITY}" != "-" ]]; then
    echo "  signed with identity: ${SIGN_IDENTITY}"
fi

echo "✓ built ${APP_DIR}"
echo "  run with: open ${APP_DIR}"
